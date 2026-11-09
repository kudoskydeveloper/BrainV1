import CourierCore
import SwiftUI

/// Strip under the subject of bulk mail: who sends it and an Unsubscribe button. Asks before doing anything.
struct UnsubscribeBar: View {
    @EnvironmentObject var model: AppModel
    let m: MessageSummary
    @State private var method: UnsubscribeMethod?
    @State private var asking = false
    @State private var working = false
    @State private var result: String?

    var body: some View {
        Group {
            if let method {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.badge.shield.half.filled").foregroundStyle(.secondary)
                    Text(result ?? "Hromadná pošta od \(m.fromAddress)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if working { ProgressView().controlSize(.small) } else if result == nil {
                        Button("Odhlásiť") { asking = true }.controlSize(.small)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                .confirmationDialog("Odhlásiť sa od \(m.fromDisplay)?", isPresented: $asking, titleVisibility: .visible) {
                    let n = model.store.messages(from: m.fromAddress).count
                    if n > 0 { Button("Odhlásiť a archivovať \(n) správ") { run(method, archive: true) } }
                    Button("Len odhlásiť") { run(method, archive: false) }
                    Button("Zrušiť", role: .cancel) {}
                } message: {
                    Text("Spôsob: \(method.summary). Ďalšie správy od tohto odosielateľa pôjdu do Newslettrov.")
                }
            }
        }
        .task(id: m.id) {
            method = nil; result = nil
            guard m.category != .people || model.store.unsubscribeHeader(id: m.id)?.isEmpty == false else { return }
            method = try? await model.sync.unsubscribeMethod(m)
        }
    }

    func run(_ method: UnsubscribeMethod, archive: Bool) {
        working = true
        Task {
            defer { working = false }
            if !method.automatic { NSWorkspace.shared.open(method.url) }
            do {
                let n = try await model.sync.unsubscribeAndClean(m, using: method, archive: archive)
                result = (method.automatic ? "Odhlásené" : "Dokonči odhlásenie v prehliadači") + (n > 0 ? " · archivovaných \(n) správ" : "")
                model.reload()
            } catch { result = "Nepodarilo sa: \(error.localizedDescription)" }
        }
    }
}
