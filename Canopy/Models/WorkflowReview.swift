import Foundation

/// A plain-language check of an automation before it runs: what it will erase or delete, what is missing, and which
/// devices are down. Nothing here runs the automation.
enum WorkflowReview {
    struct Item: Equatable, Identifiable {
        enum Severity { case warning, info }
        var severity: Severity
        var text: String
        var id: String { "\(severity)-\(text)" }
    }

    static func items(for workflow: Workflow, offlineDeckNames: [String] = []) -> [Item] {
        var out: [Item] = []
        if workflow.steps.isEmpty { out.append(Item(severity: .warning, text: "This automation has no steps.")) }
        for (i, step) in workflow.steps.enumerated() {
            let n = i + 1
            switch step.action {
            case .format:
                out.append(Item(severity: .warning, text: "Step \(n) erases the device's drive."))
                if !step.requiresConfirmation { out.append(Item(severity: .warning, text: "Step \(n) runs without asking for confirmation first.")) }
            case .cleanup(let days):
                out.append(Item(severity: .warning, text: "Step \(n) deletes files older than \(days) day\(days == 1 ? "" : "s") from the destination folder."))
                if !step.requiresConfirmation { out.append(Item(severity: .warning, text: "Step \(n) runs without asking for confirmation first.")) }
            case .webhook(let url, _) where url.trimmingCharacters(in: .whitespaces).isEmpty:
                out.append(Item(severity: .warning, text: "Step \(n) (Send Webhook) has no URL."))
            case .notify(_, _, let recipients, _) where recipients.isEmpty:
                out.append(Item(severity: .warning, text: "Step \(n) (Notification) has no recipients."))
            case .triggerWorkflow(let id, _, _) where id == nil:
                out.append(Item(severity: .warning, text: "Step \(n) (Trigger Automation) has no automation chosen."))
            default:
                break
            }
        }
        for name in offlineDeckNames { out.append(Item(severity: .warning, text: "\(name) is offline right now.")) }
        if workflow.triggers.isEmpty { out.append(Item(severity: .info, text: "No trigger: this runs only when you start it.")) }
        return out
    }
}

extension WorkflowRun {
    /// The newest run of this automation. Runs saved before IDs were kept are matched by name.
    static func latest(for workflow: Workflow, in history: [WorkflowRun]) -> WorkflowRun? {
        history.first { $0.workflowID == workflow.id || ($0.workflowID == nil && $0.workflowName == workflow.name) }
    }

    static func filter(_ runs: [WorkflowRun], query: String, onlyErrors: Bool) -> [WorkflowRun] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return runs.filter { run in
            (!onlyErrors || run.errors > 0)
                && (q.isEmpty || run.workflowName.lowercased().contains(q) || run.decksProcessed.contains { $0.lowercased().contains(q) })
        }
    }

    static func csv(_ runs: [WorkflowRun]) -> String {
        func field(_ s: String) -> String { s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        let iso = ISO8601DateFormatter()
        var lines = ["Automation,Started,Finished,Duration,Processed,Errors,Devices"]
        for r in runs {
            lines.append([r.workflowName, iso.string(from: r.startedAt), iso.string(from: r.finishedAt), r.durationFormatted,
                          String(r.processed), String(r.errors), r.decksProcessed.joined(separator: "; ")].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Ready-made starting points, opened in the builder as a draft.
struct WorkflowTemplate: Identifiable {
    var id: String { name }
    let name: String
    let summary: String
    let make: () -> Workflow

    static let all: [WorkflowTemplate] = [
        WorkflowTemplate(name: "Sunday offload", summary: "Copy new clips off every HyperDeck, verify them, make proxies and rename.") {
            Workflow(name: "Sunday offload", steps: [
                WorkflowStep(action: .sync(destination: .global, verify: true, deleteFromDevice: false), decks: .all),
                WorkflowStep(action: .defaultAction(for: .convert)),
                WorkflowStep(action: .defaultAction(for: .rename)),
            ])
        },
        WorkflowTemplate(name: "Weekly cleanup", summary: "Delete files older than 30 days from the destination, after asking.") {
            Workflow(name: "Weekly cleanup", steps: [
                WorkflowStep(action: .cleanup(retentionDays: 30), requiresConfirmation: true),
            ])
        },
        WorkflowTemplate(name: "Service captions", summary: "Start the live transcript and stop it automatically after two hours.") {
            Workflow(name: "Service captions", steps: [
                WorkflowStep(action: .liveTranscription(command: .start, stopAfterMinutes: 120)),
            ])
        },
    ]
}
