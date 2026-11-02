import Foundation
import Testing
@testable import Canopy

/// Stands in for the Keychain, so rotation can be checked without touching real keys.
private final class MemorySecrets: RemoteHostSecrets {
    private var values: [String: String]

    init(_ values: [String: String] = [:]) { self.values = values }

    func get(_ key: String) -> String? { values[key] }
    func set(_ value: String, for key: String) { values[key] = value }
    func delete(_ key: String) { values.removeValue(forKey: key) }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

@MainActor
struct RemoteHostPairingTokenTests {
    @Test func loadsTheSavedTokenInsteadOfMakingOne() {
        let host = RemoteHostService(secrets: MemorySecrets([RemoteHostService.tokenKey: "saved-token"]),
                                     makeToken: { "should-not-be-used" })
        #expect(host.pairingToken == "saved-token")
    }

    @Test func rotatingSavesAndPublishesANewToken() {
        let secrets = MemorySecrets([RemoteHostService.tokenKey: "old-token"])
        let counter = Counter()
        let host = RemoteHostService(secrets: secrets, makeToken: { "token-\(counter.next())" })
        #expect(host.pairingToken == "old-token")

        host.rotatePairingCode()
        #expect(host.pairingToken == "token-1")
        #expect(secrets.get(RemoteHostService.tokenKey) == "token-1")

        host.rotatePairingCode()
        #expect(host.pairingToken == "token-2")
        #expect(secrets.get(RemoteHostService.tokenKey) == "token-2")
    }

    @Test func resettingIdentityDropsTheIrohKeyAndTheOldToken() {
        let secrets = MemorySecrets([RemoteHostService.tokenKey: "old-token",
                                     RemoteHostService.irohKeyKey: "b2xkLWtleQ=="])
        let counter = Counter()
        let host = RemoteHostService(secrets: secrets, makeToken: { "token-\(counter.next())" })
        #expect(!host.isRunning)

        host.resetIdentity()
        #expect(secrets.get(RemoteHostService.irohKeyKey) == nil)
        #expect(host.pairingToken == "token-1")
        #expect(secrets.get(RemoteHostService.tokenKey) == "token-1")
        // No endpoint was bound, so there is no ticket to show a code for.
        #expect(host.pairingCode.isEmpty)
    }

    @Test func tokensAreUrlSafeBase64OfEighteenBytes() {
        let a = RemoteHostService.randomToken(), b = RemoteHostService.randomToken()
        #expect(a.count == 24)
        #expect(!a.contains("+") && !a.contains("/") && !a.contains("="))
        #expect(a != b)
    }
}
