import Foundation
import Security

/// Hands the campus key from Canopy to the Transcriber helper, so signing in once covers both.
///
/// The key goes in the Keychain, not a file, in an item whose access list trusts both apps so the helper
/// can read it without a password prompt (an unattended Mac mini could never answer one). A small file
/// beside it carries the non-secret part, the campus name. A distributed notification, with nothing
/// secret in it, tells a running helper to look. The helper takes the offer, which removes it.
public enum HelperHandoff {
    public struct Offer: Sendable, Equatable {
        public var key: String
        public var campusID: String
        public var campusName: String
    }

    private struct Details: Codable { var campusID: String; var campusName: String }

    /// Not the helper's own `transcriber-key` item, so Canopy never touches the key the helper already uses.
    public static let account = "handoff-key"

    public static let pingName = Notification.Name("com.rosesashumans.churchlandingpage.helper.handoff")

    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Church Landing Page/helper-handoff.json")
    }

    public enum HandoffError: LocalizedError {
        case keychain(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .keychain(let s): "Couldn't store the campus key in the Keychain (error \(s))."
            }
        }
    }

    /// Canopy's side. `helperApp` is the helper's bundle, whose code the Keychain item will trust beside Canopy.
    public static func offer(key: String, campusID: String, campusName: String, keychainService: String, helperApp: URL,
                             file: URL = HelperHandoff.fileURL, ping: Bool = true) throws {
        try store(key: key, service: keychainService, trusting: [helperApp])
        if let data = try? JSONEncoder().encode(Details(campusID: campusID, campusName: campusName)) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        if ping { DistributedNotificationCenter.default().postNotificationName(pingName, object: nil, userInfo: nil, deliverImmediately: true) }
    }

    /// The helper's side. Returns the waiting offer and removes it, or nil if there is none.
    public static func take(keychainService: String, file: URL = HelperHandoff.fileURL) -> Offer? {
        guard let data = try? Data(contentsOf: file), let details = try? JSONDecoder().decode(Details.self, from: data),
              let key = read(service: keychainService) else { return nil }
        try? FileManager.default.removeItem(at: file)
        SecItemDelete(query(service: keychainService) as CFDictionary)
        return Offer(key: key, campusID: details.campusID, campusName: details.campusName)
    }

    // MARK: Keychain

    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read(service: String) -> String? {
        var q = query(service: service)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    // The access-list calls are deprecated, but they are how the file-based Keychain lets a second app
    // read an item without a prompt, and there is no replacement for that.
    private static func store(key: String, service: String, trusting apps: [URL]) throws {
        var trusted: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me { trusted.append(me) }
        for url in apps {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(url.path, &app) == errSecSuccess, let app { trusted.append(app) }
        }
        var access: SecAccess?
        let made = SecAccessCreate("Church Landing Page campus key" as CFString, trusted as CFArray, &access)
        guard made == errSecSuccess, let access else { throw HandoffError.keychain(made) }

        SecItemDelete(query(service: service) as CFDictionary)
        var add = query(service: service)
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccess as String] = access
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw HandoffError.keychain(status) }
    }

    /// For tests: the paths the item's access list trusts.
    static func trustedPaths(service: String) -> [String] {
        var q = query(service: service)
        q[kSecReturnRef as String] = true
        var ref: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess, let item = ref else { return [] }
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item as! SecKeychainItem, &access) == errSecSuccess, let access else { return [] }
        var acls: CFArray?
        guard SecAccessCopyACLList(access, &acls) == errSecSuccess, let list = acls as? [SecACL] else { return [] }
        var paths: [String] = []
        for acl in list {
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &description, &prompt) == errSecSuccess, let trusted = apps as? [SecTrustedApplication] else { continue }
            for app in trusted {
                var data: CFData?
                if SecTrustedApplicationCopyData(app, &data) == errSecSuccess, let data = data as Data? {
                    paths.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .controlCharacters))
                }
            }
        }
        return paths
    }
}
