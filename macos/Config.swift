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
    var type = "fader"                        // "fader" (also for knobs), "jog" or "button"
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
    var isButton: Bool { type.lowercased() == "button" }

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
    var type: String?                         // "scroll", "keys", or leave it out for a request to a server

    // Requests
    var server: String?
    var method: String?                       // POST if left out
    var path: String?
    var body: JSON?
    var range: [Double]?                      // the value at the bottom and at the top; [0, 1] if left out
    var decimals: Int?
    var response: String?                     // where the number to show is in the answer: a key, or keys separated by dots
    var show: ShowConfig?                     // lights on the controller that show that number

    // Pressing keys, for a button
    var keys: String?                         // a key combination, like "ctrl+shift+option+p"
    var on: String?                           // "press" (if left out), "release", or "both"

    // Scrolling
    var pixelsPerTick: Double?                // scroll distance per jog tick; fractions accumulate
    var wheelUnitsPerTick: Double?            // the Windows version's setting, kept so a synced file doesn't lose it

    init() {}

    var isScroll: Bool { type?.lowercased() == "scroll" }
    var isKeys: Bool { type?.lowercased() == "keys" }
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

/// The settings are in two files: config.json, which can be synced between computers, and config.local.json
/// beside it, for settings that stay on this computer. The local file is optional, and wins where they overlap:
/// see mergeSettings.
struct ConfigFiles {
    var synced: URL
    var local: URL

    static let standard = ConfigFiles(synced: configURL,
                                      local: configURL.deletingLastPathComponent().appendingPathComponent("config.local.json"))
}

/// Why a settings file couldn't be read the last time they were loaded, and which file, or nil.
var configLoadError: String?
var configLoadErrorFile: URL?

/// Loads the settings, or the defaults if there's no settings file. If one of them can't be read, it returns
/// the defaults and sets configLoadError, and saveConfig won't write over either of them.
func loadConfig(_ files: ConfigFiles = .standard) -> Config {
    configLoadError = nil
    configLoadErrorFile = nil
    switch readSettings(files) {
    case .success(let (synced, local)):
        guard let cfg = try? decodeConfig(mergeSettings(synced: synced ?? .object([:]), local: local)) else { return Config() }
        if cfg.migrate() { saveConfig(cfg, files) }
        return cfg
    case .failure(let failure):
        configLoadError = describe(failure.error)
        configLoadErrorFile = failure.file
        return Config()
    }
}

private struct SettingsFileError: Error { var file: URL; var error: Error }

/// Both files as JSON, or nil for one that isn't there, after checking that each can be read as settings.
private func readSettings(_ files: ConfigFiles) -> Result<(synced: JSON?, local: JSON?), SettingsFileError> {
    func read(_ url: URL) -> Result<JSON?, SettingsFileError> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(nil) }
        return Result {
            let data = try Data(contentsOf: url)
            _ = try JSONDecoder().decode(Config.self, from: data)   // for errors that say which setting is wrong
            return try JSONDecoder().decode(JSON.self, from: data)
        }.mapError { SettingsFileError(file: url, error: $0) }
    }
    return read(files.synced).flatMap { synced in read(files.local).map { (synced, $0) } }
}

private func decodeConfig(_ json: JSON) throws -> Config {
    try JSONDecoder().decode(Config.self, from: try JSONEncoder().encode(json))
}

private func describe(_ error: Error) -> String {
    switch error {
    case DecodingError.dataCorrupted(let context): return context.underlyingError.map { "\($0.localizedDescription)" } ?? context.debugDescription
    case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context), DecodingError.keyNotFound(_, let context):
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    default: return error.localizedDescription
    }
}

/// Saves the settings, each to the file it came from, unless one of the files can't be read. That's usually a
/// hand edit with a typo, and writing over it would lose it: everywhere, if the file is synced to other computers.
/// The local file is only written if there is one.
func saveConfig(_ cfg: Config, _ files: ConfigFiles = .standard) {
    guard case .success(let (synced, local)) = readSettings(files),
          let data = try? JSONEncoder().encode(cfg),
          let merged = try? JSONDecoder().decode(JSON.self, from: data) else { return }
    let (syncedOut, localOut) = splitSettings(merged, synced: synced ?? .object([:]), local: local)
    try? Data(canonicalJSON(syncedOut).utf8).write(to: files.synced)
    if let localOut { try? Data(canonicalJSON(localOut).utf8).write(to: files.local) }
}

