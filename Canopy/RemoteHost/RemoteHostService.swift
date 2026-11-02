import Combine
import Foundation
import IrohLib
import Security

/// Lets a paired Remote Access viewer see and control this Mac. Off by default; turn on with the
/// `remoteHostEnabled` setting.
///
/// Viewers connect through Iroh: peer-to-peer with a relay fallback, so it works from any network with nothing
/// forwarded or installed. The viewer enters the pairing code (ticket + token), and the token is checked too.
@MainActor
final class RemoteHostService: ObservableObject {
    static let shared = RemoteHostService()
    static let enabledKey = "remoteHostEnabled"
    /// Wire name agreed with the viewer app. Kept as `taildesk` after the rename to Remote Access so
    /// already-installed apps still connect.
    nonisolated static let alpn = Data("taildesk/stream/1".utf8)
    static let tokenKey = "remoteHostToken"
    static let irohKeyKey = "remoteHostIrohKey"

    @Published private(set) var isRunning = false
    /// The Iroh ticket for this Mac, once the endpoint is online. Empty until then.
    @Published private(set) var irohTicket = ""

    private var endpoint: Endpoint?
    private var acceptTask: Task<Void, Never>?
    private var viewer: Viewer?
    private let encoder = ScreenEncoder()
    private let secrets: RemoteHostSecrets
    private let makeToken: @Sendable () -> String

    /// The pairing token the viewer must present. Created once, kept in the Keychain.
    @Published private(set) var pairingToken = ""

    /// What to type into Remote Access: `ticket|token`. Empty until the ticket is ready.
    var pairingCode: String { irohTicket.isEmpty ? "" : "\(irohTicket)|\(pairingToken)" }

    init(secrets: RemoteHostSecrets = KeychainRemoteHostSecrets(),
         makeToken: @escaping @Sendable () -> String = { RemoteHostService.randomToken() }) {
        self.secrets = secrets
        self.makeToken = makeToken
        pairingToken = secrets.get(Self.tokenKey) ?? ""
    }

    /// 18 random bytes in base64url: unguessable, and short enough to carry inside a pairing code.
    nonisolated static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    /// Reads the saved token, or makes and saves one the first time it is needed.
    @discardableResult
    private func ensurePairingToken() -> String {
        if !pairingToken.isEmpty { return pairingToken }
        let t = makeToken()
        secrets.set(t, for: Self.tokenKey)
        pairingToken = t
        return t
    }

    /// Replaces the pairing token, so a code copied earlier stops working. The iPad using the old code is
    /// disconnected, because the running viewer holds the token it authenticated with.
    func rotatePairingCode() {
        let t = makeToken()
        secrets.set(t, for: Self.tokenKey)
        pairingToken = t
        disconnectViewer()
    }

    private func disconnectViewer() {
        guard let v = viewer else { return }
        viewer = nil
        v.close()
        encoder.stop()
    }

    /// Replaces the Mac's Iroh identity along with the pairing token, so a code copied earlier can no longer
    /// even find this Mac on the network. The endpoint is rebound to a fresh key, so every paired device has
    /// to be added again with the new code.
    func resetIdentity() {
        let wasRunning = isRunning
        if wasRunning { stop() }
        secrets.delete(Self.irohKeyKey)
        irohTicket = ""
        rotatePairingCode()   // a new identity deserves a new token too
        if wasRunning { start() }
    }

    /// The Mac's Iroh identity, kept so the pairing code stays the same between launches.
    private func irohSecretKey() -> Data {
        if let s = secrets.get(Self.irohKeyKey), let d = Data(base64Encoded: s), d.count == 32 { return d }
        let d = SecretKey.generate().toBytes()
        secrets.set(d.base64EncodedString(), for: Self.irohKeyKey)
        return d
    }

    /// The Settings switch: remembers the choice and starts or stops the host.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    /// At launch: only if it was left on, and never prompting. Missing permissions show as a warning in Settings.
    func startIfEnabled() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() }
    }

    func start() {
        guard !isRunning else { return }
        ensurePairingToken()   // create it now so it is there to read in Settings
        let key = irohSecretKey()
        isRunning = true

        acceptTask = Task { [weak self] in
            do {
                let ep = try await Endpoint.bind(options: EndpointOptions(secretKey: key, alpns: [Self.alpn]))
                await MainActor.run { self?.endpoint = ep }
                await ep.online()
                let ticket = try EndpointTicket.fromAddr(addr: ep.addr()).description
                await MainActor.run { self?.irohTicket = ticket }
                while let incoming = await ep.acceptNext() {
                    Task { [weak self] in
                        guard let conn = try? await incoming.accept().connect(),
                              let bi = try? await conn.acceptBi() else { return }
                        let link = IrohLink(connection: conn, send: bi.send(), recv: bi.recv())
                        await MainActor.run { self?.accept(link) }
                    }
                }
            } catch {
                // Offline at launch, say: stay off; turning Remote Host off and on retries.
            }
        }
    }

    func stop() {
        viewer?.close()
        viewer = nil
        acceptTask?.cancel(); acceptTask = nil
        if let ep = endpoint { endpoint = nil; Task { try? await ep.close() } }
        irohTicket = ""
        encoder.stop()
        isRunning = false
    }

    private func accept(_ link: RemoteLink) {
        viewer?.close()   // one viewer at a time; the newest wins
        let v = Viewer(link: link, token: pairingToken, encoder: encoder)
        v.onClose = { [weak self, weak v] in
            Task { @MainActor in
                guard let self, let v, self.viewer === v else { return }
                self.viewer = nil
                self.encoder.stop()
            }
        }
        viewer = v
        link.start(onData: { [weak v] d in v?.feed(d) }, onEnd: { [weak v] in v?.close() })
        v.armAuthTimeout()
    }
}

