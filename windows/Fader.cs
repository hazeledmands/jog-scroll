namespace JogScroll;

/// A fader or knob: it passes its position, from 0 at the bottom to 1 at the top, to its actions.
sealed class Fader : IControlHandler
{
    readonly MidiControl control;
    readonly Outputs outputs;
    int coarse;   // the latest coarse value of a high-resolution fader

    public Fader(MidiControl control, Outputs outputs)
    {
        this.control = control;
        this.outputs = outputs;
    }

    public void Handle(MidiMessage m)
    {
        if (control.Midi is not { } midi || m.Status != midi.Status) return;
        int value;
        if ((m.Status & 0xF0) == 0xE0) value = (m.Data2 << 7) | m.Data1;
        else if (m.Data1 == midi.Data1 && control.Fine == null) value = m.Data2;
        else if (m.Data1 == midi.Data1) { coarse = m.Data2; return; }   // wait for the fine value that follows
        else if (m.Data1 == control.Fine) value = (coarse << 7) | m.Data2;
        else return;

        int low = control.Low ?? 0, high = control.High ?? ((m.Status & 0xF0) == 0xE0 || control.Fine != null ? 16383 : 127);
        double position = high > low ? Math.Clamp((double)(value - low) / (high - low), 0, 1) : 0;
        if (control.Invert) position = 1 - position;
        foreach (var action in control.Actions) outputs.SetPosition(control, action, position);
    }

    /// The fader's identity in a message: pitch bend has no controller number.
    public static MidiMatch Key(MidiMessage m) =>
        new() { Status = m.Status, Data1 = (m.Status & 0xF0) == 0xE0 ? (byte)0 : m.Data1 };
}

/// Collects what the controller sends while the person sweeps a fader or knob, and works it out once they
/// stop for a second.
sealed class FaderLearner : Learner
{
    readonly List<MidiMessage> heard = new();
    CancellationTokenSource? stillTimer;

    public FaderLearner(MidiControl control, Config cfg) : base(control, cfg) { }

    public override string Prompt => $"Move the fader or knob for {Control.Name} all the way down and up. It saves when you stop.";
    public override string ShortPrompt => $"Move the control for {Control.Name}";

    public override void Handle(MidiMessage m)
    {
        int type = m.Status & 0xF0;
        if (type != 0xB0 && type != 0xE0) return;
        var key = Fader.Key(m);
        if (Cfg.Controls.Any(c => c.IsJog && (c.Midi == key || c.Touch == key))) return;
        heard.Add(m);
        stillTimer?.Cancel();
        var cts = new CancellationTokenSource();
        stillTimer = cts;
        _ = FinishWhenStill(cts.Token);
    }

    public override void Cancel() => stillTimer?.Cancel();

    async Task FinishWhenStill(CancellationToken token)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(1), token); }
        catch (TaskCanceledException) { return; }
        Finish();
    }

    void Finish()
    {
        // The control that moved most, so a stray knob doesn't count. Keep listening if it barely moved.
        var groups = heard.GroupBy(Fader.Key).OrderByDescending(g => g.Count()).ToList();
        if (groups.Count == 0 || groups[0].Count() < 5) return;
        var main = groups[0].Key;

        // A high-resolution fader sends a coarse CC and then a fine CC every time it moves. The coarse
        // one is the one with fewer different values.
        MidiMatch midi = main;
        byte? fine = null;
        var partner = groups.Skip(1).FirstOrDefault(g =>
            (main.Status & 0xF0) == 0xB0 && g.Key.Status == main.Status && g.Count() >= groups[0].Count() / 2);
        if (partner != null)
        {
            bool mainIsCoarse = groups[0].Select(h => h.Data2).Distinct().Count() <= partner.Select(h => h.Data2).Distinct().Count();
            midi = mainIsCoarse ? main : partner.Key;
            fine = mainIsCoarse ? partner.Key.Data1 : main.Data1;
        }

        // The range the sweep covered, so each end of the control is each end of its actions' ranges.
        var values = new List<int>();
        int coarseValue = 0;
        foreach (var h in heard)
        {
            var key = Fader.Key(h);
            if (key == midi && (h.Status & 0xF0) == 0xE0) values.Add((h.Data2 << 7) | h.Data1);
            else if (key == midi && fine == null) values.Add(h.Data2);
            else if (key == midi) coarseValue = h.Data2;
            else if (key == midi with { Data1 = fine ?? 0 } && fine != null) values.Add((coarseValue << 7) | h.Data2);
        }
        if (values.Count == 0 || values.Max() == values.Min()) return;

        Control.Midi = midi;
        Control.Fine = fine;
        Control.Low = values.Min();
        Control.High = values.Max();
        Done?.Invoke();
    }
}
