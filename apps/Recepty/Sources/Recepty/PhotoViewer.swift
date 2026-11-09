import AppKit
import ReceptyCore
import SwiftUI

/// The archived photos of a recipe's original, one at a time: zoom (pinch, double-click, slider), ← → between photos, and
/// the text read from the photo beside it (editable, for handwriting the OCR got wrong).
struct PhotoViewer: View {
    @ObservedObject var model: AppModel
    let recipeId: Int64
    @State var index: Int
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var showText = true
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, recipeId: Int64, index: Int) {
        self.model = model; self.recipeId = recipeId
        _index = State(initialValue: index)
    }

    var recipe: Recipe? { model.recipe(recipeId) }
    var photos: [SourcePhoto] { recipe?.photos ?? [] }
    var photo: SourcePhoto? { photos.indices.contains(index) ? photos[index] : nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe?.title ?? "").font(.headline)
                    Text([recipe?.author.isEmpty == false ? "Od: \(recipe!.author)" : nil, photos.count > 1 ? "fotka \(index + 1) z \(photos.count)" : nil,
                          photo.map { "pridaná \(Day.friendly(String($0.added.prefix(10))))" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                Button { step(1) } label: { Image(systemName: "chevron.right") }.disabled(index >= photos.count - 1)
                Slider(value: $zoom, in: 1...5).frame(width: 120).help("Zväčšenie")
                Toggle(isOn: $showText) { Image(systemName: "text.alignleft") }.toggleStyle(.button).help("Prečítaný text")
                Menu {
                    if let p = photo {
                        Button("Otvoriť v Náhľade") { NSWorkspace.shared.open(URL(fileURLWithPath: p.path)) }
                        Button("Ukázať vo Finderi") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
                        Divider()
                        Button("Odstrániť z archívu…", role: .destructive) { remove(p) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button("Hotovo") { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                GeometryReader { g in
                    ScrollView([.horizontal, .vertical]) {
                        if let p = photo, let img = Thumbs.image(p.path) {
                            Image(nsImage: img).resizable().scaledToFit()
                                .frame(width: g.size.width * zoom * pinch, height: g.size.height * zoom * pinch)
                                .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = zoom > 1 ? 1 : 2.5 } }
                        } else {
                            ContentUnavailableView("Fotka chýba", systemImage: "photo").frame(width: g.size.width, height: g.size.height)
                        }
                    }
                    .gesture(MagnifyGesture().onChanged { pinch = $0.magnification }.onEnded { _ in zoom = min(5, max(1, zoom * pinch)); pinch = 1 })
                }
                .background(Color.black.opacity(0.85))
                if showText {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Text z fotky").font(.subheadline.weight(.semibold))
                        Text("Prečítaný automaticky; oprav, čo nesedí (rukopis).").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $text).font(.body).padding(4).cardBackground()
                    }
                    .padding(12)
                    .frame(width: 300)
                }
            }
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 640, idealHeight: 780)
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onAppear { focused = true; text = photo?.text ?? "" }
    }

    func step(_ d: Int) {
        let n = index + d
        guard photos.indices.contains(n) else { return }
        save()
        index = n; zoom = 1
        text = photo?.text ?? ""
    }

    /// Keeps a corrected text.
    func save() {
        guard let p = photo, text != p.text else { return }
        model.act { try model.store.setPhotoText(p.id, text) }
    }

    func remove(_ p: SourcePhoto) {
        let a = NSAlert()
        a.messageText = "Odstrániť túto fotku z archívu?"
        a.informativeText = "Recept zostane, fotka sa zmaže."
        a.addButton(withTitle: "Odstrániť").hasDestructiveAction = true
        a.addButton(withTitle: "Zrušiť")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        model.act { try model.store.deletePhoto(p.id) }
        if photos.isEmpty { dismiss() } else { index = min(index, photos.count - 1); text = photo?.text ?? "" }
    }
}
