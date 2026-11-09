import Foundation

/// A recipe from a web page (its schema.org Recipe data, which most recipe sites publish), or from any text (a page without
/// that data, a pasted recipe, a note) through the model. Recipes in other languages than Slovak or Czech are translated.
public final class Importer {
    let store: Store
    public init(store: Store) { self.store = store }

    static let textSystem = """
    You turn a recipe written in any form into JSON. Return ONLY a JSON object, no prose:
    {"title":"","servings":<number>,"prep_min":<int or null>,"cook_min":<int or null>,"tags":["<2-5 short Slovak tags, e.g. 'polievka','vegetariánske','rýchle','dezert'>"],
    "ingredients":[{"line":"<one ingredient line with its amount, as written>","section":"<group heading like 'Cesto' or ''>"}],
    "steps":["<one step per item, without numbering>"],"notes":"<tips worth keeping, or ''>",
    "author":"<who the recipe is from when the text or a photo says so (e.g. 'babka Mária', 'teta Eva', a cookbook's name), else ''>"}
    Write everything in Slovak: translate when the recipe is in another language (keep Czech as Czech is NOT allowed, translate it too),
    and convert cups/ounces/°F to metric (g, ml, °C) in the lines. Keep amounts exact. When servings aren't stated, estimate them.
    If the text holds no recipe, return {"title":""}.
    """

    static let translateSystem = """
    Translate this recipe JSON into Slovak and return ONLY the same JSON shape: {"title":"","ingredients":["…"],"steps":["…"],"tags":["…"]}.
    Keep each list the same length and order. Convert cups, ounces, pounds and °F to metric (g, ml, °C) inside the lines; keep amounts exact.
    """

    // MARK: Web

    public func fromURL(_ s: String, progress: (@Sendable (String) -> Void)? = nil) async throws -> Recipe {
        var str = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !str.contains("://") { str = "https://" + str }
        guard let url = URL(string: str), url.scheme?.hasPrefix("http") == true else { throw ReceptyError("Neplatná adresa: \(s)") }
        progress?("Sťahujem stránku…")
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("sk,cs;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { throw ReceptyError("Stránka vrátila chybu \(code).") }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)

        var r: Recipe
        if let ld = Self.schemaRecipe(html) {
            r = Self.recipe(fromSchema: ld)
            if !Self.looksSlovak(r) {
                progress?("Prekladám do slovenčiny…")
                r = try await translate(r)
            }
        } else {
            progress?("Čítam recept zo stránky…")
            r = try await fromText(Self.plainText(html), progress: nil)
            if r.imagePath.isEmpty, let og = Self.meta(html, "og:image") { r.imagePath = og }
        }
        r.sourceURL = url.absoluteString
        if r.imagePath.hasPrefix("http") {
            progress?("Sťahujem fotku…")
            r.imagePath = await Self.downloadImage(r.imagePath, base: url) ?? ""
        }
        return r
    }

    /// The first schema.org Recipe in the page's JSON-LD (also inside @graph or a list).
    static func schemaRecipe(_ html: String) -> [String: Any]? {
        let re = try! NSRegularExpression(pattern: #"<script[^>]*application/ld\+json[^>]*>(.*?)</script>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let j = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed]) else { continue }
            if let r = findRecipe(j) { return r }
        }
        return nil
    }

    static func findRecipe(_ v: Any) -> [String: Any]? {
        if let d = v as? [String: Any] {
            let t = d["@type"]
            if (t as? String) == "Recipe" || ((t as? [String])?.contains("Recipe") ?? false) { return d }
            if let g = d["@graph"], let r = findRecipe(g) { return r }
            if let m = d["mainEntity"], let r = findRecipe(m) { return r }
        }
        if let a = v as? [Any] { for x in a { if let r = findRecipe(x) { return r } } }
        return nil
    }

    static func recipe(fromSchema d: [String: Any]) -> Recipe {
        var r = Recipe(title: decodeEntities(text(d["name"])))
        r.servings = servings(d["recipeYield"]) ?? 4
        r.prepMin = minutes(d["prepTime"])
        r.cookMin = minutes(d["cookTime"])
        if r.prepMin == nil, r.cookMin == nil { r.cookMin = minutes(d["totalTime"]) }
        let lines = (d["recipeIngredient"] as? [Any] ?? d["ingredients"] as? [Any] ?? []).map { decodeEntities(text($0)) }.filter { !$0.isEmpty }
        r.ingredients = lines.map { Ingredient(line: $0) }
        r.steps = steps(d["recipeInstructions"])
        var tags: [String] = []
        for k in ["recipeCategory", "recipeCuisine"] {
            if let s = d[k] as? String { tags += s.components(separatedBy: ",") } else if let a = d[k] as? [Any] { tags += a.map(text) }
        }
        if let k = d["keywords"] as? String, tags.isEmpty { tags += k.components(separatedBy: ",").prefix(4) }
        r.tags = Array(NSOrderedSet(array: tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && $0.count < 30 })).compactMap { $0 as? String }.prefix(5).map { $0 }
        r.imagePath = imageURL(d["image"]) ?? ""
        if let desc = d["description"] as? String { r.notes = decodeEntities(desc).trimmingCharacters(in: .whitespacesAndNewlines) }
        return r
    }

