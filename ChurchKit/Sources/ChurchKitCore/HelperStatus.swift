import Foundation

/// What the Transcriber helper tells Canopy about itself. The helper writes this to a
/// small file in the shared folder; Canopy reads it to show status without any
/// connection between the two processes. A file that stops being refreshed means the helper has stopped.
public struct HelperStatus: Codable, Sendable, Equatable {
    public var running: Bool
    public var listening: Bool
    /// The campus this Mac sends to, or empty when not signed in.
    public var connectedTo: String
    /// Set when the feed is silent or clipping.
    public var warning: String?
    public var version: String
    public var updatedAt: Date

    public init(running: Bool, listening: Bool, connectedTo: String, warning: String? = nil, version: String, updatedAt: Date = Date()) {
        self.running = running
        self.listening = listening
        self.connectedTo = connectedTo
        self.warning = warning
        self.version = version
        self.updatedAt = updatedAt
    }

    /// The helper refreshes its status at least this often while it is alive.
    public static let heartbeat: TimeInterval = 30

    /// True when the status is too old to trust: the helper quit or crashed since writing it.
    public func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(updatedAt) > Self.heartbeat * 3 }

    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Church Landing Page/helper-status.json")
    }

    public func write(to url: URL = HelperStatus.fileURL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL = HelperStatus.fileURL) -> HelperStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HelperStatus.self, from: data)
    }

    /// Removes the file when the helper quits cleanly, so Canopy shows "not running" at once rather than after the timeout.
    public static func clear(at url: URL = HelperStatus.fileURL) { try? FileManager.default.removeItem(at: url) }
}
