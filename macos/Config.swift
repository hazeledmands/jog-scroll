import Foundation

struct MidiMatch: Codable, Equatable, Hashable {
    var status: UInt8   // status byte including channel, e.g. 0x90 = note on ch 1
    var data1: UInt8    // note / controller number (0 for pitch bend, which has none)

    var description: String {
        let kind: String
        switch status & 0xF0 {
        case 0x80, 0x90: kind = "note"
        case 0xB0: kind = "CC"
        case 0xE0: return "pitch bend on channel \(Int(status & 0x0F) + 1)"
        default: kind = String(format: "0x%02X", status & 0xF0)
        }
        return "\(kind) \(data1) on channel \(Int(status & 0x0F) + 1)"
    }
}

/// Any JSON value, for request bodies and servers' answers.
enum JSON: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] } else { return nil }
    }
}

// Missing keys keep these defaults, so adding a setting never discards a learned control.
final class Config: Codable {
    var portName = "Reloop Ready"             // substring of the MIDI input name; "" = all inputs
    var connectionAlerts = true               // notify when the controller is plugged in or out
    var outputPortName: String?               // MIDI output for the controller's lights; worked out from portName if left out
    var servers: [String: ServerConfig] = [:] // where controls send their changes, by name
    var controls: [MidiControl] = []          // jog wheels, faders and knobs, and what each one does

    // Settings from before the jog wheel was a control. loadConfig moves them into one.
    var touch: MidiMatch?
    var jog: MidiMatch?
    var touchHoldSeconds: Double?
    var touchMultiplier: Double?
    var pixelsPerTick: Double?
    var invert: Bool?
    var centerThreshold: Int?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        portName = try c.decodeIfPresent(String.self, forKey: .portName) ?? portName
        connectionAlerts = try c.decodeIfPresent(Bool.self, forKey: .connectionAlerts) ?? connectionAlerts
        outputPortName = try c.decodeIfPresent(String.self, forKey: .outputPortName)
        servers = try c.decodeIfPresent([String: ServerConfig].self, forKey: .servers) ?? [:]
        controls = try c.decodeIfPresent([MidiControl].self, forKey: .controls) ?? []
        touch = try c.decodeIfPresent(MidiMatch.self, forKey: .touch)
        jog = try c.decodeIfPresent(MidiMatch.self, forKey: .jog)
        touchHoldSeconds = try c.decodeIfPresent(Double.self, forKey: .touchHoldSeconds)
        touchMultiplier = try c.decodeIfPresent(Double.self, forKey: .touchMultiplier)
        pixelsPerTick = try c.decodeIfPresent(Double.self, forKey: .pixelsPerTick)
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert)
        centerThreshold = try c.decodeIfPresent(Int.self, forKey: .centerThreshold)
    }

    /// The MIDI output for the controller's lights: outputPortName, or portName with "In" at the end changed to "Out".
    var outputPort: String {
        if let outputPortName { return outputPortName }
        return portName.lowercased().hasSuffix(" in") ? String(portName.dropLast(3)) + " Out" : portName
    }

    /// The jog wheel that the menu's Learn Jog Wheel is for: the first one.
    var mainJog: MidiControl? { controls.first { $0.isJog } }

    /// Moves the settings from before the jog wheel was a control into a jog control. Returns whether it changed anything.
    func migrate() -> Bool {
        if touch == nil && jog == nil && touchHoldSeconds == nil && touchMultiplier == nil
            && pixelsPerTick == nil && invert == nil && centerThreshold == nil { return false }
        if mainJog == nil {
            let control = MidiControl.newJog()
            control.midi = jog
            control.touch = touch
            control.touchHoldSeconds = touchHoldSeconds ?? control.touchHoldSeconds
            control.touchMultiplier = touchMultiplier ?? control.touchMultiplier
            control.centerThreshold = centerThreshold ?? control.centerThreshold
            control.invert = invert ?? false
            control.actions[0].pixelsPerTick = pixelsPerTick ?? control.actions[0].pixelsPerTick
            controls.insert(control, at: 0)
        }
        touch = nil; jog = nil
        touchHoldSeconds = nil; touchMultiplier = nil; pixelsPerTick = nil
        invert = nil
        centerThreshold = nil
        return true
    }
}

/// A server that controls send changes to. Its url and headers can use ${file:PATH#key} and ${env:NAME}.
final class ServerConfig: Codable {
    var type = "http"                         // the only kind so far
    var url = ""                              // action paths are added to this
    var headers: [String: String] = [:]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? type
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? url
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }
}

