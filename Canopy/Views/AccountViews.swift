import SwiftUI

// MARK: - The website connection
// Canopy talks to the church's website with one thing: the campus key, set when this Mac is connected to a campus
// (Settings → Connections → Church Landing Page). It covers the live transcript, device jobs and email. There is no separate person sign-in. This card shows what the connection is being used for.

/// Settings → Connections: what the campus connection covers.
struct WebsiteCard: View {
    @ObservedObject private var connection = CampusConnection.shared

    var body: some View {
        GroupBox(label: Label("Website", systemImage: "globe")) {
            VStack(alignment: .leading, spacing: 12) {
                if connection.isConnected { connected } else { notConnected }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
    }

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect this Mac to your campus to send email from automations.")
                .font(.canopyBody).foregroundStyle(.secondary)
            Button {
                UserDefaults.standard.set(SettingsTab.transcription.rawValue, forKey: SettingsTab.storageKey)
            } label: { Label("Connect in Transcription settings…", systemImage: "link") }
                .buttonStyle(.canopyPrimary)
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.campusName.isEmpty ? "Connected to a campus" : "Connected to \(connection.campusName)").font(.canopySubheadline)
                    if let host = connection.site?.host { Text(host).font(.canopyCaption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let origin = connection.origin { Link("Open website", destination: origin).font(.canopyCaption) }
            }
            Divider()

            row("Email", icon: "envelope", detail: "Sends from \(NotificationMailer.fromAddress)", ok: true)
        }
    }

    private func row(_ title: String, icon: String, detail: String, ok: Bool,
                     @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(ok ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.canopySubheadline)
                Text(detail).font(.canopyCaption).foregroundStyle(ok ? Color.secondary : Color.orange)
            }
            Spacer()
            trailing()
        }
    }
}
