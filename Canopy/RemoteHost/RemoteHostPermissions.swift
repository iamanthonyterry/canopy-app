import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// The two macOS permissions Remote Host needs, checked live so the setup screen can tick them off.
@MainActor
final class RemoteHostPermissions: ObservableObject {
    @Published private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    @Published private(set) var accessibility = InputInjector.isTrusted

    var allGranted: Bool { screenRecording && accessibility }

    private var timer: Timer?

    /// Starts checking once a second (permissions are granted in another app, so nothing notifies us).
    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    func refresh() {
        let s = CGPreflightScreenCaptureAccess(), a = InputInjector.isTrusted
        if s != screenRecording { screenRecording = s }
        if a != accessibility { accessibility = a }
    }

    /// Shows the system prompt the first time; after a refusal it only works through System Settings.
    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openSettings("Privacy_ScreenCapture") }
    }

    func requestAccessibility() {
        InputInjector.requestTrust()
        openSettings("Privacy_Accessibility")
    }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Screen Recording sometimes only takes effect after the app restarts.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