/// Something on the controller, and what it does. A jog wheel sends turns; a fader or knob sends its position.
final class MidiControl: Codable {
    var name = ""
    var type = "fader"                        // "fader" (also for knobs) or "jog"
    var midi: MidiMatch?                      // learned from the menu or `jog-scroll learn-control`
    var invert = false                        // a fader whose top sends the lowest value, or a jog turning the other way

    // Faders and knobs
    var fine: UInt8?                          // for a high-resolution fader: the CC with its fine value
    var low: Int?                             // the lowest and highest values it sends, found while learning
    var high: Int?

    // Jog wheels
    var touch: MidiMatch?                     // the sensor in the jog's top
    var touchMultiplier: Double?              // speed-up while the top is touched (Bome: if gt>0 then oo=10*oo)
    var touchHoldSeconds: Double?             // how long the speed-up lasts after letting go
    var centerThreshold: Int?                 // values below this are clockwise

    var actions: [ControlAction] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? type
        midi = try c.decodeIfPresent(MidiMatch.self, forKey: .midi)
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        fine = try c.decodeIfPresent(UInt8.self, forKey: .fine)
        low = try c.decodeIfPresent(Int.self, forKey: .low)
        high = try c.decodeIfPresent(Int.self, forKey: .high)
        touch = try c.decodeIfPresent(MidiMatch.self, forKey: .touch)
        touchMultiplier = try c.decodeIfPresent(Double.self, forKey: .touchMultiplier)
        touchHoldSeconds = try c.decodeIfPresent(Double.self, forKey: .touchHoldSeconds)
        centerThreshold = try c.decodeIfPresent(Int.self, forKey: .centerThreshold)
        actions = try c.decodeIfPresent([ControlAction].self, forKey: .actions) ?? []
    }

    var isJog: Bool { type.lowercased() == "jog" }
    var isFader: Bool { type.lowercased() == "fader" }

    /// A jog wheel that scrolls, with every setting written out so they're easy to find in the settings file.
    static func newJog() -> MidiControl {
        let jog = MidiControl()
        jog.name = "Jog"
        jog.type = "jog"
        jog.touchMultiplier = 10
        jog.touchHoldSeconds = 1.0
        jog.centerThreshold = 50
        let scroll = ControlAction()
        scroll.type = "scroll"
        scroll.pixelsPerTick = ScrollOutput.defaultPixelsPerTick
        jog.actions = [scroll]
        return jog
    }
}

/// One thing a control does when it moves. Either a request to a server, where "$value" in the path or body is
/// the control's position scaled to range (a body string that's exactly "$value" becomes a number), or, for
/// a jog wheel, scrolling.
final class ControlAction: Codable {
    var type: String?                         // "scroll", or leave it out for a request to a server

    // Requests
    var server: String?
    var method: String?                       // POST if left out
    var path: String?
    var body: JSON?
    var range: [Double]?                      // the value at the bottom and at the top; [0, 1] if left out
    var decimals: Int?
    var response: String?                     // where the number to show is in the answer: a key, or keys separated by dots
    var show: ShowConfig?                     // lights on the controller that show that number

    // Scrolling
    var pixelsPerTick: Double?                // scroll distance per jog tick; fractions accumulate

    init() {}

    var isScroll: Bool { type?.lowercased() == "scroll" }
}

/// Lights on the controller that show a number by lighting that many of them, for a moment. The number is the one
/// in the answer that response points to, or the value sent if there's no response.
final class ShowConfig: Codable {
    var lights: [MidiMatch] = []              // in order: the first lights for 1, the first two for 2…
    var on = 127                              // the value that lights one. On some controllers, it's the color
    var off = 0
    var seconds = 1.0                         // how long they stay lit after the last change

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lights = try c.decodeIfPresent([MidiMatch].self, forKey: .lights) ?? []
        on = try c.decodeIfPresent(Int.self, forKey: .on) ?? on
        off = try c.decodeIfPresent(Int.self, forKey: .off) ?? off
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? seconds
    }
}

let configURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/jog-scroll", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("config.json")
}()

func loadConfig() -> Config {
    guard let data = try? Data(contentsOf: configURL),
          let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
    if cfg.migrate() { saveConfig(cfg) }
    return cfg
}

func saveConfig(_ cfg: Config) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(cfg) { try? data.write(to: configURL) }
}

func configModified() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
}
