import BrainCore
import SwiftUI
import UniformTypeIdentifiers

/// Light / dark / follow the system, for the panel only.
enum Look: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String { ["auto": "Automaticky", "light": "Svetlý", "dark": "Tmavý"][rawValue]! }
    var appearance: NSAppearance? { self == .auto ? nil : NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
}

/// Spotlight-style panel that grows upwards: the input sits at the bottom, the conversation above it.
/// Everything around it (history, what Brain knows, timers, commands, settings) is in the Brain window.
struct PanelView: View {
    @ObservedObject var session: Session
    @ObservedObject var history = HistoryStore.shared
    @ObservedObject var timers = TimerStore.shared
    let close: () -> Void
    let brief: () -> Void
    let openWindow: (BrainSection) -> Void
    /// Tells the window how tall the panel is, so it can animate to that height (the panel stays anchored at its bottom).
    let resize: (CGFloat) -> Void
    /// Transparent margin around the panel for its shadow (radius 18, y 8 reaches ~44 pt below): less clips the shadow at the window edge.
    static let shadowRoom: CGFloat = 52
    @FocusState var focused: Bool
    @AppStorage("look") var look: Look = .auto
    @State var slashIndex = 0
    @State var dropping = false

    var expanded: Bool { !session.messages.isEmpty || session.needsLogin || session.status != nil }
    var slash: [SlashItem] { SlashMenu.items(for: session.input) }

