import Foundation

/// How far along a Mac is with the first things Canopy needs: the website, a working audio input, and (optionally)
/// Planning Center, a device and an automation. Drives the Set Up window and the menu item that reopens it.
struct SetupState: Equatable {
    var website = false
    var audio = false
    var planningCenter = false
    var device = false
    var automation = false

    static let total = 5

    var doneCount: Int { [website, audio, planningCenter, device, automation].filter { $0 }.count }
    /// Live captions need these two; the rest are optional.
    var requiredDone: Bool { website && audio }
    var isComplete: Bool { doneCount == Self.total }
}

@MainActor
enum SetupProgress {
    static let dismissedKey = "setup.dismissed"
    static let audioCheckedKey = "setup.audioChecked"
    private static let openedKey = "setup.autoOpened"

    static var isDismissed: Bool { UserDefaults.standard.bool(forKey: dismissedKey) }

    static func dismiss() { UserDefaults.standard.set(true, forKey: dismissedKey) }

    /// Reads the current state. An input counts as ready once a person picked a device for it or a level check passed.
    static func state(model: AppModel, appState: AppState = .shared) -> SetupState {
        SetupState(
            website: !model.token.isEmpty,
            audio: UserDefaults.standard.bool(forKey: audioCheckedKey) || model.settings.inputs.contains { $0.device != nil },
            planningCenter: model.pcoSignedIn,
            device: !(appState.hyperDecks.isEmpty && appState.cloudStores.isEmpty && appState.localFolders.isEmpty),
            automation: !appState.workflows.isEmpty)
    }

    /// Whether the menu should offer the Set Up window: until it's finished or put away.
    static func menuShouldOffer(_ state: SetupState, dismissed: Bool) -> Bool { !dismissed && !state.isComplete }

    /// Opens by itself, once, on a Mac that still needs the required steps (a Mac already set up never sees it).
    static func shouldAutoOpen(_ state: SetupState, dismissed: Bool, alreadyOpened: Bool) -> Bool {
        !dismissed && !alreadyOpened && !state.requiredDone
    }

    static func claimAutoOpen(model: AppModel) -> Bool {
        let defaults = UserDefaults.standard
        guard shouldAutoOpen(state(model: model), dismissed: isDismissed, alreadyOpened: defaults.bool(forKey: openedKey)) else { return false }
        defaults.set(true, forKey: openedKey)
        return true
    }
}
