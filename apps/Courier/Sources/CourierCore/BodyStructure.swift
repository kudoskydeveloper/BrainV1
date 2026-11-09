import Foundation

/// Reads attachment names, types and sizes out of an IMAP BODYSTRUCTURE, so attachments are known (and searchable)
/// before a message is downloaded. Order matches MIME.collect (depth-first), so indexes line up with the parsed message.
enum BodyStructure {
    static func attachments(_ v: IMAPValue) -> [Attachment] {
        var out: [Attachment] = []
        walk(v, &out)
        return out
    }

    /// Has a text/calendar part (an invitation or a reply to one).
    static func hasCalendar(_ v: IMAPValue) -> Bool {
        guard let l = v.list, !l.isEmpty else { return false }
        if l[0].list != nil { return l.contains { $0.list != nil && hasCalendar($0) } }
        return l.count > 1 && l[0].text?.lowercased() == "text" && l[1].text?.lowercased() == "calendar"
            || attachments(v).contains { $0.filename.lowercased().hasSuffix(".ics") }
    }

    static func params(_ v: IMAPValue?) -> [String: String] {
        guard let l = v?.list else { return [:] }
        var d: [String: String] = [:]
        var i = 0
        while i + 1 < l.count {
            if let k = l[i].text?.lowercased() { d[k] = l[i + 1].text ?? "" }
            i += 2
        }
        return d
    }

    static func walk(_ v: IMAPValue, _ out: inout [Attachment]) {
        guard let l = v.list, !l.isEmpty else { return }
        if l[0].list != nil {   // multipart: children first, then subtype and extensions
            for c in l where c.list != nil { walk(c, &out) }
            return
        }
        guard l.count >= 7 else { return }
        let type = (l[0].text ?? "").lowercased(), sub = (l[1].text ?? "").lowercased()
        let mime = "\(type)/\(sub)"
        let p = params(l[2])
        let size = Int(l[6].text ?? "") ?? 0
        // Extension fields start after the type-specific ones: text has lines, message/rfc822 has envelope, body, lines.
        let dispIndex = type == "text" ? 9 : (mime == "message/rfc822" ? 11 : 8)
        let disp = dispIndex < l.count ? l[dispIndex].list : nil
        let dispType = disp?.first?.text?.lowercased()
        let dp = params(disp.flatMap { $0.count > 1 ? $0[1] : nil })
        var name = dp["filename"] ?? p["name"]
        if name == nil, let star = dp["filename*"] ?? p["name*"] { name = MIME.parseHeaderValue("x; n*=\(star)").params["n"] }
        if name == nil {   // RFC 2231 continuations: filename*0*, filename*1*…
            let parts = (dp.isEmpty ? p : dp).filter { $0.key.hasPrefix("filename*") || $0.key.hasPrefix("name*") }
            if !parts.isEmpty {
                let joined = parts.sorted { $0.key < $1.key }.map { "; \($0.key)=\($0.value)" }.joined()
                let parsed = MIME.parseHeaderValue("x\(joined)").params
                name = parsed["filename"] ?? parsed["name"]
            }
        }
        if mime == "message/rfc822", dispType != "attachment" { return }   // forwarded mail is shown inline
        let isText = type == "text" && name == nil
        guard dispType == "attachment" || (name != nil && dispType != "inline") || (!isText && type != "multipart" && dispType != "inline" && name != nil) else { return }
        // base64 is ~4/3 of the real size
        let enc = (l[5].text ?? "").lowercased()
        out.append(Attachment(filename: MIME.decodeWords(name ?? "príloha"), mimeType: mime, size: enc == "base64" ? size * 3 / 4 : size))
    }
}
