import Charts
import MarketCore
import ServiceManagement
import SwiftUI

extension Double {
    var pctText: String { String(format: "%+.2f%%", self) }
    var tint: Color { self > 0.005 ? .green : self < -0.005 ? .red : .secondary }
}

struct Sparkline: View {
    let points: [Double]
    let prev: Double?
    var body: some View {
        if points.count > 1, let lo = points.min(), let hi = points.max() {
            let low = min(lo, prev ?? lo), high = max(hi, prev ?? hi)
            Chart {
                if let p = prev { RuleMark(y: .value("prev", p)).lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 2])).foregroundStyle(.secondary) }
                ForEach(Array(points.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("t", i), y: .value("p", v)).foregroundStyle((points.last! - (prev ?? points[0])).tint)
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: low...(high > low ? high : low + 1))
        } else {
            Color.clear
        }
    }
}

// MARK: menu bar

struct MenuLabel: View {
    @ObservedObject var model: Model
    @AppStorage("menuCountdown") var countdown = true

    /// Time to the close while open (timer), to the open when it's less than a day away (moon).
    var clock: Text? {
        guard countdown, let c = model.clock, let left = c.compact(model.now) else { return nil }
        return Text(" \(Image(systemName: c.isOpen ? "timer" : "moon.zzz"))\(left)").font(.system(size: 12).monospacedDigit())
    }

    var body: some View {
        if let q = model.headline {
            // short, so it still fits on a crowded menu bar next to the notch
            Text("\(q.symbol) \(String(format: "%+.1f%%", q.pct))") + (clock ?? Text(""))
        } else {
            Image(systemName: "chart.line.uptrend.xyaxis")
        }
    }
}

/// Open/closed, countdown to the next bell and how much of today's session is gone.
struct SessionRow: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(model.marketOpen ? .green : .secondary).frame(width: 7, height: 7)
                Text(model.clock?.status(model.now) ?? (model.marketOpen ? "US market open" : "US market closed")).font(.caption)
                Spacer()
                Text(model.live ? "live" : "every minute").font(.caption2).foregroundStyle(.secondary)
            }
            if let p = model.clock?.progress(model.now) {
                ProgressView(value: p).progressViewStyle(.linear).tint(p > 0.94 ? .orange : .green).controlSize(.mini)
            }
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: Model
    let openBrief: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SessionRow(model: model)
            Divider()
            ForEach(model.ordered, id: \.symbol) { q in
                HStack(spacing: 8) {
                    Text(q.symbol).font(.system(.body, design: .monospaced).weight(.semibold)).frame(width: 56, alignment: .leading)
                    Sparkline(points: model.sparks[q.symbol] ?? [], prev: q.prev).frame(width: 70, height: 20)
                    Spacer()
                    Text(String(format: "%.2f", q.last)).monospacedDigit()
                    Text(q.pct.pctText).monospacedDigit().foregroundStyle(q.pct.tint).frame(width: 62, alignment: .trailing)
                }
            }
            if model.ordered.isEmpty { Text("Loading prices…").foregroundStyle(.secondary) }
            if let a = model.account {
                Divider()
                HStack {
                    Text("Paper").foregroundStyle(.secondary)
                    Text(String(format: "%.0f USD", a.equity)).monospacedDigit()
                    Spacer()
                    Text(String(format: "%+.2f today", a.plToday)).monospacedDigit().foregroundStyle(a.plToday.tint)
                }.font(.caption)
            }
            if let p = model.problem { Text(p).font(.caption2).foregroundStyle(.orange).lineLimit(3) }
            Divider()
            HStack {
                Button("Brief now") { Task { await model.makeBrief(notify: false); openBrief() } }
                Button("Open brief", action: openBrief)
                Spacer()
                Button { openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit MarketBar")
            }
        }
        .padding(12)
        .frame(width: 330)
    }
}

// MARK: brief window

