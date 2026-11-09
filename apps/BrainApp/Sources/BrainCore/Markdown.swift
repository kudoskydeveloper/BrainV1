import Foundation

/// One block of an answer. Inline Markdown (bold, links, code) stays in the strings; the panel renders it with AttributedString.
public enum MDBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MDListItem])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case code(String)
    case rule
}

public struct MDListItem: Equatable {
    public var text: String
    public var depth: Int            // 0 = top level, by indentation
    public var marker: Marker
    public enum Marker: Equatable { case bullet, number(String), task(done: Bool) }
}

public enum MarkdownBlocks {
    /// Splits Markdown into blocks. Anything it doesn't recognise becomes a paragraph, so nothing is ever dropped.
    public static func parse(_ text: String) -> [MDBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [MDBlock] = []
        var para: [String] = [], items: [MDListItem] = [], quote: [String] = [], table: [[String]] = []
        var code: [String]? = nil

        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !items.isEmpty { out.append(.list(items)); items = [] }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty {
                // a header row needs the |---| separator under it; without one every row is data
                let rows = table.filter { !isSeparator($0) }
                let hasHeader = table.count > 1 && isSeparator(table[1])
                out.append(.table(header: hasHeader ? rows[0] : [], rows: hasHeader ? Array(rows.dropFirst()) : rows))
                table = []
            }
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if line.hasPrefix("```") { out.append(.code(c.joined(separator: "\n"))); code = nil } else { c.append(raw); code = c }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }

            if let h = heading(line) { flush(); out.append(h); continue }
            if line.count >= 3, Set(line.replacingOccurrences(of: " ", with: "")).isSubset(of: ["-", "*", "_"]),
               line.replacingOccurrences(of: " ", with: "").count >= 3 { flush(); out.append(.rule); continue }
            if line.hasPrefix(">") {
                if quote.isEmpty { flush() }
                var q = String(line.dropFirst())
                if q.hasPrefix(" ") { q.removeFirst() }
                quote.append(q); continue
            }
            if line.hasPrefix("|") {
                if table.isEmpty { flush() }
                table.append(cells(line)); continue
            }
            if let item = listItem(raw) {
                if items.isEmpty { flush() }
                items.append(item); continue
            }
            // a wrapped line right after a list item continues it
            if !items.isEmpty, raw.hasPrefix("  ") { items[items.count - 1].text += " " + line; continue }
            if !items.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
            para.append(line)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    static func heading(_ line: String) -> MDBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    static func listItem(_ raw: String) -> MDListItem? {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let line = raw.trimmingCharacters(in: .whitespaces)
        let depth = min(indent / 2, 3)
        for b in ["- ", "* ", "+ "] where line.hasPrefix(b) {
            let rest = String(line.dropFirst(2))
            for (box, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where rest.hasPrefix(box) {
                return MDListItem(text: String(rest.dropFirst(4)), depth: depth, marker: .task(done: done))
            }
            return MDListItem(text: rest, depth: depth, marker: .bullet)
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = line.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return MDListItem(text: String(after.dropFirst(2)), depth: depth, marker: .number(String(digits)))
            }
        }
        return nil
    }

    static func cells(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isSeparator(_ row: [String]) -> Bool {
        !row.isEmpty && row.allSatisfy { c in !c.isEmpty && c.allSatisfy { "-:".contains($0) } }
    }
}
