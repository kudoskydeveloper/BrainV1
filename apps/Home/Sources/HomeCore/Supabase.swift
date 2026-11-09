import Foundation

/// The signed-in member. Saved to a file only the user can read (`session.json`), so the app and the MCP server share it.
public struct Session: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expires: Date
    public var userId: String
    public var email: String?
}

public struct SupabaseError: LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public var errorDescription: String? { message }
}

/// Minimal Supabase client over its REST APIs (Auth + PostgREST), no SDK.
public final class Supabase: @unchecked Sendable {
    let url: URL
    let key: String
    let sessionFile: URL
    private let lock = NSLock()
    private var cached: Session?

    public init(url: URL = Config.supabaseURL, key: String = Config.supabaseKey, folder: URL = Store.folder) {
        self.url = url; self.key = key
        sessionFile = folder.appendingPathComponent("session.json")
        cached = try? JSONDecoder.iso.decode(Session.self, from: Data(contentsOf: sessionFile))
    }

    public var session: Session? { lock.withLock { cached } }
    public var signedIn: Bool { session != nil }

    // MARK: Auth

    /// Sends the sign-in e-mail. Its link opens `home://auth#access_token=…`, which `finishSignIn` reads. Sign-ups are closed:
    /// only e-mails added under Authentication → Users get a link.
    public func sendSignInLink(email: String) async throws {
        var c = URLComponents(url: url.appendingPathComponent("auth/v1/otp"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "redirect_to", value: Config.authRedirect)]
        let body: [String: Any] = ["email": email.trimmingCharacters(in: .whitespaces).lowercased(), "create_user": false]
        do {
            _ = try await send("POST", c.url!, body: body, auth: false)
        } catch let e as SupabaseError where e.message.localizedCaseInsensitiveContains("signup") || e.status == 422 {
            throw SupabaseError(status: e.status, message: "Tento e-mail ešte nemá prístup. Pridaj ho v Supabase (Authentication → Users → Add user).")
        }
    }

