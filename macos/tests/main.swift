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

// MARK: - Key combinations

do {
    let cases: [(String, KeyCombo?)] = [
        ("ctrl+shift+option+p", KeyCombo(key: 35, flags: [.maskControl, .maskShift, .maskAlternate])),
        (" Control + Alt + Shift + P ", KeyCombo(key: 35, flags: [.maskControl, .maskShift, .maskAlternate])),
        ("cmd+space", KeyCombo(key: 49, flags: [.maskCommand])),
        ("command+shift+4", KeyCombo(key: 21, flags: [.maskCommand, .maskShift])),
        ("f5", KeyCombo(key: 96, flags: [])),
        ("opt+escape", KeyCombo(key: 53, flags: [.maskAlternate])),
        ("ctrl+/", KeyCombo(key: 44, flags: [.maskControl])),
        ("", nil),
        ("ctrl+shift", nil),
        ("p+q", nil),
        ("hyper+p", nil),
        ("ctrl++p", nil),
    ]
    for (text, want) in cases {
        let got = try? KeyCombo(text)
        check(got == want, "KeyCombo(\"\(text)\"): got \(String(describing: got)), want \(String(describing: want))")
    }
    do { _ = try KeyCombo("hyper+p"); check(false, "an unknown key is an error") }
    catch { check("\(error)".contains("hyper"), "the error names the unknown key: \(error)") }
}

// MARK: - Buttons

func note(_ on: Bool, _ number: UInt8, velocity: UInt8 = 127) -> MidiMessage {
    MidiMessage(status: on ? 0x90 : 0x80, data1: number, data2: velocity, source: "Reloop Ready")
}

func keysAction(_ keys: String, on: String? = nil) -> ControlAction {
    let action = ControlAction()
    action.type = "keys"
    action.keys = keys
    action.on = on
    return action
}

func button(_ actions: [ControlAction], midi: MidiMatch = MidiMatch(status: 0x90, data1: 7)) -> MidiControl {
    let control = MidiControl()
    control.name = "Puck"
    control.type = "button"
    control.midi = midi
    control.actions = actions
    return control
}

/// Sends the messages to a button with these actions, and returns the key combinations it pressed, as the
/// action's keys, and the errors it reported.
func pressed(_ actions: [ControlAction], _ messages: [MidiMessage], midi: MidiMatch = MidiMatch(status: 0x90, data1: 7)) -> (keys: [String], errors: [String]) {
    var keys: [String] = [], errors: [String] = []
    let output = KeyOutput { _, error in if let error { errors.append(error) } }
    output.post = { combo in keys.append(actions.first { (try? KeyCombo($0.keys ?? "")) == combo }?.keys ?? "?") }
    let b = Button(control: button(actions, midi: midi), keys: output)
    for m in messages { b.handle(m) }
    return (keys, errors)
}

do {
    let puck = "ctrl+shift+option+p"
    check(pressed([keysAction(puck)], [note(true, 7), note(false, 7)]).keys == [puck], "by default, keys are pressed when the button is")
    check(pressed([keysAction(puck, on: "release")], [note(true, 7), note(false, 7)]).keys == [puck], "on release")
    check(pressed([keysAction(puck, on: "both")], [note(true, 7), note(false, 7), note(true, 7), note(false, 7)]).keys == [puck, puck, puck, puck],
          "on both: pressing shows Puck and letting go hides it")
    check(pressed([keysAction(puck, on: "both")], [note(true, 7), note(true, 7, velocity: 0)]).keys == [puck, puck],
          "a note on with velocity 0 is letting go")
    check(pressed([keysAction(puck, on: "both")], [note(true, 7), note(true, 7)]).keys == [puck], "a repeated press counts once")
    check(pressed([keysAction(puck, on: "both")], [note(false, 7)]).keys.isEmpty,
          "letting go without a press does nothing, such as just after learning the button")
    check(pressed([keysAction(puck, on: "both")], [note(true, 8), note(false, 8)]).keys.isEmpty, "other notes do nothing")
    check(pressed([keysAction(puck, on: "both")],
                  [MidiMessage(status: 0x91, data1: 7, data2: 127, source: "")]).keys.isEmpty, "the same note on another channel does nothing")
    let cc = MidiMatch(status: 0xB0, data1: 20)
    check(pressed([keysAction(puck, on: "both")],
                  [MidiMessage(status: 0xB0, data1: 20, data2: 127, source: ""), MidiMessage(status: 0xB0, data1: 20, data2: 0, source: "")],
                  midi: cc).keys == [puck, puck], "a button that sends a CC")
    check(pressed([keysAction("ctrl+a"), keysAction("ctrl+b", on: "release")], [note(true, 7), note(false, 7)]).keys == ["ctrl+a", "ctrl+b"],
          "each action in turn")

    let bad = pressed([keysAction("hyper+p")], [note(true, 7)])
    check(bad.keys.isEmpty && bad.errors.contains { $0.contains("Puck") && $0.contains("hyper") }, "unknown keys are reported: \(bad.errors)")
    let badOn = pressed([keysAction(puck, on: "hold")], [note(true, 7)])
    check(badOn.keys.isEmpty && badOn.errors.contains { $0.contains("hold") }, "an unknown \"on\" is reported: \(badOn.errors)")
    let request = ControlAction()
    request.server = "hue"
    check(!pressed([request], [note(true, 7)]).errors.isEmpty, "a button can't send requests yet, and says so")
}

do {
    let outputs = Outputs(servers: { [:] }, outputPort: { "" })
    var errors: [String] = []
    outputs.onResult = { _, error in if let error { errors.append(error) } }
    outputs.setPosition(button([]), keysAction("ctrl+a"), position: 0.5)
    outputs.turn(button([]), keysAction("ctrl+a"), ticks: 1)
    check(errors.count == 2 && errors.allSatisfy { $0.contains("only a button") }, "faders and jog wheels say only a button presses keys: \(errors)")
}

// MARK: - Learning a button

do {
    let cfg = Config()
    let jog = MidiControl.newJog()
    jog.midi = MidiMatch(status: 0xB0, data1: 33)
    jog.touch = MidiMatch(status: 0x90, data1: 54)
    let puck = button([])
    puck.midi = nil
    cfg.controls = [jog, puck]
    let learner = ButtonLearner(control: puck, cfg: cfg)
    var done = false
    learner.done = { done = true }
    learner.handle(note(true, 54))    // touching the jog wheel
    learner.handle(MidiMessage(status: 0xB0, data1: 33, data2: 1, source: ""))
    learner.handle(note(false, 9))    // letting go of something pressed before learning started
    check(!done && puck.midi == nil, "learning ignores the jog wheel and letting go")
    learner.handle(note(true, 9))
    check(done && puck.midi == MidiMatch(status: 0x90, data1: 9), "the first press is the button: \(String(describing: puck.midi))")
    check(ControlRouter(cfg: cfg).canLearn(puck), "buttons can be learned")
}

if failures > 0 {
    print("\(failures) failed")
    exit(1)
}
print("All tests passed")
