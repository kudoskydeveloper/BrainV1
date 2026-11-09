import Foundation

/// One event from `claude -p --output-format stream-json`.
public enum StreamEvent: Equatable {
    case started(session: String, brainConnected: Bool)
    case text(String)
    case usingTool(String)          // e.g. "where_is"
    case proposal(id: String, summary: String)   // a Brain tool returned something waiting for the user's yes
    case finished(result: String, session: String?, isError: Bool)
}

public enum StreamParser {
    /// Parse one line. Unknown or partial lines give no events.
    public static func parse(_ line: String) -> [StreamEvent] {
        // Claude Code's lines can carry raw control characters inside strings, which strict JSON rejects. A whole line is
        // one object, so turning them into spaces is safe.
        let clean = String(String.UnicodeScalarView(line.unicodeScalars.map { $0.value < 0x20 ? " " : $0 }))
        guard let d = clean.data(using: .utf8), let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        switch m["type"] as? String {
        case "system" where m["subtype"] as? String == "init":
            let servers = m["mcp_servers"] as? [[String: Any]] ?? []
            let ok = servers.contains { $0["name"] as? String == "brain" && $0["status"] as? String == "connected" }
            return [.started(session: m["session_id"] as? String ?? "", brainConnected: ok)]
        case "assistant":
            let content = (m["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { c in
                switch c["type"] as? String {
                case "text": return (c["text"] as? String).map(StreamEvent.text)
                case "tool_use": return (c["name"] as? String).map { .usingTool(friendly($0)) }
                default: return nil
                }
            }
        case "user":
            // tool results: a Brain proposal ({needs_confirm, proposal_id, summary}) becomes a card with buttons in the panel
            let content = (m["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.filter { $0["type"] as? String == "tool_result" }.flatMap { c -> [StreamEvent] in
                let texts: [String] = (c["content"] as? String).map { [$0] }
                    ?? (c["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                return texts.compactMap(proposal)
            }
        case "result":
            return [.finished(result: m["result"] as? String ?? "", session: m["session_id"] as? String,
                              isError: (m["is_error"] as? Bool ?? false) || m["subtype"] as? String != "success")]
        default:
            return []
        }
    }

    /// A tool result's text that is a Brain proposal: Brain renders it as Markdown ("**Čaká na tvoje potvrdenie**", the
    /// summary, "proposal: `brain_…`"); raw JSON ({needs_confirm, proposal_id, summary}) is understood too.
    public static func proposal(_ text: String) -> StreamEvent? {
        if let r = text.range(of: #"proposal: `(brain_[0-9a-f]+)`"#, options: .regularExpression) {
            let id = String(text[r]).replacingOccurrences(of: "proposal: `", with: "").replacingOccurrences(of: "`", with: "")
            var summary = String(text[..<r.lowerBound])
            if let h = summary.range(of: "**Čaká na tvoje potvrdenie**") { summary = String(summary[h.upperBound...]) }
            return .proposal(id: id, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard text.contains("needs_confirm"), text.contains("proposal_id"),
              let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let j = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any],
              j["needs_confirm"] as? Bool == true, let id = j["proposal_id"] as? String else { return nil }
        return .proposal(id: id, summary: j["summary"] as? String ?? "")
    }

    /// "mcp__brain__where_is" → "where_is"; "mcp__brain__call" → "call".
    public static func friendly(_ tool: String) -> String {
        tool.components(separatedBy: "__").last ?? tool
    }

    /// Claude Code reports a logged-out CLI as a normal answer; spot it so the UI can say how to fix it.
    public static func needsLogin(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("failed to authenticate") || t.contains("please run /login") || t.contains("oauth session expired") || t.contains("invalid api key")
    }

    /// The account's usage limit is used up (Claude Code says so as a normal answer): the moment to switch accounts.
    public static func limitReached(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["usage limit", "limit reached", "hit your limit", "reached your limit", "5-hour limit", "weekly limit", "rate_limit_error", "out of extra usage"]
            .contains { t.contains($0) }
    }
}
