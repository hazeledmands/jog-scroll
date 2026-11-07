import Foundation

/// A jog wheel: the Bome translators. Each tick it turns is passed to its actions, sped up while its top
/// is touched and for a moment after. windows/Jog.cs is the same for the Windows version; change both together.
final class Jog: ControlHandler {
    private let control: MidiControl
    private let outputs: Outputs
    private let changed: () -> Void
    private var releaseTimer: DispatchWorkItem?
    private(set) var fast = false { didSet { if fast != oldValue { changed() } } }   // Bome's "gt"

    init(control: MidiControl, outputs: Outputs, changed: @escaping () -> Void) {
        self.control = control
        self.outputs = outputs
        self.changed = changed
    }

    func handle(_ m: MidiMessage) {
        if let touch = control.touch, Button.matches(m, touch) {
            releaseTimer?.cancel()  // re-touching within the hold window keeps it fast
            if Button.isDown(m) {
                fast = true
            } else {
                let work = DispatchWorkItem { [weak self] in self?.fast = false }
                releaseTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, control.touchHoldSeconds ?? 1.0), execute: work)
            }
            return
        }
        guard let midi = control.midi, m.status == midi.status, m.data1 == midi.data1 else { return }

        // Relative jog: small values = clockwise, values near 128 = counter-clockwise.
        let v = Int(m.data2)
        let ticks = v < (control.centerThreshold ?? 50) ? v : -(128 - v)
        var amount = Double(ticks) * (fast ? control.touchMultiplier ?? 10 : 1)
        if control.invert { amount = -amount }
        for action in control.actions { outputs.turn(control, action, ticks: amount) }
    }
}

/// Learns a jog wheel in two steps: touch its top, then spin it by its edge. It listens to every MIDI input,
/// and the one the touch came from becomes the controller.
final class JogLearner: Learner {
    private var touch: MidiMatch?
    private var source = ""
    private var candidate: MidiMatch?
    private var candidateCount = 0

    override var listensEverywhere: Bool { true }

    override var prompt: String {
        touch == nil ? "Touch the top of the jog wheel, then let go." : "Now spin the jog wheel slowly by its edge."
    }

    override var shortPrompt: String { touch == nil ? "Touch the jog top" : "Now spin the jog edge" }

    override func handle(_ m: MidiMessage) {
        let type = m.status & 0xF0
        guard type == 0x80 || type == 0x90 || type == 0xB0 else { return }
        guard let touch else {
            // Take the first note/CC press as the touch sensor.
            guard Button.isDown(m) else { return }
            self.touch = MidiMatch(status: m.status, data1: m.data1)
            source = m.source
            changed?()
            return
        }

        // Wait for the same controller to repeat a few times so a stray button doesn't count.
        guard type == 0xB0, m.source == source, !Button.matches(m, touch) else { return }
        let match = MidiMatch(status: m.status, data1: m.data1)
        if match == candidate { candidateCount += 1 } else { candidate = match; candidateCount = 1 }
        guard candidateCount >= 5 else { return }
        control.touch = touch
        control.midi = match
        // Keep a portName that already matches, such as "Reloop Ready". The full name can differ between computers
        // ("Reloop Ready In" on Windows), so a synced settings file needs the shorter one.
        if !cfg.portName.isEmpty && !source.lowercased().contains(cfg.portName.lowercased()) { cfg.portName = source }
        done?()
    }
}
