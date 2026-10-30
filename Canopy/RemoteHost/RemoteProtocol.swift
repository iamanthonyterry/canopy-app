import Foundation

/// Wire format shared by Canopy (host) and TailDesk (viewer). Keep the two copies identical.
/// A frame is: u32 big-endian length (type byte + payload), u8 type, payload.
nonisolated enum RemoteMsg: UInt8, Sendable {
    case hello = 1    // viewer -> host, JSON RemoteHello
    case info = 2     // host -> viewer, JSON RemoteInfo
    case config = 3   // host -> viewer, HEVC parameter sets: repeated (u16 length, bytes)
    case frame = 4    // host -> viewer, u8 keyframe flag + AVCC (4-byte length prefixed) HEVC sample
    case input = 5    // viewer -> host, JSON RemoteInput
    case denied = 6   // host -> viewer, UTF-8 reason
    case termOpen = 7   // viewer -> host, JSON RemoteTermSize: start a login shell on a PTY
    case termData = 8   // both ways, raw terminal bytes (viewer keystrokes in, shell output out)
    case termResize = 9 // viewer -> host, JSON RemoteTermSize
    case termExit = 10  // host -> viewer, the shell ended (empty payload)
    case automationSubscribe = 11   // viewer -> host, empty: start sending automation snapshots
    case automationUnsubscribe = 12 // viewer -> host, empty: stop
    case automationSnapshot = 13    // host -> viewer, JSON RemoteAutomationSnapshot, sent when it changes
}

nonisolated struct RemoteHello: Codable, Sendable { var token: String }
nonisolated struct RemoteInfo: Codable, Sendable { var width: Int; var height: Int }
nonisolated struct RemoteTermSize: Codable, Sendable { var cols: Int; var rows: Int }

/// Read-only view of Canopy's automation runs, for the viewer's Automations tab.
nonisolated struct RemoteAutomationSnapshot: Codable, Sendable, Equatable { var runs: [RemoteAutomationRun] }
nonisolated struct RemoteAutomationRun: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var startedAt: Double          // seconds since 1970
    var state: String              // running, paused, waiting, finished, failed, cancelled
    var currentStep: Int?          // index into steps
    var steps: [RemoteAutomationStep]
    var tasks: [RemoteAutomationTask]
    var log: [String]              // the latest lines
    var errors: Int
    var mountError: String?
}
nonisolated struct RemoteAutomationStep: Codable, Sendable, Equatable { var name: String; var status: String } // pending, running, waiting, done, skipped, cancelled
nonisolated struct RemoteAutomationTask: Codable, Sendable, Equatable {
    var file: String
    var device: String
    var phase: String              // queued, downloading, converting, done, error
    var sync: Double               // 0...1
    var convert: Double            // 0...1
    var error: String?
    var eta: Double?               // seconds
}

/// Pointer positions are normalised 0...1 across the streamed display.
nonisolated struct RemoteInput: Codable, Sendable {
    var kind: String          // move, down, up, scroll, key, text
    var x: Double?
    var y: Double?
    var button: Int?          // 0 left, 1 right
    var dx: Double?
    var dy: Double?
    var keyCode: UInt16?      // macOS virtual key code
    var down: Bool?
    var flags: UInt64?        // CGEventFlags raw value (modifiers held for this event)
    var pressure: Double?     // 0...1, from Apple Pencil
    var clickCount: Int?      // 1 single, 2 double... so the Mac sees double-clicks
    var text: String?
}

nonisolated enum RemoteFraming {
    static let maxPayload = 32 * 1024 * 1024

    static func encode(_ type: RemoteMsg, _ payload: Data) -> Data {
        var out = Data()
        var len = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    /// Accumulates stream bytes and yields whole messages. `next()` returns nil when more bytes are needed,
    /// and throws if the peer sends something impossible (the connection should be dropped).
    struct Decoder {
        private var buffer = Data()
        mutating func append(_ d: Data) { buffer.append(d) }

        mutating func next() throws -> (RemoteMsg, Data)? {
            guard buffer.count >= 4 else { return nil }
            let len = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard len >= 1, len <= maxPayload else { throw CocoaError(.coderReadCorrupt) }
            guard buffer.count >= 4 + len else { return nil }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + len)
            buffer = Data(buffer.dropFirst(4 + len))
            guard let type = RemoteMsg(rawValue: body[body.startIndex]) else { return try next() }
            return (type, body.dropFirst())
        }
    }
}
