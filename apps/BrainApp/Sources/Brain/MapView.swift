import AppKit
import SwiftUI

/// Brain map: everything Brain works with (Hangar apps, other apps and MCP servers, folders, its own parts) around Brain,
/// grouped. Nodes and whole groups can be dragged (positions are kept), the canvas pans and zooms, and a click opens the
/// node with its switch: off means Brain won't use it (brain.config.json "off", enforced by the Brain MCP).
struct MapNode: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let group: String
    let kind: String
    let symbol: String
    let app: String?
    let on: Bool
    let detail: String
    let path: String?
    let usable: Bool?
}

struct MapData: Decodable {
    let groups: [String: String]
    let nodes: [MapNode]
}

@MainActor
final class MapStore: ObservableObject {
    static let shared = MapStore()
    @Published var nodes: [MapNode] = []
    @Published var groups: [String: String] = [:]
    @Published var error: String?
    @Published var positions: [String: CGPoint] = [:]
    static let script = NSHomeDirectory() + "/Developer/brain/src/map.js"
    static let order = ["hangar", "komunikacia", "praca", "peniaze", "zdravie", "apple", "subory", "brain", "ine", "nove"]

    init() {
        if let d = UserDefaults.standard.data(forKey: "mapPositions"), let p = try? JSONDecoder().decode([String: [CGFloat]].self, from: d) {
            positions = p.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        }
    }

    func load() {
        run([]) { [weak self] data in
            guard let self else { return }
            guard let m = try? JSONDecoder().decode(MapData.self, from: data) else { error = "Mapu sa nepodarilo načítať z Brainu."; return }
            let fresh = nodes.map(\.id) != m.nodes.map(\.id)
            error = nil; nodes = m.nodes; groups = m.groups
            if fresh || auto.isEmpty { relax() }
        }
    }

    func set(_ ids: [String], on: Bool) {
        // optimistic: the switch flips now, the file follows
        nodes = nodes.map { n in ids.contains(n.id) ? MapNode(id: n.id, name: n.name, group: n.group, kind: n.kind, symbol: n.symbol, app: n.app,
                                                               on: on, detail: n.detail, path: n.path, usable: n.usable) : n }
        var left = ids
        func next() {
            guard !left.isEmpty else { load(); return }
            run(["set", left.removeFirst(), on ? "on" : "off"]) { _ in next() }
        }
        next()
    }

