// jog-scroll: turn a DJ controller's jog wheel into mouse-wheel scrolling, and its faders and knobs into
// requests to other programs.
//
// A standalone replacement for this Bome MIDI Translator project:
//   - touching the jog top sets a "fast" flag
//   - releasing it clears the flag after a 1 s delay
//   - jog ticks become scroll-wheel events (x10 while the flag is set)
//
// The jog wheel, faders and knobs are each a control in the settings (Config.swift). Controls.swift routes
// MIDI to them, Jog.swift and Fader.swift handle each type, and Outputs.swift carries out what they do.
//
// Usage:
//   jog-scroll              menu bar app (what runs at login)
//   jog-scroll run          same, without the menu bar icon, logging to the terminal
//   jog-scroll learn        record which MIDI messages your jog wheel sends
//   jog-scroll learn-control NAME  record which jog wheel, fader or knob a control uses
//   jog-scroll monitor      print every incoming MIDI message
//   jog-scroll login on|off start (or stop starting) the menu bar app at login

import Foundation
import AppKit
import CoreMIDI
import ApplicationServices
import UserNotifications

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

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, check: Bool = false, key: String = "", _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        state = check ? .on : .off
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private static let sensitivityPresets: [Double] = [1, 2, 3, 4, 6, 8, 12, 16, 24]

    private let controls = ControlRouter(cfg: loadConfig())
    private var input: MidiInput!
    private var statusItem: NSStatusItem!
    private var trusted = false
    private var banner: String?
    private var configDate = configModified()   // after loadConfig, which saves when it updates old settings
    private var errors: [String: String?] = [:]   // the last error shown for each server, so it alerts only once
    private var wasConnected = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controls.onChange = { [weak self] in self?.refresh() }
        controls.onLearned = { [weak self] _ in
            self?.configDate = configModified()
            self?.showBanner("Learned ✓")
        }
        controls.onResult = { [weak self] target, error in
            guard let self else { return }
            if let error, error != self.errors[target] ?? nil { self.notify("Controls", error, id: "controls") }
            self.errors[target] = .some(error)
        }
        input = MidiInput { [weak self] m in self?.controls.handle(m) }
        input.verbose = false
        wasConnected = deviceConnected   // no alert for the state at launch
        input.onSourcesChanged = { [weak self] in self?.sourcesChanged() }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("jog-scroll: notification permission granted=\(granted) error=\(String(describing: error))")
        }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)

        // Every 2 s: notice Accessibility being granted, and pick up hand edits to config.json.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }

        reportLoadError()
        if !controls.isConfigured && configLoadError == nil { controls.startLearning(controls.mainJogToLearn()) }
        refresh()
    }

    /// Says so if the settings file couldn't be read. Until it's fixed, Jog Scroll runs on the defaults and won't save over it.
    private func reportLoadError() {
        if let configLoadError {
            notify("The settings file has an error", "Jog Scroll won't change it until it's fixed. \(configLoadError)", id: "config")
        }
    }

    private func poll() {
        if !trusted && AXIsProcessTrusted() {
            // Scroll events from a process that wasn't trusted at launch can be dropped, so relaunch once.
            relaunch()
        }
        let date = configModified()
        if date != configDate && controls.learning == nil {
            controls.cfg = loadConfig()
            configDate = configModified()   // after loadConfig, which saves when it updates old settings
            reportLoadError()
        }
    }

    private var deviceConnected: Bool { input.sourceNames.contains(where: controls.matchesPort) }

    private var deviceLabel: String { controls.cfg.portName.isEmpty ? "MIDI controller" : controls.cfg.portName }

    private func sourcesChanged() {
        let connected = deviceConnected
        NSLog("jog-scroll: MIDI sources \(input.sourceNames), controller connected=\(connected)")
        // MIDI setup changes come in bursts, so only alert when the controller's state actually flips.
        if connected != wasConnected && controls.learning == nil && controls.cfg.connectionAlerts {
            notify(connected ? "\(deviceLabel) connected" : "\(deviceLabel) disconnected",
                   connected ? "Jog scrolling is ready." : "Jog scrolling is paused until it's plugged back in.")
        }
        wasConnected = connected
        refresh()
    }

    private func notify(_ title: String, _ body: String, id: String = "connection") {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default   // turn off per-app in System Settings → Notifications if unwanted
        // Reusing one identifier replaces the previous alert instead of stacking them up.
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("jog-scroll: couldn't show alert: \(error)") }
        }
    }

    // Show alerts even though a menu bar app counts as "in the foreground".
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func refresh() {
        guard let button = statusItem?.button else { return }
        let symbol = !controls.scrollingEnabled ? "dial.min" : controls.fast ? "dial.high.fill" : "dial.medium"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jog Scroll")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: "Jog Scroll")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.appearsDisabled = !controls.scrollingEnabled || !deviceConnected || !trusted

        if let prompt = controls.shortLearnPrompt { button.title = " " + prompt }
        else { button.title = banner.map { " " + $0 } ?? (trusted ? "" : " ⚠︎") }
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
        let isLearning = controls.learning != nil

        let status: String
        if let learning = controls.learning { status = "Learning \(learning.name)" }
        else if configLoadError != nil { status = "The settings file has an error" }
        else if !controls.isConfigured { status = "Jog wheel not learned yet" }
        else if deviceConnected { status = "Connected: \(controls.cfg.portName)" }
        else { status = "Waiting for \(controls.cfg.portName.isEmpty ? "a MIDI device" : controls.cfg.portName)…" }
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))

        if !trusted {
            menu.addItem(ClosureMenuItem("⚠︎ Allow Accessibility access…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            })
        }
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Scrolling On", check: controls.scrollingEnabled) { [weak self] in
            self?.controls.scrollingEnabled.toggle()
        })
        addScrollSettings(to: menu)
        menu.addItem(ClosureMenuItem("Connection Alerts", check: controls.cfg.connectionAlerts) { [weak self] in
            self?.changeConfig { $0.connectionAlerts.toggle() }
        })
        menu.addItem(.separator())

        if !isLearning {
            menu.addItem(ClosureMenuItem("Learn Jog Wheel…") { [weak self] in
                guard let self else { return }
                self.controls.startLearning(self.controls.mainJogToLearn())
            })
            menu.addItem(controlsMenuItem())
        } else {
            menu.addItem(ClosureMenuItem("Cancel Learning") { [weak self] in
                self?.controls.cancelLearning()
                self?.controls.cfg = loadConfig()
            })
        }
        menu.addItem(ClosureMenuItem("Open Settings File") { [weak self] in self?.openSettings() })
        menu.addItem(ClosureMenuItem("Start at Login", check: startsAtLogin) { setStartsAtLogin(!startsAtLogin) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Jog Scroll", key: "q") { NSApp.terminate(nil) })
    }

    /// Invert Direction and Sensitivity for each jog wheel that scrolls: in the menu itself for one,
    /// and in a submenu named for each if there are more.
    private func addScrollSettings(to menu: NSMenu) {
        let jogs = controls.cfg.controls.filter { $0.isJog && $0.actions.contains { $0.isScroll } }
        for jog in jogs {
            var items = menu
            if jogs.count > 1 {
                let parent = NSMenuItem(title: jog.name, action: nil, keyEquivalent: "")
                parent.submenu = NSMenu()
                menu.addItem(parent)
                items = parent.submenu!
            }
            items.addItem(ClosureMenuItem("Invert Direction", check: jog.invert) { [weak self] in
                self?.changeJog(jog) { jog.invert.toggle() }
            })
            items.addItem(sensitivityMenuItem(jog, jog.actions.first { $0.isScroll }!))
        }
    }

    private func sensitivityMenuItem(_ jog: MidiControl, _ scroll: ControlAction) -> NSMenuItem {
        let current = scroll.pixelsPerTick ?? ScrollOutput.defaultPixelsPerTick
        let sub = NSMenu()
        var presets = Self.sensitivityPresets
        if !presets.contains(current) { presets = (presets + [current]).sorted() }   // hand-edited value
        for value in presets {
            sub.addItem(ClosureMenuItem("\(formatted(value)) px per tick", check: value == current) { [weak self] in
                self?.changeJog(jog) { scroll.pixelsPerTick = value }
            })
        }
        let parent = NSMenuItem(title: "Sensitivity: \(formatted(current))", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    private func controlsMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        for control in controls.cfg.controls {
            if controls.canLearn(control) {
                let learned = control.midi?.description ?? "not learned yet"
                sub.addItem(ClosureMenuItem("Learn \(control.name)… (\(learned))") { [weak self] in
                    self?.controls.startLearning(control)
                })
            } else {
                sub.addItem(NSMenuItem(title: "\(control.name): there's no control type called \"\(control.type)\"",
                                       action: nil, keyEquivalent: ""))
            }
        }
        if controls.cfg.controls.isEmpty {
            sub.addItem(NSMenuItem(title: "None yet: add them in the settings file", action: nil, keyEquivalent: ""))
        }
        let parent = NSMenuItem(title: "Controls", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    private func formatted(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }

    private func changeConfig(_ change: (Config) -> Void) {
        change(controls.cfg)
        saveConfig(controls.cfg)
        configDate = configModified()
        refresh()
    }

    /// Changes a jog wheel's settings, unless the settings were reloaded from the file since the menu opened
    /// and it isn't in them any more.
    private func changeJog(_ jog: MidiControl, _ change: () -> Void) {
        if controls.cfg.controls.contains(where: { $0 === jog }) { changeConfig { _ in change() } }
    }

    private func openSettings() {
        if !FileManager.default.fileExists(atPath: configURL.path) { saveConfig(controls.cfg) }
        NSWorkspace.shared.open([configURL],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

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
    let controls = ControlRouter(cfg: loadConfig())
    controls.onResult = { _, error in if let error { log(error) } }
    let learned = controls.cfg.controls.filter { $0.midi != nil }
    if learned.isEmpty {
        print("No jog wheel learned yet. Run:  jog-scroll learn")
        exit(1)
    }
    ensureAccessibility()
    for c in learned {
        let touch = c.touch.map { " (touch: \($0.description))" } ?? ""
        let actions = c.actions.map { $0.isScroll ? "scroll" : "\($0.server ?? "") \($0.path ?? "")" }.joined(separator: ", ")
        log("\(c.name): \(c.midi!.description)\(touch) → \(actions)")
    }
    log("Running. Press Ctrl-C to quit.")
    let input = MidiInput { m in controls.handle(m) }
    _ = input
    dispatchMain()
}

func runMonitor() -> Never {
    log("Showing all incoming MIDI (Ctrl-C to quit)…")
    let input = MidiInput { m in log("\(hex(m))   from \"\(m.source)\"") }
    _ = input
    dispatchMain()
}

func runLearnControl(_ name: String) -> Never {
    let controls = ControlRouter(cfg: loadConfig())
    guard let control = controls.find(name) else {
        let names = controls.cfg.controls.map { "\"\($0.name)\"" }
        print(names.isEmpty ? "No controls yet. Add them to \(configURL.path)"
              : "Usage: jog-scroll learn-control NAME, where NAME is one of \(names.joined(separator: ", "))")
        exit(1)
    }
    guard controls.canLearn(control) else {
        print("\(control.name): there's no control type called \"\(control.type)\". Use \"jog\" or \"fader\".")
        exit(1)
    }
    learn(controls, control)
}

/// Prints each step of learning a control, and saves it once it's learned.
func learn(_ controls: ControlRouter, _ control: MidiControl) -> Never {
    var shown: String?
    controls.onChange = {
        guard let prompt = controls.learnPrompt, prompt != shown else { return }
        shown = prompt
        print("\n\(prompt)")
    }
    controls.onLearned = { c in
        print("  ✓ \(c.name) = \(c.midi!.description)")
        if let touch = c.touch { print("  ✓ Touch = \(touch.description)") }
        if c.isJog { print("  ✓ Device = \(controls.cfg.portName)") }
        print("\nSaved to \(configURL.path)\n")
        exit(0)
    }
    let input = MidiInput { m in controls.handle(m) }
    input.verbose = false
    controls.startLearning(control)
    dispatchMain()
}

// MARK: - Entry

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGINT) { _ in print("\nBye."); exit(0) }

// Ignore launch arguments macOS itself may add (e.g. -psn_…).
let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }

if ["run", "learn", "learn-control"].contains(arguments.first) {
    _ = loadConfig()
    if let configLoadError {
        print("The settings file has an error, so Jog Scroll won't use or change it until it's fixed:\n  \(configLoadError)\n  \(configURL.path)")
        exit(1)
    }
}

switch arguments.first {
case nil:       runApp()
case "run":     runScroller()
case "learn":
    let controls = ControlRouter(cfg: loadConfig())
    learn(controls, controls.mainJogToLearn())
case "learn-control": runLearnControl(arguments.dropFirst().joined(separator: " "))
case "monitor": runMonitor()
case "login":
    let on = arguments.dropFirst().first != "off"
    setStartsAtLogin(on)
    print(on ? "Jog Scroll will start at login." : "Jog Scroll will no longer start at login.")
    exit(0)
default:
    print("""
    Usage:
      jog-scroll              menu bar app
      jog-scroll run          run without the menu bar icon, logging to the terminal
      jog-scroll learn        record which MIDI messages your jog wheel sends
      jog-scroll learn-control NAME  record which jog wheel, fader or knob the control NAME uses
      jog-scroll monitor      print every incoming MIDI message
      jog-scroll login on|off start (or stop starting) the menu bar app at login
    Settings: \(configURL.path)
    """)
    exit(1)
}
