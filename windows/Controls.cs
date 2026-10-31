namespace JogScroll;

/// Turns fader and knob positions into the actions set up for them. Everything runs on the UI thread.
public sealed class ControlRouter
{
    readonly JogEngine engine;   // for the config and the controller's port
    readonly Outputs outputs;
    readonly Dictionary<MidiControl, int> coarse = new();   // latest coarse value of each high-resolution control
    MidiControl? learning;
    readonly List<MidiMessage> heard = new();                // while learning: everything the controls sent
    CancellationTokenSource? stillTimer;

    public Action? OnChange;
    public Action<MidiControl>? OnLearned;

    public ControlRouter(JogEngine engine)
    {
        this.engine = engine;
        outputs = new Outputs(() => engine.Cfg.Servers);
    }

    /// Called after each request with the server's name and null, or why it failed.
    public Action<string, string?>? OnResult { set => outputs.OnResult = value; }

    List<MidiControl> Controls => engine.Cfg.Controls;

    public MidiControl? Learning { get => learning; private set { learning = value; OnChange?.Invoke(); } }

    public MidiControl? Find(string name) =>
        Controls.FirstOrDefault(c => string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase));

    public void StartLearning(MidiControl control)
    {
        heard.Clear();
        Learning = control;
    }

    public void CancelLearning()
    {
        stillTimer?.Cancel();
        Learning = null;
    }

    /// Returns whether the message was for a control, or taken by learning.
    public bool Handle(MidiMessage m)
    {
        if (!engine.MatchesPort(m.Source)) return false;
        if (Learning != null) { Learn(m); return true; }

        bool used = false;
        foreach (var control in Controls)
        {
            if (control.Midi is not { } midi || m.Status != midi.Status) continue;
            int? raw = null;
            if ((m.Status & 0xF0) == 0xE0) raw = (m.Data2 << 7) | m.Data1;
            else if (m.Data1 == midi.Data1 && control.Fine == null) raw = m.Data2;
            else if (m.Data1 == midi.Data1) { coarse[control] = m.Data2; used = true; }   // wait for the fine value that follows
            else if (m.Data1 == control.Fine) raw = (coarse.GetValueOrDefault(control) << 7) | m.Data2;
            if (raw is not int value) continue;
            used = true;

            int low = control.Low ?? 0, high = control.High ?? ((m.Status & 0xF0) == 0xE0 || control.Fine != null ? 16383 : 127);
            double position = high > low ? Math.Clamp((double)(value - low) / (high - low), 0, 1) : 0;
            if (control.Invert) position = 1 - position;
            foreach (var action in control.Actions) outputs.Send(action, position);
        }
        return used;
    }

    static MidiMatch Key(MidiMessage m) => new() { Status = m.Status, Data1 = (m.Status & 0xF0) == 0xE0 ? (byte)0 : m.Data1 };

    /// Collects what the controls send while the person sweeps one, and works it out once they stop for a second.
    void Learn(MidiMessage m)
    {
        int type = m.Status & 0xF0;
        if (type != 0xB0 && type != 0xE0) return;
        if (Key(m) == engine.Cfg.Jog) return;
        heard.Add(m);
        stillTimer?.Cancel();
        var cts = new CancellationTokenSource();
        stillTimer = cts;
        _ = FinishWhenStill(cts.Token);
    }

    async Task FinishWhenStill(CancellationToken token)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(1), token); }
        catch (TaskCanceledException) { return; }
        if (Learning is { } target) Finish(target);
    }

    void Finish(MidiControl target)
    {
        // The control that moved most, so a stray knob doesn't count. Keep listening if it barely moved.
        var groups = heard.GroupBy(Key).OrderByDescending(g => g.Count()).ToList();
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

        // The range the sweep covered, so each end of the control is each end of the light.
        var values = new List<int>();
        int coarseValue = 0;
        foreach (var h in heard)
        {
            var key = Key(h);
            if (key == midi && (h.Status & 0xF0) == 0xE0) values.Add((h.Data2 << 7) | h.Data1);
            else if (key == midi && fine == null) values.Add(h.Data2);
            else if (key == midi) coarseValue = h.Data2;
            else if (key == midi with { Data1 = fine ?? 0 } && fine != null) values.Add((coarseValue << 7) | h.Data2);
        }
        if (values.Count == 0 || values.Max() == values.Min()) return;

        target.Midi = midi;
        target.Fine = fine;
        target.Low = values.Min();
        target.High = values.Max();
        ConfigFile.Save(engine.Cfg);
        coarse.Remove(target);
        Learning = null;
        OnLearned?.Invoke(target);
    }
}
