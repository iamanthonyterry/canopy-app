import AVFoundation
import Combine
import CoreMedia
import Foundation
import IrohLib

/// A pairing code as Remote Access shows it: `ticket|token`.
nonisolated struct RemotePairingCode: Equatable, Sendable {
    var ticket: String
    var token: String

    init?(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bar = trimmed.firstIndex(of: "|") else { return nil }
        let ticket = String(trimmed[..<bar]), token = String(trimmed[trimmed.index(after: bar)...])
        guard !ticket.isEmpty, !token.isEmpty else { return nil }
        self.ticket = ticket; self.token = token
    }
}

/// Where the picture sits inside a view, and how view points map back to the remote screen.
nonisolated enum RemoteScreenGeometry {
    /// The aspect-fit rectangle the stream occupies in `bounds`.
    static func videoRect(remote: CGSize, in bounds: CGRect) -> CGRect {
        guard remote.width > 0, remote.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / remote.width, bounds.height / remote.height)
        let w = remote.width * scale, h = remote.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// A point in the view as 0...1 across the remote screen, or nil if it is in the letterbox bars.
    /// With `clamp`, points outside are pulled to the edge instead (used while dragging).
    static func normalized(_ p: CGPoint, remote: CGSize, in bounds: CGRect, clamp: Bool = false) -> CGPoint? {
        let r = videoRect(remote: remote, in: bounds)
        guard r.width > 0, r.height > 0 else { return nil }
        // Inclusive of every edge, so the last row and column of the remote screen can be reached.
        if !clamp && (p.x < r.minX || p.x > r.maxX || p.y < r.minY || p.y > r.maxY) { return nil }
        return CGPoint(x: min(max((p.x - r.minX) / r.width, 0), 1), y: min(max((p.y - r.minY) / r.height, 0), 1))
    }
}

/// Viewer for another Mac's Remote Host: H.265 video in, pointer and keyboard events out. The Mac-side twin of
/// Remote Access's StreamSession; both speak the protocol in RemoteProtocol.swift.
@MainActor
final class RemoteViewerSession: ObservableObject {
    enum Status: Equatable { case idle, connecting, connected, failed(String) }

    @Published private(set) var status: Status = .idle
    @Published private(set) var remoteSize: CGSize = .zero

    /// Samples ready to display; the view enqueues them on its AVSampleBufferDisplayLayer.
    var onSample: ((CMSampleBuffer) -> Void)?

    private let code: RemotePairingCode?
    private var decoder = RemoteFraming.Decoder()
    private var format: CMVideoFormatDescription?
    private var task: Task<Void, Never>?
    private var endpoint: Endpoint?
    private var outbox: AsyncStream<Data>.Continuation?
    /// Bumped on every connect, so a cancelled connection winding down can't touch its replacement.
    private var generation = 0

    init(pairingCode: String) { code = RemotePairingCode(pairingCode) }

    func connect() {
        guard let code else {
            status = .failed("This Mac's pairing code is not valid. Copy it again from Settings → Connections on that Mac.")
            return
        }
        generation += 1
        let gen = generation
        status = .connecting
        decoder = RemoteFraming.Decoder()
        format = nil
        task = Task { [weak self] in
            do {
                let ep = try await Endpoint.bind(options: EndpointOptions(alpns: [RemoteHostService.alpn]))
                await MainActor.run { self?.endpoint = ep }
                let addr = try EndpointTicket.fromString(str: code.ticket).endpointAddr()
                let conn = try await ep.connect(addr: addr, alpn: RemoteHostService.alpn)
                let bi = try await conn.openBi()
                let send = bi.send(), recv = bi.recv()

                // One writer, so messages leave in the order they were queued.
                let (stream, cont) = AsyncStream<Data>.makeStream()
                await MainActor.run {
                    self?.outbox = cont
                    if let hello = try? JSONEncoder().encode(RemoteHello(token: code.token)) { self?.send(.hello, hello) }
                }
                let writer = Task { for await d in stream { try? await send.writeAll(buf: d) } }
                defer { writer.cancel() }

                while !Task.isCancelled {
                    let chunk = try await recv.read(sizeLimit: 256 * 1024)
                    if chunk.isEmpty { break }
                    let ok = await MainActor.run { self?.feed(Data(chunk)) ?? false }
                    if !ok { break }
                }
                await MainActor.run { self?.closed(nil, gen) }
            } catch {
                await MainActor.run { self?.closed(error, gen) }
            }
        }
    }

    func disconnect() {
        task?.cancel(); task = nil
        outbox?.finish(); outbox = nil
        if let ep = endpoint { endpoint = nil; Task { try? await ep.close() } }
        generation += 1
        buttonHeld = false
        status = .idle
    }