    var body: some View {
        panel
            .background(GeometryReader { g in Color.clear.preference(key: ContentHeight.self, value: g.size.height) })
            .onPreferenceChange(ContentHeight.self) { resize($0) }
            .padding(Self.shadowRoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    var panel: some View {
        VStack(spacing: 0) {
            if expanded {
                header
                Divider().opacity(0.4)
                ScrollViewReader { proxy in
                    ScrollView {
                        conversation
                            .padding(.horizontal, 22).padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.never)
                    .defaultScrollAnchor(.bottom)
                    // one fixed height once open: the answer scrolls inside instead of the panel growing with every line
                    .frame(height: 470)
                    .onChange(of: session.messages) { _, m in withAnimation(.smooth) { proxy.scrollTo(m.last?.id, anchor: .bottom) } }
                }
                Divider().opacity(0.4)
            }
            if !slash.isEmpty {
                SlashMenuView(items: slash, selected: min(slashIndex, slash.count - 1)) { pick($0) }
                Divider().opacity(0.4)
            }
            if !session.queue.isEmpty { queueRow }
            if !session.attachments.isEmpty { attachmentsRow }
            inputRow
            if session.messages.isEmpty && slash.isEmpty { emptyState } else { hintsRow }
        }
        .frame(width: 720)
        .background {   // material for depth, an almost opaque white (or deep gray) surface on top: clean like the Hangar apps
            ZStack { Rectangle().fill(.regularMaterial); Rectangle().fill(Color.panelSurface) }
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(dropping ? AnyShapeStyle(.brainAccent) : AnyShapeStyle(.separator.opacity(0.6)), lineWidth: dropping ? 2 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)   // the window itself has no shadow: it would be a rectangle
        .environment(\.brainSession, session)
        .animation(.smooth(duration: 0.25), value: expanded)
        .animation(.smooth(duration: 0.15), value: slash.count)
        .onAppear { focused = true; apply(look) }
        .onChange(of: look) { _, l in apply(l) }
        .onChange(of: session.input) { _, _ in slashIndex = 0 }
        .onExitCommand { if !slash.isEmpty { session.input = "" } else { close() } }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in drop(providers) }
        .background(shortcuts)
    }

    func apply(_ l: Look) { NSApp.windows.forEach { $0.appearance = l.appearance } }

    // MARK: pieces

    /// Over an open conversation: its title, new, pin, and the Brain window.
    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .foregroundStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(session.chatTitle ?? "Nový rozhovor").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
            Group {
                Button { session.reset(); focused = true } label: { Image(systemName: "square.and.pencil") }.help("Nový rozhovor (⌘R)")
                Button { session.pinned.toggle() } label: { Image(systemName: session.pinned ? "pin.fill" : "pin") }
                    .foregroundStyle(session.pinned ? AnyShapeStyle(.brainAccent) : AnyShapeStyle(.secondary))
                    .help(session.pinned ? "Odopnúť: panel sa skryje, keď klikneš inam" : "Pripnúť: panel ostane otvorený")
                Button { openWindow(.chats) } label: { Image(systemName: "sidebar.left") }.help("Otvoriť v okne Brain (⌘0)")
            }
            .buttonStyle(.borderless)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    var inputRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                .symbolEffect(.pulse, isActive: session.running)
                .frame(width: 24)
            TextField(placeholder, text: $session.input, axis: .vertical)
                .onKeyPress(phases: .down) { k in key(k) }
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .lineLimit(1...14)   // grows with a long message, then scrolls
                .focused($focused)
            Button { pickPhotos() } label: { Image(systemName: "photo.on.rectangle").font(.system(size: 15)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Pripojiť fotku z Fotiek (alebo ju sem pretiahni)")
            if session.running {
                Button { session.interrupt() } label: { Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).frame(width: 22, height: 22).background(.quaternary, in: Circle()).help("Zastaviť")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())   // move the panel by its input row, so answer text stays selectable
    }

    var placeholder: String {
        !session.attachments.isEmpty ? "Čo s touto fotkou? (↩ sa len spýta, čo na nej je)"
            : session.running ? "↩ pošle hneď (preruší), ⌘↩ zaradí do fronty"
            : session.messages.isEmpty ? "Opýtaj sa Brainu, / pre príkazy a appky" : "Pokračuj, alebo potvrď návrh"
    }

    /// Return, ⌘Return, Shift+Return, arrows and Tab in the field (the slash menu takes arrows, Tab and Return while open).
    func key(_ k: KeyPress) -> KeyPress.Result {
        if !slash.isEmpty {
            switch k.key {
            case .downArrow: slashIndex = min(slashIndex + 1, slash.count - 1); return .handled
            case .upArrow: slashIndex = max(slashIndex - 1, 0); return .handled
            case .tab, .return: pick(slash[min(slashIndex, slash.count - 1)]); return .handled
            default: break
            }
        }
        guard k.key == .return else { return .ignored }
        if k.modifiers.contains(.shift) { session.input += "\n"; return .handled }
        session.submit(queued: k.modifiers.contains(.command))
        return .handled
    }

    func pick(_ it: SlashItem) {
        session.input = it.id
        if !it.id.hasSuffix(" ") { session.submit(queued: false) }   // complete commands (/export, /ucet, /help) run right away
        focused = true
    }

    /// Pictures waiting to go with the next question: small thumbnails, each with a remove button.
    var attachmentsRow: some View {
        HStack(spacing: 8) {
            ForEach(session.attachments, id: \.self) { url in
                Thumbnail(url: url, size: 56)
                    .overlay(alignment: .topTrailing) {
                        Button { session.attachments.removeAll { $0 == url } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 16, height: 16).background(.black.opacity(0.6), in: Circle())
                        }
                        .buttonStyle(.plain).padding(3).help("Odobrať")
                    }
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.top, 12)
    }

    /// The Photos picker (its own window over the panel); picked pictures → stored JPEGs in the composer.
    func pickPhotos() {
        session.picking = true
        let panel = NSApp.windows.first { $0 is Panel }
        PhotoPicker.shared.pick(over: panel) { datas in
            datas.forEach(session.attach)
            session.picking = false
            panel?.makeKeyAndOrderFront(nil)
            focused = true
        }
    }

    var queueRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(session.queue.enumerated()), id: \.offset) { i, q in
                HStack(spacing: 8) {
                    Image(systemName: "clock").font(.caption).foregroundStyle(.brainAccent)
                    Text(session.decisionLabels[q] ?? q).font(.callout).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button { session.queue.remove(at: i) } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.borderless)
                }
            }
            Text("Pošle sa, keď Brain dokončí odpoveď.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20).padding(.top, 10)
    }

    /// An empty panel: one slim row of text chips under the input, the next timer and the window on the right.
    var emptyState: some View {
        HStack(spacing: 6) {
            chip("Ranný prehľad") { brief() }
            chip("Ďalší meeting") { ask("Priprav ma na môj najbližší meeting") }
            chip("Pošta") { ask("Čo je nové v pošte, na čo mám odpísať?") }
            chip("Trhy") { ask("Ako sú na tom trhy a môj Alpaca účet?") }
            chip("Kde je…") { session.input = "Kde je "; focused = true }
            chip("Nákup") { ask("Čo mám na nákupnom zozname?") }
            Spacer(minLength: 8)
            if let t = timers.jobs.first {
                Button { openWindow(.timers) } label: {
                    Text(t.at.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "sk_SK"))))
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.tertiary).help("Najbližší timer: \(t.prompt.prefix(80))")
            }
            Button { openWindow(.chats) } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Okno Brain: rozhovory, čo Brain vie, timery, príkazy, nastavenia (⌘0)")
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    func chip(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary.opacity(0.75))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Color.panelChip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    var hintsRow: some View {
        HStack(spacing: 12) {
            if session.running {
                hint("Poslať hneď", "↩") { session.submit(queued: false) }
                hint("Do fronty", "⌘↩") { session.submit(queued: true) }
                hint("Zastaviť", "esc") { session.interrupt() }
            } else {
                hint("Nový", "⌘R") { session.reset(); focused = true }
                hint("Kopírovať", "⌘⇧C") { copyAnswer() }
                hint("Pokračovať v Claude", "⌘⇧↩") { session.continueInClaude(); close() }
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    func ask(_ q: String) { session.input = q; session.submit(queued: false); focused = true }

    /// Dropped pictures (from Finder or straight from Photos) are attached as images; other files go into the question as
    /// paths, so Brain can read them.
    func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            guard p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                // Photos hands out the picture itself (a file promise / image data), not a file URL
                _ = p.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    DispatchQueue.main.async { session.attach(data); focused = true }
                }
                continue
            }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    if Attachments.isImage(url) { session.attach(file: url); focused = true; return }
                    let path = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    session.input += (session.input.isEmpty || session.input.hasSuffix(" ") ? "" : " ") + "`\(path)` "
                    focused = true
                }
            }
        }
        return true
    }

    var conversation: some View {
        VStack(alignment: .leading, spacing: 18) {
            if session.needsLogin { LoginHint { session.login() } }
            if session.limitHit && !session.needsLogin { LimitHint { session.relogin() } }
            if let r = session.repeating { RepeatBanner(job: r) { session.stopRepeat("Opakovanie som zastavil.") } }
            let lastAnswer = session.messages.lastIndex { !$0.mine }
            ForEach(Array(session.messages.enumerated()), id: \.element.id) { i, m in
                Turn(message: m, latest: i == lastAnswer, working: session.running && i == lastAnswer, decided: session.decided,
                     recent: i >= session.messages.count - 6, marked: session.marked).id(m.id)
            }
            if let s = session.status, session.messages.last?.steps.isEmpty ?? true {
                HStack(spacing: 8) {
                    NotchSpinner(size: 11, color: .secondary)
                    Text(s).font(.callout).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
    }

    func hint(_ title: String, _ keys: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(.secondary)
                Text(keys).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .buttonStyle(.plain).font(.caption)
    }

    /// Invisible buttons that carry the keyboard shortcuts.
    var shortcuts: some View {
        Group {
            Button("") { session.reset(); focused = true }.keyboardShortcut("r")   // not ⌘N: a clipboard manager takes it
            Button("") { copyAnswer() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("") { session.continueInClaude(); close() }.keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("") { brief() }.keyboardShortcut("b")
            Button("") { openWindow(.chats) }.keyboardShortcut("y")
            Button("") { openWindow(.knowledge) }.keyboardShortcut("k")
            Button("") { openWindow(.settings) }.keyboardShortcut(",")
            Button("") { openWindow(.chats) }.keyboardShortcut("0")
            Button("") { session.pinned.toggle() }.keyboardShortcut("p")
        }
        .opacity(0).frame(width: 0, height: 0)
    }

    func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.messages.last(where: { !$0.mine })?.text ?? "", forType: .string)
    }
}

struct ContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: conversation

struct Turn: View {
    let message: Message
    /// The newest answer: its options, checklist and proposals are live buttons.
    var latest = false
    /// Brain is still writing this answer.
    var working = false
    var decided: [String: Bool] = [:]
    /// One of the last few messages: its undecided proposals keep their buttons while Brain works on another one.
    var recent = false
    var marked: [String: Bool] = [:]
    @Environment(\.brainSession) var session

    var body: some View {
        if message.mine {
            // the question: a bubble on the right, like Messages, so it's clear at a glance what was asked where
            VStack(alignment: .trailing, spacing: 6) {
            if !message.images.isEmpty {
                HStack(spacing: 6) {
                    Spacer(minLength: 120)
                    ForEach(message.images, id: \.self) { url in
                        Thumbnail(url: url, size: 96).onTapGesture { NSWorkspace.shared.open(url) }.help("Otvoriť")
                    }
                }
            }
            HStack {
                Spacer(minLength: 120)
                Text(message.text)
                    .font(.system(size: 14))
                    .lineSpacing(2)
                    .foregroundStyle(.white)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(Color.brainAccent, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16,
                                                                                    bottomTrailingRadius: 5, topTrailingRadius: 16, style: .continuous))
            }
            }
            .padding(.top, 6)
        } else if !message.text.isEmpty || !message.steps.isEmpty || !message.proposals.isEmpty {
            let live = latest && !working && session != nil
            let parts = AnswerParts.split(message.text)
            VStack(alignment: .leading, spacing: 12) {
                if !message.steps.isEmpty { StepsView(steps: message.steps, working: working) }
                let md = live ? parts.markdown : parts.base   // older answers keep their checklist as text
                if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { MarkdownView(text: md) }
                if live && !parts.tasks.isEmpty { ChecklistCard(items: parts.tasks) }
                let open = message.proposals.filter { decided[$0.id] == nil }
                let proposalsLive = session != nil && (live || recent)
                let multi = proposalsLive && open.count >= 2   // several: mark each, then send them together
                ForEach(message.proposals) { p in
                    ProposalCard(proposal: p, decided: decided[p.id], live: proposalsLive, multi: multi, mark: marked[p.id])
                }
                if multi { DecideBar(open: open, marked: marked) }
                if !parts.options.isEmpty { OptionsRow(options: parts.options, live: live) }
                let files = Self.files(in: message.text)
                if !files.isEmpty {
                    VStack(spacing: 2) { ForEach(files, id: \.self) { FileRow(url: $0) } }
                        .padding(4)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    /// Existing files the answer links to (file:// Markdown links), in order, without duplicates.
    static func files(in text: String) -> [URL] {
        let re = try! NSRegularExpression(pattern: #"\((file://[^)\s]+)\)"#)
        var seen = Set<String>(), out: [URL] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 1), in: text), let url = URL(string: String(text[r])),
                  FileManager.default.fileExists(atPath: url.path), seen.insert(url.path).inserted else { continue }
            out.append(url)
        }
        return Array(out.prefix(8))
    }
}

struct FileRow: View {
    let url: URL
    @State var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            // always visible: "where is X" should end in one click to the place
            HStack(spacing: 6) {
                Button(isFolder ? "Otvoriť priečinok" : "Otvoriť") { NSWorkspace.shared.open(url) }
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Vo Finderi", systemImage: "folder") }
                    .help("Ukázať, kde to je, vo Finderi")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(hover ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
    }

    var isFolder: Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }

    var folder: String {
        url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs", with: "iCloud Drive")
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// The question repeating in this conversation, until when, and a way to stop it.
struct RepeatBanner: View {
    let job: Session.Repeat
    let stop: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "repeat").foregroundStyle(.brainAccent)
            Text("„\(job.prompt)“ každých \(Session.human(job.every)) do \(job.until.formatted(date: .omitted, time: .shortened))")
                .font(.callout).lineLimit(1)
            Spacer()
            Button("Zastaviť", action: stop).controlSize(.small)
        }
        .padding(10)
        .background(.brainAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct LimitHint: View {
    let relogin: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.2.badge.gearshape").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Limit tohto Claude účtu je vyčerpaný").font(.headline)
                Text("Prihlás sa iným účtom: klikni nižšie alebo napíš `/relogin` (s e-mailom: `/relogin meno@domena.sk`). `/ucet` ukáže, ktorý účet Brain používa.").font(.callout).foregroundStyle(.secondary)
                Button("Prihlásiť iný účet", action: relogin).controlSize(.small)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct LoginHint: View {
    let login: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude Code nie je prihlásený").font(.headline)
                Text("Napíš sem `/login` alebo klikni na Prihlásiť sa: otvorí sa prihlásenie v prehliadači. Potom sa spýtaj znova.").font(.callout).foregroundStyle(.secondary)
                Button("Prihlásiť sa", action: login).controlSize(.small)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A stored picture as a small rounded square (cropped to fill), loaded once per file.
struct Thumbnail: View {
    let url: URL
    var size: CGFloat = 56
    @State var image: NSImage?

    var body: some View {
        ZStack {
            Color.panelChip
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.tertiary) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}
