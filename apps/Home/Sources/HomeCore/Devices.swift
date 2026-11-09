import Foundation
import Observation

// The flat's devices. Mock for now: they will come from Home Assistant, so the shapes stay close to HA entities (a light with
// brightness, a cover with a position, a climate entity with a target and a mode) and swapping the source is mechanical.
// Unlike chores, device state is live and per flat, so it isn't synced through Supabase; the mock is saved to devices.json.

public enum DeviceKind: String, Codable, Sendable { case light, lamp, blinds, tv, speaker, ac, vacuum }

public enum ACMode: String, Codable, CaseIterable, Sendable {
    case cool, heat, auto, dry
    public var title: String { ["Chladenie", "Kúrenie", "Auto", "Odvlhčovanie"][ACMode.allCases.firstIndex(of: self)!] }
    public var symbol: String { ["snowflake", "flame.fill", "thermometer.medium", "drop.fill"][ACMode.allCases.firstIndex(of: self)!] }
}

public enum VacuumState: String, Codable, Sendable { case docked, cleaning, returning, paused
    public var title: String {
        switch self { case .docked: "V doku"; case .cleaning: "Upratuje"; case .returning: "Vracia sa"; case .paused: "Pozastavený" }
    }
}

public struct Device: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let room: String
    public var name: String
    public let kind: DeviceKind
    public var on: Bool
    /// 0–100 for lights, blinds (open %) and speakers (volume); target °C for the AC; battery % for the vacuum.
    public var level: Int
    public var acMode: ACMode = .cool
    public var vacuum: VacuumState = .docked

    public var isLighting: Bool { kind == .light || kind == .lamp }

    public var symbol: String {
        switch kind {
        case .light: on ? "lightbulb.fill" : "lightbulb"
        case .lamp: on ? "lamp.floor.fill" : "lamp.floor"
        case .blinds: level > 0 ? "blinds.horizontal.open" : "blinds.horizontal.closed"
        case .tv: on ? "tv.fill" : "tv"
        case .speaker: on ? "hifispeaker.fill" : "hifispeaker"
        case .ac: on ? acMode.symbol : "air.conditioner.horizontal"
        case .vacuum: "fan.fill"
        }
    }

    /// "80 %", "Vypnuté", "Otvorené na 40 %", "22 °C · Chladenie", "V doku · 100 %".
    public var state: String {
        switch kind {
        case .light, .lamp: on ? "\(level) %" : "Vypnuté"
        case .blinds: level == 0 ? "Zatvorené" : level == 100 ? "Otvorené" : "Otvorené na \(level) %"
        case .tv: on ? "Zapnutý" : "Vypnutý"
        case .speaker: on ? "Hrá · \(level) %" : "Ticho"
        case .ac: on ? "\(level) °C · \(acMode.title)" : "Vypnutá"
        case .vacuum: "\(vacuum.title) · \(level) %"
        }
    }

    /// Lit up on its tile: on, an open blind, a cleaning vacuum.
    public var active: Bool {
        switch kind {
        case .blinds: level > 0
        case .vacuum: vacuum == .cleaning || vacuum == .returning
        default: on
        }
    }
}

public struct Room: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var temperature: Double
    public var humidity: Int
    public var outdoor = false
}

public struct HomeScene: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let symbol: String
}

public enum AlarmMode: String, Codable, CaseIterable, Sendable {
    case off, home, away, night
    public var title: String { ["Vypnutý", "Doma", "Preč", "Noc"][AlarmMode.allCases.firstIndex(of: self)!] }
    public var symbol: String { ["shield.slash", "house.fill", "figure.walk.departure", "moon.fill"][AlarmMode.allCases.firstIndex(of: self)!] }
}

struct DeviceState: Codable {
    var rooms: [Room]
    var devices: [Device]
    var frontDoorLocked = true
    var alarm = AlarmMode.home
    var activeScene: String?
    /// The flat before the active scene, so tapping the scene again undoes it.
    var beforeScene: Snapshot?

    struct Snapshot: Codable { var devices: [Device]; var locked: Bool; var alarm: AlarmMode }
}

