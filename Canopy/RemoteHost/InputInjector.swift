import ApplicationServices
import CoreGraphics
import Foundation

/// Turns viewer input into real mouse and keyboard events on this Mac. Needs the Accessibility permission.
nonisolated enum InputInjector {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security > Accessibility.
    static func requestTrust() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func apply(_ input: RemoteInput) {
        guard isTrusted else { return }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        func point() -> CGPoint? {
            guard let x = input.x, let y = input.y else { return nil }
            return CGPoint(x: bounds.minX + min(max(x, 0), 1) * bounds.width,
                           y: bounds.minY + min(max(y, 0), 1) * bounds.height)
        }
        let src = CGEventSource(stateID: .hidSystemState)
        let right = input.button == 1
        func post(_ e: CGEvent?) {
            if let f = input.flags { e?.flags = CGEventFlags(rawValue: f) }
            if let p = input.pressure { e?.setDoubleValueField(.mouseEventPressure, value: p) }
            if let c = input.clickCount { e?.setIntegerValueField(.mouseEventClickState, value: Int64(c)) }
            e?.post(tap: .cghidEventTap)
        }
        switch input.kind {
        case "move":
            guard let p = point() else { return }
            post(CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
        case "down", "up":
            guard let p = point() else { return }
            let down = input.kind == "down"
            let type: CGEventType = right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp)
            post(CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: right ? .right : .left))
        case "drag":
            guard let p = point() else { return }
            let type: CGEventType = right ? .rightMouseDragged : .leftMouseDragged
            post(CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: right ? .right : .left))
        case "scroll":
            CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                    wheel1: Int32(input.dy ?? 0), wheel2: Int32(input.dx ?? 0), wheel3: 0)?.post(tap: .cghidEventTap)
        case "key":
            guard let code = input.keyCode else { return }
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: input.down ?? true)
            post(e)
        case "text":
            guard let text = input.text else { return }
            let units = Array(text.utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                e?.post(tap: .cghidEventTap)
            }
        default: break
        }
    }
}
