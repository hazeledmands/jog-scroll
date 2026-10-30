// jog-scroll: turn a DJ controller's jog wheel into mouse-wheel scrolling.
//
// A standalone replacement for this Bome MIDI Translator project:
//   - touching the jog top sets a "fast" flag
//   - releasing it clears the flag after a 1 s delay
//   - jog ticks become scroll-wheel events (x10 while the flag is set)
//
// Usage:
//   jog-scroll              menu bar app (what runs at login)
//   jog-scroll run          same, without the menu bar icon, logging to the terminal
//   jog-scroll learn        record which MIDI messages your jog wheel sends
//   jog-scroll monitor      print every incoming MIDI message
//   jog-scroll login on|off start (or stop starting) the menu bar app at login

import Foundation
import AppKit
import CoreMIDI
import CoreGraphics
import ApplicationServices

// MARK: - Config

struct MidiMatch: Codable, Equatable {
    var status: UInt8   // status byte including channel, e.g. 0x90 = note on ch 1
    var data1: UInt8    // note / controller number

    var description: String {
        let kind: String
        switch status & 0xF0 {
        case 0x80, 0x90: kind = "note"
        case 0xB0: kind = "CC"
        default: kind = String(format: "0x%02X", status & 0xF0)
        }
        return "\(kind) \(data1) on channel \(Int(status & 0x0F) + 1)"
    }
}

struct Config: Codable, Equatable {
    var portName: String = "Reloop Ready"   // substring of the MIDI input name; "" = all inputs
    var touch: MidiMatch? = nil
    var jog: MidiMatch? = nil
    var touchHoldSeconds: Double = 1.0      // how long "fast" lasts after releasing the jog top
    var touchMultiplier: Int = 10           // Bome: if gt>0 then oo=10*oo
    var scale: Int = 1                      // overall multiplier on every tick
    var invert: Bool = false                // flip scroll direction
    var centerThreshold: Int = 50           // Bome: values below this are clockwise
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
    return cfg
}

func saveConfig(_ cfg: Config) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(cfg) { try? data.write(to: configURL) }
}

func configModified() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
}

// MARK: - MIDI input

struct MidiMessage {
    var status: UInt8
    var data1: UInt8
    var data2: UInt8
    var source: String
}

/// Listens to every MIDI source and reconnects when devices are plugged in or out.
final class MidiInput {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef] = []
    private(set) var sourceNames: [String] = []
    private let handler: (MidiMessage) -> Void
    var onSourcesChanged: (() -> Void)?
    var verbose = true

    init(handler: @escaping (MidiMessage) -> Void) {
        self.handler = handler

        MIDIClientCreateWithBlock("jog-scroll" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectSources() }
            }
        }
        MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { [weak self] packets, srcRef in
            let source = srcRef.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
            for packet in packets.unsafeSequence() {
                self?.parse(packet, source: source)
            }
        }
        connectSources()
    }

    func connectSources() {
        for src in connected { MIDIPortDisconnectSource(port, src) }
        connected.removeAll()
        sourceNames.removeAll()
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            let name = endpointName(src)
            // The connection refCon carries the source name to the read block.
            let ref = Unmanaged.passRetained(name as CFString).toOpaque()
            if MIDIPortConnectSource(port, src, ref) == noErr {
                connected.append(src)
                sourceNames.append(name)
                if verbose { log("Listening to \"\(name)\"") }
            }
        }
        if connected.isEmpty && verbose { log("No MIDI inputs found. Waiting for a device…") }
        onSourcesChanged?()
    }

    private func parse(_ packet: UnsafePointer<MIDIPacket>, source: String) {
        let length = Int(packet.pointee.length)
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
        let bytes = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)

        var i = 0
        var running: UInt8 = 0
        while i < length {
            let b = bytes[i]
            if b >= 0xF8 { i += 1; continue }                 // realtime
            if b >= 0xF0 {                                    // sysex / system common: skip to next status
                i += 1
                while i < length && bytes[i] < 0x80 { i += 1 }
                running = 0
                continue
            }
            if b >= 0x80 { running = b; i += 1 }
            guard running != 0 else { i += 1; continue }
            let type = running & 0xF0
            let size = (type == 0xC0 || type == 0xD0) ? 1 : 2
            guard i + size <= length else { break }
            let d1 = bytes[i]
            let d2 = size == 2 ? bytes[i + 1] : 0
            i += size
            let msg = MidiMessage(status: running, data1: d1, data2: d2, source: source)
            DispatchQueue.main.async { self.handler(msg) }
        }
    }
}

