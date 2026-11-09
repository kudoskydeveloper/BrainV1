import Contacts
import CourierCore
import Foundation

/// Address suggestions: Apple Contacts plus everyone from the mail history, people the user writes to ranked first.
@MainActor
final class ContactBook: ObservableObject {
    struct Entry: Hashable { var name: String; var address: String; var score: Int }
    private var entries: [Entry] = []

    func load(store: Store, myAddresses: Set<String>) {
        Task.detached(priority: .utility) {
            var map: [String: Entry] = [:]
            for k in store.knownAddresses(myAddresses: myAddresses) {
                map[k.address.lowercased()] = Entry(name: k.name, address: k.address, score: k.sentTo * 5 + min(k.received, 20))
            }
            for c in await Self.appleContacts() {
                let key = c.address.lowercased()
                guard !myAddresses.contains(key) else { continue }
                var e = map[key] ?? Entry(name: c.name, address: c.address, score: 0)
                if !c.name.isEmpty { e.name = c.name }   // the address book knows the name best
                e.score += 8
                map[key] = e
            }
            let list = Array(map.values)
            await MainActor.run { self.entries = list }
        }
    }

    nonisolated static func appleContacts() async -> [(name: String, address: String)] {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined { _ = try? await store.requestAccess(for: .contacts) }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        var out: [(String, String)] = []
        try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
            let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            for e in c.emailAddresses { out.append((name.isEmpty ? c.organizationName : name, e.value as String)) }
        }
        return out
    }

    /// Best matches for what is typed (by any word of the name or the start of the address).
    func suggest(_ q: String, excluding: Set<String> = [], limit: Int = 6) -> [Entry] {
        let q = q.trimmingCharacters(in: .whitespaces).lowercased().folding(options: .diacriticInsensitive, locale: nil)
        guard q.count >= 1 else { return [] }
        return entries.filter { e in
            guard !excluding.contains(e.address.lowercased()) else { return false }
            let name = e.name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            return e.address.lowercased().hasPrefix(q) || name.hasPrefix(q) || name.split(separator: " ").contains { $0.hasPrefix(q) }
                || e.address.lowercased().split(separator: "@").last?.hasPrefix(q) == true
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.address < $1.address }
        .prefix(limit).map { $0 }
    }
}