/// The synced settings with the local ones over them. A setting in the local file wins. A server in the local file
/// replaces the synced server with its name. A control in the local file replaces the synced control with its name,
/// ignoring case, where that one is, and the rest go at the end. Nothing inside a server or control is merged.
/// macos/Config.swift and windows/Config.cs do this the same way; change both together.
func mergeSettings(synced: JSON, local: JSON?) -> JSON {
    guard case .object(var merged) = synced, case .object(let local)? = local else { return synced }
    for (key, value) in local {
        switch (key, merged[key], value) {
        case ("servers", .object(var servers)?, .object(let localServers)):
            servers.merge(localServers) { _, new in new }
            merged[key] = .object(servers)
        case ("controls", .array(var controls)?, .array(let localControls)):
            for control in localControls {
                if let i = controls.firstIndex(where: { sameName($0, control) }) { controls[i] = control }
                else { controls.append(control) }
            }
            merged[key] = .array(controls)
        default:
            merged[key] = value
        }
    }
    return .object(merged)
}

/// Splits settings that mergeSettings made, perhaps changed since, back into the two files. `synced` and `local`
/// are the files as they are now: the synced file keeps what the local file overrides, and everything else that's
/// in the local file goes back to it. New settings, servers and controls go to the synced file.
func splitSettings(_ merged: JSON, synced: JSON, local: JSON?) -> (synced: JSON, local: JSON?) {
    guard case .object(let merged) = merged, case .object(let local)? = local else { return (merged, nil) }
    let syncedFields: [String: JSON]
    if case .object(let o) = synced { syncedFields = o } else { syncedFields = [:] }
    var syncedOut: [String: JSON] = [:], localOut: [String: JSON] = [:]

    for (key, value) in merged {
        switch (key, value) {
        case ("servers", .object(let servers)):
            var localNames: Set<String> = []
            if case .object(let s)? = local[key] { localNames = Set(s.keys) }
            var mine: [String: JSON] = [:], theirs: [String: JSON] = [:]
            if case .object(let s)? = syncedFields[key] { theirs = s.filter { localNames.contains($0.key) } }
            for (name, server) in servers {
                if localNames.contains(name) { mine[name] = server } else { theirs[name] = server }
            }
            if local[key] != nil { localOut[key] = .object(mine) }
            if syncedFields[key] != nil || !theirs.isEmpty || local[key] == nil { syncedOut[key] = .object(theirs) }
        case ("controls", .array(let controls)):
            var localControls: [JSON] = []
            if case .array(let c)? = local[key] { localControls = c }
            var syncedControls: [JSON] = []
            if case .array(let c)? = syncedFields[key] { syncedControls = c }
            var mine: [(index: Int, control: JSON)] = [], theirs: [JSON] = []
            for control in controls {
                if let i = localControls.firstIndex(where: { sameName($0, control) }) {
                    mine.append((i, control))
                    if let overridden = syncedControls.first(where: { sameName($0, control) }) { theirs.append(overridden) }
                } else {
                    theirs.append(control)
                }
            }
            if local[key] != nil { localOut[key] = .array(mine.sorted { $0.index < $1.index }.map(\.control)) }
            if syncedFields[key] != nil || !theirs.isEmpty || local[key] == nil { syncedOut[key] = .array(theirs) }
        default:
            if local[key] != nil {
                localOut[key] = value
                if let overridden = syncedFields[key] { syncedOut[key] = overridden }
            } else {
                syncedOut[key] = value
            }
        }
    }
    return (.object(syncedOut), .object(localOut))
}

private func sameName(_ a: JSON, _ b: JSON) -> Bool {
    guard case .string(let x)? = a["name"], case .string(let y)? = b["name"] else { return false }
    return x.lowercased() == y.lowercased()
}

/// JSON written exactly as the Windows version writes it (ConfigFile.Serialize in windows/Config.cs), so a file
/// synced between the two only changes where a setting did: keys in ordinal order, two-space indents,
/// `"key": value`, \n line endings, and only the characters JSON requires escaped.
func canonicalJSON(_ value: JSON) -> String { writeJSON(value, indent: "") + "\n" }

private func writeJSON(_ value: JSON, indent: String) -> String {
    let inner = indent + "  "
    switch value {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n):
        // Whole numbers without ".0", like .NET. Others in the shortest form that reads back the same.
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return "\(n)"
    case .string(let s): return quoted(s)
    case .array(let items):
        if items.isEmpty { return "[]" }
        return "[\n" + items.map { inner + writeJSON($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
    case .object(let fields):
        if fields.isEmpty { return "{}" }
        // .NET's StringComparer.Ordinal compares UTF-16 code units.
        let keys = fields.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        return "{\n" + keys.map { inner + quoted($0) + ": " + writeJSON(fields[$0]!, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "}"
    }
}

private func quoted(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{8}": out += "\\b"
        case "\u{C}": out += "\\f"
        default:
            if c.value < 0x20 { out += String(format: "\\u%04X", c.value) }
            else { out.unicodeScalars.append(c) }
        }
    }
    return out + "\""
}

/// When each settings file last changed, to notice edits to either.
func configModified(_ files: ConfigFiles = .standard) -> [Date?] {
    [files.synced, files.local].map { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
}
