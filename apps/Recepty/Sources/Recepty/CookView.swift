import AppKit
import ReceptyCore
import SwiftUI
import UserNotifications

/// Cook mode: one step at a time in large type, the ingredients to tick off, and the timers each step mentions.
/// ← → (or space) move between steps; the display stays awake while the window is open.
struct CookView: View {
    let recipe: Recipe
    @State private var step = 0
    @State private var servings: Double?
    @State private var done: Set<Int64> = []
    @StateObject private var timers = CookTimers()
    @State private var activity: NSObjectProtocol?
    @FocusState private var focused: Bool

    var factor: Double { (servings ?? recipe.servings) / max(recipe.servings, 0.01) }
    var steps: [String] { recipe.steps.isEmpty ? ["Recept nemá postup."] : recipe.steps }

    var body: some View {
        HStack(spacing: 0) {
            ingredients
                .frame(width: 320)
                .background(.background.secondary)
            Divider()
            VStack(spacing: 0) {
                progress
                stepView
                if !timers.items.isEmpty { runningTimers }
                controls
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle(recipe.title)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.rightArrow) { next(); return .handled }
        .onKeyPress(.space) { next(); return .handled }
        .onKeyPress(.leftArrow) { back(); return .handled }
        .onAppear {
            focused = true
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Varenie")
            CookTimers.center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        .onDisappear { if let a = activity { ProcessInfo.processInfo.endActivity(a) } }
    }

    func next() { withAnimation(.snappy) { step = min(step + 1, steps.count - 1) } }
    func back() { withAnimation(.snappy) { step = max(step - 1, 0) } }

    var ingredients: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Suroviny").font(.title3.weight(.semibold))
                Spacer()
                PortionStepper(value: Binding(get: { servings ?? recipe.servings }, set: { servings = $0 }), original: recipe.servings)
            }
            .padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recipe.sections, id: \.self) { sec in
                        if !sec.isEmpty { Text(sec).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 10).padding(.horizontal, 16) }
                        ForEach(recipe.ingredients.filter { $0.section == sec }) { ing in
                            let on = done.contains(ing.id)
                            Button {
                                if on { done.remove(ing.id) } else { done.insert(ing.id) }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? .green : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(ing.scaledLine(factor)).strikethrough(on).foregroundStyle(on ? .secondary : .primary)
                                        if let g = ing.scaledGrams(factor), ing.status != .skipped, ing.qty == nil || Analyzer.exactGrams(qty: ing.qty, unit: ing.unit) == nil {
                                            Text("≈ \(Fmt.grams(g))").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .font(.body)
                                .padding(.horizontal, 16).padding(.vertical, 6)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    var progress: some View {
        HStack(spacing: 4) {
            ForEach(steps.indices, id: \.self) { i in
                Capsule().fill(i <= step ? Color.orange : Color.secondary.opacity(0.25)).frame(height: 4)
                    .onTapGesture { withAnimation(.snappy) { step = i } }
            }
        }
        .padding(.horizontal, 32).padding(.top, 20)
    }

    var stepView: some View {
        let s = steps[step]
        return VStack(alignment: .leading, spacing: 24) {
            Text("Krok \(step + 1) z \(steps.count)").font(.title3.weight(.semibold)).foregroundStyle(.orange)
            Text(s)
                .font(.system(size: 30, weight: .regular, design: .rounded))
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .id(step)
                .transition(.opacity)
            let found = s.timers
            if !found.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(found.enumerated()), id: \.offset) { _, t in
                        Button { timers.start(t, step: step + 1, recipe: recipe.title) } label: {
                            Label("Časovač \(CookTimers.format(t.seconds))", systemImage: "timer")
                        }
                        .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var runningTimers: some View {
        HStack(spacing: 10) {
            ForEach(timers.items) { t in
                HStack(spacing: 8) {
                    Image(systemName: t.remaining == 0 ? "bell.fill" : "timer").foregroundStyle(t.remaining == 0 ? .red : .orange)
                        .symbolEffect(.bounce, options: .repeating, isActive: t.remaining == 0)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(CookTimers.format(t.remaining)).font(.title2.monospacedDigit().weight(.semibold))
                        Text("Krok \(t.step)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button { timers.stop(t.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .cardBackground()
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    var controls: some View {
        HStack {
            Button { back() } label: { Label("Späť", systemImage: "chevron.left").frame(minWidth: 110) }
                .disabled(step == 0)
            Spacer()
            if step == steps.count - 1 {
                Button { NSApp.keyWindow?.close() } label: { Label("Hotovo", systemImage: "checkmark").frame(minWidth: 110) }
                    .buttonStyle(.borderedProminent).tint(.green)
            } else {
                Button { next() } label: { Label("Ďalej", systemImage: "chevron.right").labelStyle(TrailingIcon()).frame(minWidth: 110) }
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
        }
        .controlSize(.extraLarge)
        .padding(24)
    }
}

struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 6) { configuration.title; configuration.icon } }
}

/// Countdown timers of a cooking session; a finished one rings and shows a notification.
@MainActor
final class CookTimers: ObservableObject {
    struct Item: Identifiable { let id = UUID(); var end: Date; var step: Int; var remaining: Int; var rung = false }
    @Published var items: [Item] = []
    /// Only inside the .app (the bare binary of a snapshot run has no bundle to notify from).
    nonisolated static var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : .current() }
    private var tick: Timer?

    func start(_ t: StepTimer, step: Int, recipe: String) {
        items.append(Item(end: Date().addingTimeInterval(Double(t.seconds)), step: step, remaining: t.seconds))
        let c = UNMutableNotificationContent()
        c.title = recipe
        c.body = "Krok \(step): uplynulo \(CookTimers.format(t.seconds))."
        c.sound = .default
        CookTimers.center?.add(UNNotificationRequest(identifier: items.last!.id.uuidString, content: c,
                                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(t.seconds), repeats: false)))
        if tick == nil {
            tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.update() } }
        }
    }

    func stop(_ id: UUID) {
        CookTimers.center?.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        items.removeAll { $0.id == id }
        if items.isEmpty { tick?.invalidate(); tick = nil }
    }

    func update() {
        for i in items.indices {
            items[i].remaining = max(0, Int(items[i].end.timeIntervalSinceNow.rounded(.up)))
            if items[i].remaining == 0, !items[i].rung { items[i].rung = true; NSSound(named: "Glass")?.play() }
        }
    }

    static func format(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    deinit { tick?.invalidate() }
}