struct BriefView: View {
    @ObservedObject var model: Model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Market brief").font(.largeTitle.bold())
                    Spacer()
                    Button("Refresh") { Task { await model.makeBrief(notify: false) } }
                    if let f = model.lastBrief { Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([f]) } }
                }
                if let a = model.account {
                    HStack(spacing: 28) {
                        stat("Equity", String(format: "%.2f USD", a.equity))
                        stat("Today", String(format: "%+.2f USD", a.plToday), a.plToday.tint)
                        stat("Cash", String(format: "%.2f", a.cash))
                        stat("Buying power", String(format: "%.0f", a.buyingPower))
                    }
                }
                if !model.positions.isEmpty {
                    section("Positions")
                    Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow { Text("").gridColumnAlignment(.leading); Text("Qty"); Text("Price"); Text("P/L"); Text("P/L %") }.foregroundStyle(.secondary)
                        ForEach(model.positions) { p in
                            GridRow {
                                Text(p.symbol).bold()
                                Text(String(format: "%g", p.qty)); Text(String(format: "%.2f", p.price))
                                Text(String(format: "%+.2f", p.pl)).foregroundStyle(p.pl.tint)
                                Text(String(format: "%+.1f%%", p.plPct)).foregroundStyle(p.pl.tint)
                            }.monospacedDigit()
                        }
                    }
                }
                section("Watchlist")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(model.ordered.sorted { abs($0.pct) > abs($1.pct) }, id: \.symbol) { q in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(q.symbol).font(.headline)
                                Spacer()
                                Text(q.pct.pctText).foregroundStyle(q.pct.tint).monospacedDigit().bold()
                            }
                            Sparkline(points: model.sparks[q.symbol] ?? [], prev: q.prev).frame(height: 54)
                            Text(String(format: "%.2f  ·  prev %.2f", q.last, q.prev)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if !model.news.isEmpty {
                    section("News")
                    ForEach(model.news) { n in
                        HStack(alignment: .firstTextBaseline) {
                            Text(n.symbols.prefix(3).joined(separator: ", ")).font(.caption.bold()).frame(width: 90, alignment: .leading)
                            if let u = URL(string: n.url) { Link(n.headline, destination: u) } else { Text(n.headline) }
                        }
                    }
                }
                Text("Alpaca paper account, IEX prices. For your own tracking, not advice.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(minWidth: 640, minHeight: 520)
        .task { if model.news.isEmpty { await model.makeBrief(notify: false) } }
    }

    func stat(_ t: String, _ v: String, _ c: Color = .primary) -> some View {
        VStack(alignment: .leading) { Text(t).font(.caption).foregroundStyle(.secondary); Text(v).font(.title3.monospacedDigit()).foregroundStyle(c) }
    }

    func section(_ t: String) -> some View { Text(t).font(.title2.bold()).padding(.top, 4) }
}

// MARK: settings

struct SettingsView: View {
    @ObservedObject var model: Model
    @State var draft = WatchConfig(symbols: [], moveAlertPct: 3)
    @State var newSymbol = ""
    @State var atLogin = SMAppService.mainApp.status == .enabled
    @State var saved = false
    @AppStorage("chimes") var chimes = true
    @AppStorage("closeWarning") var closeWarning = true
    @AppStorage("menuCountdown") var menuCountdown = true

    var body: some View {
        Form {
            Section("Watchlist") {
                ForEach(draft.symbols, id: \.self) { s in
                    HStack {
                        Text(s).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) { draft.symbols.removeAll { $0 == s } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add symbol, e.g. AMD", text: $newSymbol).onSubmit(add)
                    Button("Add", action: add).disabled(newSymbol.isEmpty)
                }
                Text("The first symbol is shown in the menu bar.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Alerts") {
                HStack {
                    Text("Alert when a symbol moves")
                    TextField("", value: $draft.moveAlertPct, format: .number).frame(width: 50)
                    Text("% from yesterday's close")
                }
                ForEach(draft.levels.indices, id: \.self) { i in
                    HStack {
                        TextField("Symbol", text: $draft.levels[i].symbol).frame(width: 70)
                        Text("above"); TextField("0 = off", value: $draft.levels[i].above, format: .number).frame(width: 80)
                        Text("below"); TextField("0 = off", value: $draft.levels[i].below, format: .number).frame(width: 80)
                        Button(role: .destructive) { draft.levels.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Add price level") { draft.levels.append(Level(symbol: draft.symbols.first ?? "SPY")) }
            }
            Section("Market hours") {
                Toggle("Chime at the open and the close", isOn: $chimes)
                Toggle("Warn 15 minutes before the close", isOn: $closeWarning)
                Toggle("Countdown in the menu bar", isOn: $menuCountdown)
                Text("Times come from Alpaca's market clock, holidays and early closes included.").font(.caption).foregroundStyle(.secondary)
                Button("Play the chimes") { Notifier.post(title: "🔔 US market open", body: "Test chime", id: "test-open", sound: "market-open.wav") }
            }
            .onChange(of: chimes) { _, _ in model.scheduleBells() }
            .onChange(of: closeWarning) { _, _ in model.scheduleBells() }
            Section("App") {
                Toggle("Open at login", isOn: $atLogin).onChange(of: atLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { model.problem = "Open at login: \(error.localizedDescription)"; atLogin = !on }
                }
                Button("Send a test notification") { Notifier.post(title: "MarketBar", body: "Notifications work", id: "test") }
            }
            HStack {
                Spacer()
                if saved { Text("Saved").foregroundStyle(.secondary) }
                Button("Save") {
                    draft.levels = draft.levels.map { Level(symbol: $0.symbol.uppercased(), above: $0.above, below: $0.below) }
                    model.apply(draft, save: true)
                    saved = true
                }.keyboardShortcut(.defaultAction).disabled(draft == model.cfg)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .onAppear { draft = model.cfg }
        .onChange(of: draft) { _, _ in saved = false }
    }

    func add() {
        let s = newSymbol.uppercased().trimmingCharacters(in: .whitespaces)
        if !s.isEmpty, !draft.symbols.contains(s) { draft.symbols.append(s) }
        newSymbol = ""
    }
}
