import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Prospector: every registered SK and CZ company (2,2 mil. from RPO and RES) and their people, filtered like BizMachine —
// country, kraj, industry (NACE sections or codes), size, revenue, legal form, founded — with the live count, a table,
// the detail, enrichment ("Obohatiť": web, konatelia's e-mails, revenue) and picking into a Scout list or a CSV.

// MARK: model

struct OrgRow: Codable, Identifiable, Hashable {
    var id: String
    var country: String
    var ico: String
    var name: String?
    var legalForm: String?
    var address: String?
    var city: String?
    var region: String?
    var founded: String?
    var dissolved: String?
    var nace: String?
    var industry: String?
    var employees: String?
    var size: String?
    var revenue: Int?
    var profit: Int?
    var finYear: String?
    var enrichedAt: String?
    var enrichNote: String?
    var source: String?
    var domain: String?
    var people: Int?
    var emails: Int?
}

struct ProspectPage: Codable { var total: Int?; var offset: Int; var limit: Int; var rows: [OrgRow] }

struct OrgDetail: Codable, Hashable {
    var id: String
    var country: String
    var ico: String
    var name: String?
    var legalForm: String?
    var dic: String?
    var address: String?
    var city: String?
    var region: String?
    var founded: String?
    var dissolved: String?
    var nace: String?
    var industry: String?
    var employees: String?
    var size: String?
    var revenue: Int?
    var revenuePrev: Int?
    var profit: Int?
    var finYear: String?
    var enrichedAt: String?
    var enrichNote: String?
    var source: String?
    var sites: [Site]
    var people: [Member]
    struct Site: Codable, Hashable { var domain: String; var crawledAt: String? }
    struct Member: Codable, Hashable, Identifiable {
        var id: String; var name: String; var title: String?; var role: String?; var seniority: String?; var email: String?
        var confidence: String?; var domain: String?; var origin: String?
    }
}

struct PersonRow: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var title: String?
    var role: String?
    var seniority: String?
    var email: String?
    var confidence: String?
    var phone: String?
    var domain: String?
    var origin: String?
    var orgId: String
    var company: String?
    var city: String?
    var region: String?
    var industry: String?
    var nace: String?
    var size: String?
    var employees: String?
    var revenue: Int?
    var blocked: Bool?
}

struct PeoplePage: Codable { var total: Int?; var offset: Int; var limit: Int; var rows: [PersonRow] }

struct Facets: Codable {
    var regions: [Region]
    var legalForms: [Form]
    var sections: [Section]
    var sizes: [String]
    struct Region: Codable, Hashable { var country: String; var region: String; var n: Int }
    struct Form: Codable, Hashable { var form: String; var n: Int }
    struct Section: Codable, Hashable { var code: String; var name: String }
}

/// The company filters, shared by Firmy and Ľudia.
struct CompanyFilters: Equatable, Codable {
    var company = ""                 // name, city or IČO
    var country = ""                 // "" = both
    var regions: Set<String> = []
    var sections: Set<String> = []
    var nace = ""
    var sizes: Set<String> = []
    var revenue = ""                 // a bucket key from Money.buckets
    var legalForms: Set<String> = []
    var foundedFrom = ""
    var foundedTo = ""
    var withSite = false
    var withPeople = false
    var enriched = ""                // "" | yes | no
    var includeDissolved = false

    func args(companyKey: String) -> [String] {
        var a: [String] = []
        func add(_ k: String, _ v: String) { let t = v.trimmingCharacters(in: .whitespaces); if !t.isEmpty { a.append("--\(k)=\(t)") } }
        add(companyKey, company); add("country", country)
        add("region", regions.sorted().joined(separator: ","))
        add("section", sections.sorted().joined(separator: ","))
        add("nace", nace.replacingOccurrences(of: " ", with: ""))
        add("size", sizes.sorted().joined(separator: ","))
        if let b = Money.buckets.first(where: { $0.key == revenue }) { if let f = b.from { add("revenueFrom", "\(f)") }; if let t = b.to { add("revenueTo", "\(t)") } }
        add("legalForm", legalForms.sorted().joined(separator: ","))
        add("foundedFrom", foundedFrom); add("foundedTo", foundedTo); add("enriched", enriched)
        if withSite { a.append("--withSite") }
        if withPeople { a.append("--withPeople") }
        if includeDissolved { a.append("--includeDissolved") }
        return a
    }

    /// The active filters as removable chips.
    func chips(_ facets: Facets?) -> [(label: String, clear: (inout CompanyFilters) -> Void)] {
        var c: [(String, (inout CompanyFilters) -> Void)] = []
        if !company.isEmpty { c.append(("„\(company)“", { $0.company = "" })) }
        if !country.isEmpty { c.append((country == "SK" ? "🇸🇰 Slovensko" : "🇨🇿 Česko", { $0.country = "" })) }
        for r in regions.sorted() { c.append((r, { $0.regions.remove(r) })) }
        for s in sections.sorted() { c.append(("\(s) · \(facets?.sections.first { $0.code == s }?.name ?? "")", { $0.sections.remove(s) })) }
        if !nace.isEmpty { c.append(("NACE \(nace)", { $0.nace = "" })) }
        for s in sizes.sorted() { c.append(("\(s) zam.", { $0.sizes.remove(s) })) }
        if let b = Money.buckets.first(where: { $0.key == revenue }) { c.append(("tržby \(b.label)", { $0.revenue = "" })) }
        for f in legalForms.sorted() { c.append((f, { $0.legalForms.remove(f) })) }
        if !foundedFrom.isEmpty || !foundedTo.isEmpty { c.append(("založená \(foundedFrom.isEmpty ? "…" : foundedFrom)–\(foundedTo.isEmpty ? "…" : foundedTo)", { $0.foundedFrom = ""; $0.foundedTo = "" })) }
        if withSite { c.append(("má web", { $0.withSite = false })) }
        if withPeople { c.append(("má konateľov", { $0.withPeople = false })) }
        if !enriched.isEmpty { c.append((enriched == "yes" ? "obohatené" : "neobohatené", { $0.enriched = "" })) }
        if includeDissolved { c.append(("aj zaniknuté", { $0.includeDissolved = false })) }
        return c
    }
}

