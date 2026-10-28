import Combine
import AppKit
import SwiftUI

/// Settings → Connections: everything Canopy connects to, in one place. Each card shows whether it is connected and
/// has the sign-in or switch for it. The details (service types, devices, alerts) stay on their own pages.
struct ConnectionsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WebsiteConnectionCard(model: model)
                PlanningCenterConnectionCard(model: model)
                RemoteHostCard()
                OtherConnectionsCard()
                Spacer(minLength: 24)
            }
            .padding(.vertical)
        }
    }
}

/// A card header: icon, name and a connected / not connected badge.
private struct ConnectionHeader: View {
    let title: String
    let icon: String
    let connected: Bool
    var detail: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(connected ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.canopySubheadline)
                if let detail { Text(detail).font(.canopyCaption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(connected ? "Connected" : "Not connected")
                .font(.canopyCaption)
                .foregroundStyle(connected ? Color.green : .secondary)
        }
    }
}

// MARK: Church Landing Page

private struct WebsiteConnectionCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var connection = CampusConnection.shared

    private var connected: Bool { !model.token.isEmpty }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ConnectionHeader(title: "Church Landing Page", icon: "globe", connected: connected,
                                 detail: connected ? (model.settings.connectedTo.isEmpty ? "A campus (key entered by hand)" : model.settings.connectedTo)
                                                   : "Live transcript, device jobs, automation progress and email")
                HStack {
                    Button(connected ? "Change campus…" : "Sign in with website…") { model.signInWithWebsite() }
                        .buttonStyle(.canopyPrimary)
                        .disabled(model.signInBusy || model.running)
                    if model.signInBusy {
                        ProgressView().controlSize(.small)
                        Text("Finish in your browser").font(.canopyCaption).foregroundStyle(.secondary)
                        Button("Cancel") { model.cancelSignIn() }
                    }
                    Spacer()
                    if let origin = connection.origin { Link("Open website", destination: origin).font(.canopyCaption) }
                    if connected && !model.signInBusy {
                        Button("Disconnect", role: .destructive) { model.disconnect() }.disabled(model.running)
                    }
                }
                if model.running { Text("Stop transcribing to change where the transcript is sent.").font(.canopyCaption).foregroundStyle(.secondary) }
                if let e = model.signInError { Text(e).font(.canopyCaption).foregroundStyle(.orange) }
                Text("What's shared and synced is under Settings → More → Website.").font(.canopyCaption).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal)
    }
}

// MARK: Planning Center

private struct PlanningCenterConnectionCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ConnectionHeader(title: "Planning Center", icon: "calendar", connected: model.pcoSignedIn,
                                 detail: model.pcoSignedIn ? (model.settings.pcoServiceTypeName.isEmpty ? "Choose a service type below" : model.settings.pcoServiceTypeName)
                                                           : "Service times and who is on the plan")
                PlanningCenterSection(model: model)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal)
    }
}

// MARK: Remote Host (TailDesk)

private struct RemoteHostCard: View {
    @ObservedObject private var host = RemoteHostService.shared
    @State private var showToken = false
    @StateObject private var perms = RemoteHostPermissions()
    @State private var showSetup = false

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ConnectionHeader(title: "Remote Host (TailDesk)", icon: "display", connected: host.isRunning,
                                 detail: "Lets your paired iPad see and control this Mac from anywhere")
                // Off until you turn it on; turning it on first checks the macOS permissions.
                Toggle("Allow TailDesk to connect", isOn: Binding(get: { host.isRunning }, set: { on in
                    if !on { host.setEnabled(false) }
                    else if perms.allGranted { host.setEnabled(true) }
                    else { showSetup = true }
                }))
                .toggleStyle(.switch)
                if host.isRunning {
                    LabeledContent("Pairing code") {
                        HStack {
                            if host.pairingCode.isEmpty {
                                ProgressView().controlSize(.small)
                                Text("Getting online…").font(.canopyCaption).foregroundStyle(.secondary)
                            } else {
                                Text(showToken ? host.pairingCode : "••••••••••••").font(.system(.caption, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                                Button("Copy") { copy(host.pairingCode) }
                            }
                        }
                    }
                    if !perms.allGranted {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("A macOS permission is missing, so streaming or control won't work.")
                                .font(.canopyCaption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Fix…") { showSetup = true }
                        }
                    }
                    Text("Paste the pairing code into TailDesk's Add Mac screen. It works from any network with nothing to install. Keep the code private: anyone with it can control this Mac.")
                        .font(.canopyCaption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal)
        .onAppear { perms.startPolling() }
        .onDisappear { perms.stopPolling() }
        .sheet(isPresented: $showSetup) {
            RemoteHostSetupView(
                onFinish: { host.setEnabled(true); showSetup = false },
                onCancel: { showSetup = false })
        }
    }
}

// MARK: Everything else

/// The other things Canopy talks to. Each one is set up on its own page; this just points to it.
private struct OtherConnectionsCard: View {
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.connections.rawValue

    var body: some View {
        GroupBox(label: Label("Other connections", systemImage: "point.3.connected.trianglepath.dotted")) {
            VStack(alignment: .leading, spacing: 8) {
                link("HyperDecks, cloud stores and folders", icon: "externaldrive.connected.to.line.below", to: .devices)
                link("Email notifications", icon: "envelope", to: .more)
                link("OSC and MIDI remote control", icon: "slider.horizontal.3", to: .more)
                link("AI models", icon: "sparkles", to: .more)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
    }

    private func link(_ title: String, icon: String, to dest: SettingsTab) -> some View {
        Button { tab = dest.rawValue } label: {
            HStack {
                Image(systemName: icon).frame(width: 22)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
