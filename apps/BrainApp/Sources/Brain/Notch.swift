import AppKit
import Combine
import SwiftUI

/// Notch mode (Settings → Notch): Brain lives under the MacBook's notch, like a Dynamic Island.
/// Collapsed it is the notch itself (black, invisible) and only grows "ears" when something goes on: Brain answering,
/// a proposal waiting, a timer due soon, queued messages. Hovering the notch opens a small menu out of it; Brain's own
/// notifications (answer ready, timer, reminder) pop it open for a few seconds.
///
/// Approach as in Boring Notch / NotchNook / DynamicNotchKit: a borderless, non-activating panel above the menu bar
/// (`.mainMenu + 3`), on every Space and over full-screen apps, the notch's size from the screen's auxiliary top areas, and a
/// shape whose top corners curve outwards into the menu bar. Hover comes from mouse-moved monitors (no focus taken, no
/// permissions), and the window lets clicks through while collapsed.
@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    /// A notification shown in the island for a few seconds: (title, text, chat to open).
    @Published var flash: (title: String, text: String, chat: UUID?)?
    @Published var notch = CGSize(width: 180, height: 32)
    var flashTask: Task<Void, Never>?
    /// An answer just finished: a checkmark (or a cross) beside the notch for a few seconds; a click opens that chat.
    @Published var done: (chat: UUID, failed: Bool)?
    var doneTask: Task<Void, Never>?

    func finished(_ chat: UUID, failed: Bool) {
        doneTask?.cancel()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { done = (chat, failed) }
        doneTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { done = nil }
        }
    }
    /// Opening grows with a slight overshoot, closing settles quickly without one.
    static let opening = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let closing = Animation.spring(response: 0.32, dampingFraction: 0.95)

    func show(_ title: String, _ text: String, chat: UUID? = nil) {
        flashTask?.cancel()
        withAnimation(Self.opening) { flash = (title, text, chat) }
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(Self.closing) { flash = nil }
        }
    }
}

/// The notch's outline: flat top across the menu bar, small concave corners where it meets the bar, rounded bottom.
struct NotchShape: Shape {
    var top: CGFloat = 6
    var bottom: CGFloat = 14
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var session: Session
    @ObservedObject var timers = TimerStore.shared
    /// Opens the ⌥Space panel (optionally with a question), the Brain window, a conversation.
    let ask: (String?) -> Void
    let openWindow: (BrainSection) -> Void
    let openChat: (UUID) -> Void
    static let size = CGSize(width: 620, height: 300)   // the window: room for the open island and its shadow

    var proposal: Proposal? {
        guard let m = session.messages.last(where: { !$0.mine }) else { return nil }
        return m.proposals.last { session.decided[$0.id] == nil }
    }
    var soonTimer: TimerStore.Job? { timers.jobs.first { $0.at.timeIntervalSinceNow < 600 } }
    var activity: Bool { session.running || proposal != nil || soonTimer != nil || !session.queue.isEmpty || model.done != nil }
    var open: Bool { model.expanded || model.flash != nil }

    var width: CGFloat { open ? Self.openWidth : model.notch.width + (activity ? 104 : 0) }

    /// Height of the open island's content, measured, so the shape itself can animate to it.
    @State var contentHeight: CGFloat = 90
    static let openWidth: CGFloat = 380

    var shape: NotchShape { NotchShape(top: open ? 10 : 6, bottom: open ? 24 : 12) }