struct PeopleFilters: Equatable, Codable {
    var q = ""
    var seniority: Set<String> = []
    var withEmail = false
    var confidence: Set<String> = []
    var origin: Set<String> = []
    var org = CompanyFilters()
    var sort = "company"

    var args: [String] {
        var a = org.args(companyKey: "company")
        if !q.trimmingCharacters(in: .whitespaces).isEmpty { a.append("--q=\(q.trimmingCharacters(in: .whitespaces))") }
        if !seniority.isEmpty { a.append("--seniority=\(seniority.sorted().joined(separator: ","))") }
        if !confidence.isEmpty { a.append("--confidence=\(confidence.sorted().joined(separator: ","))") }
        if !origin.isEmpty { a.append("--origin=\(origin.sorted().joined(separator: ","))") }
        if withEmail { a.append("--withEmail") }
        a.append("--sort=\(sort)")
        return a
    }
}

enum Money {
    static let buckets: [(key: String, label: String, from: Int?, to: Int?)] = [
        ("lt100k", "do 100 tis. €", nil, 100_000), ("100k-1m", "100 tis. – 1 mil. €", 100_000, 1_000_000),
        ("1m-10m", "1 – 10 mil. €", 1_000_000, 10_000_000), ("10m-50m", "10 – 50 mil. €", 10_000_000, 50_000_000), ("gt50m", "nad 50 mil. €", 50_000_000, nil),
    ]
    static func short(_ v: Int?) -> String {
        guard let v else { return "–" }
        let a = Double(abs(v)), s = v < 0 ? "−" : ""
        if a >= 1_000_000 { return "\(s)\((a / 1_000_000).formatted(.number.precision(.fractionLength(a >= 10_000_000 ? 0 : 1)).locale(Fmt.sk))) mil. €" }
        if a >= 1_000 { return "\(s)\(Int((a / 1_000).rounded())) tis. €" }
        return "\(s)\(Int(a)) €"
    }
}

let seniorities: [(key: String, label: String)] = [("owner", "Majiteľ / konateľ"), ("c-level", "C-level"), ("director", "Riaditeľ"), ("manager", "Manažér"), ("staff", "Ostatní")]

// MARK: stores

@MainActor
final class Prospector: ObservableObject {
    static let shared = Prospector()
    @Published var filters = CompanyFilters() { didSet { if filters != oldValue { save(); search() } } }
    @Published var sort = UserDefaults.standard.string(forKey: "prospector.sort") ?? "founded_desc" { didSet { UserDefaults.standard.set(sort, forKey: "prospector.sort"); search() } }
    @Published private(set) var rows: [OrgRow] = []
    @Published private(set) var total: Int?
    @Published private(set) var loading = false
    @Published private(set) var facets: Facets?
    @Published var detail: [String: OrgDetail] = [:]
    @Published var selection: Set<String> = []
    private var generation = 0
    private var pending: Task<Void, Never>?
    nonisolated static let pageSize = 200

