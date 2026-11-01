import Combine
import Foundation

/// A Mac whose Remote Host this Mac can view. The pairing code is a secret, so it lives in the Keychain.
struct SavedRemoteMac: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
}

/// The list of Macs this one can connect to, from Settings → Connections.
@MainActor
final class RemoteMacStore: ObservableObject {
    static let shared = RemoteMacStore()
    private static let listKey = "remoteViewerMacs"

    @Published private(set) var macs: [SavedRemoteMac] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.listKey),
           let list = try? JSONDecoder().decode([SavedRemoteMac].self, from: data) {
            macs = list
        }
    }

    private static func keychainKey(_ id: UUID) -> String { "remoteViewerCode.\(id.uuidString)" }

    func pairingCode(for id: UUID) -> String? { KeychainStore.get(key: Self.keychainKey(id)) }

    func mac(_ id: UUID) -> SavedRemoteMac? { macs.first { $0.id == id } }

    /// Saves a Mac. Returns false if the code isn't a valid pairing code.
    @discardableResult
    func add(name: String, pairingCode: String) -> Bool {
        guard let code = RemotePairingCode(pairingCode) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let mac = SavedRemoteMac(name: trimmed.isEmpty ? "Mac \(macs.count + 1)" : trimmed)
        KeychainStore.set("\(code.ticket)|\(code.token)", key: Self.keychainKey(mac.id))
        macs.append(mac)
        save()
        return true
    }

    func remove(_ id: UUID) {
        KeychainStore.delete(key: Self.keychainKey(id))
        macs.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(macs) { UserDefaults.standard.set(data, forKey: Self.listKey) }
    }
}
