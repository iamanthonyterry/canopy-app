import Foundation
import Testing
@testable import ChurchKitAuth

struct ConnectFlowTests {
    let key = String(repeating: "ab", count: 24)
    let token = String(repeating: "c0", count: 16)

    @Test func acceptsSessionAndKey() {
        let line = "GET /callback?state=S&church=lifepoint&token=\(token)&supabase=https://x.supabase.co&apikey=pk&key=\(key)&campus=c1&campus_name=Main%20Campus HTTP/1.1"
        guard case .accepted(let r) = ConnectFlow.parse(requestLine: line, state: "S", want: [.session, .key]) else { Issue.record("not accepted"); return }
        #expect(r.church == "lifepoint")
        #expect(r.grant?.project.host == "x.supabase.co")
        #expect(r.campus?.campusName == "Main Campus")
        #expect(r.campus?.key == key)
    }

    @Test func keyOnlyIgnoresMissingToken() {
        let line = "GET /callback?state=S&church=l&key=\(key)&campus=c1 HTTP/1.1"
        guard case .accepted(let r) = ConnectFlow.parse(requestLine: line, state: "S", want: .key) else { Issue.record("not accepted"); return }
        #expect(r.grant == nil)
    }

    @Test func keyIsOptionalWhenSignInIsAlsoAskedFor() {
        let line = "GET /callback?state=S&church=l&token=\(token)&supabase=https://x.supabase.co&apikey=pk HTTP/1.1"
        guard case .accepted(let r) = ConnectFlow.parse(requestLine: line, state: "S", want: [.session, .key]) else { Issue.record("not accepted"); return }
        #expect(r.grant != nil && r.campus == nil)
        // But a malformed key is still refused rather than ignored.
        let bad = "GET /callback?state=S&church=l&token=\(token)&supabase=https://x.supabase.co&apikey=pk&key=zz&campus=c1 HTTP/1.1"
        #expect(ConnectFlow.parse(requestLine: bad, state: "S", want: [.session, .key]) == .invalid)
    }

    @Test func rejectsWrongState() {
        let line = "GET /callback?state=other&church=l&key=\(key)&campus=c1 HTTP/1.1"
        #expect(ConnectFlow.parse(requestLine: line, state: "S", want: .key) == .invalid)
    }

    @Test func rejectsMissingPartsAskedFor() {
        // Asked for both but the site sent only a key.
        let line = "GET /callback?state=S&church=l&key=\(key)&campus=c1 HTTP/1.1"
        #expect(ConnectFlow.parse(requestLine: line, state: "S", want: [.session, .key]) == .invalid)
    }

    @Test func rejectsForeignSupabaseHostAndPlainHTTP() {
        for project in ["https://evil.example.com", "http://x.supabase.co"] {
            let line = "GET /callback?state=S&church=l&token=\(token)&supabase=\(project)&apikey=pk HTTP/1.1"
            #expect(ConnectFlow.parse(requestLine: line, state: "S", want: .session) == .invalid)
        }
    }

    @Test func rejectsMalformedKeyAndOtherPaths() {
        #expect(ConnectFlow.parse(requestLine: "GET /callback?state=S&key=nothex&campus=c HTTP/1.1", state: "S", want: .key) == .invalid)
        #expect(ConnectFlow.parse(requestLine: "GET /favicon.ico HTTP/1.1", state: "S", want: .key) == .notFound)
        #expect(ConnectFlow.parse(requestLine: "POST /callback?state=S HTTP/1.1", state: "S", want: .key) == .notFound)
    }

    @Test func parsesTokenReply() throws {
        let json = #"{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"id":"u","email":"p@x.org"}}"#
        let now = Date(timeIntervalSince1970: 1000)
        let s = try SupabaseAuth.session(from: Data(json.utf8), now: now)
        #expect(s.accessToken == "a" && s.email == "p@x.org" && s.expiresAt == now.addingTimeInterval(3600))
    }
}
