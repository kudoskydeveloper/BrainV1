import AppKit
import LocalAuthentication
import SwiftUI

/// Touch ID lock for the window (the MCP server isn't affected). Locked on start, when the Mac sleeps, the screen locks or
/// sleeps, and after five minutes in the background. Unlocks with Touch ID, or the Mac's password when Touch ID can't be used.
@MainActor
final class Lock: ObservableObject {
    static let shared = Lock()

    @Published private(set) var locked = true
    @Published private(set) var busy = false
    @Published var message: String?
    private var leftAt: Date?
    static let idle: TimeInterval = 5 * 60
    /// Locking by itself (start, sleep, idle). Demo data (FINANCIE_DEMO) opens unlocked and stays so unless locked by hand,
    /// so screenshots of the design need no finger.
    let automatic = ProcessInfo.processInfo.environment["FINANCIE_DEMO"] != "1"
    /// The lock screen asks for Touch ID as soon as it shows; not after locking by hand (you lock to hide, not to unlock).
    private(set) var promptOnShow = true

    init() {
        locked = automatic
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { _ in Task { @MainActor in Lock.shared.lock() } }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in Lock.shared.lock() }
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Lock.shared.leftAt = Date() }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let l = Lock.shared
                if let t = l.leftAt, Date().timeIntervalSince(t) > Lock.idle { l.lock() }
                l.leftAt = nil
                if l.locked && l.promptOnShow { l.unlock() }
            }
        }
    }

    /// Automatic locks (sleep, idle) only when `automatic`; a lock by hand (menu, toolbar, ⌃⌘L) always.
    func lock(byHand: Bool = false) {
        guard automatic || byHand else { return }
        promptOnShow = !byHand
        locked = true
        message = nil
    }

    func unlock() {
        guard locked, !busy else { return }
        busy = true
        message = nil
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Zadať heslo"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            busy = false
            message = err?.localizedDescription ?? "Tento Mac nevie overiť, že si to ty."
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "odomknúť Financie") { ok, e in
            Task { @MainActor in
                let l = Lock.shared
                l.busy = false
                if ok { l.locked = false } else if let e = e as? LAError, e.code != .userCancel, e.code != .appCancel, e.code != .systemCancel {
                    l.message = e.localizedDescription
                }
            }
        }
    }
}

/// What the window shows while locked: nothing of the money, just the way in.
struct LockView: View {
    @ObservedObject var lock: Lock

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "touchid")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.pink.gradient)
                .symbolEffect(.pulse, isActive: lock.busy)
            VStack(spacing: 6) {
                Text("Financie sú zamknuté").font(.title2.weight(.semibold))
                Text("Odomkni ich odtlačkom prsta alebo heslom k Macu.").foregroundStyle(.secondary)
            }
            Button { lock.unlock() } label: {
                Label("Odomknúť", systemImage: "lock.open.fill").frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(lock.busy)
            if let m = lock.message { Text(m).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear { if lock.promptOnShow { lock.unlock() } }
    }
}