@MainActor @Observable
public final class Devices {
    public static let scenes = [
        HomeScene(id: "morning", name: "Dobré ráno", symbol: "sunrise.fill"),
        HomeScene(id: "movie", name: "Film", symbol: "film.fill"),
        HomeScene(id: "workout", name: "Cvičenie", symbol: "figure.strengthtraining.traditional"),
        HomeScene(id: "leave", name: "Odchod", symbol: "figure.walk.departure"),
        HomeScene(id: "night", name: "Dobrú noc", symbol: "moon.stars.fill"),
        HomeScene(id: "off", name: "Zhasnúť všetko", symbol: "power"),
    ]

    private var s: DeviceState
    private let file: URL?

    public init(folder: URL? = Store.folder) {
        file = folder?.appendingPathComponent("devices.json")
        s = file.flatMap { try? JSONDecoder.iso.decode(DeviceState.self, from: Data(contentsOf: $0)) } ?? Devices.mockFlat()
    }

    public var rooms: [Room] { s.rooms }
    public var devices: [Device] { s.devices }
    public var frontDoorLocked: Bool { s.frontDoorLocked }
    public var alarm: AlarmMode { s.alarm }
    public var activeScene: String? { s.activeScene }
    public var isMock: Bool { true }

    public func devices(in room: Room) -> [Device] { s.devices.filter { $0.room == room.id } }
    public var lightsOn: [Device] { s.devices.filter { $0.isLighting && $0.on } }
    public var openBlinds: [Device] { s.devices.filter { $0.kind == .blinds && $0.level > 0 } }
    public var ac: Device? { s.devices.first { $0.kind == .ac } }
    public var vacuum: Device? { s.devices.first { $0.kind == .vacuum } }
    public var indoorAverage: Double {
        let r = s.rooms.filter { !$0.outdoor }
        return r.isEmpty ? 0 : r.map(\.temperature).reduce(0, +) / Double(r.count)
    }

    // MARK: Control

    public func toggle(_ d: Device) {
        update(d.id) { x in
            switch x.kind {
            case .blinds: x.level = x.level > 0 ? 0 : 100
            case .vacuum: x.vacuum = x.vacuum == .cleaning ? .docked : .cleaning; x.on = x.vacuum == .cleaning
            default: x.on.toggle()
            }
        }
    }

    public func setLevel(_ d: Device, _ level: Int) {
        update(d.id) { x in
            x.level = x.kind == .ac ? min(max(level, 16), 30) : min(max(level, 0), 100)
            if x.isLighting || x.kind == .speaker { x.on = x.level > 0 }
        }
    }

    public func setACMode(_ mode: ACMode) {
        guard let ac else { return }
        update(ac.id) { $0.acMode = mode; $0.on = true }
    }

    public func setRoomLights(_ room: Room, on: Bool) {
        for d in devices(in: room) where d.isLighting { update(d.id, save: false) { $0.on = on } }
        changed()
    }

    public func setFrontDoor(locked: Bool) { s.frontDoorLocked = locked; changed() }
    public func setAlarm(_ mode: AlarmMode) { s.alarm = mode; changed() }

    private func update(_ id: String, save: Bool = true, _ f: (inout Device) -> Void) {
        guard let i = s.devices.firstIndex(where: { $0.id == id }) else { return }
        f(&s.devices[i])
        if save { changed() }
    }

    /// Runs a scene; running the active one again undoes it (back to the flat before the first scene).
    public func run(scene id: String) {
        if s.activeScene == id, let b = s.beforeScene {
            s.devices = b.devices; s.frontDoorLocked = b.locked; s.alarm = b.alarm
            s.activeScene = nil; s.beforeScene = nil
            changed(); return
        }
        if s.activeScene == nil { s.beforeScene = .init(devices: s.devices, locked: s.frontDoorLocked, alarm: s.alarm) }
        s.devices = s.devices.map { d in
            var a = d
            switch id {
            case "off": if a.isLighting { a.on = false }
            case "night":
                if a.id == "b-bedside" { a.on = true; a.level = 15 }
                else if a.isLighting || a.kind == .tv || a.kind == .speaker || a.kind == .ac { a.on = false }
                else if a.kind == .blinds { a.level = 0 }
            case "movie":
                guard a.room == "living" else { break }
                if a.kind == .tv { a.on = true }
                else if a.id == "l-lamp" { a.on = true; a.level = 20 }
                else if a.kind == .light { a.on = false }
                else if a.kind == .blinds { a.level = 0 }
            case "workout":
                if a.id == "s-ceiling" { a.on = true; a.level = 100 }
                if a.id == "s-speaker" { a.on = true; a.level = 60 }
                if a.id == "s-blinds" { a.level = 100 }
            case "morning":
                if a.kind == .blinds { a.level = 100 }
                if a.id == "l-kitchen" { a.on = true; a.level = 80 }
            case "leave":
                if a.kind == .vacuum { if a.level >= 15 { a.vacuum = .cleaning; a.on = true } }
                else if a.kind != .blinds { a.on = false }
            default: break
            }
            return a
        }
        switch id {
        case "leave": s.alarm = .away; s.frontDoorLocked = true
        case "night": s.alarm = .night; s.frontDoorLocked = true
        case "morning": s.alarm = .home
        default: break
        }
        s.activeScene = id
        changed()
    }