    init() {
        if let d = UserDefaults.standard.data(forKey: "prospector.filters2"), let f = try? JSONDecoder().decode(CompanyFilters.self, from: d) { filters = f }
    }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(filters), forKey: "prospector.filters2") }

    func loadFacets() {
        guard facets == nil else { return }
        Task { if case .success(let d) = await Task.detached { Store.run(["facets"]) }.value { facets = try? JSONDecoder().decode(Facets.self, from: d) } }
    }

    func search() {
        pending?.cancel()
        generation += 1
        let gen = generation, args = filters.args(companyKey: "q") + ["--sort=\(sort)"]
        loading = true
        pending = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let r = await Task.detached { Store.run(["prospect"] + args + ["--limit=\(Self.pageSize)"]) }.value
            guard gen == generation else { return }
            loading = false
            if case .success(let d) = r, let p = try? JSONDecoder().decode(ProspectPage.self, from: d) { rows = p.rows; total = p.total }
            else if case .failure(let e) = r { Store.shared.error = e.message }
        }
    }

    func loadMore() {
        guard !loading, let t = total, rows.count < t else { return }
        loading = true
        let args = filters.args(companyKey: "q") + ["--sort=\(sort)"], offset = rows.count, gen = generation
        Task {
            let r = await Task.detached { Store.run(["prospect"] + args + ["--limit=\(Self.pageSize)", "--offset=\(offset)", "--noCount"]) }.value
            loading = false
            guard gen == generation, case .success(let d) = r, let p = try? JSONDecoder().decode(ProspectPage.self, from: d) else { return }
            rows += p.rows
        }
    }

    /// Reloads rows in place (after enrichment) without losing the scroll position.
    func refreshRows(_ ids: Set<String>) {
        for id in ids { load(id, force: true) }
        let args = filters.args(companyKey: "q") + ["--sort=\(sort)"], count = max(rows.count, Self.pageSize)
        Task {
            if case .success(let d) = await Task.detached { Store.run(["prospect"] + args + ["--limit=\(min(500, count))", "--noCount"]) }.value,
               let p = try? JSONDecoder().decode(ProspectPage.self, from: d) {
                let fresh = Dictionary(uniqueKeysWithValues: p.rows.map { ($0.id, $0) })
                rows = rows.map { fresh[$0.id] ?? $0 }
            }
        }
    }

    func load(_ id: String, force: Bool = false) {
        if !force, detail[id] != nil { return }
        Task {
            if case .success(let d) = await Task.detached { Store.run(["org", id]) }.value, let o = try? JSONDecoder().decode(OrgDetail.self, from: d) { detail[id] = o }
        }
    }

    func addToList(_ name: String, _ ids: [String]) {
        Task {
            _ = await Task.detached { Store.run(["lists", "add", name] + ids) }.value
            Store.shared.toast = "\(ids.count == 1 ? "1 záznam" : "\(ids.count) záznamov") v zozname „\(name)“"
            Store.shared.refresh()
        }
    }

    func exportCSV(only ids: [String]? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "firmy-\(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let args = filters.args(companyKey: "q") + ["--sort=\(sort)"]
        Store.shared.busy = "Exportujem…"
        Task {
            var csv: String?
            if let ids {
                let tmp = "export-\(UUID().uuidString.prefix(8))"
                _ = await Task.detached { Store.run(["lists", "add", tmp] + ids) }.value
                if case .success(let d) = await Task.detached { Store.run(["export-companies", "--list=\(tmp)"]) }.value { csv = String(decoding: d, as: UTF8.self) }
                _ = await Task.detached { Store.run(["lists", "delete", tmp]) }.value
            } else if case .success(let d) = await Task.detached { Store.run(["export-companies"] + args) }.value { csv = String(decoding: d, as: UTF8.self) }
            Store.shared.busy = nil
            if let csv { try? csv.write(to: url, atomically: true, encoding: .utf8); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

@MainActor
final class PeopleProspector: ObservableObject {
    static let shared = PeopleProspector()
    @Published var filters = PeopleFilters() { didSet { if filters != oldValue { save(); search() } } }
    @Published private(set) var rows: [PersonRow] = []
    @Published private(set) var total: Int?
    @Published private(set) var loading = false
    @Published var selection: Set<String> = []
    private var generation = 0
    private var pending: Task<Void, Never>?

    init() {
        if let d = UserDefaults.standard.data(forKey: "people.filters"), let f = try? JSONDecoder().decode(PeopleFilters.self, from: d) { filters = f }
    }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(filters), forKey: "people.filters") }

    func search() {
        pending?.cancel()
        generation += 1
        let gen = generation, args = filters.args
        loading = true
        pending = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let r = await Task.detached { Store.run(["prospect-people"] + args + ["--limit=200"]) }.value
            guard gen == generation else { return }
            loading = false
            if case .success(let d) = r, let p = try? JSONDecoder().decode(PeoplePage.self, from: d) { rows = p.rows; total = p.total }
            else if case .failure(let e) = r { Store.shared.error = e.message }
        }
    }

    func loadMore() {
        guard !loading, let t = total, rows.count < t else { return }
        loading = true
        let args = filters.args, offset = rows.count, gen = generation
        Task {
            let r = await Task.detached { Store.run(["prospect-people"] + args + ["--limit=200", "--offset=\(offset)", "--noCount"]) }.value
            loading = false
            guard gen == generation, case .success(let d) = r, let p = try? JSONDecoder().decode(PeoplePage.self, from: d) else { return }
            rows += p.rows
        }
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "ludia-\(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let picked = rows.filter { selection.isEmpty || selection.contains($0.id) }
        let cols: [(String, (PersonRow) -> String?)] = [("meno", { $0.name }), ("titul", { $0.title }), ("rola", { $0.role }), ("email", { $0.email }), ("istota", { $0.confidence }),
            ("firma", { $0.company }), ("ico", { $0.orgId }), ("mesto", { $0.city }), ("kraj", { $0.region }), ("odvetvie", { $0.industry }), ("trzby", { $0.revenue.map(String.init) })]
        func q(_ v: String?) -> String { guard let v else { return "" }; return v.contains(where: { ",\"\n;".contains($0) }) ? "\"\(v.replacingOccurrences(of: "\"", with: "\"\""))\"" : v }
        let csv = ([cols.map(\.0).joined(separator: ",")] + picked.filter { $0.blocked != true }.map { r in cols.map { q($0.1(r)) }.joined(separator: ",") }).joined(separator: "\n")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Runs `scout enrich` and reads its progress line by line.
@MainActor
final class Enricher: ObservableObject {
    static let shared = Enricher()
    @Published private(set) var running = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var withWeb = 0
    @Published private(set) var peopleWithEmail = 0
    @Published private(set) var last = ""
    private var process: Process?
    private var finished: Set<String> = []

    func start(_ ids: [String]) {
        guard !running, !ids.isEmpty else { return }
        running = true; done = 0; total = ids.count; withWeb = 0; peopleWithEmail = 0; last = ""; finished = []
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: Store.node)
        p.arguments = [Store.cli, "enrich"] + ids
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<nl]
                buffer.removeSubrange(...nl)
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], o["progress"] != nil else { continue }
                Task { @MainActor in self?.update(o) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.running = false
                self.process = nil
                Prospector.shared.refreshRows(self.finished)
                PeopleProspector.shared.search()
                Store.shared.toast = "Obohatené \(self.done) firiem: \(self.withWeb) s webom, \(self.peopleWithEmail) ľudí s e-mailom"
            }
        }
        do { try p.run(); process = p } catch { running = false; Store.shared.error = "Obohatenie sa nespustilo: \(error.localizedDescription)" }
    }

    private func update(_ o: [String: Any]) {
        done = o["progress"] as? Int ?? done
        if o["domain"] as? String != nil { withWeb += 1 }
        peopleWithEmail += o["peopleWithEmail"] as? Int ?? 0
        if let id = o["id"] as? String { finished.insert(id); Prospector.shared.load(id, force: true) }
        last = "\(o["name"] as? String ?? "") → \(o["domain"] as? String ?? (o["note"] as? String ?? "…"))"
    }

    func cancel() { process?.terminate() }
}

// MARK: shared filter UI

