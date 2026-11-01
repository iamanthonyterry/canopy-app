import Foundation
import Testing
@testable import Canopy

@MainActor
struct ProToolsStepTests {
    @Test func stepsSurviveSaveAndLoad() throws {
        for action in [StepAction.proToolsOpenInsert(track: "Pastor", slot: "C"), .proToolsSelectPreset(preset: "Warm Voice")] {
            let data = try JSONEncoder().encode(WorkflowStep(action: action))
            #expect(try JSONDecoder().decode(WorkflowStep.self, from: data).action == action)
        }
    }

    @Test func kindsDontNeedFilesOrADestination() {
        for kind in [StepKind.proToolsOpenInsert, .proToolsSelectPreset] {
            #expect(!kind.worksOnFiles)
            #expect(StepAction.defaultAction(for: kind).kind == kind)
        }
    }

    @Test func namesAreEscapedInTheScript() {
        let script = ProToolsRunner.openInsertScript(track: "The \"Boss\" \\ Mic", slot: "b")
        #expect(script.contains("\"The \\\"Boss\\\" \\\\ Mic\""))
        #expect(script.contains("Insert B"))
    }

    @Test func emptyNamesAreRefused() async {
        await #expect(throws: AppleScriptRunner.Failure.self) { try await ProToolsRunner.openInsert(track: " ", slot: "A") }
        await #expect(throws: AppleScriptRunner.Failure.self) { try await ProToolsRunner.openInsert(track: "Pastor", slot: "Z") }
        await #expect(throws: AppleScriptRunner.Failure.self) { try await ProToolsRunner.selectPreset("") }
    }

    @Test func reviewFlagsMissingNames() {
        let workflow = Workflow(name: "t", steps: [WorkflowStep(action: .proToolsOpenInsert(track: "", slot: "A")),
                                                   WorkflowStep(action: .proToolsSelectPreset(preset: ""))])
        let texts = WorkflowReview.items(for: workflow).map(\.text)
        #expect(texts.contains { $0.contains("Open Insert") && $0.contains("no track name") })
        #expect(texts.contains { $0.contains("Select Preset") && $0.contains("no preset name") })
    }
}