    /// The link from the e-mail: tokens (or an error) in the URL fragment.
    public func finishSignIn(_ link: URL) async throws {
        let fragment = URLComponents(string: "x:?" + (link.fragment ?? link.query ?? ""))?.queryItems ?? []
        let v = Dictionary(fragment.compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        if let err = v["error_description"] ?? v["error"] {
            throw SupabaseError(status: 400, message: err.contains("expired") || err.contains("invalid")
                                ? "Odkaz už neplatí. Pošli si nový." : err.replacingOccurrences(of: "+", with: " "))
        }
        guard let access = v["access_token"], let refresh = v["refresh_token"] else {
            throw SupabaseError(status: 400, message: "Odkaz neobsahuje prihlásenie.")
        }
        try await establish(access: access, refresh: refresh, expiresIn: Double(v["expires_in"] ?? "3600") ?? 3600)
    }

    /// E-mail + password sign-in. The password goes to Supabase only and is never stored.
    public func signIn(email: String, password: String) async throws {
        var c = URLComponents(url: url.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        let o: Any?
        do {
            o = try await send("POST", c.url!, body: ["email": email.trimmingCharacters(in: .whitespaces).lowercased(), "password": password],
                               auth: false)
        } catch let e as SupabaseError where e.status == 400 {
            throw SupabaseError(status: 400, message: e.message.localizedCaseInsensitiveContains("confirm")
                                ? "E-mail ešte nie je potvrdený." : "Nesprávny e-mail alebo heslo.")
        }
        guard let d = o as? [String: Any], let access = d["access_token"] as? String, let refresh = d["refresh_token"] as? String else {
            throw SupabaseError(status: 500, message: "Prihlásenie sa nepodarilo.")
        }
        try await establish(access: access, refresh: refresh, expiresIn: (d["expires_in"] as? Double) ?? 3600)
    }

    /// Sets a new password for the signed-in member (e.g. after signing in with the e-mail link).
    public func setPassword(_ password: String) async throws {
        guard password.count >= 6 else { throw SupabaseError(status: 422, message: "Heslo musí mať aspoň 6 znakov.") }
        try await send("PUT", url.appendingPathComponent("auth/v1/user"), body: ["password": password])
    }

    private func establish(access: String, refresh: String, expiresIn: Double) async throws {
        var req = URLRequest(url: url.appendingPathComponent("auth/v1/user"))
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let id = user["id"] as? String else { throw SupabaseError(status: 401, message: "Prihlásenie sa nepodarilo overiť.") }
        save(Session(accessToken: access, refreshToken: refresh, expires: .now.addingTimeInterval(expiresIn),
                     userId: id, email: user["email"] as? String))
    }

    public func signOut() {
        save(nil)
    }

    private func save(_ s: Session?) {
        lock.withLock { cached = s }
        if let s, let data = try? JSONEncoder.iso.encode(s) {
            try? FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: sessionFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionFile.path)
        } else {
            try? FileManager.default.removeItem(at: sessionFile)
        }
    }

    /// A valid access token, refreshed when it's about to run out. Another process (app or MCP) may have refreshed it
    /// already, so the file is read again first.
    func accessToken() async throws -> String {
        if let fresh = try? JSONDecoder.iso.decode(Session.self, from: Data(contentsOf: sessionFile)) { lock.withLock { cached = fresh } }
        guard let s = session else { throw SupabaseError(status: 401, message: "Nie si prihlásený.") }
        if s.expires.timeIntervalSinceNow > 60 { return s.accessToken }
        var c = URLComponents(url: url.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        let o: Any?
        do {
            o = try await send("POST", c.url!, body: ["refresh_token": s.refreshToken], auth: false)
        } catch let e as SupabaseError where (400..<500).contains(e.status) {
            save(nil)
            throw SupabaseError(status: 401, message: "Prihlásenie vypršalo, prihlás sa znova.")
        }
        guard let d = o as? [String: Any], let access = d["access_token"] as? String, let refresh = d["refresh_token"] as? String else {
            throw SupabaseError(status: 500, message: "Obnovenie prihlásenia zlyhalo.")
        }
        var n = s
        n.accessToken = access; n.refreshToken = refresh
        n.expires = .now.addingTimeInterval((d["expires_in"] as? Double) ?? 3600)
        save(n)
        return access
    }

    // MARK: Data

    public func rpc(_ name: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await send("POST", url.appendingPathComponent("rest/v1/rpc/\(name)"), body: args)
    }

    /// Rows of `table` in the household changed after `since` (an ISO timestamp from an earlier row), oldest first.
    func changed(_ table: String, household: String, since: String?) async throws -> [[String: Any]] {
        var c = URLComponents(url: url.appendingPathComponent("rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        var q = [URLQueryItem(name: "household_id", value: "eq.\(household)"), URLQueryItem(name: "order", value: "updated_at.asc"),
                 URLQueryItem(name: "limit", value: "5000")]
        if let since { q.append(URLQueryItem(name: "updated_at", value: "gt.\(since)")) }
        c.queryItems = q
        // A "+" in the timestamp's offset must reach PostgREST as %2B, not a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return (try await send("GET", c.url!) as? [[String: Any]]) ?? []
    }

    /// Insert-or-update rows; conflicts on the primary key merge.
    func upsert(_ table: String, _ rows: [[String: Any]], onConflict: String) async throws {
        guard !rows.isEmpty else { return }
        var c = URLComponents(url: url.appendingPathComponent("rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "on_conflict", value: onConflict)]
        _ = try await send("POST", c.url!, body: rows, prefer: "resolution=merge-duplicates,return=minimal")
    }

    @discardableResult
    func send(_ method: String, _ u: URL, body: Any? = nil, auth: Bool = true, prefer: String? = nil) async throws -> Any? {
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(auth ? try await accessToken() : key)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        guard (200..<300).contains(status) else {
            let o = json as? [String: Any]
            let msg = (o?["msg"] ?? o?["message"] ?? o?["error_description"] ?? o?["error"]) as? String
            throw SupabaseError(status: status, message: msg ?? "Supabase vrátil \(status)")
        }
        return json
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
}