    func run(_ args: [String], done: @escaping (Data) -> Void) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/node")
        p.arguments = [Self.script] + args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            let d = out.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async { done(d) }
        }
        do { try p.run() } catch { self.error = error.localizedDescription }
    }

    /// Synchronous load, for the snapshot.
    func loadNow() {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/node")
        p.arguments = [Self.script]
        p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        if let m = try? JSONDecoder().decode(MapData.self, from: out.fileHandleForReading.readDataToEndOfFile()) { nodes = m.nodes; groups = m.groups; relax() }
    }

    // MARK: layout: Brain at the origin, groups on a ring, their nodes fanned out behind them

    var shownGroups: [String] { Self.order.filter { g in nodes.contains { $0.group == g } } }

    func defaultHub(_ g: String) -> CGPoint {
        let gs = shownGroups, i = gs.firstIndex(of: g) ?? 0
        let a = -Double.pi / 2 + Double(i) / Double(max(gs.count, 1)) * 2 * .pi
        return CGPoint(x: cos(a) * 360, y: sin(a) * 270)
    }

    func hub(_ g: String) -> CGPoint { positions["group:" + g] ?? defaultHub(g) }

    /// Default spots after nudging overlapping nodes apart (computed once per load).
    @Published var auto: [String: CGPoint] = [:]

    func position(_ n: MapNode) -> CGPoint { positions[n.id] ?? auto[n.id] ?? fan(n) }

    /// Pushes nodes apart until none overlap (Brain and the group labels stay put), so the default map is readable.
    func relax() {
        func size(_ name: String) -> CGSize { CGSize(width: 44 + CGFloat(name.count) * 7.4, height: 36) }
        var pts = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, positions[$0.id] ?? fan($0)) })
        let movable = Set(nodes.filter { positions[$0.id] == nil }.map(\.id))
        var fixed: [(CGPoint, CGSize)] = [(.zero, CGSize(width: 110, height: 110))]
        for g in shownGroups { fixed.append((hub(g), size((groups[g] ?? g) + " 10/10"))) }
        let sizes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, size($0.name)) })
        let ids = nodes.map(\.id)
        for _ in 0..<120 {
            var moved = false
            for (i, a) in ids.enumerated() where movable.contains(a) {
                var pa = pts[a]!, sa = sizes[a]!
                func push(_ pb: CGPoint, _ sb: CGSize, both: String?) {
                    let dx = pa.x - pb.x, dy = pa.y - pb.y
                    let ox = (sa.width + sb.width) / 2 + 10 - abs(dx), oy = (sa.height + sb.height) / 2 + 8 - abs(dy)
                    guard ox > 0, oy > 0 else { return }
                    moved = true
                    let share: CGFloat = both != nil && movable.contains(both!) ? 0.5 : 1
                    if ox < oy * 1.6 { let m = (dx >= 0 ? 1 : -1) * ox * share; pa.x += m; if let b = both, share < 1 { pts[b]!.x -= m } }
                    else { let m = (dy >= 0 ? 1 : -1) * oy * share; pa.y += m; if let b = both, share < 1 { pts[b]!.y -= m } }
                }
                for b in ids[(i + 1)...] { push(pts[b]!, sizes[b]!, both: b) }
                for (fp, fs) in fixed { push(fp, fs, both: nil) }
                pts[a] = pa; sa = sizes[a]!
            }
            if !moved { break }
        }
        auto = pts.filter { movable.contains($0.key) }
    }

    func fan(_ n: MapNode) -> CGPoint {
        // fanned out behind the hub on up to three arcs, so a big group doesn't spill into its neighbours
        let members = nodes.filter { $0.group == n.group }, i = members.firstIndex(of: n) ?? 0, count = members.count
        let rings = count > 6 ? 3 : count > 3 ? 2 : 1, ring = i % rings, k = i / rings
        let perRing = Int((Double(count) / Double(rings)).rounded(.up))
        let h = hub(n.group), base = atan2(Double(h.y), Double(h.x))
        let spread = min(1.5, Double(perRing - 1) * 0.42) * (ring == 1 ? 0.8 : 1)
        let a = base + (perRing <= 1 ? 0 : -spread / 2 + spread * Double(k) / Double(max(perRing - 1, 1))) + (ring == 1 ? 0.12 : 0)
        let r = 120.0 + Double(ring) * 62
        return CGPoint(x: h.x + cos(a) * r * 1.35, y: h.y + sin(a) * r)
    }

    func move(_ id: String, to p: CGPoint) { positions[id] = p }

    /// Dragging a group moves its hub and every node of it by the same amount.
    func moveGroup(_ g: String, by d: CGSize, from start: [String: CGPoint]) {
        // one change per drag step (not one per node), so the map redraws once
        var all = positions
        for (k, p) in start { all[k] = CGPoint(x: p.x + d.width, y: p.y + d.height) }
        positions = all
        _ = g
    }

    func savePositions() {
        let p = positions.mapValues { [$0.x, $0.y] }
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: "mapPositions") }
    }

    /// Everything on the map (world coordinates), for fitting it into the window.
    var bounds: CGRect {
        var r = CGRect(x: -60, y: -60, width: 120, height: 120)
        for g in shownGroups { let h = hub(g); r = r.union(CGRect(x: h.x - 70, y: h.y - 18, width: 140, height: 36)) }
        for n in nodes { let p = position(n), w = 44 + CGFloat(n.name.count) * 7.4; r = r.union(CGRect(x: p.x - w / 2, y: p.y - 18, width: w, height: 36)) }
        return r
    }

    func resetLayout() { positions = [:]; savePositions(); relax() }

    static func color(_ g: String) -> Color {
        switch g {
        case "hangar": .brainAccent
        case "komunikacia": .green
        case "praca": .blue
        case "peniaze": .mint
        case "zdravie": .orange
        case "subory": .cyan
        case "brain": .pink
        case "apple": .indigo
        case "nove": .yellow
        default: .gray
        }
    }
}