struct FilterGroup<Content: View>: View {
    let title: String
    var count = 0
    @State private var open: Bool
    let content: Content
    init(_ title: String, count: Int = 0, open: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.count = count; _open = State(initialValue: open || count > 0); self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if count > 0 { Text("\(count)").font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor, in: .capsule) }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { VStack(alignment: .leading, spacing: 3) { content }.transition(.opacity) }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct CheckRow: View {
    let title: String
    var detail: Int? = nil
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : Color.secondary)
                Text(title).lineLimit(1).foregroundStyle(on ? .primary : .secondary)
                Spacer(minLength: 4)
                if let detail { Text(detail.formatted(.number.notation(.compactName).locale(Fmt.sk))).font(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
            }
            .font(.callout)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

func toggle(_ set: inout Set<String>, _ v: String) { if set.contains(v) { set.remove(v) } else { set.insert(v) } }

/// The company filters (both screens use them).
struct CompanyFilterGroups: View {
    @Binding var f: CompanyFilters
    let facets: Facets?
    var showCompanyField = false

    var body: some View {
        if showCompanyField {
            FilterGroup("Firma", count: f.company.isEmpty ? 0 : 1, open: true) {
                TextField("názov, mesto alebo IČO", text: $f.company).textFieldStyle(.roundedBorder)
            }
        }
        FilterGroup("Krajina", count: f.country.isEmpty ? 0 : 1, open: true) {
            Picker("", selection: $f.country) { Text("Obe").tag(""); Text("🇸🇰 SK").tag("SK"); Text("🇨🇿 CZ").tag("CZ") }.pickerStyle(.segmented).labelsHidden()
        }
        FilterGroup("Kraj", count: f.regions.count, open: true) {
            ForEach((facets?.regions ?? []).filter { f.country.isEmpty || $0.country == f.country }, id: \.self) { r in
                CheckRow(title: f.country.isEmpty ? "\(r.country == "SK" ? "🇸🇰" : "🇨🇿") \(r.region)" : r.region, detail: r.n, on: f.regions.contains(r.region)) { toggle(&f.regions, r.region) }
            }
        }
        FilterGroup("Odvetvie", count: f.sections.count + (f.nace.isEmpty ? 0 : 1), open: true) {
            ForEach(facets?.sections ?? [], id: \.self) { s in
                CheckRow(title: "\(s.code)  \(s.name)", on: f.sections.contains(s.code)) { toggle(&f.sections, s.code) }
            }
            TextField("NACE kódy: 6201, 7311 …", text: $f.nace).textFieldStyle(.roundedBorder).padding(.top, 4)
        }
        FilterGroup("Tržby", count: f.revenue.isEmpty ? 0 : 1) {
            ForEach(Money.buckets, id: \.key) { b in CheckRow(title: b.label, on: f.revenue == b.key) { f.revenue = f.revenue == b.key ? "" : b.key } }
            Text("Zo závierok v RegisterUZ, len SK firmy po obohatení.").font(.caption2).foregroundStyle(.secondary)
        }
        FilterGroup("Zamestnanci", count: f.sizes.count) {
            ForEach(facets?.sizes ?? ["1-9", "10-49", "50-249", "250-999", "1000+"], id: \.self) { s in CheckRow(title: s, on: f.sizes.contains(s)) { toggle(&f.sizes, s) } }
            Text("CZ z registra, SK po obohatení.").font(.caption2).foregroundStyle(.secondary)
        }
        FilterGroup("Právna forma", count: f.legalForms.count) {
            ForEach((facets?.legalForms ?? []).prefix(12), id: \.self) { x in CheckRow(title: x.form, detail: x.n, on: f.legalForms.contains(x.form)) { toggle(&f.legalForms, x.form) } }
        }
        FilterGroup("Založená", count: f.foundedFrom.isEmpty && f.foundedTo.isEmpty ? 0 : 1) {
            HStack { TextField("od roku", text: $f.foundedFrom).textFieldStyle(.roundedBorder); Text("–"); TextField("do roku", text: $f.foundedTo).textFieldStyle(.roundedBorder) }
        }
        FilterGroup("Ďalšie", count: [f.withSite, f.withPeople, f.includeDissolved, !f.enriched.isEmpty].filter { $0 }.count) {
            Toggle("Má konateľov v databáze", isOn: $f.withPeople)
            Toggle("Scout pozná ich web", isOn: $f.withSite)
            Picker("Obohatené", selection: $f.enriched) { Text("všetky").tag(""); Text("áno").tag("yes"); Text("nie").tag("no") }
            Toggle("Aj zaniknuté firmy", isOn: $f.includeDissolved)
        }
    }
}

struct ChipsBar: View {
    let chips: [(label: String, clear: (inout CompanyFilters) -> Void)]
    let clear: ((inout CompanyFilters) -> Void) -> Void
    let reset: () -> Void
    var body: some View {
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, c in
                        Button { clear(c.clear) } label: {
                            HStack(spacing: 4) { Text(c.label).lineLimit(1); Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                                .font(.caption).padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.12), in: .capsule).foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Zrušiť všetko", action: reset).buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }
}

struct EnrichBar: View {
    @ObservedObject var e = Enricher.shared
    var body: some View {
        if e.running {
            HStack(spacing: 10) {
                ProgressView(value: Double(e.done), total: Double(max(e.total, 1))).frame(width: 140)
                Text("Obohacujem \(e.done)/\(e.total) · \(e.withWeb) s webom · \(e.peopleWithEmail) e-mailov").font(.callout).monospacedDigit()
                Text(e.last).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Zastaviť") { e.cancel() }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
    }
}

// MARK: Firmy

struct ProspectorView: View {
    @ObservedObject var p = Prospector.shared
    @ObservedObject var e = Enricher.shared
    @ObservedObject var store: Store
    @Binding var pick: String?
    @State private var newList = false
    @State private var newListName = ""
    @State private var confirmEnrich: [String]?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Hľadať firmu, mesto alebo IČO", text: $p.filters.company)
                        .textFieldStyle(.roundedBorder).controlSize(.large).padding(.bottom, 6)
                    CompanyFilterGroups(f: $p.filters, facets: p.facets)
                }
                .padding(14)
            }
            .frame(width: 270)
            .background(.background.secondary)
            Divider()
            VStack(spacing: 0) {
                header
                ChipsBar(chips: p.filters.chips(p.facets).filter { !$0.label.hasPrefix("„") }, clear: { c in var f = p.filters; c(&f); p.filters = f }, reset: { p.filters = CompanyFilters() })
                Divider()
                table
                EnrichBar()
            }
        }
        .navigationTitle("Firmy")
        .toolbar {
            ToolbarItemGroup {
                Button { confirmEnrich = enrichTargets } label: { Label("Obohatiť", systemImage: "wand.and.stars") }
                    .disabled(e.running || p.rows.isEmpty)
                    .help("Nájsť web, adresy, e-maily konateľov a tržby pre vybrané firmy (alebo prvých 50 vo výsledku)")
                Menu {
                    let ids = Array(p.selection)
                    Section(ids.isEmpty ? "Vyber firmy v tabuľke (⌘-klik, ⇧-klik)" : "\(ids.count) vybraných") {
                        ForEach(store.data?.lists ?? []) { l in Button(l.name) { p.addToList(l.name, ids) }.disabled(ids.isEmpty) }
                        Button("Nový zoznam…") { newList = true }.disabled(ids.isEmpty)
                    }
                } label: { Label("Do zoznamu", systemImage: "text.badge.plus") }
                Menu {
                    Button("Vybrané (\(p.selection.count))") { p.exportCSV(only: Array(p.selection)) }.disabled(p.selection.isEmpty)
                    Button("Celý výsledok (najviac 50 000)") { p.exportCSV() }
                } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
            }
        }
        .alert("Nový zoznam", isPresented: $newList) {
            TextField("Názov", text: $newListName)
            Button("Vytvoriť") { if !newListName.isEmpty { p.addToList(newListName, Array(p.selection)); newListName = "" } }
            Button("Zrušiť", role: .cancel) {}
        }
        .alert("Obohatiť \(confirmEnrich?.count ?? 0) firiem?", isPresented: Binding(get: { confirmEnrich != nil }, set: { if !$0 { confirmEnrich = nil } })) {
            Button("Obohatiť") { if let ids = confirmEnrich { e.start(ids) } }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("Scout skúsi nájsť ich web (overí ho podľa IČO), prečíta z neho adresy, telefóny a ľudí, konateľom zostaví e-maily a pri SK firmách doplní tržby a zamestnancov. Trvá to asi \(max(1, (confirmEnrich?.count ?? 0) * 12 / 60)) min., beží na pozadí.")
        }
        .onAppear { p.loadFacets(); if p.rows.isEmpty { p.search() } }
    }

    /// The picked companies, or the first 50 not yet enriched in the result.
    var enrichTargets: [String] {
        if !p.selection.isEmpty { return Array(p.selection) }
        return Array(p.rows.filter { $0.enrichedAt == nil }.prefix(50).map(\.id))
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(p.total.map { $0.formatted(.number.locale(Fmt.sk)) } ?? "…").font(.title2.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
            Text(p.total == 1 ? "firma" : (2...4).contains(p.total ?? 0) ? "firmy" : "firiem").foregroundStyle(.secondary)
            if p.loading { ProgressView().controlSize(.mini) }
            if !p.selection.isEmpty { Text("· \(p.selection.count) vybraných").foregroundStyle(.secondary) }
            Spacer()
            Picker("Zoradiť", selection: $p.sort) {
                Text("Najnovšie").tag("founded_desc"); Text("Najstaršie").tag("founded"); Text("Podľa názvu").tag("name")
                Text("Najvyššie tržby").tag("revenue_desc"); Text("Najväčšie").tag("size_desc")
            }
            .pickerStyle(.menu).fixedSize()
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
        .animation(.snappy, value: p.total)
    }

    var table: some View {
        Table(p.rows, selection: $p.selection) {
            TableColumn("Firma") { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(r.name ?? "–").fontWeight(.medium).lineLimit(1).strikethrough(r.dissolved != nil)
                        if r.enrichedAt != nil { Image(systemName: "wand.and.stars").font(.caption2).foregroundStyle(.purple).help(r.enrichNote ?? "obohatené") }
                    }
                    Text("\(r.country == "SK" ? "🇸🇰" : "🇨🇿") \([r.legalForm, r.ico].compactMap { $0 }.joined(separator: " · "))").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
            .width(min: 200, ideal: 280)
            TableColumn("Odvetvie") { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.industry ?? "–").lineLimit(1).font(.callout)
                    if let n = r.nace { Text("NACE \(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
            .width(min: 150, ideal: 220)
            TableColumn("Kde") { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.city.map(shortCity) ?? "–").lineLimit(1).font(.callout)
                    Text(r.region ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .width(min: 110, ideal: 150)
            TableColumn("Tržby") { r in
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Money.short(r.revenue)).monospacedDigit().foregroundStyle(r.revenue == nil ? .tertiary : .primary)
                    if let y = r.finYear { Text(y).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Zam.") { r in Text(r.employees ?? r.size ?? "–").monospacedDigit().foregroundStyle(r.size == nil ? .tertiary : .primary) }
                .width(min: 50, ideal: 64)
            TableColumn("Rok") { r in Text(r.founded.map { String($0.prefix(4)) } ?? "–").monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 40, ideal: 46)
            TableColumn("Kontakty") { r in
                HStack(spacing: 8) {
                    if let n = r.people, n > 0 { Label("\(n)", systemImage: "person.fill").foregroundStyle(.green).help("\(n) ľudí") }
                    if let d = r.domain { Label("\(r.emails ?? 0)", systemImage: "envelope.fill").foregroundStyle(.blue).help("\(d): \(r.emails ?? 0) adries") }
                }
                .font(.caption).labelStyle(.titleAndIcon)
            }
            .width(min: 70, ideal: 84)
        }
        .onChange(of: p.selection) { _, s in if s.count == 1 { pick = s.first } }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Obohatiť (\(ids.count))") { e.start(Array(ids)) }.disabled(e.running)
            Menu("Do zoznamu") { ForEach(store.data?.lists ?? []) { l in Button(l.name) { p.addToList(l.name, Array(ids)) } } }
            if ids.count == 1, let id = ids.first, let r = p.rows.first(where: { $0.id == id }) {
                Button("Kopírovať IČO") { copy(r.ico) }
                if let d = r.domain { Button("Otvoriť web") { open("https://\(d)") } }
            }
        }
        .overlay {
            if p.rows.isEmpty && !p.loading {
                ContentUnavailableView("Nič nevyhovuje filtrom", systemImage: "line.3.horizontal.decrease.circle", description: Text("Uvoľni niektorý filter."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let t = p.total, p.rows.count < t, !e.running {
                HStack {
                    Text("Zobrazených \(p.rows.count.formatted(.number.locale(Fmt.sk))) z \(t.formatted(.number.locale(Fmt.sk)))").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Načítať ďalších \(Prospector.pageSize)") { p.loadMore() }.disabled(p.loading)
                }
                .padding(.horizontal, 12).padding(.vertical, 7).background(.bar)
            }
        }
    }
}

func shortCity(_ c: String) -> String { c.replacingOccurrences(of: " - mestská časť ", with: " – ") }

// MARK: Ľudia

struct PeopleView: View {
    @ObservedObject var pp = PeopleProspector.shared
    @ObservedObject var p = Prospector.shared
    @ObservedObject var store: Store
    @Binding var pick: String?
    @State private var newList = false
    @State private var newListName = ""

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Meno alebo rola", text: $pp.filters.q).textFieldStyle(.roundedBorder).controlSize(.large).padding(.bottom, 6)
                    FilterGroup("Pozícia", count: pp.filters.seniority.count, open: true) {
                        ForEach(seniorities, id: \.key) { s in CheckRow(title: s.label, on: pp.filters.seniority.contains(s.key)) { toggle(&pp.filters.seniority, s.key) } }
                    }
                    FilterGroup("E-mail", count: (pp.filters.withEmail ? 1 : 0) + pp.filters.confidence.count, open: true) {
                        Toggle("Len s e-mailom", isOn: $pp.filters.withEmail)
                        CheckRow(title: "nájdený na webe", on: pp.filters.confidence.contains("found")) { toggle(&pp.filters.confidence, "found") }
                        CheckRow(title: "podľa vzoru firmy", on: pp.filters.confidence.contains("pattern")) { toggle(&pp.filters.confidence, "pattern") }
                        CheckRow(title: "len odhad", on: pp.filters.confidence.contains("mx")) { toggle(&pp.filters.confidence, "mx") }
                    }
                    FilterGroup("Zdroj", count: pp.filters.origin.count) {
                        CheckRow(title: "obchodný register", on: pp.filters.origin.contains("registry")) { toggle(&pp.filters.origin, "registry") }
                        CheckRow(title: "web firmy", on: pp.filters.origin.contains("site")) { toggle(&pp.filters.origin, "site") }
                        CheckRow(title: "hľadané ručne", on: pp.filters.origin.contains("lookup")) { toggle(&pp.filters.origin, "lookup") }
                    }
                    Text("Firma").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.top, 14)
                    CompanyFilterGroups(f: $pp.filters.org, facets: p.facets, showCompanyField: true)
                }
                .padding(14)
            }
            .frame(width: 270)
            .background(.background.secondary)
            Divider()
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(pp.total.map { $0.formatted(.number.locale(Fmt.sk)) } ?? "…").font(.title2.weight(.semibold)).monospacedDigit()
                    Text("ľudí").foregroundStyle(.secondary)
                    if pp.loading { ProgressView().controlSize(.mini) }
                    Spacer()
                    Picker("Zoradiť", selection: $pp.filters.sort) {
                        Text("Podľa firmy").tag("company"); Text("Podľa mena").tag("name"); Text("Najvyššie tržby firmy").tag("revenue_desc"); Text("Naposledy zmenení").tag("recent")
                    }
                    .pickerStyle(.menu).fixedSize()
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                ChipsBar(chips: pp.filters.org.chips(p.facets), clear: { c in var f = pp.filters; c(&f.org); pp.filters = f }, reset: { pp.filters = PeopleFilters() })
                Divider()
                table
                EnrichBar()
            }
        }
        .navigationTitle("Ľudia")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    let ids = Array(pp.selection)
                    Section(ids.isEmpty ? "Vyber ľudí v tabuľke (⌘-klik, ⇧-klik)" : "\(ids.count) vybraných") {
                        ForEach(store.data?.lists ?? []) { l in Button(l.name) { p.addToList(l.name, ids) }.disabled(ids.isEmpty) }
                        Button("Nový zoznam…") { newList = true }.disabled(ids.isEmpty)
                    }
                } label: { Label("Do zoznamu", systemImage: "text.badge.plus") }
                .help("Zoznam ľudí ide do sekvencie v Courieri")
                Button { pp.exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .help(pp.selection.isEmpty ? "Načítaní ľudia do CSV" : "Vybraní ľudia do CSV")
            }
        }
        .alert("Nový zoznam", isPresented: $newList) {
            TextField("Názov", text: $newListName)
            Button("Vytvoriť") { if !newListName.isEmpty { p.addToList(newListName, Array(pp.selection)); newListName = "" } }
            Button("Zrušiť", role: .cancel) {}
        }
        .onAppear { p.loadFacets(); if pp.rows.isEmpty { pp.search() } }
    }

