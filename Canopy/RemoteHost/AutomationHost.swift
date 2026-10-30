import Foundation

/// Mirrors the automation runs to a paired viewer, read-only. While subscribed it samples `AppState.activeRuns`
/// and calls `onSnapshot` with the encoded snapshot whenever it changes.
@MainActor
final class AutomationHost {
    private var timer: Timer?
    private var lastSent: Data?
    private let onSnapshot: @Sendable (Data) -> Void

    nonisolated init(onSnapshot: @escaping @Sendable (Data) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func start() {
        guard timer == nil else { return }
        lastSent = nil
        publish()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func publish() {
        let snapshot = RemoteAutomationSnapshot(runs: AppState.shared.activeRuns.map(Self.describe))
        guard let data = try? JSONEncoder().encode(snapshot), data != lastSent else { return }
        lastSent = data
        onSnapshot(data)
    }

    private static func describe(_ run: WorkflowRunSession) -> RemoteAutomationRun {
        let state: String
        if run.isFinished {
            if run.isCancelled { state = "cancelled" }
            else if run.errors > 0 || run.mountError != nil || !run.failedTasks.isEmpty { state = "failed" }
            else { state = "finished" }
        } else if run.pendingConfirmationStep != nil { state = "waiting" }
        else if run.isPaused { state = "paused" }
        else { state = "running" }

        let steps = run.stepRuns.map { s in
            RemoteAutomationStep(name: s.step.kind.title, status: stepStatus(s.status))
        }
        // Unfinished files first, so the busy ones stay visible when a run has hundreds.
        let ordered = run.tasks.filter { $0.phase != .done } + run.tasks.filter { $0.phase == .done }
        let tasks = ordered.prefix(40).map { t in
            RemoteAutomationTask(
                file: t.fileName, device: t.deckName, phase: t.phase.rawValue,
                sync: t.syncProgress, convert: t.convertProgress, error: t.errorMessage, eta: t.etaSeconds)
        }
        return RemoteAutomationRun(
            id: run.id.uuidString, name: run.workflow.name, startedAt: run.startedAt.timeIntervalSince1970,
            state: state, currentStep: run.currentStepIndex, steps: steps, tasks: Array(tasks),
            log: Array(run.lines.suffix(12)), errors: run.errors, mountError: run.mountError)
    }

    private static func stepStatus(_ s: WorkflowRunSession.StepRun.Status) -> String {
        switch s {
        case .pending: "pending"
        case .awaitingConfirmation: "waiting"
        case .running: "running"
        case .done: "done"
        case .skipped: "skipped"
        case .cancelled: "cancelled"
        }
    }
}
