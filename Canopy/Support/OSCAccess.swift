import Foundation

/// Which computers may send OSC to this Mac. Empty means any, as before. Entries are separated by commas, spaces or
/// lines: a full address ("192.168.1.20"), a prefix ending in a dot ("192.168.1."), or "localhost".
enum OSCAccess {
    static let storageKey = "osc.allowedSenders"

    static func allows(host: String, allowList: String = UserDefaults.standard.string(forKey: storageKey) ?? "") -> Bool {
        let entries = allowList.split(whereSeparator: { ", \n\t".contains($0) }).map { $0.lowercased() }
        guard !entries.isEmpty else { return true }
        let sender = normalised(host)
        return entries.contains { entry in
            if entry == "localhost" { return sender == "127.0.0.1" || sender == "::1" }
            if entry.hasSuffix(".") { return sender.hasPrefix(entry) }
            return sender == entry
        }
    }

    /// "::ffff:192.168.1.5%en0" is the same sender as "192.168.1.5".
    static func normalised(_ host: String) -> String {
        var h = host.lowercased()
        if let i = h.firstIndex(of: "%") { h = String(h[..<i]) }
        if h.hasPrefix("::ffff:") { h = String(h.dropFirst(7)) }
        return h
    }
}
