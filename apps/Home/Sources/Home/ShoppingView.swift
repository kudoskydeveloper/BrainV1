import HomeCore
import SwiftUI

struct ShoppingView: View {
    @Environment(Store.self) private var store
    @State private var newItem = ""
    @FocusState private var focused: Bool

    var body: some View {
        let toBuy = store.shopping.filter { !$0.done }
        let bought = store.shopping.filter(\.done)
        Page {
            HStack(alignment: .firstTextBaseline) {
                Text("Nákup").font(.largeTitle.weight(.semibold))
                Spacer()
                Text(toBuy.isEmpty ? "Nič netreba" : "\(toBuy.count) kúpiť").foregroundStyle(.secondary)
            }

            Card("Pridať") {
                HStack {
                    TextField("Napr. Mlieko, vajcia 10 ks (viac naraz oddeľ čiarkou)", text: $newItem)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(add)
                    Button("Pridať", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Card("Kúpiť", subtitle: "Spoločný zoznam, vidia ho všetci v domácnosti") {
                if toBuy.isEmpty {
                    EmptyChart(text: "Zoznam je prázdny. Pridaj niečo hore alebo povedz Brainu.")
                } else {
                    Rows(items: toBuy) { ShopRow(item: $0) }
                }
            }

            if !bought.isEmpty {
                Card("Kúpené", subtitle: "\(bought.count) položiek") {
                    Rows(items: bought) { ShopRow(item: $0) }
                    Button("Vymazať kúpené", role: .destructive) { withAnimation { store.clearBought() } }
                        .padding(.leading, 10).padding(.top, 4)
                }
            }
        }
        .onAppear { focused = true }
    }

    func add() {
        let names = newItem.split(separator: ",").map(String.init)
        withAnimation(.snappy) { store.addShopping(names) }
        newItem = ""
    }
}

struct ShopRow: View {
    @Environment(Store.self) private var store
    let item: ShopItem
    @State private var editing = false
    @State private var name = ""

    var body: some View {
        HoverRow {
            CheckButton(done: item.done, tint: .green) { withAnimation(.snappy) { store.setBought(item, !item.done) } }
            if editing {
                TextField("Názov", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.rename(item, to: name); editing = false }
                    .onExitCommand { editing = false }
            } else {
                Text(item.name)
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .onTapGesture(count: 2) { name = item.name; editing = true }
            }
            Spacer()
        }
        .contextMenu {
            Button("Premenovať") { name = item.name; editing = true }
            Button("Odstrániť", role: .destructive) { withAnimation { store.remove(item) } }
        }
    }
}
