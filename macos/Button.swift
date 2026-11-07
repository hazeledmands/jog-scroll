import Foundation

/// A button: its actions happen when it's pressed, let go, or both, as each action's "on" says.
/// windows/Button.cs is the same for the Windows version; change both together.
final class Button: ControlHandler {
    private let control: MidiControl
    private let keys: KeyOutput
    private var pressed = false

    init(control: MidiControl, keys: KeyOutput) {
        self.control = control
        self.keys = keys
    }

    /// Whether a message is from this button, or a jog wheel's touch sensor, which is a button too. A button that
    /// sends notes can send note off or note on with velocity 0 when it's let go.
    static func matches(_ m: MidiMessage, _ button: MidiMatch) -> Bool {
        guard m.data1 == button.data1, m.status & 0x0F == button.status & 0x0F else { return false }
        let type = m.status & 0xF0, learned = button.status & 0xF0
        if learned == 0x90 || learned == 0x80 { return type == 0x90 || type == 0x80 }
        return type == learned
    }

    /// Whether a button's message is it being pressed, rather than let go.
    static func isDown(_ m: MidiMessage) -> Bool {
        switch m.status & 0xF0 {
        case 0x80: return false
        case 0x90: return m.data2 > 0
        default:   return m.data2 >= 64
        }
    }

    func handle(_ m: MidiMessage) {
        guard let midi = control.midi, Self.matches(m, midi) else { return }
        let down = Self.isDown(m)
        // Repeats count once, and letting go without a press, such as just after learning it, does nothing.
        guard down != pressed else { return }
        pressed = down
        for action in control.actions { keys.press(control, action, down: down) }
    }
}

/// Learns a button from the first press, other than the jog wheels'.
final class ButtonLearner: Learner {
    override var prompt: String { "Press the button for \(control.name)." }
    override var shortPrompt: String { "Press the button for \(control.name)" }

    override func handle(_ m: MidiMessage) {
        let type = m.status & 0xF0
        guard type == 0x90 || type == 0xB0, Button.isDown(m) else { return }
        let key = MidiMatch(status: m.status, data1: m.data1)
        if cfg.controls.contains(where: { $0.isJog && ($0.midi == key || $0.touch.map { Button.matches(m, $0) } == true) }) { return }
        control.midi = key
        done?()
    }
}
