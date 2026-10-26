import Foundation
import Security

/// Carries an app's data across a bundle id change. Settings and Keychain items
/// are stored per bundle id, so an app that gets a new id would otherwise start
/// blank. Everything here copies and never deletes, so the old app still works
/// if the person goes back to it.
public enum LegacyMigration {
    /// The marker written once a migration has run, so it never repeats.
    static let markerKey = "churchkit.migratedFromBundleID"

    /// Copies the old bundle id's UserDefaults into this app's, then marks it done.
    /// Keys the new app already has are kept. Returns how many keys were copied.
    @discardableResult
    public static func copyDefaults(
        fromBundleID old: String,
        into defaults: UserDefaults = .standard,
        reading read: (String) -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: $0) }
    ) -> Int {
        guard defaults.string(forKey: markerKey) == nil else { return 0 }
        var copied = 0
        for (key, value) in read(old) ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(old, forKey: markerKey)
        return copied
    }

    /// Copies every generic-password item stored under `oldService` to `newService`.
    /// An item the new service already has is kept. The first read of items the old app
    /// created can make macOS ask for the login password once, because the old app's
    /// code identity (which includes its bundle id) is what the Keychain trusts.
    @discardableResult
    public static func copyKeychain(fromService oldService: String, toService newService: String) -> Int {
        // macOS can't return item data together with a list of items, so list the accounts first and read each.
        let list: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var listed: AnyObject?
        guard SecItemCopyMatching(list as CFDictionary, &listed) == errSecSuccess, let items = listed as? [[String: Any]] else { return 0 }
        var copied = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            let read: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: oldService,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
            ]
            var out: AnyObject?
            guard SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { continue }
            let target: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: newService,
                kSecAttrAccount as String: account,
            ]
            if SecItemCopyMatching(target as CFDictionary, nil) == errSecSuccess { continue }
            var add = target
            add[kSecValueData as String] = data
            if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { copied += 1 }
        }
        return copied
    }

    /// The usual call at launch, before anything reads settings: defaults and Keychain together.
    public static func run(fromBundleID old: String, keychainServices: [(old: String, new: String)]) {
        let alreadyDone = UserDefaults.standard.string(forKey: markerKey) != nil
        copyDefaults(fromBundleID: old)
        // Keychain copy is idempotent, but skipping it after the first run avoids a Keychain query on every launch.
        guard !alreadyDone else { return }
        for service in keychainServices { copyKeychain(fromService: service.old, toService: service.new) }
    }
}
