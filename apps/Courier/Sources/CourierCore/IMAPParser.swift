import Foundation

/// One value of an IMAP response: an atom (NIL is its own case), a quoted string or literal (raw bytes), or a parenthesized list.
/// Atoms keep `[...]` sections whole, so `BODY[HEADER.FIELDS (FROM TO)]` is one atom.
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nil_

    /// Text of an atom or string (strings decoded as UTF-8, falling back to Latin-1).
    public var text: String? {
        switch self {
        case .atom(let a): return a
        case .string(let d): return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
        default: return nil
        }
    }
    public var data: Data? {
        switch self {
        case .string(let d): return d
        case .atom(let a): return Data(a.utf8)
        default: return nil
        }
    }
    public var list: [IMAPValue]? { if case .list(let l) = self { return l }; return nil }
    public var isNil: Bool { if case .nil_ = self { return true }; return false }
}

/// Parses one logical IMAP response (literals already inlined after their `{n}\r\n`) into values.
public struct IMAPParser {
    let b: [UInt8]
    var i = 0

    public init(_ data: Data) { b = [UInt8](data) }

    public static func parse(_ data: Data) -> [IMAPValue] {
        var p = IMAPParser(data)
        return p.values(until: nil)
    }

    mutating func skipSpaces() { while i < b.count, b[i] == 0x20 { i += 1 } }

    mutating func values(until close: UInt8?) -> [IMAPValue] {
        var out: [IMAPValue] = []
        while true {
            skipSpaces()
            guard i < b.count else { return out }
            let c = b[i]
            if c == 0x0D || c == 0x0A { i += 1; continue }
            if let close, c == close { i += 1; return out }
            if c == 0x29 { i += 1; continue }   // stray ')' outside a list
            out.append(value())
        }
    }

    mutating func value() -> IMAPValue {
        let c = b[i]
        switch c {
        case 0x28: // (
            i += 1
            return .list(values(until: 0x29))
        case 0x22: // "
            i += 1
            var bytes: [UInt8] = []
            while i < b.count, b[i] != 0x22 {
                if b[i] == 0x5C, i + 1 < b.count { i += 1 }
                bytes.append(b[i]); i += 1
            }
            i += 1
            return .string(Data(bytes))
        case 0x7B: // {n} or {n+}
            var j = i + 1, n = 0, ok = false
            while j < b.count, (0x30...0x39).contains(b[j]) { n = n * 10 + Int(b[j] - 0x30); j += 1; ok = true }
            if j < b.count, b[j] == 0x2B { j += 1 }
            if ok, j < b.count, b[j] == 0x7D {
                j += 1
                if j < b.count, b[j] == 0x0D { j += 1 }
                if j < b.count, b[j] == 0x0A { j += 1 }
                let end = min(b.count, j + n)
                let d = Data(b[j..<end])
                i = end
                return .string(d)
            }
            return atom()
        default:
            return atom()
        }
    }

    mutating func atom() -> IMAPValue {
        var bytes: [UInt8] = []
        var depth = 0
        while i < b.count {
            let c = b[i]
            if depth == 0, c == 0x20 || c == 0x28 || c == 0x29 || c == 0x0D || c == 0x0A { break }
            if c == 0x5B { depth += 1 }
            if c == 0x5D, depth > 0 { depth -= 1 }
            bytes.append(c); i += 1
        }
        if bytes.isEmpty { i += 1; return .atom("") }
        let s = String(decoding: bytes, as: UTF8.self)
        return s.uppercased() == "NIL" ? .nil_ : .atom(s)
    }
}

/// IMAP mailbox names use "modified UTF-7" (RFC 3501 §5.1.3).
public enum ModifiedUTF7 {
    public static func decode(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c != "&" { out.append(c); continue }
            var enc = ""
            while let d = it.next(), d != "-" { enc.append(d) }
            if enc.isEmpty { out.append("&"); continue }
            var b64 = enc.replacingOccurrences(of: ",", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            if let data = Data(base64Encoded: b64), let str = String(data: data, encoding: .utf16BigEndian) { out += str } else { out += "&" + enc + "-" }
        }
        return out
    }

    public static func encode(_ s: String) -> String {
        var out = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var d = Data()
            for u in pending { d.append(UInt8(u >> 8)); d.append(UInt8(u & 0xFF)) }
            out += "&" + d.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: ",") + "-"
            pending = []
        }
        for u in s.utf16 {
            if u >= 0x20 && u <= 0x7E {
                flush()
                out += u == 0x26 ? "&-" : String(UnicodeScalar(UInt8(u)))
            } else { pending.append(u) }
        }
        flush()
        return out
    }
}
