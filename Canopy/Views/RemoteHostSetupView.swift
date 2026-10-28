import SwiftUI

/// Walks through the macOS permissions Remote Host needs before it turns on.
struct RemoteHostSetupView: View {
    @StateObject private var perms = RemoteHostPermissions()
    @State private var askedScreen = false
    let onFinish: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Remote Host").font(.canopyTitle)
                Text("Two macOS permissions let your iPad see this Mac and control it. Canopy can't turn them on for you; you approve each one in System Settings.")
                    .font(.canopyBody).foregroundStyle(.secondary)
            }

            step(1, title: "Screen Recording", done: perms.screenRecording,
                 detail: "Lets Canopy send this Mac's screen to your iPad.",
                 action: perms.screenRecording ? nil : (askedScreen ? "Open System Settings…" : "Allow…")) {
                perms.requestScreenRecording(); askedScreen = true
            }

            step(2, title: "Accessibility", done: perms.accessibility,
                 detail: "Lets your iPad move the pointer, click and type on this Mac.",
                 action: perms.accessibility ? nil : "Allow…") { perms.requestAccessibility() }

            if askedScreen && !perms.screenRecording {
                Label("Switched Canopy on in Screen Recording but this still shows a warning? macOS sometimes needs Canopy to restart first.",
                      systemImage: "info.circle")
                    .font(.canopyCaption).foregroundStyle(.secondary)
                Button("Restart Canopy") { perms.relaunch() }
            }

            Divider()

            HStack {
                Text(perms.allGranted ? "All set. Canopy will show a pairing code to paste into TailDesk."
                                      : "Turn on both to continue.")
                    .font(.canopyCaption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Turn on Remote Host", action: onFinish)
                    .buttonStyle(.canopyPrimary)
                    .disabled(!perms.allGranted)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { perms.startPolling() }
        .onDisappear { perms.stopPolling() }
    }

    private func step(_ n: Int, title: String, done: Bool, detail: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2).foregroundStyle(done ? Color.green : .secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.canopySubheadline)
                Text(detail).font(.canopyCaption).foregroundStyle(.secondary)
            }
            Spacer()
            if let action { Button(action, action: perform) }
        }
    }
}
