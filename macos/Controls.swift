import Foundation

/// What a type of control does with the MIDI messages it hears.
protocol ControlHandler: AnyObject {
    func handle(_ m: MidiMessage)
}

/// Works out which MIDI messages a control sends, while the person moves it.
class Learner {
    let control: MidiControl
    let cfg: Config
    var changed: (() -> Void)?   // prompt changed
    var done: (() -> Void)?      // the control has its MIDI messages now

    init(control: MidiControl, cfg: Config) { self.control = control; self.cfg = cfg }

    var prompt: String { "" }                // what to do next, for the terminal
    var shortPrompt: String { "" }           // the same, short enough for the menu bar
    var listensEverywhere: Bool { false }    // whether it needs every MIDI input, to find the controller
    func handle(_ m: MidiMessage) {}
    func cancel() {}
}

/// Sends each MIDI message to the controls that use it, and runs learning. Everything runs on the main queue.
/// Each type of control is in its own file: Jog.swift, Fader.swift and Button.swift.
/// windows/Controls.cs is the same for the Windows version; change both together.
final class ControlRouter {
    private var handlers: [ObjectIdentifier: ControlHandler?] = [:]
    private var learner: Learner?
    private var outputs: Outputs!

    var onChange: (() -> Void)?
    var onLearned: ((MidiControl) -> Void)?

    init(cfg: Config) {
        self.cfg = cfg
        outputs = Outputs(servers: { [weak self] in self?.cfg.servers ?? [:] },
                          outputPort: { [weak self] in self?.cfg.outputPort ?? "" })
    }

    /// Called after each action with what it went to (a server's name, say) and nil, or why it failed.
    var onResult: ((String, String?) -> Void)? {
        get { outputs.onResult }
        set { outputs.onResult = newValue }
    }

    /// The settings. Setting them starts every control afresh.
    var cfg: Config {
        didSet {
            handlers.removeAll()
            outputs?.reset()
            onChange?()
        }
    }

    var scrollingEnabled: Bool {
        get { outputs.scroll.enabled }
        set { outputs.scroll.enabled = newValue; onChange?() }
    }

    /// Whether a jog wheel's top is touched, or was a moment ago.
    var fast: Bool { handlers.values.contains { ($0 as? Jog)?.fast == true } }

    var isConfigured: Bool { cfg.mainJog?.midi != nil }

    var learning: MidiControl? { learner?.control }
    var learnPrompt: String? { learner?.prompt }
    var shortLearnPrompt: String? { learner?.shortPrompt }

    func matchesPort(_ name: String) -> Bool {
        cfg.portName.isEmpty || name.lowercased().contains(cfg.portName.lowercased())
    }

    func find(_ name: String) -> MidiControl? {
        cfg.controls.first { $0.name.lowercased() == name.lowercased() }
    }

    /// The jog wheel for Learn Jog Wheel: the first one, or a new one if there isn't one yet, which is saved once it's learned.
    func mainJogToLearn() -> MidiControl {
        if let jog = cfg.mainJog { return jog }
        let jog = MidiControl.newJog()
        cfg.controls.insert(jog, at: 0)
        return jog
    }

    func canLearn(_ control: MidiControl) -> Bool { control.isJog || control.isFader || control.isButton }

    func startLearning(_ control: MidiControl) {
        learner?.cancel()
        learner = control.isJog ? JogLearner(control: control, cfg: cfg)
            : control.isFader ? FaderLearner(control: control, cfg: cfg)
            : control.isButton ? ButtonLearner(control: control, cfg: cfg)
            : nil
        guard let started = learner else {
            onResult?(control.name, "\(control.name): there's no control type called \"\(control.type)\"")
            return
        }
        started.changed = { [weak self] in self?.onChange?() }
        started.done = { [weak self, weak started] in
            guard let self, let started, self.learner === started else { return }
            self.learner = nil
            self.handlers.removeValue(forKey: ObjectIdentifier(started.control))
            saveConfig(self.cfg)
            self.onChange?()
            self.onLearned?(started.control)
        }
        onChange?()
    }

    func cancelLearning() {
        guard let learner else { return }
        learner.cancel()
        self.learner = nil
        onChange?()
    }

    func handle(_ m: MidiMessage) {
        if let learner {
            if learner.listensEverywhere || matchesPort(m.source) { learner.handle(m) }
            return
        }
        guard matchesPort(m.source) else { return }
        for control in cfg.controls { handler(control)?.handle(m) }
    }

    private func handler(_ control: MidiControl) -> ControlHandler? {
        if let handler = handlers[ObjectIdentifier(control)] { return handler }
        let handler: ControlHandler? = control.isJog ? Jog(control: control, outputs: outputs, changed: { [weak self] in self?.onChange?() })
            : control.isFader ? Fader(control: control, outputs: outputs)
            : control.isButton ? Button(control: control, keys: outputs.keys)
            : nil
        if handler == nil { onResult?(control.name, "\(control.name): there's no control type called \"\(control.type)\"") }
        handlers[ObjectIdentifier(control)] = .some(handler)
        return handler
    }
}