    private func changed() {
        guard let file, let d = try? JSONEncoder.iso.encode(s) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: file, options: .atomic)
    }

    /// The flat as the Android panel had it: living room with the kitchen, bedroom, office/gym, bathroom, WC, hall, two balconies.
    static func mockFlat() -> DeviceState {
        func d(_ id: String, _ room: String, _ name: String, _ kind: DeviceKind, _ on: Bool, _ level: Int = 0) -> Device {
            Device(id: id, room: room, name: name, kind: kind, on: on, level: level)
        }
        return DeviceState(
            rooms: [
                Room(id: "living", name: "Obývačka a kuchyňa", temperature: 22.1, humidity: 45),
                Room(id: "bedroom", name: "Spálňa", temperature: 20.6, humidity: 47),
                Room(id: "studio", name: "Pracovňa a posilňovňa", temperature: 21.4, humidity: 42),
                Room(id: "bathroom", name: "Kúpeľňa", temperature: 23.5, humidity: 62),
                Room(id: "wc", name: "WC", temperature: 21.8, humidity: 50),
                Room(id: "hall", name: "Chodba", temperature: 21.2, humidity: 44),
                Room(id: "balcony-k", name: "Balkón pri kuchyni", temperature: 17.5, humidity: 68, outdoor: true),
                Room(id: "balcony-b", name: "Balkón pri spálni", temperature: 17.2, humidity: 70, outdoor: true),
            ],
            devices: [
                d("l-ceiling", "living", "Strop", .light, true, 80),
                d("l-kitchen", "living", "Kuchyňa", .light, true, 60),
                d("l-lamp", "living", "Stojaca lampa", .lamp, true, 40),
                d("l-ac", "living", "Klimatizácia", .ac, true, 22),
                d("l-blinds", "living", "Žalúzie balkón", .blinds, true, 100),
                d("l-blinds-2", "living", "Žalúzie okno 1", .blinds, true, 100),
                d("l-blinds-3", "living", "Žalúzie okno 2", .blinds, true, 100),
                d("l-speaker", "living", "Reproduktor", .speaker, true, 32),
                d("k-speaker", "living", "Reproduktor kuchyňa", .speaker, false, 25),
                d("l-tv", "living", "Televízor", .tv, false),
                d("b-ceiling", "bedroom", "Strop", .light, false, 70),
                d("b-bedside", "bedroom", "Nočná lampa", .lamp, false, 30),
                d("b-speaker", "bedroom", "Reproduktor", .speaker, false, 20),
                d("b-blinds", "bedroom", "Žalúzie", .blinds, true, 40),
                d("s-ceiling", "studio", "Strop", .light, false, 100),
                d("s-desk", "studio", "Stolová lampa", .lamp, true, 90),
                d("s-blinds", "studio", "Žalúzie", .blinds, true, 100),
                d("s-speaker", "studio", "Reproduktor", .speaker, false, 50),
                d("h-light", "hall", "Svetlo", .light, true, 50),
                d("h-vacuum", "hall", "Robotický vysávač", .vacuum, false, 100),
                d("ba-light", "bathroom", "Svetlo", .light, false, 100),
                d("ba-speaker", "bathroom", "Reproduktor", .speaker, false, 30),
                d("w-light", "wc", "Svetlo", .light, false, 100),
                d("bk-light", "balcony-k", "Svetlo", .light, false, 100),
                d("bb-light", "balcony-b", "Svetlo", .light, false, 100),
            ])
    }
}
