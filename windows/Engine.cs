using static JogScroll.Native;

namespace JogScroll;

static class Scroller
{
    /// Positive scrolls up. Sideways scrolling needs nothing extra: like a real mouse, we send a vertical
    /// wheel event while Shift is held, and apps turn that into scrolling left (positive) or right.
    /// A horizontal wheel event doesn't work here, because apps such as Chrome swap its axis when Shift is down.
    public static void Scroll(int units)
    {
        if (units == 0) return;
        var input = new INPUT
        {
            type = INPUT_MOUSE,
            mi = new MOUSEINPUT
            {
                mouseData = unchecked((uint)Math.Clamp(units, -10_000, 10_000)),
                dwFlags = MOUSEEVENTF_WHEEL,
            },
        };
        SendInput(1, new[] { input }, System.Runtime.InteropServices.Marshal.SizeOf<INPUT>());
    }

    /// Whether either physical Shift key is down.
    public static bool KeyboardShiftHeld =>
        (GetAsyncKeyState(VK_LSHIFT) & 0x8000) != 0 || (GetAsyncKeyState(VK_RSHIFT) & 0x8000) != 0;
}

/// The Bome translators, plus the "learn" flow. Everything runs on the UI thread.
/// A port of JogEngine in macos/main.swift; change both together.
public sealed class JogEngine
{
    public enum LearnStep { None, Touch, Spin }

    public Config Cfg;
    public Action? OnChange;
    public Action? OnLearned;

    bool enabled = true;
    bool fast;                          // Bome's "gt"
    LearnStep learnStep = LearnStep.None;
    CancellationTokenSource? releaseTimer;
    double remainder;                   // sub-unit scroll carried over to the next tick
    bool remainderHorizontal;
    MidiMatch? candidate;
    int candidateCount;

    public JogEngine(Config cfg) { Cfg = cfg; }

    public bool Enabled { get => enabled; set { enabled = value; OnChange?.Invoke(); } }
    public bool Fast { get => fast; private set { if (fast != value) { fast = value; OnChange?.Invoke(); } } }
    public LearnStep Step { get => learnStep; private set { learnStep = value; OnChange?.Invoke(); } }
    public bool IsConfigured => Cfg.Touch != null && Cfg.Jog != null;

    public bool MatchesPort(string name) =>
        Cfg.PortName.Length == 0 || name.Contains(Cfg.PortName, StringComparison.OrdinalIgnoreCase);

    public void StartLearning()
    {
        candidate = null;
        candidateCount = 0;
        Step = LearnStep.Touch;
    }

    public void CancelLearning() => Step = LearnStep.None;

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
        if (Step != LearnStep.None) { Learn(m); return; }
        if (!MatchesPort(m.Source) || Cfg.Touch is not { } touch || Cfg.Jog is not { } jog) return;

        if (IsTouchMessage(m, touch))
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
        if (!Enabled || m.Status != jog.Status || m.Data1 != jog.Data1) return;

        // Relative jog: small values = clockwise, values near 128 = counter-clockwise.
        int v = m.Data2;
        int ticks = v < Cfg.CenterThreshold ? v : -(128 - v);
        double distance = ticks * Cfg.WheelUnitsPerTick;
        if (Fast) distance *= Cfg.TouchMultiplier;
        if (Cfg.Invert) distance = -distance;

        bool horizontal = Scroller.KeyboardShiftHeld;

        // Carry fractions forward so low sensitivities still move, but drop them on a direction change.
        if ((remainder < 0) != (distance < 0) || horizontal != remainderHorizontal) remainder = 0;
        remainderHorizontal = horizontal;
        remainder += distance;
        int whole = (int)Math.Truncate(remainder);
        remainder -= whole;
        Scroller.Scroll(whole);
    }

    async Task ReleaseAfterHold(CancellationToken token)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(Math.Max(0, Cfg.TouchHoldSeconds)), token); }
        catch (TaskCanceledException) { return; }
        Fast = false;
    }

    void Learn(MidiMessage m)
    {
        int type = m.Status & 0xF0;
        if (type != 0x80 && type != 0x90 && type != 0xB0) return;
        switch (Step)
        {
            case LearnStep.Touch:
                // Take the first note/CC press as the touch sensor.
                if (!IsTouchDown(m)) return;
                Cfg.Touch = new MidiMatch { Status = m.Status, Data1 = m.Data1 };
                Cfg.PortName = m.Source;
                Step = LearnStep.Spin;
                break;
            case LearnStep.Spin:
                // Wait for the same controller to repeat a few times so a stray button doesn't count.
                if (type != 0xB0 || Cfg.Touch is not { } t || IsTouchMessage(m, t)) return;
                var match = new MidiMatch { Status = m.Status, Data1 = m.Data1 };
                if (match == candidate) candidateCount++; else { candidate = match; candidateCount = 1; }
                if (candidateCount >= 5)
                {
                    Cfg.Jog = match;
                    ConfigFile.Save(Cfg);
                    Step = LearnStep.None;
                    OnLearned?.Invoke();
                }
                break;
        }
    }
}

/// Starts the tray app at login with a per-user Run registry entry.
static class LoginItem
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "Jog Scroll";

    public static string TrayExe => Path.Combine(AppContext.BaseDirectory, "JogScroll.exe");

    public static bool Enabled
    {
        get
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) != null;
        }
        set
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(ValueName, $"\"{TrayExe}\"");
            else key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }
}
