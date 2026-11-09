#if os(iOS)
import SwiftUI
import WebKit
import CourierCore

/// Whole conversation, oldest first; the newest message is expanded, older ones open on tap.
struct ThreadView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let message: MessageSummary
    @State private var messages: [MessageSummary] = []
    @State private var expanded: Set<Int64> = []
    @State private var replyTo: MessageSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(message.subject.isEmpty ? "(bez predmetu)" : message.subject)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal)
                    .padding(.top, 4)
                if let sender = messages.last(where: { $0.fromAddress.lowercased() != model.account($0.accountID)?.email.lowercased() }) {
                    UnsubscribeBar(m: sender).padding(.horizontal)
                }
                ForEach(messages) { m in
                    MessageCard(message: m, expanded: expanded.contains(m.id)) {
                        if expanded.contains(m.id) { expanded.remove(m.id) } else { expanded.insert(m.id) }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { Task { await model.archive(message); dismiss() } } label: { Image(systemName: "archivebox") }
                Button { Task { await model.trash(message); dismiss() } } label: { Image(systemName: "trash") }
                Spacer()
                Button { Task { await model.markThread(message, seen: false); dismiss() } } label: { Image(systemName: "envelope.badge") }
                Button { replyTo = messages.last ?? message } label: { Image(systemName: "arrowshape.turn.up.left") }
            }
        }
        .sheet(item: $replyTo) { ComposeView(reply: $0) }
        .task {
            messages = model.thread(message)
            if let last = messages.last { expanded = [last.id] }
            let unseen = messages.filter { !$0.seen }
            if !unseen.isEmpty { await model.setSeen(unseen, true) }
        }
    }
}

struct MessageCard: View {
    @Environment(MobileModel.self) private var model
    let message: MessageSummary
    let expanded: Bool
    let toggle: () -> Void
    @State private var height: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    Avatar(name: message.fromName, address: message.fromAddress, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(message.fromDisplay).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Text(MailDate.short(message.date)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(expanded ? "Komu: \(message.to)" : message.snippet)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? 2 : 1)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                content
                if let b = model.bodies[message.id], !b.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(b.attachments, id: \.self) { a in
                                Label(a.filename, systemImage: "doc")
                                    .font(.caption).lineLimit(1)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(.quaternary, in: .capsule)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .padding(.horizontal)
        .task(id: expanded) { if expanded { await model.body(message) } }
    }

    @ViewBuilder var content: some View {
        if let b = model.bodies[message.id] {
            if let html = b.html, !html.isEmpty {
                HTMLView(html: html, height: $height).frame(height: height)
            } else {
                Text(b.text ?? "").font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let e = model.bodyErrors[message.id] {
            Label(e, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

/// Strip under the subject of bulk mail with an Unsubscribe button; asks before doing anything.
struct UnsubscribeBar: View {
    @Environment(MobileModel.self) private var model
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
                    Text(result ?? "Hromadná pošta").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if working { ProgressView() } else if result == nil {
                        Button("Odhlásiť") { asking = true }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.background.secondary, in: .rect(cornerRadius: 12))
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
            if !method.automatic { await UIApplication.shared.open(method.url) }
            do {
                let n = try await model.sync.unsubscribeAndClean(m, using: method, archive: archive)
                result = (method.automatic ? "Odhlásené" : "Dokonči odhlásenie v prehliadači") + (n > 0 ? " · archivovaných \(n)" : "")
                model.reload()
            } catch { result = "Nepodarilo sa: \(error.localizedDescription)" }
        }
    }
}

/// HTML mail without JavaScript and without remote content, sized to its content (the page itself scrolls).
struct HTMLView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        cfg.dataDetectorTypes = [.link, .phoneNumber]
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.isScrollEnabled = false
        v.scrollView.bounces = false
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        let key = "\(html.hashValue)"
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: cid:; style-src 'unsafe-inline';">
        <meta name="color-scheme" content="light dark">
        <style>
          html, body { background: transparent; }
          body { font-family: -apple-system, system-ui; font-size: 16px; margin: 0; color: CanvasText; word-wrap: break-word; }
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
                Task { @MainActor in if abs((self?.height.wrappedValue ?? 0) - h) > 2 { self?.height.wrappedValue = min(h + 4, 30000) } }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.measure(webView) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
#endif
