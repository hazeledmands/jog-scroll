namespace JogScroll;

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

/// Sends each MIDI message to the controls that use it, and runs learning. Everything runs on the UI thread.
/// Each type of control is in its own file: Jog.cs and Fader.cs.
public sealed class ControlRouter
{
    Config cfg;
    readonly Outputs outputs;
    readonly Dictionary<MidiControl, IControlHandler?> handlers = new(ReferenceEqualityComparer.Instance);
    Learner? learner;
    Action<string, string?>? onResult;

    public Action? OnChange;
    public Action<MidiControl>? OnLearned;

    public ControlRouter(Config cfg)
    {
        this.cfg = cfg;
        outputs = new Outputs(() => this.cfg.Servers);
    }

    /// Called after each action with what it went to (a server's name, say) and null, or why it failed.
    public Action<string, string?>? OnResult { set { onResult = value; outputs.OnResult = value; } }

    /// The settings. Setting them starts every control afresh.
    public Config Cfg
    {
        get => cfg;
        set
        {
            cfg = value;
            handlers.Clear();
            outputs.Reset();
            OnChange?.Invoke();
        }
    }

    public bool ScrollingEnabled
    {
        get => outputs.Scroll.Enabled;
        set { outputs.Scroll.Enabled = value; OnChange?.Invoke(); }
    }

    /// Whether a jog wheel's top is touched, or was a moment ago.
    public bool Fast => handlers.Values.OfType<Jog>().Any(j => j.Fast);

    public bool IsConfigured => cfg.MainJog?.Midi != null;

    public MidiControl? Learning => learner?.Control;
    public string? LearnPrompt => learner?.Prompt;
    public string? ShortLearnPrompt => learner?.ShortPrompt;
    public bool ListensEverywhere => learner?.ListensEverywhere == true;

    public bool MatchesPort(string name) =>
        cfg.PortName.Length == 0 || name.Contains(cfg.PortName, StringComparison.OrdinalIgnoreCase);

    public MidiControl? Find(string name) =>
        cfg.Controls.FirstOrDefault(c => string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase));

    /// The jog wheel for Learn Jog Wheel: the first one, or a new one if there isn't one yet, which is saved once it's learned.
    public MidiControl MainJogToLearn()
    {
        if (cfg.MainJog is { } jog) return jog;
        jog = MidiControl.NewJog();
        cfg.Controls.Insert(0, jog);
        return jog;
    }

    public bool CanLearn(MidiControl control) => control.IsJog || control.IsFader;

    public void StartLearning(MidiControl control)
    {
        learner?.Cancel();
        learner = control.IsJog ? new JogLearner(control, cfg)
            : control.IsFader ? new FaderLearner(control, cfg)
            : null;
        if (learner == null)
        {
            onResult?.Invoke(control.Name, $"{control.Name}: there's no control type called \"{control.Type}\"");
            return;
        }
        var started = learner;
        started.Changed = () => OnChange?.Invoke();
        started.Done = () =>
        {
            if (learner != started) return;
            learner = null;
            handlers.Remove(started.Control);
            ConfigFile.Save(cfg);
            OnChange?.Invoke();
            OnLearned?.Invoke(started.Control);
        };
        OnChange?.Invoke();
    }

    public void CancelLearning()
    {
        if (learner == null) return;
        learner.Cancel();
        learner = null;
        OnChange?.Invoke();
    }

    public void Handle(MidiMessage m)
    {
        if (learner != null)
        {
            if (learner.ListensEverywhere || MatchesPort(m.Source)) learner.Handle(m);
            return;
        }
        if (!MatchesPort(m.Source)) return;
        foreach (var control in cfg.Controls) Handler(control)?.Handle(m);
    }

    IControlHandler? Handler(MidiControl control)
    {
        if (handlers.TryGetValue(control, out var handler)) return handler;
        handler = control.IsJog ? new Jog(control, outputs, () => OnChange?.Invoke())
            : control.IsFader ? new Fader(control, outputs)
            : null;
        if (handler == null) onResult?.Invoke(control.Name, $"{control.Name}: there's no control type called \"{control.Type}\"");
        handlers[control] = handler;
        return handler;
    }
}
