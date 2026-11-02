import Combine
import ChurchKitAuth
import Foundation

/// The person's own website sign-in, handed to the app by the website's connect page and kept in the Keychain.
/// Canopy's campus key belongs to a campus, not a person, so it can't say who is signed in or which campuses they
/// may see; this can. It is what records a Mac on its campus and lists the other computers.
nonisolated struct AccountSession: Codable, Sendable, Equatable {
    var project: URL
    var apiKey: String
    var session: SupabaseSession
}

/// The Keychain side of it: the refresh token is a password, so it never goes in UserDefaults.
@MainActor
enum AccountSessionStore {
    private static let key = "account-session"

    static func load() -> AccountSession? {
        guard let text = KeychainStore.get(key: key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AccountSession.self, from: data)
    }

    static func save(_ value: AccountSession) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        KeychainStore.set(String(decoding: data, as: UTF8.self), key: key)
    }

    static func clear() { KeychainStore.delete(key: key) }
}

/// One Mac, as the website lists it for the signed-in person.
nonisolated struct RegisteredComputer: Identifiable, Decodable, Equatable, Sendable {
    var id: String
    var name: String
    var campus: String
    var campusName: String
    var church: String
    var lastSeen: Date?

    private enum CodingKeys: String, CodingKey { case id, name, campus, campusName, church, lastSeen }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        campus = try c.decodeIfPresent(String.self, forKey: .campus) ?? ""
        campusName = try c.decodeIfPresent(String.self, forKey: .campusName) ?? ""
        church = try c.decodeIfPresent(String.self, forKey: .church) ?? ""
        lastSeen = Self.date(try c.decodeIfPresent(String.self, forKey: .lastSeen))
    }

    /// Postgres sends timestamps with six fractional digits, which the plain ISO 8601 style refuses.
    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
    }
}

/// The Macs signed in to Canopy, and this Mac's own row on the website. A Mac is recorded for whoever signed in on
/// it, on the campus they chose; the list is what that person may see: every computer on the campuses their website
/// account can use (a church admin sees all of them).
@MainActor
final class ComputerRegistry: ObservableObject {
    static let shared = ComputerRegistry()

    @Published private(set) var computers: [RegisteredComputer] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// False when this Mac has only the campus key (no person's sign-in), so there is nobody to ask.
    @Published private(set) var signedIn = false

    private var busy = false

    private init() { signedIn = AccountSessionStore.load() != nil }

    /// This Mac's own id: made once, then kept, so the website knows it is the same computer.
    static var deviceID: String {
        let key = "computer.deviceID"
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// The name people will recognize in the list (System Settings → General → Sharing).
    static var name: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    /// The person's session, refreshed when the access token is about to expire (it lasts an hour).
    private func session() async throws -> AccountSession {
        guard var stored = AccountSessionStore.load() else {
            signedIn = false
            throw RegistryError("Sign in with the website to see the computers on your campuses.", status: 401)
        }
        if stored.session.expiresAt.timeIntervalSinceNow < 60 {
            do {
                stored.session = try await SupabaseAuth.refresh(project: stored.project, apiKey: stored.apiKey, session: stored.session)
                AccountSessionStore.save(stored)
            } catch {
                AccountSessionStore.clear()
                signedIn = false
                throw RegistryError("Your website sign-in has expired. Sign in again in Settings → Connections.", status: 401)
            }
        }
        return stored
    }

    /// Takes the session the website just handed over (called after signing in).
    func adopt(_ grant: ConnectResult.Grant) async {
        do {
            let session = try await SupabaseAuth.verify(project: grant.project, apiKey: grant.apiKey, tokenHash: grant.token)
            AccountSessionStore.save(AccountSession(project: grant.project, apiKey: grant.apiKey, session: session))
            signedIn = true
            error = nil
        } catch {
            signedIn = false
            self.error = error.localizedDescription
        }
    }

    /// Forgets the person's sign-in (on Disconnect); the Mac no longer appears for them.
    func signOut() {
        AccountSessionStore.clear()
        computers = []
        signedIn = false
        error = nil
    }

    /// Records this Mac on its campus, or refreshes when it was last seen.
    func register(campusID: String) async {
        guard !campusID.isEmpty, !FileTest.isSafeMode else { return }
        do {
            let stored = try await session()
            guard let site = CampusConnection.shared.origin else { return }
            let body: [String: Any] = ["deviceId": Self.deviceID, "name": Self.name, "campusId": campusID]
            var request = URLRequest(url: site.appendingPathComponent("api/computers"), timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("Bearer \(stored.session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(stored.apiKey, forHTTPHeaderField: "apikey")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data: data)
            error = nil
        } catch {
            note(error)
        }
    }

    /// Reads the computers the signed-in person may see.
    func refresh() async {
        guard !FileTest.isSafeMode, !busy else { return }
        busy = true
        loading = true
        defer { busy = false; loading = false }
        do {
            let stored = try await session()
            guard let site = CampusConnection.shared.origin else { throw RegistryError("Connect a campus first.") }
            var request = URLRequest(url: site.appendingPathComponent("api/computers"), timeoutInterval: 15)
            request.setValue("Bearer \(stored.session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(stored.apiKey, forHTTPHeaderField: "apikey")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data: data)
            struct Reply: Decodable { var computers: [RegisteredComputer] }
            computers = try JSONDecoder().decode(Reply.self, from: data).computers
                .sorted { ($0.campusName.lowercased(), $0.name.lowercased()) < ($1.campusName.lowercased(), $1.name.lowercased()) }
            signedIn = true
            error = nil
        } catch {
            note(error)
        }
    }

    private func note(_ error: Error) {
        if let e = error as? RegistryError, e.status == 401 { signedIn = false }
        self.error = error.localizedDescription
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw RegistryError(message ?? (status == 401 ? "Sign in again on the website." : "The website answered \(status)."), status: status)
        }
    }
}

nonisolated struct RegistryError: LocalizedError {
    let message: String
    let status: Int
    init(_ message: String, status: Int = 0) { self.message = message; self.status = status }
    var errorDescription: String? { message }
}
