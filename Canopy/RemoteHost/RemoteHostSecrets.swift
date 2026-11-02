import Foundation

/// Where Remote Access keeps its pairing secrets: the Mac's Iroh identity and the pairing token.
/// The app uses the Keychain; tests use a dictionary, so rotation can be checked without real keys.
/// Main-actor, like the Keychain itself.
@MainActor
protocol RemoteHostSecrets: Sendable {
    func get(_ key: String) -> String?
    func set(_ value: String, for key: String)
    func delete(_ key: String)
}

/// The real store. No-ops in safe mode, like every other Keychain use in Canopy.
struct KeychainRemoteHostSecrets: RemoteHostSecrets {
    func get(_ key: String) -> String? { KeychainStore.get(key: key) }
    func set(_ value: String, for key: String) { KeychainStore.set(value, key: key) }
    func delete(_ key: String) { KeychainStore.delete(key: key) }
}
