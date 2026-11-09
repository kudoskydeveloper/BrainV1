import AppKit
import Charts
import ReceptyCore
import SwiftUI

/// The week's meal plan as a grid of days (today marked), each with its recipes and what they bring per person.
struct PlanPage: View {
    @ObservedObject var model: AppModel
    @State private var week = Day.weekStart(Day.today)

    var body: some View {
        let _ = model.version
        let items = model.store.plan(from: week, to: Day.adding(6, to: week))
        let planned = items.compactMap { p in model.recipe(p.recipeId) }
        ScrollPage(maxWidth: 1400) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jedálniček").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(items.isEmpty ? "Tento týždeň nič naplánované" : "\(items.count) \(items.count == 1 ? "jedlo" : items.count < 5 ? "jedlá" : "jedál") · priemer \(Fmt.kcal(planned.map(\.perServing.kcal).reduce(0, +) / Double(max(1, Set(items.map(\.date)).count)))) na osobu a deň")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                WeekSwitcher(week: $week)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(0..<7, id: \.self) { n in
                    let day = Day.adding(n, to: week)
                    DayCard(model: model, day: day, items: items.filter { $0.date == day })
                }
            }
        }
        .navigationTitle("Jedálniček")
        .toolbar {
            ToolbarItem { Button { model.page = .shopping } label: { Label("Nákup", systemImage: "cart") }.help("Nákupný zoznam na naplánované recepty") }
        }
    }
}

struct DayCard: View {
    @ObservedObject var model: AppModel
    let day: String
    let items: [PlanItem]

    var weekday: String {
        guard let d = Day.date(day) else { return day }
        let f = DateFormatter(); f.locale = Locale(identifier: "sk_SK"); f.dateFormat = "EEEE"
        return f.string(from: d).capitalized
    }

    var body: some View {
        let today = day == Day.today, past = day < Day.today
        let kcal = items.compactMap { model.recipe($0.recipeId)?.perServing.kcal }.reduce(0, +)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(weekday).font(.headline)
                Text(Day.short(day).components(separatedBy: " ").dropFirst().joined(separator: " ")).foregroundStyle(.secondary)
                if today { Text("DNES").font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange, in: Capsule()) }
                Spacer()
                if kcal > 0 { Text(Fmt.kcal(kcal)).font(.caption.monospacedDigit()).foregroundStyle(Color.energy) }
            }
            ForEach(items) { p in PlanRow(model: model, item: p) }
            Button { model.sheet = .planRecipe(nil, day) } label: {
                Label(items.isEmpty ? "Naplánovať" : "Pridať", systemImage: "plus")
                    .font(.callout).frame(maxWidth: .infinity, minHeight: items.isEmpty ? 54 : 30)
                    .foregroundStyle(.secondary)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.quaternary))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.recipes.isEmpty)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange, lineWidth: today ? 1.5 : 0))
        .opacity(past ? 0.6 : 1)
    }
}

struct PlanRow: View {
    @ObservedObject var model: AppModel
    let item: PlanItem
    var body: some View {
        let r = model.recipe(item.recipeId)
        HStack(spacing: 10) {
            RecipeImage(path: r?.coverPath ?? "", corner: 8).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                Label("\(item.slot.label) · \(Fmt.number(item.servings)) porc.", systemImage: item.slot.symbol).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Otvoriť recept") { model.open(item.recipeId) }
                if let r { Button("Variť") { model.cook(r) } ; Button("Zjedol som…") { model.sheet = .logMeal(r, 1) } }
                Divider()
                Button("Odstrániť z plánu", role: .destructive) { model.act { try model.store.deletePlan(item.id) } }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { model.open(item.recipeId) }
    }
}

struct WeekSwitcher: View {
    @Binding var week: String
    var body: some View {
        HStack(spacing: 8) {
            if week != Day.weekStart(Day.today) { Button("Tento týždeň") { week = Day.weekStart(Day.today) }.buttonStyle(.bordered) }
            ControlGroup {
                Button { week = Day.adding(-7, to: week) } label: { Image(systemName: "chevron.left") }
                Button { week = Day.adding(7, to: week) } label: { Image(systemName: "chevron.right") }
            }
            .fixedSize()
            Text("\(Day.short(week)) – \(Day.short(Day.adding(6, to: week)))").font(.headline).monospacedDigit()
        }
    }
}

// MARK: Meal log

struct LogPage: View {
    @ObservedObject var model: AppModel
    @State private var day = Day.today

