import AppKit
import Foundation
import Testing
@testable import Canopy

@MainActor
struct MenuAndTranscriptTests {
    private func line(_ text: String, _ translations: [String: String] = [:]) -> TranscriptLine {
        TranscriptLine(start: .now, end: .now, text: text, translations: translations)
    }

    @Test func menuBarIconColourFollowsWhatTheAppIsDoing() {
        #expect(AppModel.tint(feedWarning: nil, listening: false, running: false) == nil, "stopped: plain icon")
        #expect(AppModel.tint(feedWarning: nil, listening: false, running: true) == .systemYellow)
        #expect(AppModel.tint(feedWarning: nil, listening: true, running: true) == .systemRed)
        #expect(AppModel.tint(feedWarning: "silent", listening: true, running: true) == .systemOrange, "a warning wins")
    }

    @Test func searchMatchesTheLanguageBeingShown() {
        let lines = [line("Welcome everyone", ["es": "Bienvenidos a todos"]), line("Open your Bibles")]
        #expect(TranscriptFilter.visible(lines, query: "bibles", language: "").count == 1)
        #expect(TranscriptFilter.visible(lines, query: "bienvenidos", language: "es").count == 1)
        #expect(TranscriptFilter.visible(lines, query: "bienvenidos", language: "").isEmpty, "the English text doesn't contain it")
        #expect(TranscriptFilter.visible(lines, query: "  ", language: "").count == 2, "a blank search shows everything")
    }

    @Test func aMissingTranslationFallsBackToTheOriginal() {
        #expect(TranscriptFilter.text(of: line("Hello"), language: "fr") == "Hello")
    }

    @Test func textSizeStaysInRange() {
        #expect(TranscriptFilter.clamped(2) == 11)
        #expect(TranscriptFilter.clamped(200) == 60)
        #expect(TranscriptFilter.clamped(24) == 24)
    }

    @Test func settingsCompareEqualOnlyWhenNothingChanged() {
        var a = Settings()
        let b = a
        #expect(a == b, "leaving Settings with no change must not restart the transcript")
        a.inputs.append(AudioInput())
        #expect(a != b)
    }
}
