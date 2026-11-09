import Foundation

public struct EmailAddress: Codable, Hashable, Sendable {
    public var name: String
    public var address: String
    public init(name: String, address: String) { self.name = name; self.address = address }
    public var display: String { name.isEmpty ? address : name }
    public var full: String { name.isEmpty ? address : "\(name) <\(address)>" }
}

public struct Attachment: Codable, Hashable, Sendable {
    public var filename: String
    public var mimeType: String
    public var size: Int
}

/// One MIME entity: headers, decoded body, and child parts for multipart.
public struct MIMEPart {
    public var headers: [(name: String, value: String)] = []
    public var body = Data()
    public var children: [MIMEPart] = []

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// ("text/html", ["charset": "utf-8"])
    public var contentType: (type: String, params: [String: String]) {
        MIME.parseHeaderValue(header("Content-Type") ?? "text/plain")
    }
    public var disposition: (type: String, params: [String: String])? {
        header("Content-Disposition").map(MIME.parseHeaderValue)
    }
    public var filename: String? {
        let raw = disposition?.params["filename"] ?? contentType.params["name"]
        return raw.map(MIME.decodeWords)
    }
    public var text: String { MIME.decodeCharset(body, contentType.params["charset"]) }
}

public struct ParsedMessage {
    public var subject = ""
    public var from: [EmailAddress] = []
    public var to: [EmailAddress] = []
    public var cc: [EmailAddress] = []
    public var date: Date?
    public var messageID = ""
    public var text: String?
    public var html: String?
    public var attachments: [Attachment] = []
    /// Decoded bytes of each attachment, same order as `attachments`.
    public var attachmentData: [Data] = []

    public var snippet: String {
        let src = text ?? html.map(MIME.stripHTML) ?? ""
        let flat = src.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(flat.prefix(220))
    }
}

public enum MIME {
    // MARK: Message

    public static func parseMessage(_ data: Data) -> ParsedMessage {
        let root = parsePart(data)
        var m = ParsedMessage()
        m.subject = decodeWords(root.header("Subject") ?? "")
        m.from = parseAddresses(root.header("From") ?? "")
        m.to = parseAddresses(root.header("To") ?? "")
        m.cc = parseAddresses(root.header("Cc") ?? "")
        m.date = root.header("Date").flatMap(parseDate)
        m.messageID = (root.header("Message-ID") ?? "").trimmingCharacters(in: .whitespaces)
        collect(root, into: &m)
        return m
    }

    static func collect(_ p: MIMEPart, into m: inout ParsedMessage) {
        let ct = p.contentType.type
        if ct.hasPrefix("multipart/") {
            for c in p.children { collect(c, into: &m) }   // alternatives fill text and html; the rest are attachments
            return
        }
        if ct == "message/rfc822", p.disposition?.type != "attachment" {
            let inner = parsePart(p.body)
            collect(inner, into: &m)
            return
        }
        let isAttachment = p.disposition?.type == "attachment" || (p.filename != nil && !ct.hasPrefix("text/"))
        if !isAttachment, ct == "text/plain", m.text == nil { m.text = p.text; return }
        if !isAttachment, ct == "text/html", m.html == nil { m.html = p.text; return }
        if isAttachment || p.filename != nil || !ct.hasPrefix("text/") {
            m.attachments.append(Attachment(filename: p.filename ?? "príloha", mimeType: ct, size: p.body.count))
            m.attachmentData.append(p.body)
        }
    }

    // MARK: Parts

