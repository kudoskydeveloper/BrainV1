import Foundation

public enum AuthMethod: String, Codable, Sendable { case password, oauth2 }

public struct ServerConfig: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var security: Security
    public var username: String
    public var auth: AuthMethod
    public init(host: String, port: Int, security: Security, username: String, auth: AuthMethod) {
        self.host = host; self.port = port; self.security = security; self.username = username; self.auth = auth
    }
}

public struct DiscoveredConfig: Sendable {
    public var provider: String
    public var source: String          // where it came from, shown to the user
    public var imap: ServerConfig
    public var smtp: ServerConfig?
    public init(provider: String, source: String, imap: ServerConfig, smtp: ServerConfig?) {
        self.provider = provider; self.source = source; self.imap = imap; self.smtp = smtp
    }
    /// The provider only accepts OAuth (no password login listed).
    public var oauthOnly: Bool { imap.auth == .oauth2 }
    public var oauthProvider: OAuthProvider? { OAuthProvider.forHost(imap.host) }
}

public enum OAuthProvider: String, Sendable {
    case google, microsoft
    static func forHost(_ h: String) -> OAuthProvider? {
        let h = h.lowercased()
        if h.hasSuffix("gmail.com") || h.hasSuffix("googlemail.com") { return .google }
        if h.contains("office365.com") || h.contains("outlook.com") || h.contains("hotmail.com") { return .microsoft }
        return nil
    }
}

/// Finds IMAP/SMTP settings from just an e-mail address, the way Thunderbird does:
/// 1. the domain's own autoconfig, 2. Mozilla ISPDB, 3. ISPDB for the domain's MX provider, 4. guessing common host names.
public enum Autoconfig {
    public static func discover(email: String, log: (@Sendable (String) -> Void)? = nil) async -> DiscoveredConfig? {
        let parts = email.lowercased().split(separator: "@")
        guard parts.count == 2 else { return nil }
        let local = String(parts[0]), domain = String(parts[1])
        let enc = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email

        let direct = [
            "https://autoconfig.\(domain)/mail/config-v1.1.xml?emailaddress=\(enc)",
            "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml?emailaddress=\(enc)",
            "http://autoconfig.\(domain)/mail/config-v1.1.xml?emailaddress=\(enc)",
        ]
        for url in direct {
            log?("Skúšam \(URL(string: url)?.host ?? url)…")
            if let c = await fetch(url, email: email, local: local, domain: domain, source: "autoconfig \(domain)") { return c }
        }
        log?("Hľadám v databáze Thunderbirdu (ISPDB)…")
        if let c = await fetch("https://autoconfig.thunderbird.net/v1.1/\(domain)", email: email, local: local, domain: domain, source: "ISPDB") {
            return c
        }
        log?("Zisťujem poštový server domény (MX)…")
        for mx in mxDomains(domain) where mx != domain {
            if let c = await fetch("https://autoconfig.thunderbird.net/v1.1/\(mx)", email: email, local: local, domain: domain, source: "MX → ISPDB \(mx)") {
                return c
            }
            if let c = await fetch("https://autoconfig.\(mx)/mail/config-v1.1.xml?emailaddress=\(enc)", email: email, local: local, domain: domain,
                                   source: "MX → autoconfig \(mx)") { return c }
        }
        log?("Skúšam bežné názvy serverov…")
        for host in ["imap.\(domain)", "mail.\(domain)"] {
            if await reachable(host: host, port: 993) {
                let smtpHost = host.replacingOccurrences(of: "imap.", with: "smtp.")
                return DiscoveredConfig(provider: domain, source: "odhad",
                                        imap: ServerConfig(host: host, port: 993, security: .ssl, username: email, auth: .password),
                                        smtp: ServerConfig(host: smtpHost, port: 465, security: .ssl, username: email, auth: .password))
            }
        }
        return nil
    }

