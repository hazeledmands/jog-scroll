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
    public string Type { get; set; } = "fader";              // "fader" (also for knobs), "jog" or "button"
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
    [JsonIgnore] public bool IsButton => Type.Equals("button", StringComparison.OrdinalIgnoreCase);

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
    public string? Type { get; set; }                        // "scroll", "keys", or leave it out for a request to a server

    // Requests
    public string? Server { get; set; }
    public string? Method { get; set; }                      // POST if left out
    public string? Path { get; set; }
    public JsonNode? Body { get; set; }
    public double[]? Range { get; set; }                     // the value at the bottom and at the top; [0, 1] if left out
    public int? Decimals { get; set; }
    public string? Response { get; set; }                    // where the number to show is in the answer: a key, or keys separated by dots
    public ShowConfig? Show { get; set; }                    // lights on the controller that show that number

    // Pressing keys, for a button
    public string? Keys { get; set; }                        // a key combination, like "ctrl+shift+option+p"
    public string? On { get; set; }                          // "press" (if left out), "release", or "both"

    // Scrolling
    public double? WheelUnitsPerTick { get; set; }           // 120 = one mouse-wheel notch; fractions accumulate
    public double? PixelsPerTick { get; set; }               // the macOS version's setting, kept so a synced file doesn't lose it

    [JsonIgnore] public bool IsScroll => string.Equals(Type, "scroll", StringComparison.OrdinalIgnoreCase);
    [JsonIgnore] public bool IsKeys => string.Equals(Type, "keys", StringComparison.OrdinalIgnoreCase);
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

/// The settings are in two files: config.json, which can be synced between computers, and config.local.json
/// beside it, for settings that stay on this computer. The local file is optional, and wins where they overlap:
/// see ConfigFile.MergeSettings.
public sealed record ConfigFiles(string Synced, string Local);