    static func steps(_ v: Any?) -> [String] {
        var out: [String] = []
        func walk(_ x: Any?) {
            if let s = x as? String {
                // One string for everything: split into paragraphs or numbered lines.
                let clean = decodeEntities(stripTags(s))
                out += clean.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if let d = x as? [String: Any] {
                if let items = d["itemListElement"] { walk(items) }
                else if let t = d["text"] as? String { out.append(decodeEntities(stripTags(t)).trimmingCharacters(in: .whitespacesAndNewlines)) }
                else if let n = d["name"] as? String { out.append(decodeEntities(n)) }
            } else if let a = x as? [Any] { a.forEach(walk) }
        }
        walk(v)
        return out.map { $0.replacingOccurrences(of: #"^\d+[.)]\s*"#, with: "", options: .regularExpression) }.filter { !$0.isEmpty }
    }

    static func servings(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        let s = (v as? String) ?? (v as? [Any])?.compactMap { $0 as? String ?? ($0 as? NSNumber)?.stringValue }.first ?? ""
        guard let m = s.range(of: #"\d+([.,]\d+)?"#, options: .regularExpression) else { return nil }
        return Double(s[m].replacingOccurrences(of: ",", with: "."))
    }

    /// ISO 8601 duration ("PT1H30M", "P0DT0H45M") in minutes.
    static func minutes(_ v: Any?) -> Int? {
        guard let s = v as? String, s.hasPrefix("P") else { return nil }
        var total = 0.0, num = ""
        var inTime = false
        for c in s.dropFirst() {
            if c == "T" { inTime = true; continue }
            if c.isNumber || c == "." { num.append(c); continue }
            let n = Double(num) ?? 0; num = ""
            switch c {
            case "D": total += n * 1440
            case "H": total += n * 60
            case "M": total += inTime ? n : n * 43200
            case "S": total += n / 60
            default: break
            }
        }
        return total > 0 ? Int(total.rounded()) : nil
    }

    static func imageURL(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let d = v as? [String: Any] { return d["url"] as? String }
        if let a = v as? [Any] { return a.lazy.compactMap { imageURL($0) }.first }
        return nil
    }

    static func meta(_ html: String, _ property: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"<meta[^>]+(?:property|name)=["']\#(property)["'][^>]+content=["']([^"']+)["']"#, options: .caseInsensitive)
        let ns = html as NSString
        return re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)).map { decodeEntities(ns.substring(with: $0.range(at: 1))) }
    }

    /// Slovak or Czech when a good share of the lines have their letters.
    static func looksSlovak(_ r: Recipe) -> Bool {
        let all = r.ingredients.map(\.line) + r.steps + [r.title]
        let marks = CharacterSet(charactersIn: "áäčďéíĺľňóôŕšťúýžěřůÁČĎÉÍĽŇÓŠŤÚÝŽŘ")
        let hits = all.filter { $0.rangeOfCharacter(from: marks) != nil }.count
        let words = all.joined(separator: " ").lowercased()
        let sk = [" a ", " na ", " do ", " s ", " so ", " lyžic", " minút", " pridáme", " nakrájame"].filter { words.contains($0) }.count
        return Double(hits) >= Double(all.count) * 0.25 || sk >= 3
    }

    func translate(_ r: Recipe) async throws -> Recipe {
        let input: [String: Any] = ["title": r.title, "ingredients": r.ingredients.map(\.line), "steps": r.steps, "tags": r.tags]
        let o = try await AI.json(system: Self.translateSystem, input: input, store: store)
        var x = r
        x.title = text(o["title"]).isEmpty ? r.title : text(o["title"])
        if let ing = o["ingredients"] as? [Any], ing.count == r.ingredients.count {
            for (i, l) in ing.enumerated() { x.ingredients[i].line = text(l) }
        }
        if let st = o["steps"] as? [Any], st.count == r.steps.count { x.steps = st.map(text) }
        if let t = o["tags"] as? [Any] { x.tags = t.map(text).filter { !$0.isEmpty } }
        return x
    }

    static func downloadImage(_ s: String, base: URL) async -> String? {
        guard let url = URL(string: s, relativeTo: base) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh) Recepty", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 else { return nil }
        let ext = ["jpg", "jpeg", "png", "webp", "avif"].first { url.pathExtension.lowercased() == $0 } ?? "jpg"
        let file = Store.imagesDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do { try data.write(to: file); return file.path } catch { return nil }
    }

