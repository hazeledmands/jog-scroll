namespace JogScroll;

/// A jog wheel: the Bome translators. Each tick it turns is passed to its actions, sped up while its top
/// is touched and for a moment after.
sealed class Jog : IControlHandler
{
    readonly MidiControl control;
    readonly Outputs outputs;
    readonly Action changed;
    CancellationTokenSource? releaseTimer;
    bool fast;                          // Bome's "gt"

    public Jog(MidiControl control, Outputs outputs, Action changed)
    {
        this.control = control;
        this.outputs = outputs;
        this.changed = changed;
    }

    public bool Fast { get => fast; private set { if (fast != value) { fast = value; changed(); } } }

    public static bool IsTouchMessage(MidiMessage m, MidiMatch t)
    {
        if (m.Data1 != t.Data1 || (m.Status & 0x0F) != (t.Status & 0x0F)) return false;
        int type = m.Status & 0xF0, learned = t.Status & 0xF0;
        if (learned == 0x90 || learned == 0x80) return type == 0x90 || type == 0x80;
        return type == learned;
    }

    public static bool IsTouchDown(MidiMessage m) => (m.Status & 0xF0) switch
    {
        0x80 => false,
        0x90 => m.Data2 > 0,
        _ => m.Data2 >= 64,
    };

    public void Handle(MidiMessage m)
    {
        if (control.Touch is { } touch && IsTouchMessage(m, touch))
        {
            releaseTimer?.Cancel();   // re-touching within the hold window keeps it fast
            if (IsTouchDown(m))
            {
                Fast = true;
            }
            else
            {
                var cts = new CancellationTokenSource();
                releaseTimer = cts;
                _ = ReleaseAfterHold(cts.Token);
            }
            return;
        }
        if (control.Midi is not { } midi || m.Status != midi.Status || m.Data1 != midi.Data1) return;

        // Relative jog: small values = clockwise, values near 128 = counter-clockwise.
        int v = m.Data2;
        int ticks = v < (control.CenterThreshold ?? 50) ? v : -(128 - v);
        double amount = ticks * (Fast ? control.TouchMultiplier ?? 10 : 1);
        if (control.Invert) amount = -amount;
        foreach (var action in control.Actions) outputs.Turn(control, action, amount);
    }

    async Task ReleaseAfterHold(CancellationToken token)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(Math.Max(0, control.TouchHoldSeconds ?? 1.0)), token); }
        catch (TaskCanceledException) { return; }
        Fast = false;
    }
}

/// Learns a jog wheel in two steps: touch its top, then spin it by its edge. It listens to every MIDI input,
/// and the one the touch came from becomes the controller.
sealed class JogLearner : Learner
{
    MidiMatch? touch;
    string source = "";
    MidiMatch? candidate;
    int candidateCount;

    public JogLearner(MidiControl control, Config cfg) : base(control, cfg) { }

    public override bool ListensEverywhere => true;

    public override string Prompt => touch == null
        ? "Touch the top of the jog wheel, then let go."
        : "Now spin the jog wheel slowly by its edge.";

    public override string ShortPrompt => touch == null ? "Touch the jog top" : "Now spin the jog edge";

    public override void Handle(MidiMessage m)
    {
        int type = m.Status & 0xF0;
        if (type != 0x80 && type != 0x90 && type != 0xB0) return;
        if (touch == null)
        {
            // Take the first note/CC press as the touch sensor.
            if (!Jog.IsTouchDown(m)) return;
            touch = new MidiMatch { Status = m.Status, Data1 = m.Data1 };
            source = m.Source;
            Changed?.Invoke();
            return;
        }

        // Wait for the same controller to repeat a few times so a stray button doesn't count.
        if (type != 0xB0 || m.Source != source || Jog.IsTouchMessage(m, touch)) return;
        var match = new MidiMatch { Status = m.Status, Data1 = m.Data1 };
        if (match == candidate) candidateCount++; else { candidate = match; candidateCount = 1; }
        if (candidateCount < 5) return;
        Control.Touch = touch;
        Control.Midi = match;
        Cfg.PortName = source;
        Done?.Invoke();
    }
}
