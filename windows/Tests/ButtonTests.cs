using JogScroll;
using Xunit;

public class KeyComboTests
{
    const KeyModifiers Ctrl = KeyModifiers.Control, Shift = KeyModifiers.Shift, Alt = KeyModifiers.Alt, Win = KeyModifiers.Win;

    public static TheoryData<string, ushort, KeyModifiers> Combos => new()
    {
        { "ctrl+shift+option+p", 0x50, Ctrl | Shift | Alt },
        { " Control + Alt + Shift + P ", 0x50, Ctrl | Shift | Alt },
        { "cmd+space", 0x20, Win },
        { "command+shift+4", 0x34, Win | Shift },
        { "f5", 0x74, KeyModifiers.None },
        { "opt+escape", 0x1B, Alt },
        { "ctrl+/", 0xBF, Ctrl },
    };

    [Theory, MemberData(nameof(Combos))]
    public void Parses(string text, ushort key, KeyModifiers modifiers) =>
        Assert.Equal(new KeyCombo(key, modifiers), KeyCombo.Parse(text));

    [Theory]
    [InlineData("")]
    [InlineData("ctrl+shift")]
    [InlineData("p+q")]
    [InlineData("hyper+p")]
    [InlineData("ctrl++p")]
    public void Rejects(string text) => Assert.Throws<FormatException>(() => KeyCombo.Parse(text));

    [Fact]
    public void NamesTheUnknownKey() => Assert.Contains("hyper", Assert.Throws<FormatException>(() => KeyCombo.Parse("hyper+p")).Message);
}

public class ButtonTests
{
    const string Puck = "ctrl+shift+option+p";

    static MidiMessage Note(bool on, byte number, byte velocity = 127) => new((byte)(on ? 0x90 : 0x80), number, velocity, "Reloop Ready");

    static ControlAction Keys(string keys, string? on = null) => new() { Type = "keys", Keys = keys, On = on };

    static MidiControl Control(List<ControlAction> actions, MidiMatch? midi = null) =>
        new() { Name = "Puck", Type = "button", Midi = midi ?? new MidiMatch { Status = 0x90, Data1 = 7 }, Actions = actions };

    /// Sends the messages to a button with these actions, and returns the key combinations it pressed, as the
    /// action's keys, and the errors it reported.
    static (List<string> Keys, List<string> Errors) Pressed(List<ControlAction> actions, MidiMessage[] messages, MidiMatch? midi = null)
    {
        var keys = new List<string>();
        var errors = new List<string>();
        var output = new KeyOutput((_, error) => { if (error != null) errors.Add(error); })
        {
            Post = combo => keys.Add(actions.FirstOrDefault(a => a.Keys != null && Try(a.Keys) == combo)?.Keys ?? "?"),
        };
        var button = new Button(Control(actions, midi), output);
        foreach (var m in messages) button.Handle(m);
        return (keys, errors);
    }

    static KeyCombo? Try(string text) { try { return KeyCombo.Parse(text); } catch (FormatException) { return null; } }

    public static TheoryData<string, List<ControlAction>, MidiMessage[], string[]> Presses => new()
    {
        { "by default, keys are pressed when the button is", [Keys(Puck)], [Note(true, 7), Note(false, 7)], [Puck] },
        { "on release", [Keys(Puck, "release")], [Note(true, 7), Note(false, 7)], [Puck] },
        { "on both: pressing shows Puck and letting go hides it", [Keys(Puck, "both")],
          [Note(true, 7), Note(false, 7), Note(true, 7), Note(false, 7)], [Puck, Puck, Puck, Puck] },
        { "a note on with velocity 0 is letting go", [Keys(Puck, "both")], [Note(true, 7), Note(true, 7, 0)], [Puck, Puck] },
        { "a repeated press counts once", [Keys(Puck, "both")], [Note(true, 7), Note(true, 7)], [Puck] },
        { "letting go without a press does nothing, such as just after learning the button", [Keys(Puck, "both")], [Note(false, 7)], [] },
        { "other notes do nothing", [Keys(Puck, "both")], [Note(true, 8), Note(false, 8)], [] },
        { "the same note on another channel does nothing", [Keys(Puck, "both")], [new MidiMessage(0x91, 7, 127, "")], [] },
        { "each action in turn", [Keys("ctrl+a"), Keys("ctrl+b", "release")], [Note(true, 7), Note(false, 7)], ["ctrl+a", "ctrl+b"] },
    };

    [Theory, MemberData(nameof(Presses))]
    public void Press(string what, List<ControlAction> actions, MidiMessage[] messages, string[] want)
    {
        _ = what;
        Assert.Equal(want, Pressed(actions, messages).Keys);
    }

    [Fact]
    public void ButtonThatSendsACC() =>
        Assert.Equal([Puck, Puck], Pressed([Keys(Puck, "both")], [new(0xB0, 20, 127, ""), new(0xB0, 20, 0, "")], new MidiMatch { Status = 0xB0, Data1 = 20 }).Keys);

    [Fact]
    public void ReportsUnknownKeys()
    {
        var (keys, errors) = Pressed([Keys("hyper+p")], [Note(true, 7)]);
        Assert.Empty(keys);
        Assert.Contains(errors, e => e.Contains("Puck") && e.Contains("hyper"));
    }

    [Fact]
    public void ReportsUnknownOn()
    {
        var (keys, errors) = Pressed([Keys(Puck, "hold")], [Note(true, 7)]);
        Assert.Empty(keys);
        Assert.Contains(errors, e => e.Contains("hold"));
    }

    [Fact]
    public void CantSendRequestsYet() => Assert.NotEmpty(Pressed([new ControlAction { Server = "hue" }], [Note(true, 7)]).Errors);

    [Fact]
    public void Learning()
    {
        var jog = MidiControl.NewJog();
        jog.Midi = new MidiMatch { Status = 0xB0, Data1 = 33 };
        jog.Touch = new MidiMatch { Status = 0x90, Data1 = 54 };
        var puck = Control([]);
        puck.Midi = null;
        var cfg = new Config { Controls = [jog, puck] };
        bool done = false;
        var learner = new ButtonLearner(puck, cfg) { Done = () => done = true };
        learner.Handle(Note(true, 54));                  // touching the jog wheel
        learner.Handle(new MidiMessage(0xB0, 33, 1, ""));
        learner.Handle(Note(false, 9));                  // letting go of something pressed before learning started
        Assert.False(done);
        Assert.Null(puck.Midi);
        learner.Handle(Note(true, 9));
        Assert.True(done);
        Assert.Equal(new MidiMatch { Status = 0x90, Data1 = 9 }, puck.Midi);
    }
}

public class NativeTests
{
    // SendInput needs the size of Windows' INPUT, which is 40 bytes in a 64-bit program (28 in 32-bit).
    [Fact]
    public void InputIsTheSizeWindowsExpects() =>
        Assert.Equal(IntPtr.Size == 8 ? 40 : 28, System.Runtime.InteropServices.Marshal.SizeOf<Native.INPUT>());
}