    // MARK: Text

    /// Any text with a recipe in it; the model writes it out in Slovak.
    public func fromText(_ t: String, fromOCR: Bool = false, images: [Data] = [], progress: (@Sendable (String) -> Void)? = nil) async throws -> Recipe {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty || !images.isEmpty else { throw ReceptyError("Prázdny text.") }
        progress?("Čítam recept…")
        var input: [String: Any] = ["text": String(s.prefix(40000))]
        if fromOCR {
            input["note"] = images.isEmpty
                ? "OCR of photos of a recipe (e.g. a cookbook page): fix OCR mistakes, broken lines and hyphenation; ignore page numbers and unrelated text around the recipe."
                : "The attached photos show the recipe (a cookbook page, a card, maybe old and handwritten, maybe in old spelling). Read the recipe from the photos themselves; 'text' is OCR of them, a hint that is often wrong for handwriting. Ignore page numbers and unrelated text. Keep the original's amounts and old units, adding metric where obvious (e.g. 'dkg' stays, 'hrnček' stays)."
        }
        let o = try await AI.json(system: Self.textSystem, input: input, images: images, store: store)
        let title = text(o["title"])
        guard !title.isEmpty else { throw ReceptyError("V texte som nenašiel recept.") }
        var r = Recipe(title: title)
        r.servings = num(o["servings"]) ?? 4
        r.prepMin = num(o["prep_min"]).map { Int($0) }
        r.cookMin = num(o["cook_min"]).map { Int($0) }
        r.tags = ((o["tags"] as? [Any]) ?? []).map(text).filter { !$0.isEmpty }
        r.ingredients = ((o["ingredients"] as? [Any]) ?? []).compactMap { x in
            if let d = x as? [String: Any] { let l = text(d["line"]); return l.isEmpty ? nil : Ingredient(line: l, section: text(d["section"])) }
            let l = text(x); return l.isEmpty ? nil : Ingredient(line: l)
        }
        r.steps = ((o["steps"] as? [Any]) ?? []).map(text).filter { !$0.isEmpty }
        r.notes = text(o["notes"])
        r.author = text(o["author"])
        return r
    }

    // MARK: Photos

