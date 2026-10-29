import SwiftUI

/// The Set Up window: what a new Mac needs before Canopy is useful, with the button for each step right in the row.
struct SetupChecklistView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var state: SetupState { SetupProgress.state(model: model, appState: appState) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up Canopy").font(.canopyTitle)
                Text(state.isComplete ? "Everything is set up." : "\(state.doneCount) of \(SetupState.total) done. Live captions need the first two; the rest are optional.")
                    .font(.canopySubheadline).foregroundStyle(.secondary)
                ProgressView(value: Double(state.doneCount), total: Double(SetupState.total)).tint(Color.green)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    websiteRow
                    Divider()
                    audioRow
                    Divider()
                    planningCenterRow
                    Divider()
                    deviceRow
                    Divider()
                    automationRow
                }
            }
            Divider()
            HStack {
                Button("Don't Show Again") { SetupProgress.dismiss(); dismiss() }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer()
                Button(state.isComplete ? "Done" : "Close") { dismiss() }.buttonStyle(.canopySecondary)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 460)
        .onChange(of: model.levelResult) { _, result in
            if result?.isOK == true { UserDefaults.standard.set(true, forKey: SetupProgress.audioCheckedKey) }
        }
    }

    // MARK: Rows

    private var websiteRow: some View {
        SetupRow(done: state.website, title: "Connect to your church website",
                 detail: "Sends the live transcript, shares automation progress and carries your campus key.") {
            HStack {
                Button(model.signInBusy ? "Finish in your browser…" : "Sign in with website…") { model.signInWithWebsite() }
                    .buttonStyle(.canopyPrimary).disabled(model.signInBusy)
                if model.signInBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelSignIn() }
                }
            }
            if let e = model.signInError { Text(e).font(.canopyCaption).foregroundStyle(.orange) }
        }
    }

    private var audioRow: some View {
        SetupRow(done: state.audio, title: "Choose the audio input and check its level",
                 detail: "Pick the feed of the speaker's mic from your board or interface, then speak for a few seconds.") {
            if model.settings.inputs.isEmpty {
                Text("No audio input is set up.").font(.canopyCaption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    InputPickers(model: model, input: $model.settings.inputs[0])
                    HStack {
                        Button(model.checkingLevel ? "Listening…" : "Check audio level") { model.checkLevel() }
                            .buttonStyle(.canopySecondary).disabled(model.checkingLevel || model.running)
                        if model.checkingLevel { Text("Speak normally for 8 seconds").font(.canopyCaption).foregroundStyle(.secondary) }
                    }
                    if let r = model.levelResult {
                        Label(r.title, systemImage: r.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.isOK ? Color.green : Color.orange)
                        Text(r.advice).font(.canopyCaption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var planningCenterRow: some View {
        SetupRow(done: state.planningCenter, title: "Connect Planning Center (optional)",
                 detail: "Spells this week's speaker and series right, and lets automations start at service time.") {
            if PCOConfig.isConfigured {
                Button(model.pcoBusy ? "Waiting for the browser…" : "Sign in to Planning Center") { model.pcoSignIn() }
                    .buttonStyle(.canopySecondary).disabled(model.pcoBusy)
            } else {
                Text("This build has no Planning Center credentials.").font(.canopyCaption).foregroundStyle(.secondary)
            }
            if let e = model.pcoError { Text(e).font(.canopyCaption).foregroundStyle(.orange) }
        }
    }

    private var deviceRow: some View {
        SetupRow(done: state.device, title: "Add a device (optional)",
                 detail: "HyperDecks, network storage or a folder that automations record to, offload from or copy to.") {
            Button("Open Devices…") { SettingsTab.devices.open(with: openWindow) }.buttonStyle(.canopySecondary)
        }
    }

    private var automationRow: some View {
        SetupRow(done: state.automation, title: "Create an automation (optional)",
                 detail: "Chain steps like offload, rename and email, and run them on a schedule or a voice cue.") {
            Button("Open Automations…") { SettingsTab.workflows.open(with: openWindow) }.buttonStyle(.canopySecondary)
        }
    }
}

/// One line of the checklist: a check mark or empty circle, what to do, and the controls to do it.
private struct SetupRow<Content: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(done ? Color.green : .secondary)
                .accessibilityLabel(done ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.canopySubheadline.weight(.semibold))
                Text(detail).font(.canopyCaption).foregroundStyle(.secondary)
                content
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}
