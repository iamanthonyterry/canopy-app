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
}

nonisolated struct RemoteHello: Codable, Sendable { var token: String }
nonisolated struct RemoteInfo: Codable, Sendable { var width: Int; var height: Int }
nonisolated struct RemoteTermSize: Codable, Sendable { var cols: Int; var rows: Int }

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