    /// Brain's text extractor (Vision OCR, local; ~/Developer/brain/tools/extract), shared instead of a second OCR here.
    public static var extractPath: String? {
        let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/brain/tools/extract/brain-extract").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// Text of a photo or a scanned PDF through brain-extract.
    public static func ocr(_ file: URL) async throws -> String {
        guard let tool = extractPath else { throw ReceptyError("Chýba brain-extract (OCR z Brainu, ~/Developer/brain/tools/extract).") }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process(), out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = [file.path, "--ocr", "force"]
            p.standardOutput = out; p.standardError = err
            p.terminationHandler = { proc in
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus == 0 { cont.resume(returning: o) }
                else { cont.resume(throwing: ReceptyError("OCR zlyhalo: \(String(decoding: err.fileHandleForReading.readDataToEndOfFile().prefix(200), as: UTF8.self))")) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// A recipe from photos (one or more pages of a cookbook, a handwritten card, a screenshot), in their order. The model
    /// looks at the photos (handwriting) with the OCR text as a hint; the photos come back in `photos` with their text, so
    /// saving the recipe keeps them in the archive.
    public func fromImages(_ files: [URL], progress: (@Sendable (String) -> Void)? = nil) async throws -> Recipe {
        guard !files.isEmpty else { throw ReceptyError("Žiadna fotka.") }
        var photos: [SourcePhoto] = [], parts: [String] = [], pictures: [Data] = []
        for (n, f) in files.enumerated() {
            progress?(files.count == 1 ? "Čítam text z fotky…" : "Čítam text z fotky \(n + 1) z \(files.count)…")
            let t = Self.extractPath == nil ? "" : ((try? await Self.ocr(f)) ?? "").replacingOccurrences(of: #"^\[image[^\]]*\]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            photos.append(SourcePhoto(path: f.path, text: t))
            if !t.isEmpty { parts.append(files.count == 1 ? t : "--- fotka \(n + 1) ---\n\(t)") }
            if let j = AI.jpeg(f) { pictures.append(j) }
        }
        guard !parts.isEmpty || !pictures.isEmpty else { throw ReceptyError("Fotky sa nedajú prečítať.") }
        progress?(pictures.isEmpty ? "Skladám recept z textu…" : "Model číta recept z fotiek…")
        var r = try await fromText(parts.joined(separator: "\n\n"), fromOCR: true, images: pictures, progress: nil)
        r.photos = photos
        return r
    }

    // MARK: HTML helpers

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<br\s*/?>|</p>|</li>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    /// The readable text of a page (no scripts, styles, navigation), shortened for the model.
    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<(script|style|noscript|svg|nav|footer|header)[^>]*>.*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = decodeEntities(stripTags(s))
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
        return String(s.prefix(40000))
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&frac12;": "½", "&frac14;": "¼", "&frac34;": "¾", "&deg;": "°"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        let re = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#)
        let ns = out as NSString
        var result = "", last = 0
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            if let n = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(n) { result.unicodeScalars.append(u) }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

public extension Recipe {
    /// Ingredient lines as edited in a text box: one per line, a line ending with ":" or starting with "#" starts a section.
    static func ingredients(fromText t: String, keeping old: [Ingredient] = []) -> [Ingredient] {
        var section = "", out: [Ingredient] = []
        for raw in t.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if l.hasPrefix("#") { section = l.trimmingCharacters(in: CharacterSet(charactersIn: "# ")); continue }
            if l.hasSuffix(":"), l.count < 40, !l.contains(where: \.isNumber) { section = String(l.dropLast()); continue }
            let line = l.replacingOccurrences(of: #"^[-•*]\s*"#, with: "", options: .regularExpression)
            // A line that didn't change keeps its analysis.
            if var o = old.first(where: { $0.line == line && $0.section == section }) { o.id = 0; out.append(o) }
            else { out.append(Ingredient(line: line, section: section)) }
        }
        return out
    }

    var ingredientsText: String {
        var s = "", sec = ""
        for i in ingredients {
            if i.section != sec { sec = i.section; s += (s.isEmpty ? "" : "\n") + (sec.isEmpty ? "#\n" : "# \(sec)\n") }
            s += i.line + "\n"
        }
        return s
    }
}
