// Tests for the macOS version, run by macos/test.sh. It compiles every Swift file in macos/ except main.swift
// together with this one, so there's no test framework to install: each check prints what went wrong.
// windows/Tests is the same for the Windows version; change both together.
import Foundation

var failures = 0

func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
    if !ok {
        failures += 1
        print("FAIL \(line): \(what)")
    }
}

func checkEqual(_ got: JSON?, _ want: JSON?, _ what: String, line: UInt = #line) {
    check(got == want, "\(what)\n  got:  \(got.map(canonicalJSON) ?? "nil\n")  want: \(want.map(canonicalJSON) ?? "nil\n")", line: line)
}

func json(_ text: String) -> JSON { try! JSONDecoder().decode(JSON.self, from: Data(text.utf8)) }

// MARK: - mergeSettings

do {
    let synced = json(#"{"portName": "Reloop Ready", "controls": [{"name": "Jog", "type": "jog"}]}"#)
    checkEqual(mergeSettings(synced: synced, local: nil), synced, "no local file: the synced settings as they are")
}

do {
    let merged = mergeSettings(synced: json(#"{"portName": "Reloop Ready", "connectionAlerts": true}"#),
                               local: json(#"{"connectionAlerts": false, "outputPortName": "Lights"}"#))
    checkEqual(merged, json(#"{"portName": "Reloop Ready", "connectionAlerts": false, "outputPortName": "Lights"}"#),
               "settings in the local file win")
}

do {
    let merged = mergeSettings(
        synced: json(#"{"servers": {"hue": {"url": "http://a/", "headers": {"X": "1"}}, "other": {"url": "http://o/"}}}"#),
        local: json(#"{"servers": {"hue": {"url": "http://b/"}, "zoom": {"url": "http://z/"}}}"#))
    checkEqual(merged, json(#"{"servers": {"hue": {"url": "http://b/"}, "other": {"url": "http://o/"}, "zoom": {"url": "http://z/"}}}"#),
               "a local server replaces the whole synced server with its name, and others are added")
}

do {
    let merged = mergeSettings(
        synced: json(#"{"controls": [{"name": "Jog", "type": "jog"}, {"name": "Desk", "invert": false}, {"name": "Scope"}]}"#),
        local: json(#"{"controls": [{"name": "Mute"}, {"name": "desk", "invert": true}]}"#))
    checkEqual(merged, json(#"{"controls": [{"name": "Jog", "type": "jog"}, {"name": "desk", "invert": true}, {"name": "Scope"}, {"name": "Mute"}]}"#),
               "a local control replaces the synced control with its name (ignoring case) where it is, and others go at the end")
}

do {
    let merged = mergeSettings(synced: json("{}"), local: json(#"{"controls": [{"name": "Mute"}], "servers": {"z": {}}}"#))
    checkEqual(merged, json(#"{"controls": [{"name": "Mute"}], "servers": {"z": {}}}"#), "only a local file")
}

// MARK: - splitSettings

do {
    let merged = json(#"{"portName": "X", "controls": [{"name": "Jog"}]}"#)
    let (synced, local) = splitSettings(merged, synced: json("{}"), local: nil)
    checkEqual(synced, merged, "no local file: everything is synced")
    checkEqual(local, nil, "no local file: nothing to write locally")
}

do {
    let synced = json(#"{"portName": "Reloop Ready", "connectionAlerts": true, "servers": {"hue": {"url": "http://a/"}}, "controls": [{"name": "Jog", "type": "jog"}, {"name": "Desk", "invert": false}]}"#)
    let local = json(#"{"connectionAlerts": false, "servers": {"hue": {"url": "http://b/"}}, "controls": [{"name": "Desk", "invert": true}]}"#)
    // What the app does: learns the local Desk fader, then adds a new jog wheel at the start.
    var merged = mergeSettings(synced: synced, local: local)
    guard case .object(var o) = merged, case .array(var controls)? = o["controls"] else { fatalError() }
    controls[1] = json(#"{"name": "Desk", "invert": true, "low": 3}"#)
    controls.insert(json(#"{"name": "Jog 2", "type": "jog"}"#), at: 0)
    o["controls"] = .array(controls)
    o["portName"] = .string("Reloop Ready In")
    merged = .object(o)

    let (syncedOut, localOut) = splitSettings(merged, synced: synced, local: local)
    checkEqual(syncedOut, json(#"{"portName": "Reloop Ready In", "connectionAlerts": true, "servers": {"hue": {"url": "http://a/"}}, "controls": [{"name": "Jog 2", "type": "jog"}, {"name": "Jog", "type": "jog"}, {"name": "Desk", "invert": false}]}"#),
               "changes to synced settings and new controls go to the synced file, which keeps what the local file overrides")
    checkEqual(localOut, json(#"{"connectionAlerts": false, "servers": {"hue": {"url": "http://b/"}}, "controls": [{"name": "Desk", "invert": true, "low": 3}]}"#),
               "changes to a local control go to the local file")
}

do {
    let synced = json(#"{"controls": [{"name": "A"}, {"name": "B"}]}"#)
    let local = json(#"{"controls": [{"name": "b", "x": 1}, {"name": "Z"}, {"name": "a", "x": 2}]}"#)
    let (s, l) = splitSettings(mergeSettings(synced: synced, local: local), synced: synced, local: local)
    checkEqual(s, synced, "synced controls stay in their order")
    checkEqual(l, local, "local controls stay in their order, though the merged ones follow the synced order")
}

do {
    let synced = json(#"{"controls": [{"name": "Jog"}]}"#)
    let local = json(#"{"portName": "Here"}"#)
    let (s, l) = splitSettings(mergeSettings(synced: synced, local: local), synced: synced, local: local)
    checkEqual(s, synced, "a local file without controls or servers")
    checkEqual(l, local, "a local file without controls or servers keeps not having them")
}

// Property: splitting merged settings without changing them gives back both files, for any pair of files
// without two controls of the same name in one file.
do {
    var rng = SystemRandomNumberGenerator()
    let names = ["Jog", "jog", "Desk", "DESK", "Scope", "Mute", "Puck", "Dictate"]
    let keys = ["portName", "connectionAlerts", "outputPortName"]
    func randomFile() -> JSON {
        var o: [String: JSON] = [:]
        for key in keys where Bool.random(using: &rng) { o[key] = .string("\(key)-\(Int.random(in: 0..<3, using: &rng))") }
        if Bool.random(using: &rng) {
            var servers: [String: JSON] = [:]
            for s in ["hue", "zoom", "amp"] where Bool.random(using: &rng) { servers[s] = .object(["url": .string("http://\(Int.random(in: 0..<9, using: &rng))/")]) }
            o["servers"] = .object(servers)
        }
        if Bool.random(using: &rng) {
            var seen = Set<String>()
            var controls: [JSON] = []
            for name in names.shuffled(using: &rng).prefix(Int.random(in: 0...5, using: &rng)) where seen.insert(name.lowercased()).inserted {
                controls.append(.object(["name": .string(name), "n": .number(Double(Int.random(in: 0..<9, using: &rng)))]))
            }
            o["controls"] = .array(controls)
        }
        return .object(o)
    }
    for _ in 0..<2000 {
        let synced = randomFile()
        let local: JSON? = Bool.random(using: &rng) ? randomFile() : nil
        let (s, l) = splitSettings(mergeSettings(synced: synced, local: local), synced: synced, local: local)
        checkEqual(s, synced, "round trip: synced file (local: \(local.map(canonicalJSON) ?? "none"))")
        checkEqual(l, local, "round trip: local file (synced: \(canonicalJSON(synced)))")
        if s != synced || l != local { break }
    }
}

// MARK: - Loading and saving both files

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jog-scroll-tests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let files = ConfigFiles(synced: dir.appendingPathComponent("config.json"), local: dir.appendingPathComponent("config.local.json"))

func write(_ url: URL, _ text: String) { try! Data(text.utf8).write(to: url) }
func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
func reset() {
    try? FileManager.default.removeItem(at: files.synced)
    try? FileManager.default.removeItem(at: files.local)
}

do {
    reset()
    write(files.synced, #"{"portName": "Reloop Ready", "controls": [{"name": "Jog", "type": "jog", "actions": [{"type": "scroll", "pixelsPerTick": 4}]}]}"#)
    write(files.local, #"{"servers": {"amp": {"url": "http://localhost:1/"}}, "controls": [{"name": "Puck", "type": "button"}]}"#)
    let cfg = loadConfig(files)
    check(configLoadError == nil, "both files load: \(configLoadError ?? "")")
    check(cfg.controls.map(\.name) == ["Jog", "Puck"], "controls from both files: \(cfg.controls.map(\.name))")
    check(cfg.servers["amp"]?.url == "http://localhost:1/", "servers from the local file")

    cfg.controls[1].midi = MidiMatch(status: 0x90, data1: 7)
    cfg.controls[0].invert = true
    saveConfig(cfg, files)
    let local = json(read(files.local) ?? "null")
    check(local["controls"] == json(#"[{"actions": [], "invert": false, "midi": {"data1": 7, "status": 144}, "name": "Puck", "type": "button"}]"#),
          "a learned local control is saved to the local file: \(canonicalJSON(local))")
    check(json(read(files.synced) ?? "null")["controls"].map(canonicalJSON)?.contains("\"invert\": true") == true, "a synced change is saved to the synced file")
    check(json(read(files.synced) ?? "null")["servers"] == nil, "the local server isn't saved to the synced file")
}

do {
    reset()
    write(files.synced, #"{"portName": "Reloop Ready"}"#)
    saveConfig(loadConfig(files), files)
    check(!FileManager.default.fileExists(atPath: files.local.path), "saving doesn't make a local file there wasn't one")
}

do {
    reset()
    let syncedText = #"{"portName": "Reloop Ready"}"#, localText = #"{"controls": [{"name": "Puck"}"#
    write(files.synced, syncedText)
    write(files.local, localText)
    let cfg = loadConfig(files)
    check(configLoadError != nil, "a local file that can't be read is an error")
    check(configLoadErrorFile == files.local, "the error is about the local file")
    check(cfg.controls.isEmpty && cfg.portName == "Reloop Ready", "the defaults, when a file can't be read")
    cfg.portName = "Changed"
    saveConfig(cfg, files)
    check(read(files.synced) == syncedText && read(files.local) == localText, "neither file is saved while one can't be read")
}

do {
    reset()
    write(files.synced, #"{"controls": 3}"#)
    _ = loadConfig(files)
    check(configLoadErrorFile == files.synced && configLoadError?.contains("controls") == true,
          "an error in the synced file says where: \(configLoadError ?? "nil")")
}

do {
    reset()
    write(files.synced, "{}")
    let before = configModified(files)
    Thread.sleep(forTimeInterval: 0.02)
    write(files.local, "{}")
    check(configModified(files) != before, "a new local file counts as a change to the settings")
}

if failures > 0 {
    print("\(failures) failed")
    exit(1)
}
print("All tests passed")