    var table: some View {
        Table(pp.rows, selection: $pp.selection) {
            TableColumn("Meno") { r in
                HStack(spacing: 9) {
                    Avatar(name: r.name, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text([r.title, r.name].compactMap { $0 }.joined(separator: " ")).fontWeight(.medium).lineLimit(1)
                        Text(r.role ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 180, ideal: 230)
            TableColumn("Firma") { r in
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.company ?? "–").lineLimit(1)
                    Text([r.city.map(shortCity), r.industry].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("E-mail") { r in
                if let e = r.email {
                    HStack(spacing: 5) {
                        Circle().fill(Confidence.tint(r.confidence)).frame(width: 7, height: 7).help(Confidence.label(r.confidence))
                        Text(e).lineLimit(1).textSelection(.enabled).strikethrough(r.blocked == true)
                    }
                } else { Text("–").foregroundStyle(.tertiary) }
            }
            .width(min: 160, ideal: 220)
            TableColumn("Tržby firmy") { r in Text(Money.short(r.revenue)).monospacedDigit().foregroundStyle(r.revenue == nil ? .tertiary : .primary).frame(maxWidth: .infinity, alignment: .trailing) }
                .width(min: 70, ideal: 90)
        }
        .onChange(of: pp.selection) { _, s in if s.count == 1 { pick = s.first } }
        .contextMenu(forSelectionType: String.self) { ids in
            let orgs = Array(Set(pp.rows.filter { ids.contains($0.id) }.map(\.orgId)))
            Button("Obohatiť ich firmy (\(orgs.count))") { Enricher.shared.start(orgs) }.disabled(Enricher.shared.running)
            if let r = pp.rows.first(where: { ids.contains($0.id) }), let e = r.email { Button("Kopírovať e-mail") { copy(e); store.toast = "Skopírované: \(e)" } }
        }
        .overlay {
            if pp.rows.isEmpty && !pp.loading { ContentUnavailableView("Nikto nevyhovuje filtrom", systemImage: "person.2", description: Text("Uvoľni niektorý filter.")) }
        }
        .safeAreaInset(edge: .bottom) {
            if let t = pp.total, pp.rows.count < t {
                HStack {
                    Text("Zobrazených \(pp.rows.count.formatted(.number.locale(Fmt.sk))) z \(t.formatted(.number.locale(Fmt.sk)))").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Načítať ďalších 200") { pp.loadMore() }.disabled(pp.loading)
                }
                .padding(.horizontal, 12).padding(.vertical, 7).background(.bar)
            }
        }
    }
}

struct PersonRowDetail: View {
    let r: PersonRow
    @ObservedObject var store: Store
    var body: some View {
        Page {
            HStack(spacing: 14) {
                Avatar(name: r.name, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text([r.title, r.name].compactMap { $0 }.joined(separator: " ")).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text([r.role, r.company].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                }
            }
            if let e = r.email {
                Card("E-mail", symbol: "envelope.fill", tint: Confidence.tint(r.confidence)) {
                    HStack {
                        Text(e).font(.title3.weight(.medium)).textSelection(.enabled).strikethrough(r.blocked == true)
                        Spacer()
                        Button("Kopírovať") { copy(e); store.toast = "Skopírované: \(e)" }
                        Button("Napísať") { open("mailto:\(e)") }
                    }
                    Label(Confidence.label(r.confidence), systemImage: r.confidence == "found" ? "checkmark.seal.fill" : r.confidence == "pattern" ? "person.text.rectangle" : "questionmark.circle")
                        .foregroundStyle(Confidence.tint(r.confidence))
                    if r.blocked == true { Notice(symbol: "hand.raised.fill", text: "Táto adresa alebo doména je v Nekontaktovať.", tint: .red) }
                }
            } else {
                Notice(symbol: "wand.and.stars", text: "Adresu zatiaľ Scout nemá. Obohať jeho firmu: nájde jej web a z neho adresu.", tint: .purple)
                Button { Enricher.shared.start([r.orgId]) } label: { Label("Obohatiť \(r.company ?? "firmu")", systemImage: "wand.and.stars") }.disabled(Enricher.shared.running)
            }
            Card("Firma", symbol: "building.2.fill", tint: .blue) {
                Text(r.company ?? "–").font(.headline)
                Text([r.city.map(shortCity), r.region, r.industry].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    if let v = r.revenue { Label(Money.short(v), systemImage: "eurosign.circle") }
                    if let s = r.employees ?? r.size { Label("\(s) zam.", systemImage: "person.3") }
                }
                .font(.callout)
                Button("Otvoriť firmu") { store.pendingSelection = "org/\(r.orgId)" }.buttonStyle(.link)
            }
        }
    }
}

// MARK: company detail

struct OrgDetailView: View {
    let id: String
    @ObservedObject var p = Prospector.shared
    @ObservedObject var e = Enricher.shared
    @ObservedObject var store: Store
    @State private var web = ""

    var body: some View {
        Group {
            if let o = p.detail[id] {
                Page {
                    header(o)
                    HStack(spacing: 12) {
                        StatTile("Tržby", Money.short(o.revenue), detail: o.finYear.map { y in o.revenuePrev.map { "\(y) · predtým \(Money.short($0))" } ?? y } ?? (o.country == "SK" ? "po obohatení" : "CZ zatiaľ nie"), symbol: "eurosign.circle.fill", tint: .green)
                        StatTile("Zisk", Money.short(o.profit), detail: o.finYear, symbol: "chart.line.uptrend.xyaxis", tint: (o.profit ?? 0) < 0 ? .red : .teal)
                        StatTile("Zamestnanci", o.employees ?? "–", detail: o.size.map { "pásmo \($0)" } ?? (o.country == "SK" ? "po obohatení" : nil), symbol: "person.3.fill", tint: .orange)
                        StatTile("Založená", o.founded.map { String($0.prefix(4)) } ?? "–", detail: o.founded.flatMap(Fmt.day).map { "pred \(Calendar.current.dateComponents([.year], from: $0, to: .now).year ?? 0) r." }, symbol: "calendar", tint: .blue)
                    }
                    Card("Ľudia", symbol: "person.2.fill", tint: .green) {
                        if o.people.isEmpty { Text(o.country == "CZ" ? "Českých jednateľov Scout zatiaľ nemá; ľudí nájde na ich webe." : "V registri nie sú uvedení.").foregroundStyle(.secondary) }
                        ForEach(o.people) { m in
                            HStack(spacing: 10) {
                                Avatar(name: m.name, size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text([m.title, m.name].compactMap { $0 }.joined(separator: " ")).font(.body.weight(.medium))
                                    Text([m.role, m.origin == "registry" ? "z registra" : "z webu"].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let em = m.email {
                                    HStack(spacing: 5) {
                                        Circle().fill(Confidence.tint(m.confidence)).frame(width: 7, height: 7)
                                        Text(em).font(.callout).textSelection(.enabled)
                                    }
                                    .help(Confidence.label(m.confidence))
                                    Button { copy(em); store.toast = "Skopírované: \(em)" } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                                } else if let d = o.sites.first?.domain {
                                    Button("Nájsť e-mail") { store.person(name: m.name, domain: d) { _ in p.load(id, force: true) } }.controlSize(.small)
                                }
                            }
                        }
                    }
                    webCard(o)
                    HStack(alignment: .top, spacing: 12) {
                        Card("Sídlo", symbol: "mappin.and.ellipse", tint: .red) {
                            Text(o.address ?? "–").textSelection(.enabled)
                            if let r = o.region { Text("\(r) kraj").font(.caption).foregroundStyle(.secondary) }
                            if let a = o.address { Button("Ukázať na mape") { open("http://maps.apple.com/?q=\(a.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") }.buttonStyle(.link) }
                        }
                        Card("Odvetvie", symbol: "square.grid.2x2.fill", tint: .purple) {
                            Text(o.industry ?? "–")
                            if let n = o.nace { Text("NACE \(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled) }
                            if let n = o.nace { Button("Firmy s rovnakým kódom") { p.filters = CompanyFilters(country: o.country, nace: n) }.buttonStyle(.link) }
                        }
                    }
                    Text([o.source.map { $0.hasPrefix("http") ? "Register účtovných závierok" : $0 }, o.enrichedAt.flatMap(Fmt.iso).map { "obohatené \(Fmt.date($0))" }, o.enrichNote].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { p.load(id) }
    }

    func header(_ o: OrgDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(o.name ?? o.ico).font(.title.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 6) {
                pill(o.country == "SK" ? "🇸🇰 Slovensko" : "🇨🇿 Česko")
                if let f = o.legalForm { pill(f) }
                Button { copy(o.ico); store.toast = "Skopírované IČO \(o.ico)" } label: { pill("IČO \(o.ico)") }.buttonStyle(.plain).help("Kopírovať")
                if let d = o.dic { pill("DIČ \(d)") }
                if let d = o.dissolved { pill("zaniknutá \(d)", tint: .red) }
                if o.enrichedAt != nil { pill("obohatené", tint: .purple) }
            }
            HStack(spacing: 8) {
                Button { e.start([o.id]) } label: { Label(o.enrichedAt == nil ? "Obohatiť" : "Obohatiť znova", systemImage: "wand.and.stars") }
                    .buttonStyle(.glassProminent).disabled(e.running)
                Menu { ForEach(store.data?.lists ?? []) { l in Button(l.name) { p.addToList(l.name, [o.id]) } } } label: { Label("Do zoznamu", systemImage: "text.badge.plus") }.fixedSize()
                if let d = o.sites.first?.domain { Button { open("https://\(d)") } label: { Label(d, systemImage: "safari") } }
                if let s = o.source, s.hasPrefix("http") { Button { open(s) } label: { Label("Register", systemImage: "building.columns") } }
            }
            .controlSize(.regular)
        }
    }

    func pill(_ t: String, tint: Color = .secondary) -> some View {
        Text(t).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3).background(tint.opacity(0.12), in: .capsule).foregroundStyle(tint == .secondary ? .primary : tint)
    }

    @ViewBuilder func webCard(_ o: OrgDetail) -> some View {
        Card("Web a kontakty", symbol: "globe", tint: .blue) {
            if o.sites.isEmpty {
                Text(o.enrichNote ?? "Scout zatiaľ nepozná ich web. Obohatenie ho skúsi nájsť, alebo ho zadaj.").foregroundStyle(.secondary)
                HStack {
                    TextField("firma.sk", text: $web).textFieldStyle(.roundedBorder).onSubmit(read)
                    Button("Prečítať web", action: read).disabled(web.trimmingCharacters(in: .whitespaces).isEmpty || store.busy != nil)
                }
                Button("Hľadať na Googli") { open("https://www.google.com/search?q=\((o.name ?? o.ico).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") }.buttonStyle(.link)
            }
            ForEach(o.sites, id: \.self) { s in
                if let c = store.companies[s.domain] {
                    let own = c.emails.filter(\.own)
                    ForEach(own.prefix(6)) { em in
                        HStack {
                            Image(systemName: em.kind == "generic" ? "building.2" : "person").foregroundStyle(.secondary).frame(width: 16)
                            Text(em.email).textSelection(.enabled)
                            if let n = em.name { Text(n).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button { copy(em.email); store.toast = "Skopírované: \(em.email)" } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                        }
                    }
                    if own.isEmpty { Text("Na \(s.domain) nie je žiadna adresa.").foregroundStyle(.secondary) }
                    HStack {
                        Text("\(s.domain) · \(own.count) adries · vzor \(Confidence.pattern(c.pattern))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Všetko z webu") { store.pendingSelection = "company/\(s.domain)" }.buttonStyle(.link)
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text(s.domain).foregroundStyle(.secondary) }.onAppear { store.company(s.domain) }
                }
            }
        }
    }

    func read() {
        let d = web.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty else { return }
        store.company(d, org: id) { _ in p.load(id, force: true); web = "" }
    }
}