// MARK: - Link

/// A byte pipe to one viewer, so the viewer logic doesn't depend on the transport.
nonisolated protocol RemoteLink: AnyObject, Sendable {
    func start(onData: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void)
    func send(_ data: Data)
    func close()
}

private nonisolated final class IrohLink: RemoteLink, @unchecked Sendable {
    private let connection: Connection
    private let sendStream: SendStream
    private let recvStream: RecvStream
    private let outbox: AsyncStream<Data>
    private let cont: AsyncStream<Data>.Continuation
    private var tasks: [Task<Void, Never>] = []

    init(connection: Connection, send: SendStream, recv: RecvStream) {
        self.connection = connection; sendStream = send; recvStream = recv
        (outbox, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    func start(onData: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) {
        let s = sendStream, r = recvStream, box = outbox
        // One writer task keeps messages in order.
        tasks.append(Task { for await d in box { if (try? await s.writeAll(buf: d)) == nil { break } } })
        tasks.append(Task {
            while !Task.isCancelled {
                guard let chunk = try? await r.read(sizeLimit: 64 * 1024), !chunk.isEmpty else { break }
                onData(Data(chunk))
            }
            onEnd()
        })
    }

    func send(_ data: Data) { cont.yield(data) }

    func close() {
        cont.finish()
        tasks.forEach { $0.cancel() }
        try? connection.close(errorCode: 0, reason: Data())
    }
}

// MARK: - Viewer

/// One connected viewer. All state lives on its own serial queue.
private nonisolated final class Viewer: @unchecked Sendable {
    private let link: RemoteLink
    private let token: String
    private let encoder: ScreenEncoder
    private let queue = DispatchQueue(label: "canopy.remote.viewer")
    private var decoder = RemoteFraming.Decoder()
    private var authed = false
    private var closed = false
    private var terminal: TerminalHost?
    private var automations: AutomationHost?
    var onClose: (@Sendable () -> Void)?

    init(link: RemoteLink, token: String, encoder: ScreenEncoder) {
        self.link = link; self.token = token; self.encoder = encoder
    }

    /// Drops viewers that never authenticate.
    func armAuthTimeout() {
        queue.asyncAfter(deadline: .now() + 10) { [self] in if !authed { close() } }
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            terminal?.stop(); terminal = nil
            stopAutomations()
            link.close()
            onClose?()
        }
    }

    func feed(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            decoder.append(data)
            do {
                while let (type, payload) = try decoder.next() { handle(type, payload) }
            } catch { close() }
        }
    }

    private func send(_ type: RemoteMsg, _ payload: Data) {
        link.send(RemoteFraming.encode(type, payload))
    }

    private func handle(_ type: RemoteMsg, _ payload: Data) {
        switch type {
        case .hello:
            guard let hello = try? JSONDecoder().decode(RemoteHello.self, from: payload),
                  Self.constantTimeEqual(hello.token, token) else {
                send(.denied, Data("Wrong pairing token".utf8))
                queue.asyncAfter(deadline: .now() + 0.5) { [self] in close() }
                return
            }
            authed = true
            Task { await startStreaming() }
        case .input:
            guard authed, let input = try? JSONDecoder().decode(RemoteInput.self, from: payload) else { return }
            InputInjector.apply(input)
        case .termOpen:
            guard authed, terminal == nil, let size = try? JSONDecoder().decode(RemoteTermSize.self, from: payload) else { return }
            let t = TerminalHost(
                onOutput: { [weak self] data in self?.queue.async { self?.send(.termData, data) } },
                onExit: { [weak self] in
                    self?.queue.async { self?.terminal = nil; self?.send(.termExit, Data()) }
                })
            terminal = t
            t.start(cols: size.cols, rows: size.rows)
        case .termData:
            guard authed else { return }
            terminal?.write(payload)
        case .termResize:
            guard authed, let size = try? JSONDecoder().decode(RemoteTermSize.self, from: payload) else { return }
            terminal?.resize(cols: size.cols, rows: size.rows)
        case .automationSubscribe:
            guard authed, automations == nil else { return }
            let host = AutomationHost(onSnapshot: { [weak self] data in
                self?.queue.async { self?.send(.automationSnapshot, data) }
            })
            automations = host
            Task { @MainActor in host.start() }
        case .automationUnsubscribe:
            guard authed else { return }
            stopAutomations()
        default: break
        }
    }

    private func stopAutomations() {
        guard let host = automations else { return }
        automations = nil
        Task { @MainActor in host.stop() }
    }

    private func startStreaming() async {
        encoder.onConfig = { [weak self] cfg in self?.queue.async { self?.send(.config, cfg) } }
        encoder.onFrame = { [weak self] key, bytes in
            self?.queue.async { self?.send(.frame, Data([key ? 1 : 0]) + bytes) }
        }
        do {
            let size = try await encoder.start()
            let info = try JSONEncoder().encode(RemoteInfo(width: Int(size.width), height: Int(size.height)))
            queue.async { [self] in send(.info, info); encoder.requestKeyframe() }
        } catch {
            queue.async { [self] in
                send(.denied, Data("Screen capture failed. Allow Canopy in Privacy & Security > Screen Recording.".utf8))
                queue.asyncAfter(deadline: .now() + 0.5) { [self] in close() }
            }
        }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
