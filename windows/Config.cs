using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace JogScroll;

public sealed record MidiMatch
{
    public byte Status { get; init; }   // status byte including channel, e.g. 0x90 = note on ch 1
    public byte Data1 { get; init; }    // note / controller number (0 for pitch bend, which has none)

    [JsonIgnore]
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
    public string? OutputPortName { get; set; }              // MIDI output for the controller's lights; worked out from PortName if left out
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

    /// The MIDI output for the controller's lights: OutputPortName, or PortName with "In" at the end changed to "Out".
    [JsonIgnore]
    public string OutputPort => OutputPortName
        ?? (PortName.EndsWith(" In", StringComparison.OrdinalIgnoreCase) ? PortName[..^3] + " Out" : PortName);

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
    public string? Response { get; set; }                    // where the number to show is in the answer: a key, or keys separated by dots
    public ShowConfig? Show { get; set; }                    // lights on the controller that show that number

    // Scrolling
    public double? WheelUnitsPerTick { get; set; }           // 120 = one mouse-wheel notch; fractions accumulate
    public double? PixelsPerTick { get; set; }               // the macOS version's setting, kept so a synced file doesn't lose it

    [JsonIgnore] public bool IsScroll => string.Equals(Type, "scroll", StringComparison.OrdinalIgnoreCase);
}

/// Lights on the controller that show a number by lighting that many of them, for a moment. The number is the one
/// in the answer that Response points to, or the value sent if there's no Response.
public sealed class ShowConfig
{
    public List<MidiMatch> Lights { get; set; } = new();     // in order: the first lights for 1, the first two for 2…
    public int On { get; set; } = 127;                       // the value that lights one. On some controllers, it's the color
    public int Off { get; set; }
    public double Seconds { get; set; } = 1;                 // how long they stay lit after the last change
}

public static class ConfigFile
{
    public static readonly string Path = MakePath();

    static readonly JsonSerializerOptions options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// Why the settings file couldn't be read the last time it was loaded, or null.
    public static string? LoadError { get; private set; }

    static string MakePath()
    {
        var dir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "jog-scroll");
        Directory.CreateDirectory(dir);
        return System.IO.Path.Combine(dir, "config.json");
    }

    /// Loads the settings, or the defaults if there's no settings file. If there's one that can't be read, it
    /// returns the defaults and sets LoadError, and Save won't write over it.
    public static Config Load()
    {
        LoadError = null;
        if (!File.Exists(Path)) return new Config();
        var cfg = Read(out var error);
        if (cfg == null)
        {
            LoadError = error;
            return new Config();
        }
        if (cfg.Migrate()) Save(cfg);
        return cfg;
    }

    static Config? Read(out string? error)
    {
        error = null;
        try { return JsonSerializer.Deserialize<Config>(File.ReadAllText(Path), options) ?? new Config(); }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or NotSupportedException or InvalidOperationException)
        {
            error = e.Message;
            return null;
        }
    }

    /// Saves the settings, unless the file there can't be read. That's usually a hand edit with a typo, and
    /// writing over it would lose it: everywhere, if the file is synced to other computers.
    public static void Save(Config cfg)
    {
        if (File.Exists(Path) && Read(out _) == null) return;
        try { File.WriteAllText(Path, Serialize(cfg)); }
        catch (IOException) { }
    }

    /// The settings as JSON, written exactly as the macOS version writes them (canonicalJSON in macos/Config.swift),
    /// so a file synced between the two only changes where a setting did: keys in ordinal order, two-space indents,
    /// "key": value, \n line endings, and only the characters JSON requires escaped.
    public static string Serialize(Config cfg)
    {
        var text = new StringBuilder();
        Write(JsonSerializer.SerializeToNode(cfg, options), "", text);
        return text.Append('\n').ToString();
    }

    static void Write(JsonNode? node, string indent, StringBuilder text)
    {
        string inner = indent + "  ";
        switch (node)
        {
            case null:
                text.Append("null");
                break;
            case JsonObject o when o.Count == 0:
                text.Append("{}");
                break;
            case JsonObject o:
                text.Append("{\n");
                bool first = true;
                foreach (var (key, value) in o.OrderBy(p => p.Key, StringComparer.Ordinal))
                {
                    if (!first) text.Append(",\n");
                    first = false;
                    text.Append(inner);
                    Quote(key, text);
                    text.Append(": ");
                    Write(value, inner, text);
                }
                text.Append('\n').Append(indent).Append('}');
                break;
            case JsonArray a when a.Count == 0:
                text.Append("[]");
                break;
            case JsonArray a:
                text.Append("[\n");
                for (int i = 0; i < a.Count; i++)
                {
                    if (i > 0) text.Append(",\n");
                    text.Append(inner);
                    Write(a[i], inner, text);
                }
                text.Append('\n').Append(indent).Append(']');
                break;
            case JsonValue v when v.GetValueKind() == JsonValueKind.String:
                Quote(v.GetValue<string>(), text);
                break;
            default:
                text.Append(node.ToJsonString());   // numbers in their shortest form, true, false
                break;
        }
    }

    static void Quote(string s, StringBuilder text)
    {
        text.Append('"');
        foreach (char c in s)
        {
            switch (c)
            {
                case '"': text.Append("\\\""); break;
                case '\\': text.Append("\\\\"); break;
                case '\n': text.Append("\\n"); break;
                case '\r': text.Append("\\r"); break;
                case '\t': text.Append("\\t"); break;
                case '\b': text.Append("\\b"); break;
                case '\f': text.Append("\\f"); break;
                case < ' ': text.Append($"\\u{(int)c:X4}"); break;
                default: text.Append(c); break;
            }
        }
        text.Append('"');
    }

    public static DateTime? Modified() => File.Exists(Path) ? File.GetLastWriteTimeUtc(Path) : null;
}
