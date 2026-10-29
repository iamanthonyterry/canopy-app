import Combine
import Foundation

/// Tells a person, from the menu bar icon and the menu, that an automation needs them: a run a crash cut short, or the
/// last run finishing with errors. Also resumes interrupted runs by itself when the person allowed it.
@MainActor
final class AutomationAttention: ObservableObject {
    static let shared = AutomationAttention()

    @Published private(set) var message: String?
    private var cancellables = Set<AnyCancellable>()
    private static let acknowledgedKey = "attention.acknowledgedRun"
    private var started = false

    /// Steps that change a device or delete files: never repeated without a person deciding.
    static let unsafeKinds: Set<StepKind> = [.format, .cleanup, .controlDeck]

    static func isSafeToAutoResume(_ checkpoint: WorkflowCheckpoint) -> Bool {
        !checkpoint.workflow.steps.dropFirst(checkpoint.nextStepIndex).contains { unsafeKinds.contains($0.kind) }
    }

    static func message(interrupted: Int, lastRun: WorkflowRun?, acknowledged: UUID?) -> String? {
        if interrupted > 0 {
            return interrupted == 1 ? "An automation was interrupted" : "\(interrupted) automations were interrupted"
        }
        if let run = lastRun, run.errors > 0, run.id != acknowledged {
            return "“\(run.workflowName)” finished with \(run.errors) error\(run.errors == 1 ? "" : "s")"
        }
        return nil
    }

    func start() {
        guard !started else { return }
        started = true
        let checkpoints = WorkflowCheckpointStore.shared
        let appState = AppState.shared
        checkpoints.$interrupted.combineLatest(appState.$workflowRunHistory)
            .receive(on: RunLoop.main)
            .sink { [weak self] interrupted, history in
                self?.message = Self.message(interrupted: interrupted.count, lastRun: history.first, acknowledged: self?.acknowledged)
            }
            .store(in: &cancellables)

        let leftOver = checkpoints.interrupted
        guard !leftOver.isEmpty else { return }
        let auto = appState.alertSettings.autoResumeInterrupted
        let resumable = leftOver.filter(Self.isSafeToAutoResume)
        NotificationService.sendDeviceAlert(
            title: leftOver.count == 1 ? "An automation was interrupted" : "\(leftOver.count) automations were interrupted",
            body: auto && !resumable.isEmpty ? "Canopy will resume the safe ones in a minute. Others wait for you in the menu."
                                              : "Open the Canopy menu to resume or discard it.")
        guard auto, !resumable.isEmpty else { return }
        Task {
            // Give network volumes and devices time to come back after a restart.
            try? await Task.sleep(for: .seconds(60))
            for checkpoint in resumable where WorkflowEngine.shared.canResume(checkpoint) {
                await WorkflowEngine.shared.resume(checkpoint)
            }
        }
    }

    private var acknowledged: UUID? {
        UserDefaults.standard.string(forKey: Self.acknowledgedKey).flatMap(UUID.init)
    }

    /// Puts away the "finished with errors" warning for the latest run.
    func acknowledge() {
        guard let run = AppState.shared.workflowRunHistory.first else { return }
        UserDefaults.standard.set(run.id.uuidString, forKey: Self.acknowledgedKey)
        message = Self.message(interrupted: WorkflowCheckpointStore.shared.interrupted.count, lastRun: run, acknowledged: run.id)
    }
}

/// An email each morning to the alert recipients: last night's runs, devices that are down, anything interrupted.
@MainActor
final class HealthSummaryService {
    static let shared = HealthSummaryService()
    private static let lastSentKey = "healthSummary.lastSent"
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.sendIfDue()
            }
        }
    }

    /// 7 a.m. or later, once a calendar day.
    nonisolated static func isDue(now: Date, lastSent: Date?, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.hour, from: now) >= 7 else { return false }
        guard let lastSent else { return true }
        return !calendar.isDate(lastSent, inSameDayAs: now)
    }

    private func sendIfDue() async {
        let appState = AppState.shared
        let settings = appState.alertSettings
        let recipients = settings.emailRecipients.map(\.email)
        let last = UserDefaults.standard.object(forKey: Self.lastSentKey) as? Date
        guard settings.dailySummary, !recipients.isEmpty, NotificationMailer.isAvailable, Self.isDue(now: Date(), lastSent: last) else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastSentKey)
        let body = Self.body(appState: appState)
        _ = await NotificationMailer.sendIndividually(to: recipients, subject: "Canopy daily summary", body: body)
    }

    static func body(appState: AppState, now: Date = Date()) -> String {
        let since = now.addingTimeInterval(-24 * 3600)
        let runs = appState.workflowRunHistory.filter { $0.finishedAt >= since }
        let failed = runs.filter { $0.errors > 0 }
        var lines = ["Canopy daily summary", ""]
        lines.append("Automations in the last 24 hours: \(runs.count) run\(runs.count == 1 ? "" : "s"), \(failed.count) with errors.")
        for run in failed { lines.append("  • \(run.workflowName): \(run.errors) error\(run.errors == 1 ? "" : "s")") }
        let interrupted = WorkflowCheckpointStore.shared.interrupted
        if !interrupted.isEmpty { lines.append("Interrupted and waiting: " + interrupted.map { $0.workflow.name }.joined(separator: ", ")) }
        let monitor = ConnectionMonitor.shared
        let down = appState.hyperDecks.filter { monitor.status(for: $0.ipAddress) == .offline }.map(\.name)
            + appState.cloudStores.filter { monitor.status(for: $0.ipAddress) == .offline }.map(\.name)
        lines.append(down.isEmpty ? "All devices are reachable." : "Devices not reachable: " + down.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }
}
