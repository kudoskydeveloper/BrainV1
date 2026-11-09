import AppKit
import FakturyCore
import SwiftUI

/// What the sidebar shows.
enum Folder: Hashable {
    case drafts, unpaid, overdue, paid, all
    case company(Int64)
    case clients
    case templates
    case overview
}

/// What the middle column has selected.
enum Pick: Hashable {
    case invoice(Int64)
    case client(Int64)
    case company(Int64)
    case template(Int64)
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store: Store
    @Published var companies: [Company] = []
    @Published var clients: [Client] = []
    @Published var invoices: [Invoice] = []
    @Published var templates: [InvoiceTemplate] = []
    /// The document being saved as a template (name sheet open).
    @Published var templateSource: Invoice?
    @Published var folder: Folder? = .all
    @Published var selection: Pick?
    @Published var error: String?
    @Published var editingCompany: Company?
    @Published var editingClient: Client?
    @Published var showExport = false
    @Published var showImport = false
    @Published var lastBackup: String?
    var openMain: (() -> Void)?
    private var timer: Timer?

    init(store: Store? = nil) {
        do { self.store = try store ?? Store() } catch { fatalError("Faktúry: databáza sa nedá otvoriť: \(error)") }
        reload()
        DistributedNotificationCenter.default().addObserver(forName: Store.changed, object: nil, queue: .main) { n in
            guard (n.object as? String) != "\(getpid())" else { return }
            Task { @MainActor in AppModel.shared.reload() }
        }
    }

    func reload() {
        companies = store.companies()
        clients = store.clients()
        invoices = store.invoices()
        templates = store.templates()
        lastBackup = Backup.lastBackup(store)
        if case .company(let id) = folder, !companies.contains(where: { $0.id == id }) { folder = .all }
    }

    func company(_ id: Int64) -> Company? { companies.first { $0.id == id } }

    func list(_ f: Folder) -> [Invoice] {
        switch f {
        case .drafts: invoices.filter(\.isDraft)
        case .unpaid: invoices.filter { $0.balanceCents > 0 }
        case .overdue: invoices.filter(\.isOverdue)
        case .paid: invoices.filter(\.isPaid)
        case .all: invoices
        case .company(let id): invoices.filter { $0.companyId == id }
        case .clients, .overview, .templates: []
        }
    }

    // MARK: Actions

    func run(_ body: () throws -> Void) {
        do { try body() } catch { self.error = error.localizedDescription }
        reload()
    }

    /// A new draft for the subject in view (or the only one); asks to create a subject first if there is none.
    func newInvoice(kind: InvoiceKind, companyId: Int64? = nil, client: Client? = nil) {
        guard !companies.isEmpty else { editCompany(Company()); return }
        var target = companyId
        if target == nil, case .company(let id) = folder { target = id }
        if target == nil { target = invoices.first?.companyId ?? companies.first?.id }
        guard let cid = target else { return }
        run {
            let d = try store.newDraft(companyId: cid, kind: kind, client: client)
            reload()
            if folder != .company(cid) && folder != .drafts && folder != .all { folder = .company(cid) }
            selection = .invoice(d.id)
        }
        Delegate.showWindow()
    }

    func editCompany(_ c: Company) { editingCompany = c }

    func newInvoice(fromTemplate id: Int64) {
        run {
            let d = try store.draft(fromTemplate: id)
            reload()
            folder = .drafts
            selection = .invoice(d.id)
        }
        Delegate.showWindow()
    }
    func editClient(_ c: Client) { editingClient = c }

    func startBackups() {
        Backup.runIfDue(store)
        lastBackup = Backup.lastBackup(store)
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in
            Task { @MainActor in let m = AppModel.shared; Backup.runIfDue(m.store); m.lastBackup = Backup.lastBackup(m.store) }
        }
    }

    func backupNow() {
        run { let f = try Backup.run(store, reason: "manual"); NSWorkspace.shared.activateFileViewerSelecting([f]) }
    }

    /// Hands the issued invoice to Courier as a draft (off the main thread: Courier may need to start).
    @Published var sending: Set<Int64> = []
    func sendViaCourier(_ i: Invoice, to: String? = nil) {
        guard let c = company(i.companyId) else { return }
        sending.insert(i.id)
        Task.detached {
            let result: String?
            do { try CourierBridge.draft(i, company: c, to: to); result = nil } catch { result = error.localizedDescription }
            await MainActor.run {
                let m = AppModel.shared
                m.sending.remove(i.id)
                if let result { m.error = result } else {
                    m.toast = "E-mail s faktúrou je v Courieri v Konceptoch."
                    NSWorkspace.shared.open(URL(string: "courier://inbox")!)
                }
            }
        }
    }
    @Published var toast: String?
}