    var body: some View {
        VStack(spacing: 0) {
            // One black shape whose width, height and corners spring together (no separate content scaling, so no gaps);
            // the content sits at its final size inside and is revealed by the shape's clip as it grows.
            shape
                .fill(.black)
                .frame(width: width, height: open ? max(contentHeight, model.notch.height) : model.notch.height)
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                        if open {
                            expandedContent
                                .frame(width: Self.openWidth, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { h in if abs(h - contentHeight) > 0.5 { contentHeight = h } }
                                .contentShape(Rectangle())
                                .onTapGesture { if let c = model.flash?.chat { openChat(c) } else { ask(nil) } }   // anywhere: open Brain
                                .contextMenu {   // what the menu bar icon's menu had (the icon is hidden in notch mode)
                                    Button("Opýtať sa Brainu") { ask(nil) }
                                    Button("Ranný prehľad") { ask("Ranný prehľad") }
                                    Button("Okno Brain") { openWindow(.chats) }
                                    Button("Nastavenia…") { openWindow(.settings) }
                                    Divider()
                                    Button("Ukončiť Brain") { AppDelegate.shared?.quitForReal() }
                                }
                                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.06)),
                                                        removal: .opacity.animation(.easeIn(duration: 0.08))))
                        } else if activity {
                            ears.transition(.opacity.animation(.easeInOut(duration: 0.15)))
                        }
                    }
                    .frame(width: width, alignment: .top)
                }
                .clipShape(shape)
                .shadow(color: .black.opacity(open ? 0.3 : 0), radius: 16, y: 6)
            Spacer(minLength: 0)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .environment(\.colorScheme, .dark)   // the island is black like the notch, in any appearance
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: activity)
    }

    // MARK: collapsed: content beside the notch

    var ears: some View {
        HStack(spacing: 0) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                .symbolEffect(.pulse, isActive: session.running)
                .frame(width: 52)
            Spacer(minLength: model.notch.width)
            Group {
                if proposal != nil { Circle().fill(Color.brainAccent).frame(width: 7, height: 7) }
                else if let t = soonTimer {
                    Text(t.at.formatted(date: .omitted, time: .shortened)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.orange)
                } else if !session.queue.isEmpty {
                    Text("\(session.queue.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                } else if session.running { NotchSpinner() }
                else if let d = model.done {
                    Image(systemName: d.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(d.failed ? .red : .green)
                        .symbolEffect(.bounce, value: d.chat)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 52)
        }
        .frame(height: model.notch.height)
    }

    // MARK: open: the menu

    /// Open: one line of what Brain is doing (or a notification), a waiting proposal with its buttons, the next timer.
    var expandedContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Color.clear.frame(height: model.notch.height - 10)   // under the camera
            if let f = model.flash {
                line(icon: brainIcon(14), title: f.title, text: f.text)
            } else {
                line(icon: brainIcon(14).symbolEffect(.pulse, isActive: session.running),
                     title: session.running ? (session.status ?? "Pracujem…").replacingOccurrences(of: "…", with: "") : session.chatTitle ?? "Opýtaj sa Brainu",
                     text: nil)
                if let p = proposal { proposalRow(p) }
                if let t = timers.jobs.first, proposal == nil, !session.running { timerRow(t) }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.bottom, 14)
    }

    func line(icon: some View, title: String, text: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                if let text { Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
    }

    func brainIcon(_ s: CGFloat) -> some View {
        Image(systemName: "brain.head.profile")
            .font(.system(size: s, weight: .medium))
            .foregroundStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
    }




    func proposalRow(_ p: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(p.summary.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Button { session.decide(p, true) } label: { NotchChip(text: "Potvrdiť", symbol: "checkmark", accent: true) }
                Button { session.decide(p, false) } label: { NotchChip(text: "Zrušiť") }
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .disabled(session.running)
        }
    }

    func timerRow(_ t: TimerStore.Job) -> some View {
        Button { openWindow(.timers) } label: {
            HStack(spacing: 7) {
                Image(systemName: t.remind == true ? "bell.fill" : "alarm.fill").font(.system(size: 9)).foregroundStyle(.orange)
                Text(t.at.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "sk_SK"))))
                    .font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                Text(t.prompt.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The panel's slim chip, for the black island.
struct NotchChip: View {
    let text: String
    var symbol: String? = nil
    var accent = false
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(accent ? 1 : 0.85))
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(accent ? Color.brainAccent : Color.white.opacity(0.14), in: Capsule())
        .contentShape(Capsule())
    }
}

/// Owns the notch window: placement on the notched screen, hover, click-through, and turning it on and off.
@MainActor
final class NotchController {
    let model = NotchModel()
    private var window: NSPanel?
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    private var bag: Set<AnyCancellable> = []
    let make: (NotchModel) -> NotchView
    /// A click on the checkmark of a finished answer (beside the notch): open that conversation.
    var openDone: ((UUID) -> Void)?

    init(make: @escaping (NotchModel) -> NotchView) {
        self.make = make
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.place() }.store(in: &bag)
        // clicks go through the window unless the island is open (a finished answer's click is caught by a monitor instead)
        model.$expanded.combineLatest(model.$flash.map { $0 != nil }).receive(on: RunLoop.main)
            .sink { [weak self] e, f in self?.window?.ignoresMouseEvents = !(e || f) }.store(in: &bag)
    }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "notchMode") }
    static var screen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } }
    static var available: Bool { screen != nil }
    var active: Bool { window != nil }

    func update() {
        if Self.enabled, Self.available { if window == nil { start() } } else if window != nil { stop() }
    }

    /// For `--notch-stress`: start on the notched screen whatever the setting says.
    func startForTest() { if window == nil, Self.available { start() } }

    private func start() {
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: NotchView.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isMovable = false
        let host = NSHostingView(rootView: make(model))
        // the window keeps the size we give it: letting SwiftUI resize it to the animating content made AppKit loop
        // in layout ("updateAnimatedWindowSize") and abort
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        w.contentView = host
        window = w
        place()
        w.orderFrontRegardless()
        let moved: (NSEvent) -> Void = { [weak self] _ in Task { @MainActor in self?.mouseMoved() } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: moved) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { e in moved(e); return e }) { monitors.append(l) }
        // the checkmark's click: the window lets clicks through while collapsed, so watch for one on the ears
        let down: (NSEvent) -> Void = { [weak self] _ in Task { @MainActor in self?.clicked() } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: down) { monitors.append(g) }
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        window?.orderOut(nil); window = nil
        model.expanded = false
    }

    private func place() {
        guard let w = window, let s = Self.screen else { stop(); return }
        let left = s.auxiliaryTopLeftArea?.width ?? (s.frame.width - 180) / 2, right = s.auxiliaryTopRightArea?.width ?? left
        model.notch = CGSize(width: s.frame.width - left - right, height: s.safeAreaInsets.top)
        let x = s.frame.minX + left + model.notch.width / 2 - NotchView.size.width / 2
        w.setFrame(NSRect(x: x, y: s.frame.maxY - NotchView.size.height, width: NotchView.size.width, height: NotchView.size.height), display: true)
    }

    /// Open when the pointer reaches the notch; close once it leaves the open island (with a little slack).
    private func mouseMoved() {
        guard let s = Self.screen else { return }
        let p = NSEvent.mouseLocation, mid = s.frame.minX + (s.auxiliaryTopLeftArea?.width ?? 0) + model.notch.width / 2
        let zone = model.expanded
            ? NSRect(x: mid - 210, y: s.frame.maxY - 170, width: 420, height: 170)
            : NSRect(x: mid - model.notch.width / 2 - 12, y: s.frame.maxY - model.notch.height - 4, width: model.notch.width + 24, height: model.notch.height + 4)
        let inside = zone.contains(p)
        guard inside != model.expanded else { hoverTask?.cancel(); return }
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(inside ? 120 : 350))
            guard !Task.isCancelled, let self else { return }
            withAnimation(inside ? NotchModel.opening : NotchModel.closing) { self.model.expanded = inside }
        }
    }

    private func clicked() {
        guard let d = model.done, let s = Self.screen, !model.expanded else { return }
        let mid = s.frame.minX + (s.auxiliaryTopLeftArea?.width ?? 0) + model.notch.width / 2
        let ears = NSRect(x: mid - model.notch.width / 2 - 56, y: s.frame.maxY - model.notch.height, width: model.notch.width + 112, height: model.notch.height)
        guard ears.contains(NSEvent.mouseLocation) else { return }
        collapse()
        openDone?(d.chat)
    }

    func collapse() { withAnimation(NotchModel.closing) { model.expanded = false; model.flash = nil; model.done = nil } }
}

/// A spinner drawn in SwiftUI. The system ProgressView is an AppKit control with its own constraints; inside the animating
/// island it sent AppKit into an endless constraint-update loop and crashed Brain.
struct NotchSpinner: View {
    var size: CGFloat = 12
    var color: Color = .white.opacity(0.85)
    var body: some View {
        TimelineView(.animation) { t in
            Circle()
                .trim(from: 0.1, to: 0.8)
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
        }
    }
}