func endpointName(_ ep: MIDIEndpointRef) -> String {
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &name)
    return (name?.takeRetainedValue() as String?) ?? "Unknown"
}

func log(_ s: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(ts)] \(s)")
    fflush(stdout)
}

func hex(_ m: MidiMessage) -> String {
    String(format: "%02X %02X %02X", m.status, m.data1, m.data2)
}

// MARK: - Scrolling engine

func isTouchMessage(_ m: MidiMessage, _ t: MidiMatch) -> Bool {
    guard m.data1 == t.data1, m.status & 0x0F == t.status & 0x0F else { return false }
    let type = m.status & 0xF0, learned = t.status & 0xF0
    if learned == 0x90 || learned == 0x80 { return type == 0x90 || type == 0x80 }
    return type == learned
}

func isTouchDown(_ m: MidiMessage) -> Bool {
    switch m.status & 0xF0 {
    case 0x80: return false
    case 0x90: return m.data2 > 0
    default:   return m.data2 >= 64
    }
}

func scroll(lines: Int) {
    guard lines != 0 else { return }
    let clamped = Int32(max(-1000, min(1000, lines)))
    CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: clamped, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
}

/// The Bome translators, plus the "learn" flow. Everything runs on the main queue.
final class JogEngine {
    enum LearnStep { case none, touch, spin }

    var cfg: Config
    var enabled = true { didSet { onChange?() } }
    private(set) var fast = false { didSet { if fast != oldValue { onChange?() } } }   // Bome's "gt"
    private(set) var learnStep: LearnStep = .none { didSet { onChange?() } }
    var onChange: (() -> Void)?
    var onLearned: (() -> Void)?

    private var releaseTimer: DispatchWorkItem?
    private var candidate: MidiMatch?
    private var candidateCount = 0

    init(cfg: Config) { self.cfg = cfg }

    var isConfigured: Bool { cfg.touch != nil && cfg.jog != nil }

    func matchesPort(_ name: String) -> Bool {
        cfg.portName.isEmpty || name.lowercased().contains(cfg.portName.lowercased())
    }

    func startLearning() {
        candidate = nil
        candidateCount = 0
        learnStep = .touch
    }

    func cancelLearning() { learnStep = .none }

    func handle(_ m: MidiMessage) {
        if learnStep != .none { learn(m); return }
        guard matchesPort(m.source), let touch = cfg.touch, let jog = cfg.jog else { return }

        if isTouchMessage(m, touch) {
            releaseTimer?.cancel()  // re-touching within the hold window keeps it fast
            if isTouchDown(m) {
                fast = true
            } else {
                let work = DispatchWorkItem { [weak self] in self?.fast = false }
                releaseTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + cfg.touchHoldSeconds, execute: work)
            }
            return
        }
        guard enabled, m.status == jog.status, m.data1 == jog.data1 else { return }