    var body: some View {
        let _ = model.version
        let meals = model.store.meals(from: day, to: day)
        let total = meals.map(\.nutrients).reduce(.zero, +)
        let from = Day.adding(-13, to: day)
        let history = model.store.meals(from: from, to: day)
        let byDay = (0..<14).map { n -> (String, Double) in
            let d = Day.adding(n, to: from)
            return (d, history.filter { $0.date == d }.map(\.nutrients.kcal).reduce(0, +))
        }
        ScrollPage {
            HStack {
                Button { day = Day.adding(-1, to: day) } label: { Image(systemName: "chevron.left") }
                Text(Day.friendly(day)).font(.title3.weight(.semibold)).frame(minWidth: 180)
                Button { day = Day.adding(1, to: day) } label: { Image(systemName: "chevron.right") }.disabled(day >= Day.today)
                if day != Day.today { Button("Dnes") { day = Day.today } }
                Spacer()
            }
            .buttonStyle(.bordered)
            Card(day == Day.today ? "Dnes" : Day.friendly(day), subtitle: meals.isEmpty ? "nič zapísané" : "\(meals.count) \(meals.count == 1 ? "jedlo" : meals.count < 5 ? "jedlá" : "jedál")") {
                NutritionSummary(n: total, ring: 110)
            }
            Card("Jedlá") {
                if meals.isEmpty {
                    Text("Nič zapísané. Na stránke receptu: Zjedol som.").foregroundStyle(.secondary)
                }
                ForEach(MealSlot.allCases, id: \.self) { slot in
                    let list = meals.filter { $0.slot == slot }
                    if !list.isEmpty {
                        Label(slot.label, systemImage: slot.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(list) { m in
                            HStack {
                                Text(m.title)
                                if let g = m.grams { Text(Fmt.grams(g)).foregroundStyle(.secondary) }
                                else if let s = m.servings { Text("\(Fmt.qty(s)) porc.").foregroundStyle(.secondary) }
                                Spacer()
                                Text("\(Fmt.kcal(m.nutrients.kcal)) · B \(Fmt.macro(m.nutrients.protein))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                if let id = m.recipeId { Button("Otvoriť recept") { model.open(id) } }
                                Button("Zmazať", role: .destructive) { model.act { try model.store.deleteMeal(m.id) } }
                            }
                        }
                    }
                }
            }
            Card("Posledné dva týždne", subtitle: "kcal za deň") {
                Chart(byDay, id: \.0) { d in
                    BarMark(x: .value("Deň", Day.date(d.0) ?? Date(), unit: .day), y: .value("kcal", d.1))
                        .foregroundStyle(d.0 == day ? Color.orange.gradient : Color.orange.opacity(0.45).gradient)
                        .cornerRadius(3)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.day().month(.defaultDigits)) } }
                .frame(height: 160)
            }
        }
        .navigationTitle("Denník")
    }
}

// MARK: Shopping

struct ShoppingPage: View {
    @ObservedObject var model: AppModel
    @State private var to = Day.adding(6, to: Day.weekStart(Day.today))
    @State private var have: Set<String> = []

    var body: some View {
        let _ = model.version
        let plan = model.store.plan(from: Day.today, to: to)
        let pairs = plan.compactMap { p in model.recipe(p.recipeId).map { ($0, p.servings) } }
        let items = Shopping.list(pairs)
        ScrollPage(maxWidth: 820) {
            HStack {
                Text("Od dnes do").foregroundStyle(.secondary)
                DatePicker("", selection: Binding(get: { Day.date(to) ?? Date() }, set: { to = Day.string($0) }), in: Date()..., displayedComponents: .date).labelsHidden().fixedSize()
                Spacer()
                Button { copy(items) } label: { Label("Kopírovať", systemImage: "doc.on.doc") }.disabled(items.isEmpty)
                    .help("Skopíruje, čo ešte nemáš, ako zoznam (napr. do Pripomienok alebo pre Brain).")
            }
            if pairs.isEmpty {
                ContentUnavailableView("Nič naplánované", systemImage: "cart", description: Text("Recepty v jedálničku od dnes do zvoleného dňa sa tu spočítajú do nákupu."))
            } else {
                Card("Na nákup", subtitle: pairs.map { "\($0.0.title) (\(Fmt.number($0.1)))" }.joined(separator: " · ")) {
                    ForEach(items) { it in
                        let on = have.contains(it.id)
                        Button {
                            if on { have.remove(it.id) } else { have.insert(it.id) }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? .green : .secondary)
                                Text(it.label).strikethrough(on).foregroundStyle(on ? .secondary : .primary)
                                Spacer()
                                if it.recipes.count > 1 { Text("\(it.recipes.count) recepty").font(.caption).foregroundStyle(.tertiary) }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Nákup")
    }

    func copy(_ items: [ShoppingItem]) {
        let s = items.filter { !have.contains($0.id) }.map { "- \($0.label)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
