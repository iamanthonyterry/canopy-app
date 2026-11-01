import Foundation
import Testing
@testable import Canopy

@MainActor
struct AppleScriptStepTests {
    @Test func stepSurvivesSaveAndLoad() throws {
        let action = StepAction.runAppleScript(script: "tell application \"Finder\"\nactivate\nend tell", timeoutSeconds: 30)
        let data = try JSONEncoder().encode(Workflow(name: "Show Finder", steps: [WorkflowStep(action: action)]))
        let loaded = try JSONDecoder().decode(Workflow.self, from: data)
        #expect(loaded.steps.map(\.kind) == [.runAppleScript])
        #expect(loaded.steps[0].action == action)
    }

    @Test func missingFieldsFallBackToDefaults() throws {
        let json = #"{"runAppleScript":{}}"#.data(using: .utf8)!
        let action = try JSONDecoder().decode(StepAction.self, from: json)
        #expect(action == .runAppleScript(script: "", timeoutSeconds: AppleScriptRunner.defaultTimeoutSeconds))
    }

    @Test func summaryNamesTheFirstLine() {
        #expect(StepAction.runAppleScript(script: "", timeoutSeconds: 60).summary == "No script written yet")
        #expect(StepAction.runAppleScript(script: "\n  beep 2\n", timeoutSeconds: 1).summary == "Runs \"beep 2\" · stops after 1 second")
    }

    @Test func emptyScriptIsFlaggedBeforeARun() {
        let workflow = Workflow(name: "Empty", steps: [WorkflowStep(action: .runAppleScript(script: "  ", timeoutSeconds: 10))])
        #expect(WorkflowReview.items(for: workflow).contains { $0.text.contains("Run AppleScript") })
    }

    @Test func returnsTheScriptsResult() async throws {
        #expect(try await AppleScriptRunner.run("return 6 * 7", timeoutSeconds: 10) == "42")
    }

    @Test func reportsTheScriptsOwnError() async {
        do {
            _ = try await AppleScriptRunner.run("error \"nope\" number 5", timeoutSeconds: 10)
            Issue.record("expected the script to fail")
        } catch {
            #expect(error.localizedDescription.contains("nope"))
        }
    }

    @Test func stopsAScriptThatOverruns() async {
        let started = Date()
        do {
            _ = try await AppleScriptRunner.run("delay 30", timeoutSeconds: 1)
            Issue.record("expected a timeout")
        } catch {
            #expect(error.localizedDescription.contains("1 second"))
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func emptyScriptIsRefused() async {
        await #expect(throws: AppleScriptRunner.Failure.self) { try await AppleScriptRunner.run("  \n", timeoutSeconds: 5) }
    }
}