    static func fetch(_ urlString: String, email: String, local: String, domain: String, source: String) async -> DiscoveredConfig? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 7)
        req.setValue("Courier", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data, email: email, local: local, domain: domain, source: source)
    }

    /// Parses a Thunderbird clientConfig XML and picks the best IMAP (SSL over STARTTLS, never plain) and SMTP server.
    public static func parse(_ data: Data, email: String, local: String, domain: String, source: String) -> DiscoveredConfig? {
        let p = ClientConfigParser()
        let x = XMLParser(data: data)
        x.delegate = p
        guard x.parse() else { return nil }
        func subst(_ s: String) -> String {
            s.replacingOccurrences(of: "%EMAILADDRESS%", with: email).replacingOccurrences(of: "%EMAILLOCALPART%", with: local)
                .replacingOccurrences(of: "%EMAILDOMAIN%", with: domain)
        }
        func best(_ list: [ClientConfigParser.Server]) -> ServerConfig? {
            let ranked = list.compactMap { s -> (Int, ServerConfig)? in
                let sec: Security
                switch s.socketType.uppercased() { case "SSL": sec = .ssl; case "STARTTLS": sec = .starttls; default: return nil }
                let auths = s.auth.map { $0.lowercased() }
                let auth: AuthMethod = auths.contains(where: { $0.hasPrefix("password") }) || auths.isEmpty ? .password : (auths.contains("oauth2") ? .oauth2 : .password)
                guard let port = Int(s.port) else { return nil }
                let cfg = ServerConfig(host: subst(s.hostname), port: port, security: sec, username: subst(s.username.isEmpty ? "%EMAILADDRESS%" : s.username), auth: auth)
                return (sec == .ssl ? 0 : 1, cfg)
            }
            return ranked.sorted { $0.0 < $1.0 }.first?.1
        }
        guard let imap = best(p.incoming.filter { $0.type == "imap" }) else { return nil }
        return DiscoveredConfig(provider: p.displayName.isEmpty ? domain : subst(p.displayName), source: source, imap: imap,
                                smtp: best(p.outgoing.filter { $0.type == "smtp" }))
    }

    /// MX hosts → their registrable domains, best preference first (e.g. aspmx.l.google.com → google.com).
    static func mxDomains(_ domain: String) -> [String] {
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        p.arguments = ["+short", "+time=3", "+tries=1", "MX", domain]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let hosts = out.split(separator: "\n").compactMap { line -> (Int, String)? in
            let f = line.split(separator: " ")
            guard f.count == 2, let pref = Int(f[0]) else { return nil }
            return (pref, f[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased())
        }.sorted { $0.0 < $1.0 }.map(\.1)
        var seen: [String] = []
        for h in hosts {
            let labels = h.split(separator: ".")
            guard labels.count >= 2 else { continue }
            let short = ["co", "com", "org", "net", "gov", "ac"]
            let n = labels.count >= 3 && short.contains(String(labels[labels.count - 2])) ? 3 : 2
            let base = labels.suffix(n).joined(separator: ".")
            if !seen.contains(base) { seen.append(base) }
        }
        return seen
        #else
        return []   // no dig on iOS: autoconfig, ISPDB and the host guess still work
        #endif
    }

    static func reachable(host: String, port: Int) async -> Bool {
        do {
            let c = try await withThrowingTaskGroup(of: Bool.self) { g in
                g.addTask { _ = try await IMAPClient(host: host, port: port, security: .ssl); return true }
                g.addTask { try await Task.sleep(for: .seconds(6)); return false }
                let r = try await g.next() ?? false
                g.cancelAll()
                return r
            }
            return c
        } catch { return false }
    }
}

final class ClientConfigParser: NSObject, XMLParserDelegate {
    struct Server { var type = "", hostname = "", port = "", socketType = "", username = "", auth: [String] = [] }
    var incoming: [Server] = [], outgoing: [Server] = []
    var displayName = ""
    private var current: Server?
    private var isIncoming = false
    private var text = ""
    private var depthInProvider = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "incomingServer" || name == "outgoingServer" {
            current = Server(type: attributes["type"] ?? "")
            isIncoming = name == "incomingServer"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if var c = current {
            switch name {
            case "hostname": c.hostname = t
            case "port": c.port = t
            case "socketType": c.socketType = t
            case "username": c.username = t
            case "authentication": c.auth.append(t)
            case "incomingServer", "outgoingServer":
                if isIncoming { incoming.append(c) } else { outgoing.append(c) }
                current = nil; text = ""; return
            default: break
            }
            current = c
        } else if name == "displayName", displayName.isEmpty {
            displayName = t
        }
        text = ""
    }
}
