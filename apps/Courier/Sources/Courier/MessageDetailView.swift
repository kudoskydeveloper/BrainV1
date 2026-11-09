import CourierCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The open conversation, Apple Mail style: subject on top, then each message separated by a hairline;
/// older messages are one line until clicked.
struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    /// Settings → Priečinky → Najnovšie hore: the thread reads newest first instead of like a chat.
    @AppStorage("thread.newestFirst") private var newestFirst = false

    var body: some View {
        if model.selectedIDs.count > 1 {
            BulkPanel()
        } else if let head = model.selectedMessage, let last = model.conversation.last {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(head).id("top")
                        ForEach(newestFirst ? Array(model.conversation.reversed()) : model.conversation) { m in
                            Divider().padding(.leading, 24)
                            MessageItem(m: m, expanded: model.expanded.contains(m.id)).id(m.id)
                        }
                    }
                    .padding(.bottom, 24)
                }
                // Chat order jumps to the newest message at the bottom; newest-first simply starts at the top.
                .onAppear { if !newestFirst, model.conversation.count > 2 { proxy.scrollTo(last.id, anchor: .top) } }
                .onChange(of: head.id) {
                    if newestFirst { proxy.scrollTo("top", anchor: .top) }
                    else if model.conversation.count > 2 { proxy.scrollTo(model.conversation.last?.id, anchor: .top) }
                }
                .onChange(of: newestFirst) { proxy.scrollTo(newestFirst || model.conversation.count <= 2 ? "top" : model.conversation.last?.id as AnyHashable?, anchor: .top) }
            }
            .background(.background)
            .navigationTitle("")
            .toolbar {
                ToolbarItemGroup {
                    if let draftMsg = model.conversation.last(where: { model.isDraft($0) }) {
                        Button { model.openDraft(draftMsg) { openWindow(id: "compose", value: $0) } } label: {
                            Label("Upraviť koncept", systemImage: "pencil").labelStyle(.titleAndIcon)
                        }
                        .help("Otvoriť koncept v editore")
                    }
                    Button { model.archive(head) } label: { Label("Archivovať", systemImage: "archivebox") }
                        .help("Archivovať")
                    if model.isJunk(head) {
                        Button { model.markSpam(head, false) } label: { Label("Nie je spam", systemImage: "checkmark.shield") }
                            .help("Nie je spam – vrátiť do Doručenej pošty (⇧⌘J)")
                    } else {
                        Button { model.markSpam(head, true) } label: { Label("Spam", systemImage: "xmark.bin") }
                            .help("Spam – presunúť do priečinka Spam (⇧⌘J)")
                    }
                    Button { model.delete(head) } label: { Label("Vymazať", systemImage: "trash") }
                        .help(model.viewingTrash ? "Vymazať natrvalo (⌫)" : "Presunúť do koša (⌫)")
                }
                ToolbarItemGroup {
                    Button { openWindow(id: "compose", value: model.replyDraft(last, .reply)) } label: { Label("Odpovedať", systemImage: "arrowshape.turn.up.left") }
                        .help("Odpovedať (⌘R)")
                    Button { openWindow(id: "compose", value: model.replyDraft(last, .replyAll)) } label: { Label("Odpovedať všetkým", systemImage: "arrowshape.turn.up.left.2") }
                        .help("Odpovedať všetkým (⇧⌘R)")
                    Button { openWindow(id: "compose", value: model.replyDraft(last, .forward)) } label: { Label("Preposlať", systemImage: "arrowshape.turn.up.right") }
                        .help("Preposlať (⇧⌘F)")
                }
            }
        } else {
            ContentUnavailableView("Žiadna správa", systemImage: "envelope", description: Text("Vyber konverzáciu v zozname."))
        }
    }

    func header(_ m: MessageSummary) -> some View {
        let t = model.ticket(m)
        return VStack(alignment: .leading, spacing: 8) {
            Text(m.subject.isEmpty ? "(bez predmetu)" : m.subject)
                .font(.title2.weight(.bold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let s = t?.status { StatusPill(status: s) }
                ForEach(t?.tags ?? [], id: \.self) { name in
                    TagChip(name: name, color: model.tag(name)?.color ?? "gray")
                        .onTapGesture { model.toggleTag(name, for: m) }
                        .help("Kliknutím odstrániš štítok")
                }
                Menu { TicketMenu(m: m) } label: {
                    Image(systemName: t == nil ? "tag" : "plus").font(.caption)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Stav a štítky")
                Spacer()
                if model.conversation.count > 1 {
                    Text("\(model.conversation.count) správy").font(.caption).foregroundStyle(.tertiary)
                }
            }
            UnsubscribeBar(m: model.conversation.last { $0.fromAddress.lowercased() != model.account($0.accountID)?.email.lowercased() } ?? m)
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
    }
}

struct MessageItem: View {
    @EnvironmentObject var model: AppModel
    let m: MessageSummary
    let expanded: Bool
    @State private var showRemote = false
    @State private var htmlHeight: CGFloat = 60

    var isMine: Bool { model.account(m.accountID)?.email.lowercased() == m.fromAddress.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: expanded ? .top : .center, spacing: 12) {
                Avatar(name: m.fromName, address: m.fromAddress, size: expanded ? 36 : 28)
                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(isMine ? "Ja" : m.fromDisplay).font(.headline)
                            if !m.fromAddress.isEmpty { CopyableAddress(address: m.fromAddress) }
                            Spacer()
                            Text(m.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(recipientLinks).font(.caption).foregroundStyle(.secondary).tint(.secondary).lineLimit(2)
                            .environment(\.openURL, AddressLinks.handler(model))
                            .help("Kliknutím na meno skopíruješ e-mail")
                    }
                } else {
                    Text(isMine ? "Ja" : m.fromDisplay).font(.subheadline.weight(.semibold)).lineLimit(1).layoutPriority(1)
                    Text(m.snippet.isEmpty ? m.subject : m.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if m.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(.tertiary) }
                    Text(m.date.listLabel).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { model.toggleExpanded(m) } }
            .contextMenu { ReplyMenu(m: m) }

            if expanded {
                content
                    .padding(.leading, 48)
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, expanded ? 16 : 10)
    }

    var recipientLinks: AttributedString {
        AddressLinks.line([("Komu", MIME.parseAddresses(m.to)), ("Kópia", MIME.parseAddresses(model.bodies[m.id]?.cc ?? ""))])
    }

    @ViewBuilder var content: some View {
        if let b = model.bodies[m.id] {
            VStack(alignment: .leading, spacing: 14) {
                if let html = b.html {
                    HTMLView(html: html, allowRemote: showRemote, height: $htmlHeight).frame(height: htmlHeight)
                    if !showRemote, html.range(of: "<img", options: .caseInsensitive) != nil {
                        Button("Načítať obrázky") { showRemote = true }.buttonStyle(.link).font(.caption)
                    }
                } else {
                    Text(b.text ?? "").font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !b.attachments.isEmpty { attachments(b.attachments) }
            }
        } else if let e = model.bodyErrors[m.id] {
            Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.callout)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    func attachments(_ list: [Attachment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, a in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (a.filename as NSString).pathExtension) ?? .data))
                            .resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.filename).font(.callout).lineLimit(1).truncationMode(.middle)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { model.previewAttachment(m, index: i, name: a.filename) }
                    .contextMenu { AttachmentMenu(m: m, index: i, name: a.filename) }
                    .help("Klik: náhľad · pravý klik: uložiť")
                }
            }
            if list.count > 1 {
                Button("Uložiť všetky do Stiahnutých") { model.saveAllAttachments(m) }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

extension Array { var nilIfEmpty: Self? { isEmpty ? nil : self } }

/// HTML mail in a WebView sized to its content: no JavaScript from the mail, remote content blocked by a CSP until
/// allowed, links open in the browser, scrolling passes through to the conversation.
struct HTMLView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PassthroughWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        let v = PassthroughWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.setValue(false, forKey: "drawsBackground")
        v.onLayout = { [weak v] in if let v { context.coordinator.measure(v) } }
        return v
    }

    func updateNSView(_ v: PassthroughWebView, context: Context) {
        let key = "\(html.hashValue)-\(allowRemote)"
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        let csp = allowRemote ? "img-src * data: cid:; media-src *; font-src *; style-src * 'unsafe-inline';" : "img-src data: cid:; style-src 'unsafe-inline';"
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; \(csp)">
        <meta name="color-scheme" content="light dark">
        <style>
          html, body { background: transparent; overflow: hidden; }
          body { font-family: -apple-system, system-ui; font-size: 13px; margin: 0; color: CanvasText; word-wrap: break-word; }
          img { max-width: 100%; height: auto; }
          table { max-width: 100% !important; }
          blockquote { border-left: 3px solid #8884; margin-left: 0; padding-left: 12px; color: #888; }
        </style></head><body>\(html)</body></html>
        """
        v.loadHTMLString(page, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = ""
        var height: Binding<CGFloat>
        init(height: Binding<CGFloat>) { self.height = height }

        func measure(_ v: WKWebView) {
            v.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { [weak self] r, _ in
                guard let h = (r as? NSNumber).map({ CGFloat($0.doubleValue) }), h > 0 else { return }
                Task { @MainActor in if abs((self?.height.wrappedValue ?? 0) - h) > 2 { self?.height.wrappedValue = min(h + 4, 20000) } }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.measure(webView) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

final class PassthroughWebView: WKWebView {
    var onLayout: (() -> Void)?
    private var lastWidth: CGFloat = 0
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 1 { lastWidth = bounds.width; onLayout?() }
    }
}
