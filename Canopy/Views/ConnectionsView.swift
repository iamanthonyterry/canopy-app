import Combine
import AppKit
import SwiftUI

/// Settings → Connections: the accounts and services Canopy signs in to: the website (and what it carries: sync,
/// progress, email), Planning Center and Remote Host. Sign-in happens only here; other pages show a status and link back.
/// What can drive Canopy and how it warns you lives on Control & Alerts.
struct ConnectionsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WebsiteConnectionCard(model: model)
                if CampusConnection.shared.isConnected || !model.token.isEmpty { WebsiteCard() }
                EmailNotificationsView()
                PlanningCenterConnectionCard(model: model)
                RemoteHostCard()
                RemoteViewerCard()
                ComputersCard(model: model)
                Spacer(minLength: 24)
            }
            .padding(.vertical)
        }
    }
}

/// Settings → Control & Alerts: OSC and MIDI control, live alerts and on-device AI.
struct ControlAlertsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RemoteControlSettingsView()
                AlertSettingsView()
                AIModelSettingsView()
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

// MARK: Remote Access

private struct RemoteHostCard: View {
    @ObservedObject private var host = RemoteHostService.shared
    @State private var showToken = false
    @StateObject private var perms = RemoteHostPermissions()
    @State private var showSetup = false
    @State private var confirmRotate = false
    @State private var confirmReset = false

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ConnectionHeader(title: "Remote Access", icon: "display", connected: host.isRunning,
                                 detail: "Lets your paired iPad see and control this Mac from anywhere")
                // Off until you turn it on; turning it on first checks the macOS permissions.
                Toggle("Allow remote devices to connect", isOn: Binding(get: { host.isRunning }, set: { on in
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
                                Button("Rotate…") { confirmRotate = true }
                                    .help("Replace this code with a new one")
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
                    Text("Paste the pairing code into Remote Access's Add Mac screen. It works from any network with nothing to install. Keep the code private: anyone with it can control this Mac. Rotate it to make a new code if it was shared or a device was lost; the old code stops working.")
                        .font(.canopyCaption).foregroundStyle(.secondary)
                }
                // Available whether or not the host is on: handing the Mac on is often the moment it is off.
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                    Text("Reset identity gives this Mac a new network identity and a new code, so codes from before can no longer find it.")
                        .font(.canopyCaption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Identity…") { confirmReset = true }
                        .confirmationDialog("Reset this Mac's remote identity?", isPresented: $confirmReset, titleVisibility: .visible) {
                            Button("Reset Identity", role: .destructive) { host.resetIdentity() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Every paired device loses access and has to be added again with the new code. This can't be undone.")
                        }
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
        .confirmationDialog("Rotate the pairing code?", isPresented: $confirmRotate, titleVisibility: .visible) {
            Button("Rotate", role: .destructive) { host.rotatePairingCode() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any device using the old code is disconnected. Copy the new code to your iPad; it will not reconnect on its own.")
        }
    }
}

// MARK: View another Mac

private struct RemoteViewerCard: View {
    @ObservedObject private var store = RemoteMacStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showAdd = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ConnectionHeader(title: "View another Mac", icon: "rectangle.on.rectangle", connected: !store.macs.isEmpty,
                                 detail: "See and control a Mac that has Remote Access turned on")
                ForEach(store.macs) { mac in
                    HStack {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        Text(mac.name)
                        Spacer()
                        Button("Connect") { openWindow(id: "remote-viewer", value: mac.id) }
                        Button(role: .destructive) { store.remove(mac.id) } label: { Image(systemName: "trash") }
                            .help("Remove this Mac")
                    }
                }
                HStack {
                    Button("Add Mac…") { showAdd = true }
                    Spacer()
                }
                Text("On the other Mac, turn on Remote Access in Settings → Connections and copy its pairing code. Anyone with that code can control that Mac.")
                    .font(.canopyCaption).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal)
        .sheet(isPresented: $showAdd) { AddRemoteMacSheet(isPresented: $showAdd) }
    }
}

// MARK: Computers on your campuses

private struct ComputersCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var registry = ComputerRegistry.shared
    @ObservedObject private var connection = CampusConnection.shared

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ConnectionHeader(title: "Computers", icon: "desktopcomputer", connected: registry.signedIn,
                                 detail: "Macs signed in to the website, and the campus each one is set to")
                if !connection.isConnected {
                    Text("Connect this Mac to a campus first, then sign in with the website.")
                        .font(.canopyCaption).foregroundStyle(.secondary)
                } else if !registry.signedIn {
                    Button("Sign in with website…") { model.signInWithWebsite() }
                        .buttonStyle(.canopyPrimary)
                        .disabled(model.signInBusy || model.running)
                    Text("Signing in records this Mac on its campus, and shows the other computers your account can access.")
                        .font(.canopyCaption).foregroundStyle(.secondary)
                } else if registry.loading && registry.computers.isEmpty {
                    ProgressView().controlSize(.small)
                } else if registry.computers.isEmpty {
                    Text("No computers have signed in yet. Each Mac appears here the first time it signs in on one of your campuses.")
                        .font(.canopyCaption).foregroundStyle(.secondary)
                } else {
                    ForEach(registry.computers) { computer in row(computer) }
                }
                if let error = registry.error {
                    Text(error).font(.canopyCaption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Refresh") { Task { await registry.refresh() } }
                        .disabled(registry.loading || !registry.signedIn)
                    Spacer()
                    if let origin = connection.origin { Link("Open website", destination: origin).font(.canopyCaption) }
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal)
        .task { if registry.signedIn { await registry.refresh() } }
    }

    private func row(_ computer: RegisteredComputer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(computer.name)
                HStack(spacing: 6) {
                    Text(computer.campusName)
                    if let seen = computer.lastSeen {
                        Text("· \(seen, format: .relative(presentation: .named))")
                    }
                }
                .font(.canopyCaption).foregroundStyle(.secondary)
            }
            Spacer()
            if computer.id == ComputerRegistry.deviceID {
                Text("This Mac").font(.canopyCaption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AddRemoteMacSheet: View {
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var code = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Mac").font(.canopyTitle)
            TextField("Name (for example, Sanctuary Mac)", text: $name)
            TextField("Pairing code", text: $code, axis: .vertical)
                .font(.system(.caption, design: .monospaced)).lineLimit(3...6)
            if invalid {
                Label("That isn't a pairing code. Copy it again from the other Mac.", systemImage: "exclamationmark.triangle.fill")
                    .font(.canopyCaption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    if RemoteMacStore.shared.add(name: name, pairingCode: code) { isPresented = false } else { invalid = true }
                }
                .buttonStyle(.canopyPrimary)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
