import Foundation

/// A fader or knob: it passes its position, from 0 at the bottom to 1 at the top, to its actions.
/// windows/Fader.cs is the same for the Windows version; change both together.
final class Fader: ControlHandler {
    private let control: MidiControl
    private let outputs: Outputs
    private var coarse = 0   // the latest coarse value of a high-resolution fader

    init(control: MidiControl, outputs: Outputs) {
        self.control = control
        self.outputs = outputs
    }

    func handle(_ m: MidiMessage) {
        guard let midi = control.midi, m.status == midi.status else { return }
        let value: Int
        if m.status & 0xF0 == 0xE0 { value = Int(m.data2) << 7 | Int(m.data1) }
        else if m.data1 == midi.data1 && control.fine == nil { value = Int(m.data2) }
        else if m.data1 == midi.data1 { coarse = Int(m.data2); return }   // wait for the fine value that follows
        else if m.data1 == control.fine { value = coarse << 7 | Int(m.data2) }
        else { return }

        let low = control.low ?? 0
        let high = control.high ?? (m.status & 0xF0 == 0xE0 || control.fine != nil ? 16383 : 127)
        var position = high > low ? min(max(Double(value - low) / Double(high - low), 0), 1) : 0
        if control.invert { position = 1 - position }
        for action in control.actions { outputs.setPosition(control, action, position: position) }
    }

    /// The fader's identity in a message: pitch bend has no controller number.
    static func key(_ m: MidiMessage) -> MidiMatch {
        MidiMatch(status: m.status, data1: m.status & 0xF0 == 0xE0 ? 0 : m.data1)
    }
}

/// Collects what the controller sends while the person sweeps a fader or knob, and works it out once they
/// stop for a second.
final class FaderLearner: Learner {
    private var heard: [MidiMessage] = []
    private var stillTimer: DispatchWorkItem?

    override var prompt: String { "Move the fader or knob for \(control.name) all the way down and up. It saves when you stop." }
    override var shortPrompt: String { "Move the control for \(control.name)" }

    override func handle(_ m: MidiMessage) {
        let type = m.status & 0xF0
        guard type == 0xB0 || type == 0xE0 else { return }
        let key = Fader.key(m)
        if cfg.controls.contains(where: { $0.isJog && ($0.midi == key || $0.touch == key) }) { return }
        heard.append(m)
        stillTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        stillTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    override func cancel() { stillTimer?.cancel() }

    private func finish() {
        // The control that moved most, so a stray knob doesn't count. Keep listening if it barely moved.
        let groups = Dictionary(grouping: heard, by: Fader.key).sorted { $0.value.count > $1.value.count }
        guard let first = groups.first, first.value.count >= 5 else { return }
        let main = first.key

        // A high-resolution fader sends a coarse CC and then a fine CC every time it moves. The coarse
        // one is the one with fewer different values.
        var midi = main
        var fine: UInt8?
        if let partner = groups.dropFirst().first(where: {
            main.status & 0xF0 == 0xB0 && $0.key.status == main.status && $0.value.count >= first.value.count / 2
        }) {
            let mainIsCoarse = Set(first.value.map(\.data2)).count <= Set(partner.value.map(\.data2)).count
            midi = mainIsCoarse ? main : partner.key
            fine = mainIsCoarse ? partner.key.data1 : main.data1
        }

        // The range the sweep covered, so each end of the control is each end of its actions' ranges.
        var values: [Int] = []
        var coarseValue = 0
        for h in heard {
            let key = Fader.key(h)
            if key == midi && h.status & 0xF0 == 0xE0 { values.append(Int(h.data2) << 7 | Int(h.data1)) }
            else if key == midi && fine == nil { values.append(Int(h.data2)) }
            else if key == midi { coarseValue = Int(h.data2) }
            else if let fine, key == MidiMatch(status: midi.status, data1: fine) { values.append(coarseValue << 7 | Int(h.data2)) }
        }
        guard let lowest = values.min(), let highest = values.max(), lowest != highest else { return }

        control.midi = midi
        control.fine = fine
        control.low = lowest
        control.high = highest
        done?()
    }
}
