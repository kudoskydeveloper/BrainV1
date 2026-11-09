import FinancieCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var lock: Lock
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            NavigationSplitView {
                Sidebar(model: model)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            } detail: {
                detail
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { lock.lock(byHand: true) } label: { Label("Zamknúť", systemImage: "lock.fill") }
                        .help("Zamknúť Financie (⌃⌘L)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { model.newTransaction(.expense) } label: { Label("Výdavok", systemImage: "arrow.up.circle") }
                        Button { model.newTransaction(.income) } label: { Label("Príjem", systemImage: "arrow.down.circle") }
                        Button { model.newTransaction(.transfer) } label: { Label("Prevod medzi účtami", systemImage: "arrow.left.arrow.right.circle") }
                        Divider()
                        Button { model.newRecurring() } label: { Label("Pravidelná položka", systemImage: "repeat.circle") }
                        Button { model.newAccount() } label: { Label("Účet", systemImage: "building.columns") }
                    } label: { Label("Pridať", systemImage: "plus") } primaryAction: { model.newTransaction(.expense) }
                    .help("Nový výdavok (⌘N), ďalšie v menu")
                }
            }
            .sheet(item: Binding(get: { lock.locked ? nil : model.sheet }, set: { model.sheet = $0 })) { s in SheetView(sheet: s, model: model) }
            .alert("Nepodarilo sa", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
            .opacity(lock.locked ? 0 : 1)
            .toolbar(lock.locked ? .hidden : .visible, for: .windowToolbar)
            if lock.locked { LockView(lock: lock).transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.2), value: lock.locked)
        .frame(minWidth: 980, minHeight: 620)
        .onAppear { model.openMain = { [openWindow] in openWindow(id: "main") } }
    }

    @ViewBuilder var detail: some View {
        switch model.page ?? .overview {
        case .overview: OverviewPage(model: model, scope: .all)
        case .transactions: TransactionsPage(model: model, scope: .all, title: "Pohyby")
        case .waiting: WaitingPage(model: model)
        case .recurring: RecurringPage(model: model)
        case .wallet(let id):
            if let w = model.wallet(id) { OverviewPage(model: model, scope: Scope(walletId: id), title: w.name) }
        case .account(let id):
            if let a = model.account(id) { TransactionsPage(model: model, scope: Scope(accountId: id), title: a.name, account: a) }
        }
    }
}

struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: $model.page) {
            Section {
                Label { Text("Prehľad") } icon: { Image(systemName: "square.grid.2x2.fill").foregroundStyle(.pink) }.tag(Page.overview)
                Label { Text("Pohyby") } icon: { Image(systemName: "list.bullet.circle.fill").foregroundStyle(.blue) }.tag(Page.transactions)
                Label { Text("Čaká") } icon: { Image(systemName: "clock.fill").foregroundStyle(.orange) }
                    .badge(model.lateCount)
                    .tag(Page.waiting)
                Label { Text("Pravidelné") } icon: { Image(systemName: "repeat.circle.fill").foregroundStyle(.purple) }.tag(Page.recurring)
            }
            ForEach(model.wallets) { w in
                Section {
                    ForEach(model.accounts(in: w)) { a in
                        AccountRow(account: a, balance: model.balances[a.id] ?? 0)
                            .tag(Page.account(a.id))
                            .contextMenu {
                                Button("Upraviť účet…") { model.sheet = .account(a) }
                                Button("Zosúladiť so zostatkom v banke…") { model.sheet = .reconcile(a) }
                            }
                    }
                } header: {
                    WalletHeader(wallet: w, total: model.balance(w)) { model.page = .wallet(w.id) }
                        .contextMenu {
                            Button("Premenovať peňaženku…") { model.sheet = .wallet(w) }
                            Button("Nový účet…") { model.sheet = .account(Account(walletId: w.id)) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.newAccount() } label: { Label("Nový účet", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                Spacer()
                Menu {
                    Button("Nová osobná peňaženka…") { model.sheet = .wallet(Wallet(kind: .personal)) }
                    Button("Nová firma…") { model.sheet = .wallet(Wallet(kind: .business)) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Peňaženky")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

struct WalletHeader: View {
    let wallet: Wallet
    let total: Int
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Text(wallet.name).lineLimit(1)
                Spacer(minLength: 4)
                Text(Money.short(total)).monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .help("Prehľad peňaženky \(wallet.name)")
    }
}

struct AccountRow: View {
    let account: Account
    let balance: Int
    var body: some View {
        HStack(spacing: 8) {
            Label { Text(account.name).lineLimit(1) } icon: { Image(systemName: account.type.symbol).foregroundStyle(account.type.color) }
            Spacer(minLength: 6)
            Text(Money.string(balance)).font(.callout.monospacedDigit()).foregroundStyle(balance < 0 ? .red : .secondary)
        }
    }
}
