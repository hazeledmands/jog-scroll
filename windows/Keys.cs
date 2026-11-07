using System.Runtime.InteropServices;

namespace JogScroll;

[Flags]
public enum KeyModifiers { None = 0, Control = 1, Shift = 2, Alt = 4, Win = 8 }

/// A key and the modifier keys held with it, written like "ctrl+shift+option+p". Option is Alt, and Cmd is the
/// Windows key, so a settings file synced from a Mac reads the same. macos/Keys.swift is the same for the macOS
/// version; change both together.
public readonly record struct KeyCombo(ushort Key, KeyModifiers Modifiers)
{
    static readonly Dictionary<string, KeyModifiers> modifiers = new()
    {
        ["ctrl"] = KeyModifiers.Control, ["control"] = KeyModifiers.Control,
        ["shift"] = KeyModifiers.Shift,
        ["option"] = KeyModifiers.Alt, ["opt"] = KeyModifiers.Alt, ["alt"] = KeyModifiers.Alt,
        ["cmd"] = KeyModifiers.Win, ["command"] = KeyModifiers.Win, ["win"] = KeyModifiers.Win,
    };

    // Windows virtual-key codes.
    static readonly Dictionary<string, ushort> keys = MakeKeys();

    static Dictionary<string, ushort> MakeKeys()
    {
        var k = new Dictionary<string, ushort>
        {
            ["="] = 0xBB, ["-"] = 0xBD, ["]"] = 0xDD, ["["] = 0xDB, ["'"] = 0xDE, [";"] = 0xBA, ["\\"] = 0xDC,
            [","] = 0xBC, ["/"] = 0xBF, ["."] = 0xBE, ["`"] = 0xC0,
            ["return"] = 0x0D, ["enter"] = 0x0D, ["tab"] = 0x09, ["space"] = 0x20, ["delete"] = 0x08, ["backspace"] = 0x08,
            ["escape"] = 0x1B, ["esc"] = 0x1B, ["left"] = 0x25, ["up"] = 0x26, ["right"] = 0x27, ["down"] = 0x28,
        };
        for (char c = 'a'; c <= 'z'; c++) k[c.ToString()] = (ushort)char.ToUpperInvariant(c);
        for (char c = '0'; c <= '9'; c++) k[c.ToString()] = c;
        for (int i = 1; i <= 12; i++) k[$"f{i}"] = (ushort)(0x70 + i - 1);
        return k;
    }

    public static KeyCombo Parse(string text)
    {
        ushort? key = null;
        var held = KeyModifiers.None;
        foreach (var raw in text.Split('+'))
        {
            var part = raw.Trim().ToLowerInvariant();
            if (modifiers.TryGetValue(part, out var modifier)) { held |= modifier; continue; }
            if (!keys.TryGetValue(part, out var code))
                throw new FormatException(part.Length == 0 ? $"\"{text}\" is missing a key" : $"there's no key called \"{part}\" (in \"{text}\")");
            if (key != null) throw new FormatException($"\"{text}\" has more than one key that isn't a modifier");
            key = code;
        }
        if (key == null) throw new FormatException($"\"{text}\" only has modifier keys");
        return new KeyCombo(key.Value, held);
    }
}

/// Carries out a button's actions, which press key combinations as if they were typed: the modifier keys go
/// down, then the key goes down and up, then the modifier keys go up.
public sealed class KeyOutput
{
    /// What presses them. Tests replace it.
    public Action<KeyCombo> Post = Send;
    readonly Action<string, string?> report;

    /// `report` is called after each action with what it went to and null, or why it failed.
    public KeyOutput(Action<string, string?> report) { this.report = report; }

    /// The button was pressed (`down`) or let go.
    public void Press(MidiControl control, ControlAction action, bool down)
    {
        if (!action.IsKeys)
        {
            if (action.IsScroll) report("scroll", $"{control.Name}: only a jog wheel can scroll");
            else if (action.Type != null) report(action.Type, $"{control.Name}: there's no action type called \"{action.Type}\"");
            else report(action.Server ?? "", $"{control.Name}: a button can only press keys so far");
            return;
        }
        var on = (action.On ?? "press").ToLowerInvariant();
        if (on is not ("press" or "release" or "both"))
        {
            report("keys", $"{control.Name}: \"on\" is \"{action.On}\", and it can be \"press\", \"release\" or \"both\"");
            return;
        }
        if (on != "both" && on != (down ? "press" : "release")) return;
        try
        {
            Post(KeyCombo.Parse(action.Keys ?? ""));
            report("keys", null);
        }
        catch (FormatException e)
        {
            report("keys", $"{control.Name}: {e.Message}");
        }
    }

    static readonly (KeyModifiers Modifier, ushort Key)[] modifierKeys =
        [(KeyModifiers.Control, 0x11), (KeyModifiers.Shift, 0x10), (KeyModifiers.Alt, 0x12), (KeyModifiers.Win, 0x5B)];

    static void Send(KeyCombo combo)
    {
        var held = modifierKeys.Where(m => combo.Modifiers.HasFlag(m.Modifier)).Select(m => m.Key).ToList();
        var inputs = new List<Native.INPUT>();
        foreach (var key in held) inputs.Add(Key(key, false));
        inputs.Add(Key(combo.Key, false));
        inputs.Add(Key(combo.Key, true));
        for (int i = held.Count - 1; i >= 0; i--) inputs.Add(Key(held[i], true));
        Native.SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<Native.INPUT>());
    }

    static Native.INPUT Key(ushort key, bool up) => new()
    {
        type = Native.INPUT_KEYBOARD,
        u = new Native.InputUnion { ki = new Native.KEYBDINPUT { wVk = key, dwFlags = up ? Native.KEYEVENTF_KEYUP : 0 } },
    };
}
