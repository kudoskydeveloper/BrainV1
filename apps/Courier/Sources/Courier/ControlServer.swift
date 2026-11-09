import AppKit
import CourierCore
import Foundation

/// Local control socket (~/Library/Application Support/Courier/courier.sock, owner-only) for courier-mcp:
/// one JSON request per line, one JSON reply per line. Used for whatever needs the network or the Keychain.
final class ControlServer: @unchecked Sendable {
    static let shared = ControlServer()
    private var started = false
    private weak var model: AppModel?

    @MainActor func start(model: AppModel) {
        guard !started else { return }
        started = true
        self.model = model
        let path = Store.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(fd, 8) == 0 else { close(fd); return }
        chmod(path, 0o600)
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                Thread.detachNewThread { self?.serve(c) }
            }
        }
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A) {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        let request = (try? JSONSerialization.jsonObject(with: data.prefix { $0 != 0x0A })) as? [String: Any] ?? [:]
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reply: [String: Any] = ["ok": false, "error": "neznámy príkaz"]
        let req = SendableBox(request)
        Task { @MainActor in
            reply = await self.handle(req.value)
            sem.signal()
        }
        sem.wait()
        var out = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{\"ok\":false}".utf8)
        out.append(0x0A)
        out.withUnsafeBytes { _ = write(c, $0.baseAddress, out.count) }
    }

    @MainActor private func handle(_ r: [String: Any]) async -> [String: Any] {
        guard let model else { return ["ok": false, "error": "appka nie je pripravená"] }
        switch r["cmd"] as? String {
        case "ping":
            return ["ok": true]
        case "reload":
            model.reload()
            return ["ok": true]
        case "sync":
            if let acc = (r["account"] as? String).flatMap(model.account) {
                if let folder = r["folder"] as? String {
                    do { try await model.sync.syncMessages(acc, folder: folder) } catch { return ["ok": false, "error": error.localizedDescription] }
                } else { await model.refresh(account: acc) }
            } else { await model.refreshAll() }
            model.reload()
            return ["ok": true, "errors": model.accountErrors]
        case "fetch_body":
            guard let id = (r["id"] as? NSNumber)?.int64Value, let m = model.store.message(id: id) else { return ["ok": false, "error": "správa neexistuje"] }
            do { _ = try await model.sync.fetchBody(m); model.loadMessages(); return ["ok": true] } catch { return ["ok": false, "error": error.localizedDescription] }
        case "draft", "send", "schedule":
            guard let data = try? JSONSerialization.data(withJSONObject: r["message"] ?? [:]),
                  var m = try? JSONDecoder().decode(OutgoingMessage.self, from: data) else { return ["ok": false, "error": "neplatná správa"] }
            // Signature: the one asked for by name, "none", or the account's default.
            let sigName = r["signature"] as? String
            let sig: Signature? = sigName == "none" ? nil
                : (sigName.flatMap { n in model.signatures.first { $0.name.lowercased() == n.lowercased() } }
                   ?? model.defaultSignatureID(account: m.accountID).flatMap { id in model.signatures.first { $0.id == id } })
            m.compose(text: m.body, signature: sig, quoted: r["quoted"] as? String ?? "")
            // Sending a draft: the message keeps the draft's Message-ID, so sending removes it from Drafts.
            // The draft is the one named by draft_id, or else the only draft with the same subject and recipients.
            var fromDraft: MessageSummary?
            if r["cmd"] as? String != "draft" {
                if let did = (r["draft_id"] as? NSNumber)?.int64Value {
                    guard let dm = model.store.message(id: did), model.isDraft(dm), dm.accountID == m.accountID else {
                        return ["ok": false, "error": "draft_id nie je koncept tohto účtu"]
                    }
                    fromDraft = dm
                } else {
                    fromDraft = model.store.matchingDraft(account: m.accountID, subject: m.subject, to: m.to)
                }
                if let dm = fromDraft {
                    let mid = model.store.threadHeaders(id: dm.id).messageID
                    if mid.isEmpty { fromDraft = nil } else { m.messageID = mid }
                }
            }
            if r["cmd"] as? String == "schedule" {   // into the outbox: "Na odoslanie" shows it, Courier sends it at its time
                guard let t = (r["send_at"] as? NSNumber)?.doubleValue else { return ["ok": false, "error": "chýba send_at"] }
                do {
                    let item = try model.store.enqueue(m, at: Date(timeIntervalSince1970: t))
                    model.outbox = model.store.outbox()
                    var out: [String: Any] = ["ok": true, "id": item.id]
                    if let dm = fromDraft { out["draft_id"] = dm.id }
                    return out
                } catch { return ["ok": false, "error": error.localizedDescription] }
            }
            do {
                if r["cmd"] as? String == "send" { try await model.sync.send(m) } else { try await model.sync.saveDraft(m) }
                model.reload()
                var out: [String: Any] = ["ok": true]
                if let dm = fromDraft { out["draft_removed"] = dm.id }
                // a new draft: its id, so it can be sent later with draft_id
                if r["cmd"] as? String == "draft", let saved = model.store.message(messageID: m.messageID, account: m.accountID) { out["id"] = saved.id }
                return out
            } catch { return ["ok": false, "error": error.localizedDescription] }
        case "move", "seen":
            // ids → messages; whole_thread widens to the conversation (without Sent and Drafts copies).
            let ids = (r["ids"] as? [NSNumber] ?? []).map(\.int64Value)
            var list = ids.compactMap(model.store.message)
            guard !list.isEmpty else { return ["ok": false, "error": "správy neexistujú"] }
            if (r["whole_thread"] as? Bool) ?? true {
                var seen = Set<Int64>()
                list = list.flatMap { m -> [MessageSummary] in
                    let skip = Set(model.store.folders(account: m.accountID).filter { [.sent, .drafts].contains($0.role) }.map(\.path))
                    let t = model.store.thread(account: m.accountID, id: m.threadID).filter { !skip.contains($0.folder) || $0.id == m.id }
                    return t.isEmpty ? [m] : t
                }.filter { seen.insert($0.id).inserted }
            }
            do {
                if r["cmd"] as? String == "seen" {
                    try await model.sync.setSeen(list, (r["seen"] as? Bool) ?? true)
                } else {
                    let target = r["target"] as? String ?? "trash"
                    for (acc, msgs) in Dictionary(grouping: list, by: \.accountID) {
                        let folders = model.store.folders(account: acc)
                        let path: String?
                        switch target {
                        case "trash": path = folders.first { $0.role == .trash }?.path
                        case "archive": path = (folders.first { $0.role == .archive } ?? folders.first { $0.role == .all })?.path
                        case "permanent": path = nil
                        case "junk", "spam": path = folders.first { $0.role == .junk }?.path
                        case "inbox": path = folders.first { $0.role == .inbox }?.path
                        default: path = folders.first { $0.path == target || ModifiedUTF7.decode($0.path).lowercased() == target.lowercased()
                                                        || $0.displayName.lowercased() == target.lowercased() }?.path
                        }
                        if target != "permanent" && path == nil { return ["ok": false, "error": "priečinok \(target) neexistuje"] }
                        try await model.sync.move(msgs, to: path)
                    }
                }
                model.reload()
                return ["ok": true, "count": list.count]
            } catch { return ["ok": false, "error": error.localizedDescription] }
        case "unsubscribe":
            // preview: how it would be done (may fetch the header once); run: unsubscribe, file the sender under Newsletters,
            // and archive what they sent to the inbox (archive: true).
            guard let id = (r["id"] as? NSNumber)?.int64Value, let m = model.store.message(id: id) else { return ["ok": false, "error": "správa neexistuje"] }
            let archive = (r["archive"] as? Bool) ?? true
            let inbox = model.store.messages(from: m.fromAddress)
            do {
                guard let method = try await model.sync.unsubscribeMethod(m) else {
                    return ["ok": false, "sender": m.fromAddress, "error": "správa nemá odkaz na odhlásenie (List-Unsubscribe)"]
                }
                var out: [String: Any] = ["sender": m.fromDisplay, "address": m.fromAddress, "method": method.kind.rawValue,
                                          "how": method.summary, "url": method.url.absoluteString, "automatic": method.automatic,
                                          "inbox_messages": inbox.count, "archive": archive]
                guard r["run"] as? Bool == true else { out["ok"] = true; return out }
                if !method.automatic { NSWorkspace.shared.open(method.url) }
                let archived = try await model.sync.unsubscribeAndClean(m, using: method, archive: archive)
                model.reload()
                out["ok"] = true
                out["unsubscribed"] = method.automatic
                out["archived"] = archived
                if !method.automatic { out["note"] = "Odhlasovacia stránka sa otvorila v prehliadači, treba ju dokončiť tam." }
                return out
            } catch { return ["ok": false, "sender": m.fromAddress, "error": error.localizedDescription] }
        case "save_attachment":
            guard let id = (r["id"] as? NSNumber)?.int64Value, let m = model.store.message(id: id) else { return ["ok": false, "error": "správa neexistuje"] }
            let dir = (r["dir"] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? model.downloads
            do {
                let url = try await model.sync.saveAttachment(m, index: (r["index"] as? NSNumber)?.intValue ?? 0, filename: r["filename"] as? String, to: dir)
                return ["ok": true, "path": url.path]
            } catch { return ["ok": false, "error": error.localizedDescription] }
        case "outbox":
            // a scheduled message: cancel (back to Drafts, nothing is lost), reschedule (send_at) or send_now
            guard let id = r["id"] as? String, let item = model.store.outbox().first(where: { $0.id == id }) else {
                return ["ok": false, "error": "správa už nie je v Na odoslanie (odišla alebo bola zrušená)"]
            }
            switch r["action"] as? String {
            case "cancel":
                do { try await model.sync.saveDraft(item.message) } catch { return ["ok": false, "error": "Nepodarilo sa vrátiť do Konceptov: \(error.localizedDescription)"] }
                model.store.dequeue(id)
            case "reschedule":
                guard let t = (r["send_at"] as? NSNumber)?.doubleValue else { return ["ok": false, "error": "chýba send_at"] }
                model.store.reschedule(id, at: Date(timeIntervalSince1970: t))
            case "send_now":
                model.store.reschedule(id, at: Date())
            default:
                return ["ok": false, "error": "action: cancel, reschedule alebo send_now"]
            }
            model.outbox = model.store.outbox()
            model.reload()
            return ["ok": true]
        case "show":
            if let id = (r["id"] as? NSNumber)?.int64Value, let m = model.store.message(id: id) {
                model.selection = .folder(account: m.accountID, path: m.folder)
                model.selectedMessageID = id
            }
            NSApp.activate()
            return ["ok": true]
        default:
            return ["ok": false, "error": "neznámy príkaz"]
        }
    }
}

struct SendableBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
