import Foundation
import Security
import Testing
@testable import ChurchKitCore

struct SharedModelFolderTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ckcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func movesModelsAndMergesWithoutOverwriting() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old"), new = dir.appendingPathComponent("new")
        try write("model", to: old.appendingPathComponent("models/argmaxinc/whisperkit-coreml/v1/AudioEncoder.mlmodelc/weights"))
        try write("old", to: old.appendingPathComponent("models/openai/whisper-base.en/tokenizer.json"))
        try write("extra", to: old.appendingPathComponent("models/openai/whisper-base.en/config.json"))
        try write("keep", to: new.appendingPathComponent("models/openai/whisper-base.en/tokenizer.json"))

        SharedModelFolder.migrate(from: old, to: new)
        SharedModelFolder.migrate(from: old, to: new)  // a second run changes nothing

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: new.appendingPathComponent("models/argmaxinc/whisperkit-coreml/v1/AudioEncoder.mlmodelc/weights").path))
        #expect(try String(contentsOf: new.appendingPathComponent("models/openai/whisper-base.en/tokenizer.json"), encoding: .utf8) == "keep")
        #expect(fm.fileExists(atPath: new.appendingPathComponent("models/openai/whisper-base.en/config.json").path))
    }

    @Test func removesOldFolderWhenEverythingMoved() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old"), new = dir.appendingPathComponent("new")
        try write("x", to: old.appendingPathComponent("models/a/b.txt"))
        SharedModelFolder.migrate(from: old, to: new)
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func recognisesCompleteModelFolders() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!SharedModelFolder.isModelFolder(dir))
        try write("w", to: dir.appendingPathComponent("AudioEncoder.mlmodelc/weights"))
        #expect(SharedModelFolder.isModelFolder(dir))
    }
}

struct LegacyMigrationTests {
    private func defaults() -> UserDefaults {
        let name = "ckcore-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func copiesMissingKeysOnceAndKeepsExisting() {
        let d = defaults()
        d.set("new value", forKey: "kept")
        let old: [String: Any] = ["kept": "old value", "settings.v1": Data([1, 2, 3]), "count": 4]
        #expect(LegacyMigration.copyDefaults(fromBundleID: "old.id", into: d, reading: { _ in old }) == 2)
        #expect(d.string(forKey: "kept") == "new value")
        #expect(d.data(forKey: "settings.v1") == Data([1, 2, 3]))
        #expect(d.integer(forKey: "count") == 4)
        // A second launch changes nothing, even if the old domain has since changed.
        #expect(LegacyMigration.copyDefaults(fromBundleID: "old.id", into: d, reading: { _ in ["later": 1] }) == 0)
        #expect(d.object(forKey: "later") == nil)
    }

    @Test func missingOldDomainStillMarksDone() {
        let d = defaults()
        #expect(LegacyMigration.copyDefaults(fromBundleID: "none", into: d, reading: { _ in nil }) == 0)
        #expect(d.string(forKey: LegacyMigration.markerKey) == "none")
    }

    @Test func copiesKeychainItemsWithoutOverwriting() {
        let old = "ckcore.test.old.\(UUID().uuidString)", new = "ckcore.test.new.\(UUID().uuidString)"
        func put(_ service: String, _ account: String, _ value: String) {
            SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                        kSecValueData: Data(value.utf8)] as CFDictionary, nil)
        }
        func get(_ service: String, _ account: String) -> String? {
            var out: AnyObject?
            guard SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                       kSecReturnData: true] as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(decoding: d, as: UTF8.self)
        }
        defer {
            for s in [old, new] { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: s] as CFDictionary) }
        }
        put(old, "key", "k1"); put(old, "pco", "p1"); put(new, "pco", "keep")
        #expect(LegacyMigration.copyKeychain(fromService: old, toService: new) == 1)
        #expect(get(new, "key") == "k1")
        #expect(get(new, "pco") == "keep")
        #expect(get(old, "key") == "k1")  // the old copy stays
    }
}

struct HelperStatusTests {
    @Test func roundTripsThroughAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString)/status.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let status = HelperStatus(running: true, listening: true, connectedTo: "Main Campus", warning: "Silent for 2 minutes", version: "2.6.0", updatedAt: when)
        status.write(to: url)
        #expect(HelperStatus.read(from: url) == status)
        HelperStatus.clear(at: url)
        #expect(HelperStatus.read(from: url) == nil)
    }

    @Test func goesStaleAfterThreeMissedHeartbeats() {
        let t = Date(timeIntervalSince1970: 1_000)
        let s = HelperStatus(running: true, listening: false, connectedTo: "", version: "1", updatedAt: t)
        #expect(!s.isStale(now: t.addingTimeInterval(60)))
        #expect(s.isStale(now: t.addingTimeInterval(91)))
    }

    @Test func unreadableFileIsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hs-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(HelperStatus.read(from: url) == nil)
    }
}

struct HelperHandoffTests {
    @Test func offerThenTakeRoundTripsAndConsumesIt() throws {
        let service = "ckcore.test.handoff.\(UUID().uuidString)"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ho-\(UUID().uuidString)/handoff.json")
        defer {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        let key = String(repeating: "ab", count: 24)
        try HelperHandoff.offer(key: key, campusID: "c1", campusName: "Main Campus", keychainService: service,
                                helperApp: URL(fileURLWithPath: "/usr/bin/true"), file: file, ping: false)
        let offer = HelperHandoff.take(keychainService: service, file: file)
        #expect(offer == .init(key: key, campusID: "c1", campusName: "Main Campus"))
        #expect(HelperHandoff.take(keychainService: service, file: file) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func nothingWaitingMeansNoOffer() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ho-none-\(UUID().uuidString).json")
        #expect(HelperHandoff.take(keychainService: "ckcore.test.none.\(UUID().uuidString)", file: file) == nil)
    }

    @Test func accessListTrustsTheHelper() throws {
        let service = "ckcore.test.acl.\(UUID().uuidString)"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ho-acl-\(UUID().uuidString).json")
        defer {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
            try? FileManager.default.removeItem(at: file)
        }
        try HelperHandoff.offer(key: "k", campusID: "c", campusName: "n", keychainService: service,
                                helperApp: URL(fileURLWithPath: "/usr/bin/true"), file: file, ping: false)
        let paths = HelperHandoff.trustedPaths(service: service)
        #expect(paths.contains { $0.hasSuffix("/usr/bin/true") }, "trusted: \(paths)")
    }
}
