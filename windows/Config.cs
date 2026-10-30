using System.Text.Json;

namespace JogScroll;

public sealed record MidiMatch
{
    public byte Status { get; init; }   // status byte including channel, e.g. 0x90 = note on ch 1
    public byte Data1 { get; init; }    // note / controller number

    public string Description
    {
        get
        {
            string kind = (Status & 0xF0) switch
            {
                0x80 or 0x90 => "note",
                0xB0 => "CC",
                _ => $"0x{Status & 0xF0:X2}",
            };
            return $"{kind} {Data1} on channel {(Status & 0x0F) + 1}";
        }
    }
}

// Missing keys keep these defaults, so adding a setting never discards a learned jog wheel.
public sealed class Config
{
    public string PortName { get; set; } = "Reloop Ready";   // substring of the MIDI input name; "" = all inputs
    public MidiMatch? Touch { get; set; }
    public MidiMatch? Jog { get; set; }
    public double TouchHoldSeconds { get; set; } = 1.0;      // how long "fast" lasts after releasing the jog top
    public double TouchMultiplier { get; set; } = 10;        // Bome: if gt>0 then oo=10*oo
    public double WheelUnitsPerTick { get; set; } = 5;       // 120 = one mouse-wheel notch; fractions accumulate
    public bool Invert { get; set; }                         // flip scroll direction
    public int CenterThreshold { get; set; } = 50;           // Bome: values below this are clockwise
    public bool ConnectionAlerts { get; set; } = true;       // notify when the controller is plugged in or out
}

public static class ConfigFile
{
    public static readonly string Path = MakePath();

    static readonly JsonSerializerOptions options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
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
        try { return JsonSerializer.Deserialize<Config>(File.ReadAllText(Path), options) ?? new Config(); }
        catch { return new Config(); }
    }

    public static void Save(Config cfg)
    {
        try { File.WriteAllText(Path, JsonSerializer.Serialize(cfg, options)); }
        catch (IOException) { }
    }

    public static DateTime? Modified() => File.Exists(Path) ? File.GetLastWriteTimeUtc(Path) : null;
}