/// Pan and zoom of the map. Trackpad scroll pans, pinch (or ⌘ + scroll) zooms around the pointer; both come from an
/// event monitor so they work anywhere over the map, not only on empty canvas.
@MainActor
final class MapCamera: ObservableObject {
    @Published var offset: CGSize = .zero
    @Published var scale: CGFloat = 0.8
    /// Panned or zoomed by hand: stop fitting to the window.
    var userMoved = false
    var size: CGSize = .zero
    var frame: CGRect = .zero
    weak var window: NSWindow?
    private var monitor: Any?
    static let range: ClosedRange<CGFloat> = 0.3...2.4

    var center: CGPoint { CGPoint(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height) }
    func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + p.x * scale, y: center.y + p.y * scale) }

    /// Zoom keeping the map point under `at` (view coordinates) where it is.
    func zoom(by f: CGFloat, at p: CGPoint? = nil) {
        let p = p ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let new = min(max(scale * f, Self.range.lowerBound), Self.range.upperBound)
        let c = center, w = CGPoint(x: (p.x - c.x) / scale, y: (p.y - c.y) / scale)
        offset = CGSize(width: p.x - size.width / 2 - w.x * new, height: p.y - size.height / 2 - w.y * new)
        scale = new
    }

    func fit(_ b: CGRect) {
        guard size.width > 0, b.width > 0 else { return }
        scale = min(max(min((size.width - 60) / b.width, (size.height - 90) / b.height), Self.range.lowerBound), 1.1)
        offset = CGSize(width: -b.midX * scale, height: -b.midY * scale - 10)
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
            let used = MainActor.assumeIsolated { self?.handle(e) ?? false }
            return used ? nil : e
        }
    }

    func stop() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }

    /// True when the event moved the map (and is used up).
    private func handle(_ e: NSEvent) -> Bool {
        guard let w = e.window, w === window, let cv = w.contentView else { return false }
        let q = cv.convert(e.locationInWindow, from: nil)
        let p = cv.isFlipped ? q : CGPoint(x: q.x, y: cv.bounds.height - q.y)
        guard frame.contains(p) else { return false }
        let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        userMoved = true
        if e.type == .magnify {
            zoom(by: 1 + e.magnification, at: local)
        } else if e.modifierFlags.contains(.command) {
            zoom(by: 1 + e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.01 : 0.08), at: local)
        } else {
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 14
            offset = CGSize(width: offset.width + e.scrollingDeltaX * k, height: offset.height + e.scrollingDeltaY * k)
        }
        return true
    }
}

