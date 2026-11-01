import Foundation

/// Drives Pro Tools the way a person would, through macOS Accessibility (System Events), because
/// Pro Tools' scripting API (PTSL) can't open plugin windows or recall presets. Each action builds an
/// AppleScript that finds things by name, acts, reads the result back, and fails with a clear message
/// rather than clicking blindly. Needs Canopy to be allowed under Privacy & Security > Accessibility.
nonisolated enum ProToolsRunner {
    static let defaultTimeoutSeconds = 30
    static let insertSlots = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"]

    /// Quotes `text` as an AppleScript string literal.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    // Shared handlers. `allElements` walks a window's whole accessibility tree; `matches` compares the
    // title, description and value an element exposes against the wanted name.
    private static let prelude = """
    on elementText(el)
        tell application "System Events"
            set parts to {}
            repeat with attr in {"AXTitle", "AXDescription", "AXValue"}
                try
                    set v to value of attribute (contents of attr) of el
                    if v is not missing value then set end of parts to (v as text)
                end try
            end repeat
        end tell
        return parts
    end elementText

    on matches(el, wanted)
        repeat with t in my elementText(el)
            if (contents of t) is wanted then return true
        end repeat
        return false
    end matches

    on findElement(root, wanted, roleName)
        tell application "System Events"
            set found to missing value
            try
                set candidates to entire contents of root
            on error
                return missing value
            end try
            repeat with el in candidates
                try
                    if (role of el) is roleName and my matches(el, wanted) then return el
                end try
            end repeat
        end tell
        return missing value
    end findElement

    tell application "System Events"
        if not (exists process "Pro Tools") then error "Pro Tools isn't running"
    end tell
    """

    /// Opens insert `slot` (A–J) on the track called `track`, in the Mix window.
    static func openInsertScript(track: String, slot: String) -> String {
        let trackName = literal(clean(track)), slotName = clean(slot).uppercased()
        return """
        \(prelude)
        tell application "Pro Tools" to activate
        tell application "System Events"
            tell process "Pro Tools"
                set mixWindow to missing value
                repeat with w in windows
                    if (name of w) starts with "Mix" then set mixWindow to w
                end repeat
                if mixWindow is missing value then error "The Mix window isn't open in Pro Tools"
                set strip to my findElement(mixWindow, \(trackName), "AXGroup")
                if strip is missing value then error "No track called " & \(trackName) & " in the Mix window"
                set insertButton to my findElement(strip, "Insert \(slotName)", "AXButton")
                if insertButton is missing value then error "Track " & \(trackName) & " has no insert \(slotName)"
                click insertButton
            end tell
        end tell
        return "Opened insert \(slotName) on " & \(trackName)
        """
    }

    /// Picks `preset` from the preset menu in the header of the frontmost plugin window, then reads the
    /// header back to confirm it took.
    static func selectPresetScript(preset: String) -> String {
        let presetName = literal(clean(preset))
        return """
        \(prelude)
        tell application "System Events"
            tell process "Pro Tools"
                set pluginWindow to missing value
                repeat with w in windows
                    if (subrole of w) is "AXFloatingWindow" or (subrole of w) is "AXStandardWindow" then
                        if (name of w) does not start with "Mix" and (name of w) does not start with "Edit" then set pluginWindow to w
                    end if
                end repeat
                if pluginWindow is missing value then error "No plugin window is open in Pro Tools"
                set presetMenu to my findElement(pluginWindow, "Settings", "AXPopUpButton")
                if presetMenu is missing value then set presetMenu to first pop up button of pluginWindow
                click presetMenu
                delay 0.3
                set chosen to missing value
                repeat with item_ in (entire contents of menu 1 of presetMenu)
                    try
                        if (role of item_) is "AXMenuItem" and (name of item_) is \(presetName) then set chosen to item_
                    end try
                end repeat
                if chosen is missing value then
                    key code 53
                    error "The plugin has no preset called " & \(presetName)
                end if
                click chosen
                delay 0.3
                set shown to ""
                try
                    set shown to (value of presetMenu) as text
                end try
                if shown is not "" and shown is not \(presetName) then error "Chose the preset but the plugin shows \\"" & shown & "\\""
            end tell
        end tell
        return "Preset set to " & \(presetName)
        """
    }

    static func openInsert(track: String, slot: String, timeoutSeconds: Int = defaultTimeoutSeconds) async throws -> String {
        guard !clean(track).isEmpty else { throw AppleScriptRunner.Failure(message: "no track name was given") }
        guard insertSlots.contains(clean(slot).uppercased()) else { throw AppleScriptRunner.Failure(message: "the insert must be A to J") }
        return try await AppleScriptRunner.run(openInsertScript(track: track, slot: clean(slot).uppercased()), timeoutSeconds: timeoutSeconds)
    }

    static func selectPreset(_ preset: String, timeoutSeconds: Int = defaultTimeoutSeconds) async throws -> String {
        guard !clean(preset).isEmpty else { throw AppleScriptRunner.Failure(message: "no preset name was given") }
        return try await AppleScriptRunner.run(selectPresetScript(preset: preset), timeoutSeconds: timeoutSeconds)
    }
}