    func reconnect() { disconnect(); connect() }

    private func closed(_ error: Error?, _ gen: Int) {
        guard gen == generation else { return }
        outbox?.finish(); outbox = nil
        switch status {
        case .failed, .idle: return
        default: status = .failed(error.map { "Can't reach that Mac: \($0.localizedDescription)" } ?? "That Mac closed the connection")
        }
    }

    /// Feeds received bytes to the message decoder. Returns false if the data was invalid.
    private func feed(_ data: Data) -> Bool {
        decoder.append(data)
        do {
            while let (type, payload) = try decoder.next() { handle(type, payload) }
            return true
        } catch {
            status = .failed("Bad data from that Mac")
            return false
        }
    }

    private func handle(_ type: RemoteMsg, _ payload: Data) {
        switch type {
        case .info:
            if let info = try? JSONDecoder().decode(RemoteInfo.self, from: payload) {
                remoteSize = CGSize(width: info.width, height: info.height)
            }
        case .config:
            makeFormat(payload)
        case .frame:
            guard payload.count > 1, let format else { return }
            enqueue(Data(payload.dropFirst()), format: format)
            if status != .connected { status = .connected }
        case .denied:
            status = .failed(String(decoding: payload, as: UTF8.self))
            task?.cancel()
        default: break
        }
    }

    private func makeFormat(_ cfg: Data) {
        var sets: [[UInt8]] = []
        var i = cfg.startIndex
        while i + 2 <= cfg.endIndex {
            let len = Int(cfg[i]) << 8 | Int(cfg[i + 1])
            i += 2
            guard i + len <= cfg.endIndex else { break }
            sets.append(Array(cfg[i ..< i + len]))
            i += len
        }
        guard !sets.isEmpty else { return }
        let ptrs = sets.map { s -> UnsafePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
            p.initialize(from: s, count: s.count)
            return UnsafePointer(p)
        }
        defer { ptrs.forEach { $0.deallocate() } }
        var fd: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs,
            parameterSetSizes: sets.map { $0.count }, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
        guard status == noErr, let fd else { return }
        format = fd
        // The picture is letterboxed by the stream's real shape, so pointer maths must use it, not the host's reported size.
        let d = CMVideoFormatDescriptionGetPresentationDimensions(fd, usePixelAspectRatio: true, useCleanAperture: true)
        if d.width > 0, d.height > 0, d != remoteSize { remoteSize = d }
    }

    private func enqueue(_ bytes: Data, format: CMVideoFormatDescription) {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block, CMBlockBufferAssureBlockMemory(block) == kCMBlockBufferNoErr else { return }
        let copied = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copied == kCMBlockBufferNoErr else { return }
        var sample: CMSampleBuffer?
        var size = bytes.count
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        // Show frames as soon as they decode; this is live video, not a timeline.
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        onSample?(sample)
    }

    // MARK: Send

    private func send(_ type: RemoteMsg, _ payload: Data) {
        outbox?.yield(RemoteFraming.encode(type, payload))
    }

    private func sendInput(_ input: RemoteInput) {
        guard status == .connected, let data = try? JSONEncoder().encode(input) else { return }
        send(.input, data)
    }

    // MARK: Pointer and keyboard (positions are 0...1 across the remote screen)

    private var buttonHeld = false

    func pointerMoved(to p: CGPoint) {
        sendInput(RemoteInput(kind: buttonHeld ? "drag" : "move", x: p.x, y: p.y, button: 0))
    }

    func pointerDragged(to p: CGPoint, right: Bool) {
        sendInput(RemoteInput(kind: "drag", x: p.x, y: p.y, button: right ? 1 : 0))
    }

    func pointerDown(at p: CGPoint, right: Bool, clickCount: Int, flags: UInt64) {
        buttonHeld = !right
        sendInput(RemoteInput(kind: "down", x: p.x, y: p.y, button: right ? 1 : 0, flags: flags, clickCount: clickCount))
    }

    func pointerUp(at p: CGPoint, right: Bool, clickCount: Int, flags: UInt64) {
        buttonHeld = false
        sendInput(RemoteInput(kind: "up", x: p.x, y: p.y, button: right ? 1 : 0, flags: flags, clickCount: clickCount))
    }

    func scroll(dx: Double, dy: Double) { sendInput(RemoteInput(kind: "scroll", dx: dx, dy: dy)) }

    func key(_ code: UInt16, down: Bool, flags: UInt64) {
        sendInput(RemoteInput(kind: "key", keyCode: code, down: down, flags: flags))
    }
}