/// Gives the hosting NSWindow to SwiftUI (for the scroll monitor).
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { found(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { if v.window != nil { DispatchQueue.main.async { found(v.window) } } }
}

/// App icons are looked up once per version of the app, not on every redraw. A reinstalled app (a new icon) is noticed by its
/// changed bundle, and an app that wasn't installed yet is looked for again after a minute.
@MainActor
enum MapIcons {
    private static var cache: [String: (stamp: Date, image: NSImage)] = [:]
    private static var missing: [String: Date] = [:]
    static func icon(_ bundle: String) -> NSImage? {
        if let m = missing[bundle], Date().timeIntervalSince(m) < 60 { return nil }
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { missing[bundle] = Date(); return nil }
        missing[bundle] = nil
        let info = u.appendingPathComponent("Contents/Info.plist")
        let stamp = (try? info.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let hit = cache[bundle], hit.stamp == stamp { return hit.image }
        // the icon file itself, so a new icon shows even while Launch Services still has the old one cached
        let name = (Bundle(url: u)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String) ?? "AppIcon"
        let file = u.appendingPathComponent("Contents/Resources/\(name.hasSuffix(".icns") ? name : name + ".icns")")
        let image = NSImage(contentsOf: file) ?? NSWorkspace.shared.icon(forFile: u.path)
        cache[bundle] = (stamp, image)
        return image
    }
}

/// Dot grid that moves and scales with the map, so panning feels like moving paper.
private struct DotGrid: View, Equatable {
    let origin: CGPoint
    let scale: CGFloat
    var body: some View {
        Canvas { ctx, size in
            var step = 26 * scale
            while step < 16 { step *= 2 }
            let r: CGFloat = max(0.6, min(1, scale)) * 0.85
            func first(_ o: CGFloat) -> CGFloat { let m = o.truncatingRemainder(dividingBy: step); return m < 0 ? m + step : m }
            var path = Path()
            for x in stride(from: first(origin.x), through: size.width, by: step) {
                for y in stride(from: first(origin.y), through: size.height, by: step) {
                    path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
            }
            ctx.fill(path, with: .color(.secondary.opacity(0.22)))
        }
    }
}

private struct NodeChip: View, Equatable {
    let n: MapNode
    let selected: Bool
    let lifted: Bool
    var body: some View {
        let c = MapStore.color(n.group)
        HStack(spacing: 7) {
            MapIcon(n: n, size: 22)
            Text(n.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if !n.on { Image(systemName: "pause.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected || lifted ? c : Color.secondary.opacity(0.22), lineWidth: selected || lifted ? 1.5 : 0.5))
        .shadow(color: .black.opacity(lifted ? 0.16 : n.on ? 0.06 : 0), radius: lifted ? 10 : 3, y: lifted ? 5 : 1)
        .opacity(n.on ? 1 : 0.45)
        .saturation(n.on ? 1 : 0)
        .scaleEffect(lifted ? 1.06 : 1)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: lifted)
    }
}

private struct HubChip: View, Equatable {
    let name: String
    let group: String
    let on: Int
    let total: Int
    let selected: Bool
    let lifted: Bool
    var body: some View {
        let c = MapStore.color(group)
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(name).font(.system(size: 12, weight: .semibold))
            Text("\(on)/\(total)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Capsule().fill(.background))
        .overlay(Capsule().strokeBorder(selected || lifted ? c : Color.secondary.opacity(0.25), lineWidth: selected || lifted ? 1.5 : 0.5))
        .shadow(color: .black.opacity(lifted ? 0.16 : 0.06), radius: lifted ? 10 : 4, y: lifted ? 5 : 1)
        .scaleEffect(lifted ? 1.06 : 1)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: lifted)
    }
}

struct MapIcon: View {
    let n: MapNode
    let size: CGFloat
    var body: some View {
        if let a = n.app, let i = MapIcons.icon(a) {
            Image(nsImage: i).resizable().frame(width: size + 2, height: size + 2)
        } else {
            Image(systemName: n.symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(MapStore.color(n.group), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        }
    }
}

struct MapPage: View {
    @ObservedObject var store = MapStore.shared
    @StateObject private var cam = MapCamera()
    @Environment(\.snapshot) private var snapshot
    @State var panStart: CGSize?
    @State var selected: String?
    /// What is being dragged ("group:…" or a node id) and where it all started (world coordinates).
    @State var dragging: String?
    @State var dragStart: [String: CGPoint]?
    static let space = "brainMap"

    var body: some View {
        GeometryReader { geo in
            let pos = Dictionary(uniqueKeysWithValues: store.nodes.map { ($0.id, store.position($0)) })
            let hubs = Dictionary(uniqueKeysWithValues: store.shownGroups.map { ($0, store.hub($0)) })
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                DotGrid(origin: cam.center, scale: cam.scale).equatable()
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture(count: 2) { cam.userMoved = false; withAnimation(.smooth(duration: 0.45)) { cam.fit(store.bounds) } }
                    .onTapGesture { selected = nil }
                lines(pos: pos, hubs: hubs)
                brainNode.scaleEffect(cam.scale).position(cam.center)
                ForEach(store.shownGroups, id: \.self) { g in
                    let members = store.nodes.filter { $0.group == g }
                    HubChip(name: store.groups[g] ?? g, group: g, on: members.filter(\.on).count, total: members.count,
                            selected: selected == "group:" + g, lifted: dragging == "group:" + g).equatable()
                        .contentShape(Capsule())
                        .pointerStyle(dragging == "group:" + g ? .grabActive : .grabIdle)
                        .onTapGesture { selected = "group:" + g }
                        .gesture(groupDrag(g, members: members))
                        .scaleEffect(cam.scale)
                        .position(cam.screen(hubs[g] ?? .zero))
                }
                ForEach(store.nodes) { n in
                    NodeChip(n: n, selected: selected == n.id, lifted: dragging == n.id || dragging == "group:" + n.group).equatable()
                        .contentShape(Rectangle())
                        .pointerStyle(dragging == n.id ? .grabActive : .grabIdle)
                        .onTapGesture { selected = n.id }
                        .contextMenu { menu(n) }
                        .gesture(nodeDrag(n))
                        .scaleEffect(cam.scale)
                        .position(cam.screen(pos[n.id] ?? .zero))
                }
            }
            .coordinateSpace(.named(Self.space))
            .clipped()
            .background(WindowReader { w in cam.window = w })
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                cam.frame = f
                let grew = cam.size != f.size
                cam.size = f.size
                if grew, !cam.userMoved { cam.fit(store.bounds) }
            }
            .onAppear { cam.size = geo.size; cam.frame = geo.frame(in: .global); cam.fit(store.bounds); cam.start() }
            .onDisappear { cam.stop() }
            .onChange(of: store.auto.count) { _, _ in if !cam.userMoved { cam.fit(store.bounds) } }
            .overlay(alignment: .topTrailing) { if let s = selected { inspector(s).padding(16).transition(.opacity.combined(with: .scale(0.97, anchor: .topTrailing))) } }
            .animation(.smooth(duration: 0.2), value: selected)
            .overlay(alignment: .bottomLeading) { legend.padding(16) }
            .overlay(alignment: .center) {
                if store.nodes.isEmpty {
                    if let e = store.error { ContentUnavailableView("Mapa nie je k dispozícii", systemImage: "point.3.connected.trianglepath.dotted", description: Text(e)) }
                    else { ProgressView() }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { withAnimation(.smooth) { cam.userMoved = true; cam.zoom(by: 1 / 1.25) } } label: { Label("Oddialiť", systemImage: "minus.magnifyingglass") }
                Button { withAnimation(.smooth) { cam.userMoved = true; cam.zoom(by: 1.25) } } label: { Label("Priblížiť", systemImage: "plus.magnifyingglass") }
                Button { cam.userMoved = false; withAnimation(.smooth(duration: 0.45)) { cam.fit(store.bounds) } } label: { Label("Zobraziť všetko", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Zobraziť celú mapu (aj dvojklik do prázdna)")
                Button {
                    cam.userMoved = false
                    withAnimation(.smooth(duration: 0.5)) { store.resetLayout(); cam.fit(store.bounds) }
                } label: { Label("Usporiadať", systemImage: "circle.grid.cross") }
                    .help("Vrátiť pôvodné rozloženie")
            }
        }
        .onAppear { if snapshot { store.loadNow() } else { store.load() } }
    }

    // MARK: gestures (all measured in the map's own space, so a moving chip doesn't feed back into its own drag)

    var panGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if panStart == nil { panStart = cam.offset; cam.userMoved = true }
                cam.offset = CGSize(width: panStart!.width + v.translation.width, height: panStart!.height + v.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    func nodeDrag(_ n: MapNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if dragStart == nil { dragStart = [n.id: store.position(n)]; dragging = n.id }
                guard let s = dragStart?[n.id] else { return }
                store.move(n.id, to: CGPoint(x: s.x + v.translation.width / cam.scale, y: s.y + v.translation.height / cam.scale))
            }
            .onEnded { _ in dragStart = nil; dragging = nil; store.savePositions() }
    }

    func groupDrag(_ g: String, members: [MapNode]) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if dragStart == nil {
                    var s: [String: CGPoint] = ["group:" + g: store.hub(g)]
                    for n in members { s[n.id] = store.position(n) }
                    dragStart = s; dragging = "group:" + g
                }
                guard let s = dragStart else { return }
                store.moveGroup(g, by: CGSize(width: v.translation.width / cam.scale, height: v.translation.height / cam.scale), from: s)
            }
            .onEnded { _ in dragStart = nil; dragging = nil; store.savePositions() }
    }

    @ViewBuilder func menu(_ n: MapNode) -> some View {
        Button(n.on ? "Vypnúť" : "Zapnúť") { store.set([n.id], on: !n.on) }
        if let p = n.path { Button("Ukázať vo Finderi") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }
        if let a = n.app, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: a) { Button("Otvoriť appku") { NSWorkspace.shared.open(u) } }
    }

    // MARK: drawing

    func lines(pos: [String: CGPoint], hubs: [String: CGPoint]) -> some View {
        let o = cam.center, s = cam.scale, nodes = store.nodes
        func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: o.x + p.x * s, y: o.y + p.y * s) }
        return Canvas { ctx, _ in
            for (g, hw) in hubs {
                let h = screen(hw), c = MapStore.color(g)
                let members = nodes.filter { $0.group == g }
                let allOff = members.allSatisfy { !$0.on }
                var p = Path(); p.move(to: o); p.addQuadCurve(to: h, control: CGPoint(x: (o.x + h.x) / 2, y: o.y + (h.y - o.y) * 0.15))
                ctx.stroke(p, with: .color(c.opacity(allOff ? 0.18 : 0.45)), style: StrokeStyle(lineWidth: 2.2 * max(s, 0.6), lineCap: .round, dash: allOff ? [5, 5] : []))
                var on = Path(), off = Path()
                for n in members {
                    let q = screen(pos[n.id] ?? .zero)
                    // a gentle curve out of the hub reads calmer than a fan of straight spokes
                    let m = CGPoint(x: (h.x + q.x) / 2, y: (h.y + q.y) / 2)
                    let ctrl = CGPoint(x: m.x + (h.y - q.y) * 0.08, y: m.y - (h.x - q.x) * 0.08)
                    if n.on { on.move(to: h); on.addQuadCurve(to: q, control: ctrl) } else { off.move(to: h); off.addQuadCurve(to: q, control: ctrl) }
                }
                ctx.stroke(on, with: .color(c.opacity(0.32)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                ctx.stroke(off, with: .color(.secondary.opacity(0.22)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [4, 4]))
            }
        }
        .allowsHitTesting(false)
    }

    var brainNode: some View {
        VStack(spacing: 6) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 70, height: 70)
                .background(Circle().fill(.background))
                .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
                .shadow(color: .purple.opacity(0.25), radius: 14, y: 4)
            Text("Brain").font(.system(size: 13, weight: .semibold))
        }
        .allowsHitTesting(false)
    }

    // MARK: inspector and legend

    @ViewBuilder func inspector(_ id: String) -> some View {
        if id.hasPrefix("group:") {
            let g = String(id.dropFirst(6)), members = store.nodes.filter { $0.group == g }
            VStack(alignment: .leading, spacing: 10) {
                HStack { Circle().fill(MapStore.color(g)).frame(width: 10, height: 10); Text(store.groups[g] ?? g).font(.headline); Spacer(); close }
                Text("\(members.filter(\.on).count) z \(members.count) zapnutých").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(members) { n in
                            Toggle(isOn: Binding(get: { n.on }, set: { store.set([n.id], on: $0) })) {
                                HStack(spacing: 8) { MapIcon(n: n, size: 18); Text(n.name).font(.callout) }
                            }
                            .toggleStyle(.switch).controlSize(.mini)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Button("Zapnúť všetko") { store.set(members.map(\.id), on: true) }
                    Button("Vypnúť všetko") { store.set(members.map(\.id), on: false) }
                }
                .controlSize(.small)
            }
            .padding(16).frame(width: 300)
            .brainCard()
        } else if let n = store.nodes.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) { MapIcon(n: n, size: 30); VStack(alignment: .leading, spacing: 2) {
                    Text(n.name).font(.headline)
                    Text(store.groups[n.group] ?? n.group).font(.caption).foregroundStyle(.secondary)
                }; Spacer(); close }
                Text(n.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Toggle(isOn: Binding(get: { n.on }, set: { store.set([n.id], on: $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n.on ? "Brain to používa" : "Vypnuté").font(.callout.weight(.medium))
                        Text(n.on ? "Vypni a Brain sa toho nedotkne." : "Brain jeho nástroje, hľadanie ani návrhy nepoužije.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                if n.usable == false { Label("Brain ho cez call nevie volať (vzdialený server).", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    if let p = n.path { Button("Vo Finderi") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }
                    if let a = n.app, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: a) { Button("Otvoriť appku") { NSWorkspace.shared.open(u) } }
                }
                .controlSize(.small)
            }
            .padding(16).frame(width: 300)
            .brainCard()
        }
    }

    var close: some View {
        Button { selected = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
    }

    var legend: some View {
        HStack(spacing: 14) {
            Label("\(store.nodes.filter(\.on).count) zapnutých", systemImage: "circle.fill").foregroundStyle(.green)
            Label("\(store.nodes.filter { !$0.on }.count) vypnutých", systemImage: "pause.circle.fill").foregroundStyle(.secondary)
            Text("Ťahaj uzly aj skupiny · dvoma prstami posúvaš, štipnutím približuješ · dvojklik ukáže všetko").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(.background.opacity(0.9)))
        .overlay(Capsule().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
    }
}
