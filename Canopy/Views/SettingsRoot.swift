import SwiftUI

/// The pages of the Settings window. The menu bar opens the window on a chosen page by setting `selected`.
enum SettingsTab: String, CaseIterable {
    case general, transcription, workflows, devices, connections, control

    static let storageKey = "settings.tab"

    /// Opens the Settings window on this page.
    @MainActor func open(with openWindow: OpenWindowAction) {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Settings, by what you are doing: General (the app itself), Transcription (listening, translating and voice
/// cues), Automations (with how they name and process files), Devices, Connections (the accounts Canopy signs in to),
/// and Control & Alerts (what can drive Canopy, and how it warns you).
struct SettingsRoot: View {
    @ObservedObject var model: AppModel
    @AppStorage(SettingsTab.storageKey) private var stored = SettingsTab.general.rawValue

    /// A page name saved by an older version ("more") opens General instead of nothing.
    private var tab: Binding<String> {
        Binding(get: { SettingsTab(rawValue: stored) == nil ? SettingsTab.general.rawValue : stored }, set: { stored = $0 })
    }

    var body: some View {
        TabView(selection: tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general.rawValue) {
                GeneralSettingsView(model: model)
            }
            Tab("Transcription", systemImage: "waveform", value: SettingsTab.transcription.rawValue) {
                ScrollView { TranscriberSettingsView(model: model) }
            }
            Tab("Automations", systemImage: "flowchart", value: SettingsTab.workflows.rawValue) {
                WorkflowsPage()
            }
            Tab("Devices", systemImage: "externaldrive.connected.to.line.below", value: SettingsTab.devices.rawValue) {
                DevicesPage()
            }
            Tab("Connections", systemImage: "link", value: SettingsTab.connections.rawValue) {
                ConnectionsView(model: model)
            }
            Tab("Control & Alerts", systemImage: "slider.horizontal.3", value: SettingsTab.control.rawValue) {
                ControlAlertsView()
            }
        }
        .environmentObject(AppState.shared)
        .frame(minWidth: 860, minHeight: 600)
    }
}

/// The automation list and builder, with the run history beside it.
struct WorkflowsPage: View {
    private enum Section: String, CaseIterable { case workflows = "Automations", history = "History", naming = "Naming & Performance" }
    @State private var section = Section.workflows

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 10)
            switch section {
            case .workflows: WorkflowsView()
            case .history: HistoryView()
            case .naming:
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ShootSettingsView()
                        PerformanceSettingsView()
                        Spacer(minLength: 24)
                    }
                    .padding(.vertical)
                }
            }
        }
    }
}

/// The devices automations run on.
struct DevicesPage: View {
    var body: some View { DevicesSettingsView() }
}

/// The app itself: how it starts, updates, and backing up what it knows.
struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox(label: Label("Startup", systemImage: "power")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Open Canopy at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        Toggle("Start transcribing when Canopy opens", isOn: $model.settings.autoStart)
                        Text("Canopy lives in the menu bar. To start and stop the transcript at set times, or when a service begins, add a Live Transcription step to an automation with a Daily or Planning Center Service trigger.")
                            .font(.canopyCaption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal)

                GroupBox(label: Label("Updates", systemImage: "arrow.down.circle")) {
                    HStack {
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                            .font(.canopyBody)
                        Spacer()
                        if let install = model.pendingUpdate {
                            Button("Restart to Update") { model.stop(); install() }.buttonStyle(.canopyPrimary)
                        } else {
                            Button("Check for Updates…") { model.updates.checkForUpdates() }.buttonStyle(.canopySecondary)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal)

                DataBackupView()
                Spacer(minLength: 24)
            }
            .padding(.vertical)
        }
        .appliesSettingsOnLeave(model)
    }
}
