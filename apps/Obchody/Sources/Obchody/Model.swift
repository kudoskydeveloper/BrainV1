import Foundation
import SwiftUI

/// `brain crm`: both business CRMs side by side (10T Base, Kuboard), in one shape.
struct Overview: Codable {
    var generatedAt: String
    var businesses: [Business]

    func business(_ id: String) -> Business? { businesses.first { $0.id == id } }
}

struct Business: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var ok: Bool
    var error: String?
    var stages: [Stage]
    var deals: [Deal]
    var accounts: [Account]
    var tasks: [CRMTask]
    var leads: [Lead]

    var tint: Color { id == "10t" ? .indigo : .orange }
    var symbol: String { id == "10t" ? "hammer.fill" : "heart.text.square.fill" }
    func stage(_ key: String?) -> Stage? { stages.first { $0.key == key } }
    func account(_ id: String?) -> Account? { accounts.first { $0.id == id } }
    var openStages: [Stage] { stages.filter { $0.kind == "open" } }
    var openDeals: [Deal] { deals.filter { stage($0.stage)?.kind == "open" } }
    /// Open pipeline value: one-off value plus a year of MRR.
    var pipelineValue: Double { openDeals.reduce(0) { $0 + ($1.value ?? 0) + ($1.mrr ?? 0) * 12 } }
}

struct Stage: Codable, Hashable, Identifiable {
    let key: String
    var label: String
    var kind: String          // open | won | lost
    var probability: Int?
    var id: String { key }
    var tint: Color { kind == "won" ? .green : kind == "lost" ? .red : .accentColor }
}

struct Deal: Codable, Hashable, Identifiable {
    let id: String
    var ref: String?
    var title: String
    var stage: String?
    var value: Double?
    var mrr: Double?
    var currency: String?
    var seats: Int?
    var probability: Int?
    var accountId: String?
    var account: String?
    var nextStep: String?
    var nextStepOn: String?
    var expectedCloseOn: String?
    var closedAt: String?
    var kinds: [String]?

    var amount: String {
        if let mrr, mrr > 0 { return "\(Fmt.money(mrr, currency ?? "EUR"))/mes." }
        return value.map { Fmt.money($0, currency ?? "EUR") } ?? ""
    }
    /// Open deal whose next step is missing or past due.
    var stale: Bool { nextStepOn == nil ? nextStep == nil : Fmt.overdue(nextStepOn) }
}

struct Account: Codable, Hashable, Identifiable {
    let id: String
    var ref: String?
    var name: String
    var lifecycle: String?
    var website: String?
    var domain: String?
    var updatedAt: String?
}

struct CRMTask: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var due: String?
    var accountId: String?
    var dealId: String?
}

struct Lead: Codable, Hashable, Identifiable {
    let id: String
    var ref: String?
    var name: String
    var website: String?
    var source: String?
    var status: String?
    var overdue: Bool
    var nextTask: NextTask?
    var contact: LeadContact?
    var createdAt: String?
    var lastTouchAt: String?

    struct NextTask: Codable, Hashable { var title: String?; var due: String? }
    struct LeadContact: Codable, Hashable { var name: String; var position: String?; var email: String?; var phone: String? }

    var statusLabel: String {
        switch status {
        case "new": "Nový"
        case "contacted": "Oslovený"
        case "engaged": "V kontakte"
        case "nurture": "Neskôr"
        case "disqualified": "Nekvalifikovaný"
        default: status ?? ""
        }
    }
}

/// `brain crm-account <business> <account>`: one client with what's around it.
struct AccountDetail: Codable {
    var business: String
    var id: String
    var ref: String?
    var name: String
    var legalName: String?
    var lifecycle: String?
    var website: String?
    var domain: String?
    var notes: String?
    var segment: String?
    var source: String?
    var industry: String?
    var employees: String?
    var contacts: [Contact]
    var companies: [Company]
    var deals: [Deal]
    var projects: [Project]
    var tasks: [CRMTask]
    var notes_: [Note]
    var mail: [Mail]
    var invoices: [Invoice]

    struct Contact: Codable, Hashable, Identifiable { let id: String; var name: String; var email: String?; var phone: String?; var position: String?; var role: String?; var primary: Bool }
    struct Company: Codable, Hashable, Identifiable { let id: String; var legalName: String?; var registrationNo: String?; var taxId: String?; var vatId: String?; var billingEmail: String?; var address: String?; var primary: Bool }
    struct Project: Codable, Hashable, Identifiable { let id: String; var code: String?; var name: String; var status: String?; var url: String? }
    struct Note: Codable, Hashable { var at: String?; var kind: String?; var body: String? }
    struct Mail: Codable, Hashable { var id: Int?; var threadId: String?; var date: String?; var subject: String?; var from: String?; var snippet: String?; var account: String?; var folder: String?; var unread: Bool? }
    struct Invoice: Codable, Hashable { var id: Int?; var number: String?; var status: String?; var total: Double?; var currency: String?; var issue_date: String?; var due_date: String?; var client: String?; var period: String?; var pdf: String? }
}

/// What the sidebar can show.
enum Folder: Hashable {
    case today
    case pipeline(String), accounts(String), tasks(String), leads(String)

    var business: String? {
        switch self {
        case .today: nil
        case .pipeline(let b), .accounts(let b), .tasks(let b), .leads(let b): b
        }
    }

    init?(_ s: String) {
        let p = s.split(separator: "/").map(String.init)
        switch (p.first, p.count > 1 ? p[1] : nil) {
        case ("today", _): self = .today
        case ("pipeline", let b?): self = .pipeline(b)
        case ("accounts", let b?): self = .accounts(b)
        case ("tasks", let b?): self = .tasks(b)
        case ("leads", let b?): self = .leads(b)
        default: return nil
        }
    }
}

extension String {
    static func lifecycleLabel(_ s: String?) -> String {
        switch s {
        case "lead": "Lead"
        case "prospect": "Prospekt"
        case "client", "customer": "Klient"
        case "trial": "Trial"
        case "demo": "Demo"
        case "dormant": "Spiaci"
        case "churned": "Odišiel"
        case "won_back": "Vrátený"
        default: s?.capitalized ?? ""
        }
    }
}