        // Relative jog: small values = clockwise, values near 128 = counter-clockwise.
        let v = Int(m.data2)
        var ticks = v < cfg.centerThreshold ? v : -(128 - v)
        if fast { ticks *= cfg.touchMultiplier }
        ticks *= cfg.scale
        if cfg.invert { ticks = -ticks }
        scroll(lines: ticks)
    }

    private func learn(_ m: MidiMessage) {
        let type = m.status & 0xF0
        guard type == 0x80 || type == 0x90 || type == 0xB0 else { return }
        switch learnStep {
        case .touch:
            // Take the first note/CC press as the touch sensor.
            guard isTouchDown(m) else { return }
            cfg.touch = MidiMatch(status: m.status, data1: m.data1)
            cfg.portName = m.source
            learnStep = .spin
        case .spin:
            // Wait for the same controller to repeat a few times so a stray button doesn't count.
            guard type == 0xB0, let t = cfg.touch, !isTouchMessage(m, t) else { return }
            let match = MidiMatch(status: m.status, data1: m.data1)
            if match == candidate { candidateCount += 1 } else { candidate = match; candidateCount = 1 }
            if candidateCount >= 5 {
                cfg.jog = match
                saveConfig(cfg)
                learnStep = .none
                onLearned?()
            }
        case .none:
            break
        }
    }
}

// MARK: - Login item (a LaunchAgent, so macOS starts it at login and restarts it if it crashes)

let agentLabel = "local.jog-scroll"
let agentURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")

var startsAtLogin: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

func setStartsAtLogin(_ on: Bool) {
    guard on else { try? FileManager.default.removeItem(at: agentURL); return }
    let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [executable],
        "RunAtLoad": true,
        "KeepAlive": ["SuccessfulExit": false],   // restart after a crash, not after Quit
        "ProcessType": "Interactive",
    ]
    try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
        try? data.write(to: agentURL)
    }
}

// MARK: - Menu bar app