    public static func parsePart(_ data: Data) -> MIMEPart {
        let bytes = [UInt8](data)
        // Header ends at the first empty line (CRLF CRLF or LF LF).
        var split = bytes.count, bodyStart = bytes.count
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { split = i; bodyStart = i + 2; break }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { split = i; bodyStart = i + 3; break }
            }
            i += 1
        }
        if i == 0 && bytes.first == 0x0A { split = 0; bodyStart = 1 }
        var part = MIMEPart()
        part.headers = parseHeaders(Data(bytes[0..<split]))
        let rawBody = bodyStart < bytes.count ? Data(bytes[bodyStart...]) : Data()
        let ct = part.contentType
        if ct.type.hasPrefix("multipart/"), let boundary = ct.params["boundary"] {
            part.children = splitMultipart(rawBody, boundary: boundary).map(parsePart)
        } else {
            part.body = decodeTransfer(rawBody, part.header("Content-Transfer-Encoding"))
        }
        return part
    }

    public static func parseHeaders(_ data: Data) -> [(name: String, value: String)] {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var out: [(String, String)] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if let f = line.first, f == " " || f == "\t", !out.isEmpty {
                out[out.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                out.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }

    static func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](data)
        let delim = [UInt8](("--" + boundary).utf8)
        var parts: [Data] = []
        var lineStart = 0
        var partStart: Int? = nil
        var i = 0
        func isDelimiter(at s: Int) -> (Bool, Bool) {
            guard s + delim.count <= bytes.count, Array(bytes[s..<s + delim.count]) == delim else { return (false, false) }
            let after = s + delim.count
            let closing = after + 1 < bytes.count && bytes[after] == 0x2D && bytes[after + 1] == 0x2D
            return (true, closing)
        }
        while lineStart < bytes.count {
            i = lineStart
            while i < bytes.count, bytes[i] != 0x0A { i += 1 }
            let next = min(i + 1, bytes.count)
            let (isDelim, closing) = isDelimiter(at: lineStart)
            if isDelim {
                if let s = partStart {
                    var e = lineStart
                    if e > s, bytes[e - 1] == 0x0A { e -= 1 }
                    if e > s, bytes[e - 1] == 0x0D { e -= 1 }
                    parts.append(Data(bytes[s..<max(s, e)]))
                }
                if closing { return parts }
                partStart = next
            }
            lineStart = next
        }
        if let s = partStart, s < bytes.count { parts.append(Data(bytes[s...])) }
        return parts
    }

    /// `text/plain; charset="utf-8"; name*=UTF-8''n%C3%A1zov.pdf` → ("text/plain", params). Handles RFC 2231 continuations.
    public static func parseHeaderValue(_ v: String) -> (type: String, params: [String: String]) {
        var parts: [String] = []
        var cur = "", inQuote = false
        for c in v {
            if c == "\"" { inQuote.toggle(); cur.append(c) } else if c == ";" && !inQuote { parts.append(cur); cur = "" } else { cur.append(c) }
        }
        parts.append(cur)
        let type = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var params: [String: String] = [:]
        var continued: [String: [(Int, String, Bool)]] = [:]
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            var key = p[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            let extended = key.hasSuffix("*")
            if extended { key.removeLast() }
            if let star = key.firstIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                continued[String(key[..<star]), default: []].append((n, val, extended))
            } else {
                params[key] = extended ? decode2231(val, first: true) : val
            }
        }
        for (k, segs) in continued {
            params[k] = segs.sorted { $0.0 < $1.0 }.enumerated().map { idx, s in s.2 ? decode2231(s.1, first: idx == 0) : s.1 }.joined()
        }
        return (type, params)
    }

    static func decode2231(_ v: String, first: Bool) -> String {
        var charset = "utf-8", text = v
        if first {
            let comps = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if comps.count == 3 { charset = String(comps[0]); text = String(comps[2]) }
        }
        var bytes: [UInt8] = []
        var it = Array(text.utf8).makeIterator()
        while let c = it.next() {
            if c == 0x25, let h = it.next(), let l = it.next(), let b = UInt8(String(bytes: [h, l], encoding: .ascii) ?? "", radix: 16) { bytes.append(b) }
            else { bytes.append(c) }
        }
        return decodeCharset(Data(bytes), charset.isEmpty ? "utf-8" : charset)
    }

    // MARK: Encodings

    public static func decodeTransfer(_ data: Data, _ encoding: String?) -> Data {
        switch encoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            let cleaned = data.filter { !($0 == 0x0D || $0 == 0x0A || $0 == 0x20 || $0 == 0x09) }
            var padded = Data(cleaned)
            while padded.count % 4 != 0 { padded.append(0x3D) }
            return Data(base64Encoded: padded, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            return decodeQP([UInt8](data), underscoreIsSpace: false)
        default:
            return data
        }
    }

    static func decodeQP(_ b: [UInt8], underscoreIsSpace: Bool) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c { case 0x30...0x39: return c - 0x30; case 0x41...0x46: return c - 0x37; case 0x61...0x66: return c - 0x57; default: return nil }
        }
        while i < b.count {
            let c = b[i]
            if c == 0x3D {
                if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) { out.append(h << 4 | l); i += 3; continue }
                // Soft line break: "=" then optional spaces then CRLF/LF.
                var j = i + 1
                while j < b.count, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
                if j < b.count, b[j] == 0x0D { j += 1 }
                if j < b.count, b[j] == 0x0A { i = j + 1; continue }
                if j >= b.count { break }
                out.append(c); i += 1; continue
            }
            out.append(underscoreIsSpace && c == 0x5F ? 0x20 : c)
            i += 1
        }
        return Data(out)
    }

    public static func decodeCharset(_ data: Data, _ charset: String?) -> String {
        let name = (charset ?? "utf-8").trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        if name == "utf-8" || name == "us-ascii" || name.isEmpty {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1250) ?? String(decoding: data, as: UTF8.self)
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        if cf != kCFStringEncodingInvalidId {
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            if let s = String(data: data, encoding: enc) { return s }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// RFC 2047 encoded words: `=?utf-8?B?...?=` / `=?iso-8859-2?Q?...?=`. Whitespace between adjacent encoded words is dropped.
    public static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        var prevWasWord = false
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if !(prevWasWord && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { out += gap }
            var charset = ns.substring(with: m.range(at: 1))
            if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }   // RFC 2231 language
            let enc = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            let data: Data
            if enc == "B" {
                var t = text
                while t.count % 4 != 0 { t += "=" }
                data = Data(base64Encoded: t) ?? Data(text.utf8)
            } else {
                data = decodeQP([UInt8](text.utf8), underscoreIsSpace: true)
            }
            out += decodeCharset(data, charset)
            last = m.range.location + m.range.length
            prevWasWord = true
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: Addresses & dates

    public static func parseAddresses(_ raw: String) -> [EmailAddress] {
        var items: [String] = []
        var cur = "", inQuote = false, angle = 0
        for c in raw {
            switch c {
            case "\"": inQuote.toggle(); cur.append(c)
            case "<": angle += 1; cur.append(c)
            case ">": angle = max(0, angle - 1); cur.append(c)
            case "," where !inQuote && angle == 0, ";" where !inQuote && angle == 0: items.append(cur); cur = ""
            default: cur.append(c)
            }
        }
        items.append(cur)
        return items.compactMap { item in
            let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            if let lt = t.lastIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt {
                let addr = String(t[t.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
                var name = String(t[..<lt]).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
                name = decodeWords(name).replacingOccurrences(of: "\\\"", with: "\"")
                return EmailAddress(name: name, address: addr)
            }
            // "addr (Name)" or bare address
            if let p = t.firstIndex(of: "("), let q = t.lastIndex(of: ")"), p < q {
                return EmailAddress(name: decodeWords(String(t[t.index(after: p)..<q])), address: String(t[..<p]).trimmingCharacters(in: .whitespaces))
            }
            return EmailAddress(name: "", address: decodeWords(t))
        }
    }

    nonisolated(unsafe) static let dateFormatters: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        "EEE, d MMM yy HH:mm:ss Z", "dd-MMM-yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
    ].map { f in
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = f
        return df
    }
    static let dateLock = NSLock()

    public static func parseDate(_ raw: String) -> Date? {
        var s = raw
        if let p = s.firstIndex(of: "(") { s = String(s[..<p]) }   // trailing "(CET)"
        s = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " ")
        dateLock.lock(); defer { dateLock.unlock() }
        for f in dateFormatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    public static func stripHTML(_ html: String) -> String {
        var s = html
        for tag in ["style", "script", "head"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<br[^>]*>|</p>|</div>|</tr>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }
}
