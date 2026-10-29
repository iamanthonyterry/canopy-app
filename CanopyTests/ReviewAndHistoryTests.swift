import Foundation
import Testing
@testable import Canopy

@MainActor
struct ReviewAndHistoryTests {
    private func run(_ name: String, errors: Int = 0, id: UUID? = nil, decks: [String] = []) -> WorkflowRun {
        var r = WorkflowRun(workflowName: name, startedAt: .now, finishedAt: .now, processed: 1, errors: errors, decksProcessed: decks, log: [])
        r.workflowID = id
        return r
    }

    @Test func reviewWarnsAboutDestructiveStepsWithoutConfirmation() {
        let w = Workflow(name: "X", steps: [WorkflowStep(action: .format), WorkflowStep(action: .cleanup(retentionDays: 7), requiresConfirmation: true)])
        let texts = WorkflowReview.items(for: w, offlineDeckNames: ["ISO 1"]).map(\.text)
        #expect(texts.contains("Step 1 erases the device's drive."))
        #expect(texts.contains("Step 1 runs without asking for confirmation first."))
        #expect(texts.contains("Step 2 deletes files older than 7 days from the destination folder."))
        #expect(!texts.contains("Step 2 runs without asking for confirmation first."))
        #expect(texts.contains("ISO 1 is offline right now."))
    }

    @Test func emptyAndIncompleteStepsAreFlagged() {
        #expect(WorkflowReview.items(for: Workflow(name: "E")).contains { $0.text == "This automation has no steps." })
        let w = Workflow(name: "W", steps: [WorkflowStep(action: .webhook(url: " ", format: .json)), WorkflowStep(action: .triggerWorkflow(workflowID: nil, waitForCompletion: false))])
        let texts = WorkflowReview.items(for: w).map(\.text)
        #expect(texts.contains("Step 1 (Send Webhook) has no URL."))
        #expect(texts.contains("Step 2 (Trigger Automation) has no automation chosen."))
    }

    @Test func templatesBuildRunnableDrafts() {
        for t in WorkflowTemplate.all {
            let w = t.make()
            #expect(!w.steps.isEmpty && w.name == t.name)
        }
        #expect(WorkflowTemplate.all.first { $0.name == "Weekly cleanup" }?.make().steps.first?.requiresConfirmation == true)
    }

    @Test func lastRunFollowsTheIdThenFallsBackToName() {
        let a = Workflow(name: "Offload"), b = Workflow(name: "Offload")
        let mine = run("Offload", id: a.id), theirs = run("Offload", id: b.id), old = run("Offload")
        #expect(WorkflowRun.latest(for: a, in: [theirs, mine, old])?.id == mine.id)
        #expect(WorkflowRun.latest(for: a, in: [theirs]) == nil, "another automation with the same name is not this one")
        #expect(WorkflowRun.latest(for: a, in: [old])?.id == old.id, "an old run without an id matches by name")
    }

    @Test func historyFilterSearchesNamesAndDevices() {
        let runs = [run("Sunday", errors: 0, decks: ["ISO 1"]), run("Cleanup", errors: 2)]
        #expect(WorkflowRun.filter(runs, query: "sun", onlyErrors: false).count == 1)
        #expect(WorkflowRun.filter(runs, query: "iso", onlyErrors: false).count == 1)
        #expect(WorkflowRun.filter(runs, query: "", onlyErrors: true).map(\.workflowName) == ["Cleanup"])
    }

    @Test func csvEscapesCommasAndQuotes() {
        let csv = WorkflowRun.csv([run("A, \"B\"", errors: 1, decks: ["x", "y"])])
        #expect(csv.hasPrefix("Automation,Started,Finished,Duration,Processed,Errors,Devices\n\"A, \"\"B\"\"\","))
        #expect(csv.contains(",x; y\n"))
    }
}