final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = JogEngine(cfg: loadConfig())
    private var input: MidiInput!
    private var statusItem: NSStatusItem!
    private var trusted = false
    private var banner: String?
    private var configDate = configModified()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        engine.onChange = { [weak self] in self?.refresh() }
        engine.onLearned = { [weak self] in self?.showBanner("Learned ✓") }
        input = MidiInput { [weak self] m in self?.engine.handle(m) }
        input.verbose = false
        input.onSourcesChanged = { [weak self] in self?.refresh() }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)

        // Every 2 s: notice Accessibility being granted, and pick up hand edits to config.json.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }

        if !engine.isConfigured { engine.startLearning() }
        refresh()
    }

    private func poll() {
        if !trusted && AXIsProcessTrusted() {
            // Scroll events from a process that wasn't trusted at launch can be dropped, so relaunch once.
            relaunch()
        }
        let date = configModified()
        if date != configDate && engine.learnStep == .none {
            configDate = date
            engine.cfg = loadConfig()
            refresh()
        }
    }

    private var deviceConnected: Bool { input.sourceNames.contains(where: engine.matchesPort) }

    private func refresh() {
        guard let button = statusItem.button else { return }
        let symbol = !engine.enabled ? "dial.min" : engine.fast ? "dial.high.fill" : "dial.medium"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jog Scroll")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: "Jog Scroll")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.appearsDisabled = !engine.enabled || !deviceConnected || !trusted

        switch engine.learnStep {
        case .touch: button.title = " Touch the jog top"
        case .spin:  button.title = " Now spin the jog edge"
        case .none:  button.title = banner.map { " " + $0 } ?? (trusted ? "" : " ⚠︎")
        }
    }

    private func showBanner(_ text: String) {
        banner = text
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.banner = nil
            self?.refresh()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if !engine.isConfigured && engine.learnStep == .none { status = "Jog wheel not learned yet" }
        else if deviceConnected { status = "Connected: \(engine.cfg.portName)" }
        else { status = "Waiting for \(engine.cfg.portName.isEmpty ? "a MIDI device" : engine.cfg.portName)…" }
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))

        if !trusted {
            menu.addItem(item("⚠︎ Allow Accessibility access…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())

        let on = item("Scrolling On", #selector(toggleEnabled))
        on.state = engine.enabled ? .on : .off
        menu.addItem(on)
        let inv = item("Invert Direction", #selector(toggleInvert))
        inv.state = engine.cfg.invert ? .on : .off
        menu.addItem(inv)
        menu.addItem(.separator())

        if engine.learnStep == .none {
            menu.addItem(item("Learn Jog Wheel…", #selector(learn)))
        } else {
            menu.addItem(item("Cancel Learning", #selector(cancelLearn)))
        }
        menu.addItem(item("Open Settings File", #selector(openSettings)))
        let login = item("Start at Login", #selector(toggleLogin))
        login.state = startsAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Jog Scroll", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleEnabled() { engine.enabled.toggle() }

    @objc private func toggleInvert() {
        engine.cfg.invert.toggle()
        saveConfig(engine.cfg)
        configDate = configModified()
    }

    @objc private func learn() { engine.startLearning() }

    @objc private func cancelLearn() {
        engine.cancelLearning()
        engine.cfg = loadConfig()
    }

    @objc private func openSettings() {
        if !FileManager.default.fileExists(atPath: configURL.path) { saveConfig(engine.cfg) }
        NSWorkspace.shared.open([configURL],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func toggleLogin() { setStartsAtLogin(!startsAtLogin) }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        exit(0)
    }
}

func runApp() -> Never {
    // Only one copy at a time, or every jog tick would scroll twice.
    if let id = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: id)
           .contains(where: { $0.processIdentifier != getpid() }) {
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = MenuBarApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

// MARK: - Terminal modes

func ensureAccessibility() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(opts) {
        log("""
        ⚠️  macOS needs to allow this program to control the mouse.
           Open System Settings → Privacy & Security → Accessibility and turn on
           the app you launched jog-scroll from (e.g. Terminal), then restart jog-scroll.
        """)
    }
}

func runScroller() -> Never {
    let engine = JogEngine(cfg: loadConfig())
    guard let touch = engine.cfg.touch, let jog = engine.cfg.jog else {
        print("No jog wheel learned yet. Run:  jog-scroll learn")
        exit(1)
    }
    ensureAccessibility()
    log("Jog: \(jog.description)  |  Touch: \(touch.description)")
    log("Running. Press Ctrl-C to quit.")
    let input = MidiInput { m in engine.handle(m) }
    _ = input
    dispatchMain()
}

func runMonitor() -> Never {
    log("Showing all incoming MIDI (Ctrl-C to quit)…")
    let input = MidiInput { m in log("\(hex(m))   from \"\(m.source)\"") }
    _ = input
    dispatchMain()
}

func runLearn() -> Never {
    let engine = JogEngine(cfg: loadConfig())
    var shown = JogEngine.LearnStep.none
    engine.onChange = {
        guard engine.learnStep != shown else { return }
        shown = engine.learnStep
        switch engine.learnStep {
        case .touch:
            print("\nStep 1 of 2: Touch the TOP of the jog wheel you want to use, then let go.")
        case .spin:
            print("  ✓ Touch = \(engine.cfg.touch!.description)  (device: \(engine.cfg.portName))")
            print("\nStep 2 of 2: Now spin the jog wheel slowly by its EDGE (don't touch the top).")
        case .none:
            break
        }
    }
    engine.onLearned = {
        print("  ✓ Jog = \(engine.cfg.jog!.description)")
        print("\nSaved to \(configURL.path)\n")
        exit(0)
    }
    let input = MidiInput { m in engine.handle(m) }
    input.verbose = false
    engine.startLearning()
    dispatchMain()
}

// MARK: - Entry

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGINT) { _ in print("\nBye."); exit(0) }

// Ignore launch arguments macOS itself may add (e.g. -psn_…).
let command = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }

switch command {
case nil:       runApp()
case "run":     runScroller()
case "learn":   runLearn()
case "monitor": runMonitor()
case "login":
    let on = CommandLine.arguments.dropFirst(2).first != "off"
    setStartsAtLogin(on)
    print(on ? "Jog Scroll will start at login." : "Jog Scroll will no longer start at login.")
    exit(0)
default:
    print("""
    Usage:
      jog-scroll              menu bar app
      jog-scroll run          run without the menu bar icon, logging to the terminal
      jog-scroll learn        record which MIDI messages your jog wheel sends
      jog-scroll monitor      print every incoming MIDI message
      jog-scroll login on|off start (or stop starting) the menu bar app at login
    Settings: \(configURL.path)
    """)
    exit(1)
}
