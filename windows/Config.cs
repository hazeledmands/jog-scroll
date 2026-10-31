using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace JogScroll;

public sealed record MidiMatch
{
    public byte Status { get; init; }   // status byte including channel, e.g. 0x90 = note on ch 1
    public byte Data1 { get; init; }    // note / controller number (0 for pitch bend, which has none)

    public string Description
    {
        get
        {
            string kind = (Status & 0xF0) switch
            {
                0x80 or 0x90 => "note",
                0xB0 => "CC",
                0xE0 => "pitch bend",
                _ => $"0x{Status & 0xF0:X2}",
            };
            if (kind == "pitch bend") return $"pitch bend on channel {(Status & 0x0F) + 1}";
            return $"{kind} {Data1} on channel {(Status & 0x0F) + 1}";
        }
    }
}

// Missing keys keep these defaults, so adding a setting never discards a learned control.
public sealed class Config
{
    public string PortName { get; set; } = "Reloop Ready";   // substring of the MIDI input name; "" = all inputs
    public bool ConnectionAlerts { get; set; } = true;       // notify when the controller is plugged in or out
    public Dictionary<string, ServerConfig> Servers { get; set; } = new();   // where controls send their changes, by name
    public List<MidiControl> Controls { get; set; } = new();                 // jog wheels, faders and knobs, and what each one does

    // Settings from before the jog wheel was a control. ConfigFile.Load moves them into one.
    public MidiMatch? Touch { get; set; }
    public MidiMatch? Jog { get; set; }
    public double? TouchHoldSeconds { get; set; }
    public double? TouchMultiplier { get; set; }
    public double? WheelUnitsPerTick { get; set; }
    public bool? Invert { get; set; }
    public int? CenterThreshold { get; set; }

    /// The jog wheel that the menu's scrolling settings and Learn Jog Wheel are for: the first one.
    [JsonIgnore] public MidiControl? MainJog => Controls.FirstOrDefault(c => c.IsJog);

    /// Moves the settings from before the jog wheel was a control into a jog control. Returns whether it changed anything.
    public bool Migrate()
    {
        if (Touch == null && Jog == null && TouchHoldSeconds == null && TouchMultiplier == null
            && WheelUnitsPerTick == null && Invert == null && CenterThreshold == null) return false;
        if (MainJog == null)
        {
            var jog = MidiControl.NewJog();
            jog.Midi = Jog;
            jog.Touch = Touch;
            jog.TouchHoldSeconds = TouchHoldSeconds ?? jog.TouchHoldSeconds;
            jog.TouchMultiplier = TouchMultiplier ?? jog.TouchMultiplier;
            jog.CenterThreshold = CenterThreshold ?? jog.CenterThreshold;
            jog.Invert = Invert ?? false;
            jog.Actions[0].WheelUnitsPerTick = WheelUnitsPerTick ?? jog.Actions[0].WheelUnitsPerTick;
            Controls.Insert(0, jog);
        }
        Touch = Jog = null;
        TouchHoldSeconds = TouchMultiplier = WheelUnitsPerTick = null;
        Invert = null;
        CenterThreshold = null;
        return true;
    }
}

/// A server that controls send changes to. Its url and headers can use ${file:PATH#key} and ${env:NAME}.
public sealed class ServerConfig
{
    public string Type { get; set; } = "http";               // the only kind so far
    public string Url { get; set; } = "";                    // action paths are added to this
    public Dictionary<string, string> Headers { get; set; } = new();
}

/// Something on the controller, and what it does. A jog wheel sends turns; a fader or knob sends its position.
public sealed class MidiControl
{
    public string Name { get; set; } = "";
    public string Type { get; set; } = "fader";              // "fader" (also for knobs) or "jog"
    public MidiMatch? Midi { get; set; }                     // learned from the menu or `jog-scroll learn-control`
    public bool Invert { get; set; }                         // a fader whose top sends the lowest value, or a jog turning the other way

    // Faders and knobs
    public byte? Fine { get; set; }                          // for a high-resolution fader: the CC with its fine value
    public int? Low { get; set; }                            // the lowest and highest values it sends, found while learning
    public int? High { get; set; }

    // Jog wheels
    public MidiMatch? Touch { get; set; }                    // the sensor in the jog's top
    public double? TouchMultiplier { get; set; }             // speed-up while the top is touched (Bome: if gt>0 then oo=10*oo)
    public double? TouchHoldSeconds { get; set; }            // how long the speed-up lasts after letting go
    public int? CenterThreshold { get; set; }                // values below this are clockwise

    public List<ControlAction> Actions { get; set; } = new();

    [JsonIgnore] public bool IsJog => Type.Equals("jog", StringComparison.OrdinalIgnoreCase);
    [JsonIgnore] public bool IsFader => Type.Equals("fader", StringComparison.OrdinalIgnoreCase);

    /// A jog wheel that scrolls, with every setting written out so they're easy to find in the settings file.
    public static MidiControl NewJog() => new()
    {
        Name = "Jog",
        Type = "jog",
        TouchMultiplier = 10,
        TouchHoldSeconds = 1.0,
        CenterThreshold = 50,
        Actions = { new ControlAction { Type = "scroll", WheelUnitsPerTick = 5 } },
    };
}

/// One thing a control does when it moves. Either a request to a server, where "$value" in the path or body is
/// the control's position scaled to Range (a body string that's exactly "$value" becomes a number), or, for
/// a jog wheel, scrolling.
public sealed class ControlAction
{
    public string? Type { get; set; }                        // "scroll", or leave it out for a request to a server

    // Requests
    public string? Server { get; set; }
    public string? Method { get; set; }                      // POST if left out
    public string? Path { get; set; }
    public JsonNode? Body { get; set; }
    public double[]? Range { get; set; }                     // the value at the bottom and at the top; [0, 1] if left out
    public int? Decimals { get; set; }

    // Scrolling
    public double? WheelUnitsPerTick { get; set; }           // 120 = one mouse-wheel notch; fractions accumulate

    [JsonIgnore] public bool IsScroll => string.Equals(Type, "scroll", StringComparison.OrdinalIgnoreCase);
}

public static class ConfigFile
{
    public static readonly string Path = MakePath();

    static readonly JsonSerializerOptions options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
    };

    static string MakePath()
    {
        var dir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "jog-scroll");
        Directory.CreateDirectory(dir);
        return System.IO.Path.Combine(dir, "config.json");
    }

    public static Config Load()
    {
        Config cfg;
        try { cfg = JsonSerializer.Deserialize<Config>(File.ReadAllText(Path), options) ?? new Config(); }
        catch { return new Config(); }
        if (cfg.Migrate()) Save(cfg);
        return cfg;
    }

    public static void Save(Config cfg)
    {
        try { File.WriteAllText(Path, JsonSerializer.Serialize(cfg, options)); }
        catch (IOException) { }
    }

    public static DateTime? Modified() => File.Exists(Path) ? File.GetLastWriteTimeUtc(Path) : null;
}
