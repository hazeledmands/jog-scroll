namespace JogScroll;

// What every type of control shares. These are here, not in Midi.cs and Controls.cs as on macOS, so the tests
// can compile them without Windows Forms.

public readonly record struct MidiMessage(byte Status, byte Data1, byte Data2, string Source);

/// What a type of control does with the MIDI messages it hears.
interface IControlHandler
{
    void Handle(MidiMessage m);
}

/// Works out which MIDI messages a control sends, while the person moves it.
abstract class Learner
{
    public readonly MidiControl Control;
    protected readonly Config Cfg;
    public Action? Changed;   // Prompt changed
    public Action? Done;      // the control has its MIDI messages now

    protected Learner(MidiControl control, Config cfg) { Control = control; Cfg = cfg; }

    public abstract string Prompt { get; }        // what to do next, for a notification or the terminal
    public abstract string ShortPrompt { get; }   // the same, short enough for the tray icon's tooltip
    public virtual bool ListensEverywhere => false;   // whether it needs every MIDI input, to find the controller
    public abstract void Handle(MidiMessage m);
    public virtual void Cancel() { }
}
