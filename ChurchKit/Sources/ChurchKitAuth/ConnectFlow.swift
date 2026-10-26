import AppKit
import Foundation
import Network
import Security

/// Which Church Landing Page app is signing in. Only changes the wording on the website's connect page.
public enum ConnectApp: String, Sendable { case canopy, transcriber }

/// What the app wants back from the website.
public struct ConnectWant: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// A one-time token for a Supabase session of the person's own (Canopy).
    public static let session = ConnectWant(rawValue: 1)
    /// The chosen campus's device key (the Transcriber helper).
    public static let key = ConnectWant(rawValue: 2)

    var queryValue: String {
        [contains(.session) ? "session" : nil, contains(.key) ? "key" : nil].compactMap { $0 }.joined(separator: ",")
    }
}

public struct ConnectRequest: Sendable {
    public var app: ConnectApp
    public var want: ConnectWant
    /// The website's origin, e.g. https://churchlandingpage.rosesashumans.com
    public var site: URL
    /// The connect page. The old per-app pages (`auth/canopy`, `auth/transcriber`) still work with the old callback.
    public var path = "auth/connect"

    public init(app: ConnectApp, want: ConnectWant, site: URL) {
        self.app = app
        self.want = want
        self.site = site
    }
}

public struct ConnectResult: Sendable, Equatable {
    public struct Grant: Sendable, Equatable {
        public var token: String
        public var project: URL
        public var apiKey: String
    }
    public struct CampusKey: Sendable, Equatable {
        public var key: String
        public var campusID: String
        public var campusName: String
    }
    public var church: String
    /// Present when `.session` was asked for. Trade it with `SupabaseAuth.verify`.
    public var grant: Grant?
    /// Present when `.key` was asked for.
    public var campus: CampusKey?
}

public enum ConnectError: LocalizedError, Sendable {
    case timedOut, badSite, listener(String)
    public var errorDescription: String? {
        switch self {
        case .timedOut: "Sign-in wasn't finished in time. Try again."
        case .badSite: "The website address isn't valid. It must start with https://."
        case .listener(let m): "Couldn't start sign-in (\(m))."
        }
    }
}

/// Signs an app in through the church website. The app listens on this Mac's
/// loopback address (127.0.0.1 only), opens the website's connect page in the
/// browser, and the site redirects back with a one-shot callback carrying
/// whatever was asked for. Used once per `run`; make a new one to try again.
public final class ConnectFlow: @unchecked Sendable {
    private let queue = DispatchQueue(label: "church.landingpage.connect")
    private let state: String = {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<ConnectResult, Error>?
    private var request: ConnectRequest?
    private var done = false

    public init() {}

    public func run(_ request: ConnectRequest) async throws -> ConnectResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async { self.begin(request, cont) }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    /// Cancel from outside, e.g. a Cancel button.
    public func cancel() { queue.async { self.finish(.failure(CancellationError())) } }

    private func begin(_ request: ConnectRequest, _ cont: CheckedContinuation<ConnectResult, Error>) {
        guard !done else { return cont.resume(throwing: CancellationError()) }
        continuation = cont
        self.request = request
        let site = request.site
        guard site.scheme == "https" || site.host == "localhost" || site.host == "127.0.0.1", site.host != nil else {
            return finish(.failure(ConnectError.badSite))
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)  // never reachable from the network
        guard let listener = try? NWListener(using: params) else { return finish(.failure(ConnectError.listener("no port available"))) }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] in self?.handle($0) }
        listener.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                guard let port = listener.port?.rawValue,
                      var c = URLComponents(url: site.appendingPathComponent(request.path), resolvingAgainstBaseURL: false) else { return }
                c.queryItems = [
                    URLQueryItem(name: "port", value: String(port)), URLQueryItem(name: "state", value: self.state),
                    URLQueryItem(name: "app", value: request.app.rawValue), URLQueryItem(name: "want", value: request.want.queryValue),
                ]
                if let url = c.url { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            case .failed(let e):
                self.finish(.failure(ConnectError.listener(e.localizedDescription)))
            default: break
            }
        }
        listener.start(queue: queue)
        // Don't leave a listener open forever if the browser step is abandoned.
        queue.asyncAfter(deadline: .now() + 300) { [weak self] in self?.finish(.failure(ConnectError.timedOut)) }
    }

    private func finish(_ result: Result<ConnectResult, Error>) {
        guard !done else { return }
        done = true
        listener?.cancel()
        listener = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = self.request else { return conn.cancel() }
            let line = String(decoding: data, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            switch Self.parse(requestLine: line, state: self.state, want: request.want) {
            case .notFound:
                self.reply(conn, app: request.app, status: "404 Not Found", body: "Not found")
            case .invalid:
                self.reply(conn, app: request.app, status: "400 Bad Request",
                           body: "This sign-in link isn't valid. Start again from the app.")
            case .accepted(let result):
                let name = result.campus?.campusName ?? result.church
                self.reply(conn, app: request.app, status: "200 OK",
                           body: "<h2>Connected\(name.isEmpty ? "" : " to " + Self.escape(name))</h2><p>You can close this tab and return to the app.</p>")
                self.finish(.success(result))
            }
        }
    }

    enum Parsed: Equatable { case notFound, invalid, accepted(ConnectResult) }

    /// Reads `GET /callback?state=…` and accepts it only if the state matches and everything asked for is present and well-formed.
    static func parse(requestLine line: String, state: String, want: ConnectWant) -> Parsed {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let c = URLComponents(string: "http://127.0.0.1" + parts[1]), c.path == "/callback" else {
            return .notFound
        }
        func item(_ n: String) -> String { c.queryItems?.first { $0.name == n }?.value ?? "" }
        func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
        guard item("state") == state else { return .invalid }

        var result = ConnectResult(church: item("church"))
        if want.contains(.session) {
            let project = URL(string: item("supabase"))
            guard matches(item("token"), "^[0-9a-f]{20,128}$"), let project, project.scheme == "https",
                  project.host?.hasSuffix(".supabase.co") == true, !item("apikey").isEmpty else { return .invalid }
            result.grant = .init(token: item("token"), project: project, apiKey: item("apikey"))
        }
        // Asked for with a sign-in, the key is a bonus: a church with no campuses sends none. Asked for alone, it is required.
        if want.contains(.key), !(want.contains(.session) && item("key").isEmpty) {
            guard matches(item("key"), "^[0-9a-f]{48}$"), !item("campus").isEmpty else { return .invalid }
            result.campus = .init(key: item("key"), campusID: item("campus"), campusName: item("campus_name"))
        }
        return .accepted(result)
    }

    private func reply(_ conn: NWConnection, app: ConnectApp, status: String, body: String) {
        // The address bar holds the key until replaced, so swap it out of the browser's history right away.
        let title = app == .canopy ? "Canopy" : "Transcriber"
        let html = "<!doctype html><meta charset=utf-8><title>\(title)</title><script>history.replaceState(null,'','/done')</script>"
            + "<body style=\"font-family:-apple-system,sans-serif;text-align:center;margin-top:20vh\">\(body)</body>"
        let payload = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension ConnectResult {
    init(church: String) { self.church = church }
}
