import Foundation

/// A person's Supabase session. Canopy sends its access token with every request,
/// so Row Level Security decides what they can read and change.
public struct SupabaseSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var userID: String
    public var email: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userID: String, email: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
        self.email = email
    }
}

public struct AuthError: LocalizedError, Sendable {
    public var message: String
    /// 401 means the session can no longer be refreshed and the person must sign in again.
    public var status: Int
    public var errorDescription: String? { message }
    public init(_ message: String, status: Int = 0) { self.message = message; self.status = status }
}

/// The two Supabase Auth calls both apps need. Requests only, no state.
public enum SupabaseAuth {
    private struct TokenReply: Decodable {
        struct User: Decodable { var id: String; var email: String? }
        var access_token: String
        var refresh_token: String
        var expires_in: Double
        var user: User
    }

    static func session(from data: Data, now: Date = Date()) throws -> SupabaseSession {
        let r = try JSONDecoder().decode(TokenReply.self, from: data)
        return SupabaseSession(accessToken: r.access_token, refreshToken: r.refresh_token,
                               expiresAt: now.addingTimeInterval(r.expires_in), userID: r.user.id, email: r.user.email ?? "")
    }

    /// Trades the one-time sign-in token from the website's connect page for a session of the app's own.
    public static func verify(project: URL, apiKey: String, tokenHash: String) async throws -> SupabaseSession {
        var req = URLRequest(url: project.appendingPathComponent("auth/v1/verify"), timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["type": "magiclink", "token_hash": tokenHash])
        let (data, res) = try await URLSession.shared.data(for: req)
        guard (res as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError("The sign-in link was refused or has expired. Try signing in again.")
        }
        return try session(from: data)
    }

    /// Trades a refresh token for a new session.
    public static func refresh(project: URL, apiKey: String, session: SupabaseSession) async throws -> SupabaseSession {
        var c = URLComponents(url: project.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": session.refreshToken])
        let data: Data, res: URLResponse
        do { (data, res) = try await URLSession.shared.data(for: req) }
        catch { throw AuthError("Couldn't reach your church's database. \(error.localizedDescription)") }
        guard (res as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError("Your sign-in has expired. Sign in again.", status: 401)
        }
        return try Self.session(from: data)
    }
}
