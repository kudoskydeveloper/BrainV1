import AppKit
import FinancieCore
import SwiftUI

/// What the sidebar shows.
enum Page: Hashable {
    case overview, transactions, waiting, recurring
    case wallet(Int64)
    case account(Int64)
}

/// A sheet the window shows.
enum Sheet: Identifiable {
    case transaction(Tx, Flow)
    case account(Account)
    case wallet(Wallet)
    case recurring(Recurring)
    case reconcile(Account)
    case confirm(Expected)
    var id: String {
        switch self {
        case .transaction(let t, let f): "t\(t.id)\(f.rawValue)"
        case .account(let a): "a\(a.id)"
        case .wallet(let w): "w\(w.id)"
        case .recurring(let r): "r\(r.id)"
        case .reconcile(let a): "c\(a.id)"
        case .confirm(let e): "e\(e.id)"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store: Store
    @Published var wallets: [Wallet] = []
    @Published var accounts: [Account] = []
    @Published var categories: [TxCategory] = []
    @Published var recurring: [Recurring] = []
    @Published var expected: [Expected] = []
    @Published var balances: [Int64: Int] = [:]
    /// Bumped on every reload so pages that compute from the store refresh.
    @Published var version = 0
    @Published var page: Page? = .overview
    @Published var sheet: Sheet?
    @Published var error: String?
    @Published var lastBackup: String?
    var openMain: (() -> Void)?

    init() {
        do { store = try Store() } catch { fatalError("Financie: databáza sa nedá otvoriť: \(error)") }
        if ProcessInfo.processInfo.environment["FINANCIE_DEMO"] == "1" { Demo.fill(store) }
        _ = try? FakturyLink.sync(store)
        reload()
        DistributedNotificationCenter.default().addObserver(forName: Store.changed, object: nil, queue: .main) { n in
            guard (n.object as? String) != "\(getpid())" else { return }
            Task { @MainActor in AppModel.shared.reload() }
        }
    }

    func reload() {
        wallets = store.wallets()
        accounts = store.accounts()
        categories = store.categories(includeArchived: true)
        recurring = store.recurringItems()
        expected = store.expected(to: Day.adding(days: 45, to: Day.today))
        balances = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, store.balance($0.id)) })
        lastBackup = Backup.last(store)
        version += 1
        if case .account(let id) = page, !accounts.contains(where: { $0.id == id }) { page = .overview }
        if case .wallet(let id) = page, !wallets.contains(where: { $0.id == id }) { page = .overview }
    }

    /// Runs a write, shows its error, reloads.
    func act(_ body: () throws -> Void) {
        do { try body(); error = nil } catch { self.error = error.localizedDescription }
        reload()
    }

    // MARK: Lookups

    func account(_ id: Int64?) -> Account? { id.flatMap { i in accounts.first { $0.id == i } } ?? id.flatMap(store.account) }
    func wallet(_ id: Int64?) -> Wallet? { id.flatMap { i in wallets.first { $0.id == i } } }
    func category(_ id: Int64?) -> TxCategory? { id.flatMap { i in categories.first { $0.id == i } } }
    func accounts(in w: Wallet) -> [Account] { accounts.filter { $0.walletId == w.id } }
    func balance(_ w: Wallet) -> Int { accounts(in: w).reduce(0) { $0 + (balances[$1.id] ?? 0) } }
    func total(_ kind: WalletKind? = nil) -> Int { wallets.filter { kind == nil || $0.kind == kind }.reduce(0) { $0 + balance($1) } }
    func accountLabel(_ id: Int64) -> String {
        guard let a = account(id) else { return "?" }
        return wallets.count > 1 ? "\(wallet(a.walletId)?.name ?? "") · \(a.name)" : a.name
    }
    var lateCount: Int { expected.filter(\.isLate).count }
    var defaultAccount: Account? {
        if case .account(let id) = page, let a = account(id) { return a }
        if case .wallet(let id) = page, let a = accounts.first(where: { $0.walletId == id }) { return a }
        return accounts.first { wallet($0.walletId)?.kind == .personal } ?? accounts.first
    }

    // MARK: Actions

    func newTransaction(_ flow: Flow) {
        guard let a = defaultAccount else { sheet = .account(Account(walletId: wallets.first?.id ?? 0)); return }
        sheet = .transaction(Tx(accountId: a.id, kind: flow == .income ? .income : .expense), flow)
    }

    func edit(_ t: Tx) {
        sheet = .transaction(t, t.kind == .transfer ? .transfer : t.kind == .income ? .income : .expense)
    }

    func newRecurring(_ flow: Flow = .expense) {
        guard let a = defaultAccount else { return }
        sheet = .recurring(Recurring(flow: flow, accountId: a.id, day: Calendar.current.component(.day, from: Date())))
    }

    func newAccount() {
        var w = wallets.first?.id ?? 0
        if case .wallet(let id) = page { w = id }
        if case .account(let id) = page, let a = account(id) { w = a.walletId }
        sheet = .account(Account(walletId: w))
    }

    func backupNow() {
        act { _ = try Backup.run(store) }
    }
}
