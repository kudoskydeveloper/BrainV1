import HomeCore
import SwiftUI

struct DevicesView: View {
    @Environment(Devices.self) private var devices

    var body: some View {
        Page {
            HStack(alignment: .firstTextBaseline) {
                Text("Zariadenia").font(.largeTitle.weight(.semibold))
                Spacer()
                if devices.isMock {
                    Label("Ukážka, kým nie je pripojený Home Assistant", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            StatGrid {
                StatTile("Svetlá", devices.lightsOn.isEmpty ? "Zhasnuté" : "\(devices.lightsOn.count) svieti",
                         detail: devices.lightsOn.prefix(2).map { "\(roomName($0.room)): \($0.name)" }.joined(separator: ", "),
                         symbol: "lightbulb.fill", tint: .yellow)
                StatTile("Teplota", "\(Fmt1.one(devices.indoorAverage)) °C",
                         detail: devices.ac.map { $0.on ? "Klíma \($0.level) °C, \($0.acMode.title.lowercased())" : "Klíma vypnutá" },
                         symbol: "thermometer.medium", tint: .orange)
                StatTile("Dvere", devices.frontDoorLocked ? "Zamknuté" : "Odomknuté",
                         detail: "Alarm: \(devices.alarm.title.lowercased())",
                         symbol: devices.frontDoorLocked ? "lock.fill" : "lock.open.fill", tint: devices.frontDoorLocked ? .green : .red)
                StatTile("Vysávač", devices.vacuum?.vacuum.title ?? "–", detail: devices.vacuum.map { "Batéria \($0.level) %" },
                         symbol: "fan.fill", tint: .teal)
            }

            Card("Scény", subtitle: "Druhé kliknutie na aktívnu scénu ju vráti späť") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(Devices.scenes) { s in SceneButton(scene: s) }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                Card("Vchodové dvere") {
                    HStack {
                        Image(systemName: devices.frontDoorLocked ? "lock.fill" : "lock.open.fill")
                            .font(.title2).foregroundStyle(devices.frontDoorLocked ? .green : .red)
                            .contentTransition(.symbolEffect(.replace))
                        Text(devices.frontDoorLocked ? "Zamknuté" : "Odomknuté").font(.headline)
                        Spacer()
                        Button(devices.frontDoorLocked ? "Odomknúť" : "Zamknúť") {
                            withAnimation(.snappy) { devices.setFrontDoor(locked: !devices.frontDoorLocked) }
                        }
                    }
                }
                Card("Alarm") {
                    Picker("Alarm", selection: Binding(get: { devices.alarm }, set: { devices.setAlarm($0) })) {
                        ForEach(AlarmMode.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }

            ForEach(devices.rooms) { room in
                let items = devices.devices(in: room)
                if !items.isEmpty { RoomCard(room: room, items: items) }
            }
        }
    }

    func roomName(_ id: String) -> String { devices.rooms.first { $0.id == id }?.name ?? id }
}

enum Fmt1 {
    static func one(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(1)).locale(Fmt.sk)) }
}

struct SceneButton: View {
    @Environment(Devices.self) private var devices
    let scene: HomeScene
    @State private var hover = false

    var body: some View {
        let active = devices.activeScene == scene.id
        Button { withAnimation(.snappy) { devices.run(scene: scene.id) } } label: {
            HStack(spacing: 8) {
                Image(systemName: scene.symbol).font(.body.weight(.semibold))
                    .foregroundStyle(active ? .white : .indigo)
                Text(scene.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .foregroundStyle(active ? .white : .primary)
            .background(active ? AnyShapeStyle(Color.indigo.gradient) : AnyShapeStyle(.fill.tertiary.opacity(hover ? 1.6 : 1)),
                        in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(active ? "Vrátiť späť" : "Spustiť scénu")
    }
}

struct RoomCard: View {
    @Environment(Devices.self) private var devices
    let room: Room
    let items: [Device]

    var body: some View {
        let lights = items.filter(\.isLighting)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.name).font(.headline)
                    Label("\(Fmt1.one(room.temperature)) °C · vlhkosť \(room.humidity) %", systemImage: room.outdoor ? "cloud.sun" : "thermometer.medium")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if lights.count > 1 {
                    let anyOn = lights.contains(where: \.on)
                    Button(anyOn ? "Zhasnúť" : "Rozsvietiť") { withAnimation(.snappy) { devices.setRoomLights(room, on: !anyOn) } }
                        .buttonStyle(.link)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10, alignment: .top)], spacing: 10) {
                ForEach(items) { DeviceTile(device: $0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardBackground()
    }
}

/// One device, HomeKit-style: click toggles it; lights, blinds and speakers get a slider, the AC a target and a mode.
struct DeviceTile: View {
    @Environment(Devices.self) private var devices
    let device: Device
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { devices.toggle(device) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: device.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(device.active ? .white : .secondary)
                        .frame(width: 32, height: 32)
                        .background(device.active ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.fill.secondary), in: .circle)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text(device.state).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(help)

            controls
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(device.active ? AnyShapeStyle(tint.opacity(0.12)) : AnyShapeStyle(.fill.quaternary), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(hover ? 0.9 : 0.4), lineWidth: 0.5))
        .onHover { hover = $0 }
    }

    @ViewBuilder var controls: some View {
        switch device.kind {
        case .light, .lamp, .speaker:
            if device.on { LevelSlider(value: device.level) { devices.setLevel(device, $0) } }
        case .blinds:
            LevelSlider(value: device.level) { devices.setLevel(device, $0) }
        case .ac:
            if device.on {
                HStack(spacing: 6) {
                    Button { devices.setLevel(device, device.level - 1) } label: { Image(systemName: "minus") }
                    Text("\(device.level) °C").font(.callout.weight(.semibold)).monospacedDigit().frame(minWidth: 44)
                    Button { devices.setLevel(device, device.level + 1) } label: { Image(systemName: "plus") }
                    Spacer()
                    Menu {
                        ForEach(ACMode.allCases, id: \.self) { m in
                            Button { devices.setACMode(m) } label: { Label(m.title, systemImage: m.symbol) }
                        }
                    } label: { Image(systemName: device.acMode.symbol) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Režim: \(device.acMode.title)")
                }
                .controlSize(.small)
            }
        default: EmptyView()
        }
    }

    var tint: Color {
        switch device.kind {
        case .light, .lamp: .yellow
        case .blinds: .teal
        case .tv: .indigo
        case .speaker: .pink
        case .ac: device.acMode == .heat ? .orange : .cyan
        case .vacuum: .green
        }
    }

    var help: String {
        switch device.kind {
        case .blinds: device.level > 0 ? "Zatvoriť" : "Otvoriť"
        case .vacuum: device.vacuum == .cleaning ? "Poslať do doku" : "Začať upratovať"
        default: device.on ? "Vypnúť" : "Zapnúť"
        }
    }
}

/// A 0–100 slider that reports when the drag ends (no write per pixel).
struct LevelSlider: View {
    let value: Int
    let set: (Int) -> Void
    @State private var draft: Double?

    var body: some View {
        Slider(value: Binding(get: { draft ?? Double(value) }, set: { draft = $0 }), in: 0...100) { editing in
            if !editing, let d = draft { set(Int(d.rounded())); draft = nil }
        }
        .controlSize(.mini)
    }
}
