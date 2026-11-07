namespace JogScroll;

/// A button: its actions happen when it's pressed, let go, or both, as each action's "on" says.
/// macos/Button.swift is the same for the macOS version; change both together.
sealed class Button : IControlHandler
{
    readonly MidiControl control;
    readonly KeyOutput keys;
    bool pressed;

    public Button(MidiControl control, KeyOutput keys)
    {
        this.control = control;
        this.keys = keys;
    }

    /// Whether a message is from this button, or a jog wheel's touch sensor, which is a button too. A button that
    /// sends notes can send note off or note on with velocity 0 when it's let go.
    public static bool Matches(MidiMessage m, MidiMatch button)
    {
        if (m.Data1 != button.Data1 || (m.Status & 0x0F) != (button.Status & 0x0F)) return false;
        int type = m.Status & 0xF0, learned = button.Status & 0xF0;
        if (learned == 0x90 || learned == 0x80) return type == 0x90 || type == 0x80;
        return type == learned;
    }

    /// Whether a button's message is it being pressed, rather than let go.
    public static bool IsDown(MidiMessage m) => (m.Status & 0xF0) switch
    {
        0x80 => false,
        0x90 => m.Data2 > 0,
        _ => m.Data2 >= 64,
    };

    public void Handle(MidiMessage m)
    {
        if (control.Midi is not { } midi || !Matches(m, midi)) return;
        bool down = IsDown(m);
        // Repeats count once, and letting go without a press, such as just after learning it, does nothing.
        if (down == pressed) return;
        pressed = down;
        foreach (var action in control.Actions) keys.Press(control, action, down);
    }
}

/// Learns a button from the first press, other than the jog wheels'.
sealed class ButtonLearner : Learner
{
    public ButtonLearner(MidiControl control, Config cfg) : base(control, cfg) { }

    public override string Prompt => $"Press the button for {Control.Name}.";
    public override string ShortPrompt => $"Press the button for {Control.Name}";

    public override void Handle(MidiMessage m)
    {
        int type = m.Status & 0xF0;
        if ((type != 0x90 && type != 0xB0) || !Button.IsDown(m)) return;
        var key = new MidiMatch { Status = m.Status, Data1 = m.Data1 };
        if (Cfg.Controls.Any(c => c.IsJog && (c.Midi == key || (c.Touch is { } touch && Button.Matches(m, touch))))) return;
        Control.Midi = key;
        Done?.Invoke();
    }
}