public static class ConfigFile
{
    public static readonly string Path = MakePath();
    public static readonly ConfigFiles Standard = new(Path, System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Path)!, "config.local.json"));

    static readonly JsonSerializerOptions options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// Why a settings file couldn't be read the last time they were loaded, and which file, or null.
    public static string? LoadError { get; private set; }
    public static string? LoadErrorPath { get; private set; }

    static string MakePath()
    {
        var dir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "jog-scroll");
        Directory.CreateDirectory(dir);
        return System.IO.Path.Combine(dir, "config.json");
    }

    /// Loads the settings, or the defaults if there's no settings file. If one of them can't be read, it returns
    /// the defaults and sets LoadError, and Save won't write over either of them.
    public static Config Load(ConfigFiles? files = null)
    {
        files ??= Standard;
        LoadError = LoadErrorPath = null;
        if (!ReadBoth(files, out var synced, out var local, out var error, out var errorPath))
        {
            LoadError = error;
            LoadErrorPath = errorPath;
            return new Config();
        }
        var cfg = MergeSettings(synced ?? new JsonObject(), local).Deserialize<Config>(options) ?? new Config();
        if (cfg.Migrate()) Save(cfg, files);
        return cfg;
    }

    /// Both files as JSON, or null for one that isn't there, after checking that each can be read as settings.
    static bool ReadBoth(ConfigFiles files, out JsonNode? synced, out JsonNode? local, out string? error, out string? errorPath)
    {
        local = null;
        errorPath = files.Synced;
        if (!Read(files.Synced, out synced, out error)) return false;
        errorPath = files.Local;
        if (!Read(files.Local, out local, out error)) return false;
        errorPath = null;
        return true;
    }

    static bool Read(string path, out JsonNode? json, out string? error)
    {
        json = null;
        error = null;
        if (!File.Exists(path)) return true;
        try
        {
            var text = File.ReadAllText(path);
            _ = JsonSerializer.Deserialize<Config>(text, options);   // for errors that say which setting is wrong
            json = JsonNode.Parse(text) as JsonObject ?? throw new JsonException("The settings need to be a JSON object.");
            return true;
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or NotSupportedException or InvalidOperationException)
        {
            error = e.Message;
            return false;
        }
    }

    /// Saves the settings, each to the file it came from, unless one of the files can't be read. That's usually a
    /// hand edit with a typo, and writing over it would lose it: everywhere, if the file is synced to other computers.
    /// The local file is only written if there is one.
    public static void Save(Config cfg, ConfigFiles? files = null)
    {
        files ??= Standard;
        if (!ReadBoth(files, out var synced, out var local, out _, out _)) return;
        var (syncedOut, localOut) = SplitSettings(JsonSerializer.SerializeToNode(cfg, options)!, synced ?? new JsonObject(), local);
        try
        {
            File.WriteAllText(files.Synced, Serialize(syncedOut));
            if (localOut != null) File.WriteAllText(files.Local, Serialize(localOut));
        }
        catch (IOException) { }
    }

    /// The synced settings with the local ones over them. A setting in the local file wins. A server in the local file
    /// replaces the synced server with its name. A control in the local file replaces the synced control with its name,
    /// ignoring case, where that one is, and the rest go at the end. Nothing inside a server or control is merged.
    /// macos/Config.swift and windows/Config.cs do this the same way; change both together.
    public static JsonNode MergeSettings(JsonNode synced, JsonNode? local)
    {
        var merged = synced.DeepClone();
        if (merged is not JsonObject m || local is not JsonObject l) return merged;
        foreach (var (key, value) in l)
        {
            if (key == "servers" && m[key] is JsonObject servers && value is JsonObject localServers)
            {
                foreach (var (name, server) in localServers) servers[name] = server?.DeepClone();
            }
            else if (key == "controls" && m[key] is JsonArray controls && value is JsonArray localControls)
            {
                foreach (var control in localControls)
                {
                    int i = IndexOf(controls, control);
                    if (i >= 0) controls[i] = control?.DeepClone();
                    else controls.Add(control?.DeepClone());
                }
            }
            else
            {
                m[key] = value?.DeepClone();
            }
        }
        return m;
    }

    /// Splits settings that MergeSettings made, perhaps changed since, back into the two files. `synced` and `local`
    /// are the files as they are now: the synced file keeps what the local file overrides, and everything else that's
    /// in the local file goes back to it. New settings, servers and controls go to the synced file.
    public static (JsonNode Synced, JsonNode? Local) SplitSettings(JsonNode merged, JsonNode synced, JsonNode? local)
    {
        if (merged is not JsonObject m || local is not JsonObject l) return (merged.DeepClone(), null);
        var s = synced as JsonObject ?? new JsonObject();
        JsonObject syncedOut = new(), localOut = new();

        foreach (var (key, value) in m)
        {
            if (key == "servers" && value is JsonObject servers)
            {
                var localNames = (l[key] as JsonObject)?.Select(p => p.Key).ToHashSet() ?? [];
                JsonObject mine = new(), theirs = new();
                if (s[key] is JsonObject syncedServers)
                    foreach (var (name, server) in syncedServers)
                        if (localNames.Contains(name)) theirs[name] = server?.DeepClone();
                foreach (var (name, server) in servers)
                    (localNames.Contains(name) ? mine : theirs)[name] = server?.DeepClone();
                if (l[key] != null) localOut[key] = mine;
                if (s[key] != null || theirs.Count > 0 || l[key] == null) syncedOut[key] = theirs;
            }
            else if (key == "controls" && value is JsonArray controls)
            {
                var localControls = l[key] as JsonArray ?? [];
                var syncedControls = s[key] as JsonArray ?? [];
                var mine = new List<(int Index, JsonNode? Control)>();
                var theirs = new JsonArray();
                foreach (var control in controls)
                {
                    int i = IndexOf(localControls, control);
                    if (i >= 0)
                    {
                        mine.Add((i, control?.DeepClone()));
                        int overridden = IndexOf(syncedControls, control);
                        if (overridden >= 0) theirs.Add(syncedControls[overridden]?.DeepClone());
                    }
                    else
                    {
                        theirs.Add(control?.DeepClone());
                    }
                }
                if (l[key] != null) localOut[key] = new JsonArray(mine.OrderBy(c => c.Index).Select(c => c.Control).ToArray());
                if (s[key] != null || theirs.Count > 0 || l[key] == null) syncedOut[key] = theirs;
            }
            else if (l.ContainsKey(key))
            {
                localOut[key] = value?.DeepClone();
                if (s.ContainsKey(key)) syncedOut[key] = s[key]?.DeepClone();
            }
            else
            {
                syncedOut[key] = value?.DeepClone();
            }
        }
        return (syncedOut, localOut);
    }

    static int IndexOf(JsonArray controls, JsonNode? control)
    {
        var name = Name(control);
        if (name == null) return -1;
        for (int i = 0; i < controls.Count; i++)
            if (string.Equals(Name(controls[i]), name, StringComparison.OrdinalIgnoreCase)) return i;
        return -1;
    }

    static string? Name(JsonNode? control) =>
        control is JsonObject o && o["name"] is JsonValue v && v.TryGetValue<string>(out var name) ? name : null;

    /// The settings as JSON, written exactly as the macOS version writes them (canonicalJSON in macos/Config.swift),
    /// so a file synced between the two only changes where a setting did: keys in ordinal order, two-space indents,
    /// "key": value, \n line endings, and only the characters JSON requires escaped.
    public static string Serialize(Config cfg) => Serialize(JsonSerializer.SerializeToNode(cfg, options));

    static string Serialize(JsonNode? json)
    {
        var text = new StringBuilder();
        Write(json, "", text);
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

    /// When each settings file last changed, to notice edits to either.
    public static (DateTime?, DateTime?) Modified(ConfigFiles? files = null)
    {
        files ??= Standard;
        static DateTime? When(string path) => File.Exists(path) ? File.GetLastWriteTimeUtc(path) : null;
        return (When(files.Synced), When(files.Local));
    }
}
