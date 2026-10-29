import Testing
@testable import Canopy

@MainActor
struct SetupProgressTests {
    @Test func countsDoneStepsAndNeedsOnlyTheFirstTwo() {
        var s = SetupState()
        #expect(s.doneCount == 0 && !s.requiredDone && !s.isComplete)
        s.website = true
        #expect(!s.requiredDone, "captions need an input too")
        s.audio = true
        #expect(s.requiredDone && s.doneCount == 2 && !s.isComplete)
        s.planningCenter = true; s.device = true; s.automation = true
        #expect(s.isComplete)
    }

    @Test func menuOffersSetupUntilFinishedOrDismissed() {
        var s = SetupState(website: true, audio: true)
        #expect(SetupProgress.menuShouldOffer(s, dismissed: false))
        #expect(!SetupProgress.menuShouldOffer(s, dismissed: true))
        s = SetupState(website: true, audio: true, planningCenter: true, device: true, automation: true)
        #expect(!SetupProgress.menuShouldOffer(s, dismissed: false))
    }

    @Test func opensItselfOnlyOnceAndOnlyWhenARequiredStepIsMissing() {
        let fresh = SetupState()
        #expect(SetupProgress.shouldAutoOpen(fresh, dismissed: false, alreadyOpened: false))
        #expect(!SetupProgress.shouldAutoOpen(fresh, dismissed: false, alreadyOpened: true))
        #expect(!SetupProgress.shouldAutoOpen(fresh, dismissed: true, alreadyOpened: false))
        #expect(!SetupProgress.shouldAutoOpen(SetupState(website: true, audio: true), dismissed: false, alreadyOpened: false),
                "a Mac that was already set up is left alone")
    }
}
