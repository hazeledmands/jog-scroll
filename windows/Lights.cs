using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace JogScroll;

/// Turns faders and knobs into light changes, sent to Hue Tray's local API. Everything runs on the UI thread.
public sealed class LightControls
{
    readonly JogEngine engine;   // for the config and the controller's port
    readonly HueTrayClient hue = new();
    readonly Dictionary<LightControl, int> coarse = new();   // latest coarse value of each high-resolution control
    LightControl? learning;
    readonly List<MidiMessage> heard = new();                // while learning: everything the controls sent
    CancellationTokenSource? stillTimer;

    public Action? OnChange;
    public Action<LightControl>? OnLearned;

    public LightControls(JogEngine engine) { this.engine = engine; }

    /// Called after each request with null, or why it failed.
    public Action<string?>? OnResult { set => hue.OnResult = value; }

    List<LightControl> Controls => engine.Cfg.LightControls;

    public LightControl? Learning { get => learning; private set { learning = value; OnChange?.Invoke(); } }

    public LightControl? Find(string name) =>
        Controls.FirstOrDefault(c => string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase));

    public void StartLearning(LightControl control)
    {
        heard.Clear();
        Learning = control;
    }

    public void CancelLearning()
    {
        stillTimer?.Cancel();
        Learning = null;
    }

    /// Returns whether the message was for a light control, or taken by learning.
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
            bool kelvin = control.Set.Equals("colorTemp", StringComparison.OrdinalIgnoreCase);
            double min = control.Min ?? (kelvin ? 2000 : 0), max = control.Max ?? (kelvin ? 6500 : 100);
            double level = min + position * (max - min);
            foreach (var path in control.Targets)
                hue.Set(path, kelvin ? "colorTemp" : "brightness", kelvin ? Math.Round(level) : Math.Round(level, 1));
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

    void Finish(LightControl target)
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

/// Sends changes to Hue Tray, one request at a time per light or group. Changes made while a request
/// is on its way are merged into the next one, so a fast fader sweep doesn't pile up requests.
sealed class HueTrayClient
{
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(3) };
    readonly Dictionary<string, JsonObject> pending = new();   // path -> fields waiting to be sent
    readonly HashSet<string> sending = new();

    public Action<string?>? OnResult;

    public void Set(string path, string field, double value)
    {
        if (!pending.TryGetValue(path, out var body)) pending[path] = body = new JsonObject();
        body[field] = value;
        if (sending.Add(path)) _ = Send(path);
    }

    async Task Send(string path)
    {
        try
        {
            while (pending.Remove(path, out var body))
                OnResult?.Invoke(await Patch(path, body));
        }
        finally { sending.Remove(path); }
    }

    static async Task<string?> Patch(string path, JsonObject body)
    {
        if (HueTraySettings.Read() is not (int port, string token)) return "Hue Tray isn't set up on this computer";
        var url = $"http://127.0.0.1:{port}/api/v1/" + string.Join('/', path.Split('/').Select(Uri.EscapeDataString));
        using var request = new HttpRequestMessage(HttpMethod.Patch, url)
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        try
        {
            using var response = await http.SendAsync(request);
            if (response.IsSuccessStatusCode) return null;
            string text = await response.Content.ReadAsStringAsync();
            string? error = null;
            try { error = JsonNode.Parse(text)?["error"]?.GetValue<string>(); } catch (JsonException) { }
            return $"Hue Tray couldn't change {path}: {error ?? ((int)response.StatusCode).ToString(CultureInfo.InvariantCulture)}";
        }
        catch (HttpRequestException) { return "Hue Tray isn't running"; }
        catch (TaskCanceledException) { return "Hue Tray didn't answer"; }
    }
}

/// Hue Tray's API port and token, from its own settings file, so there's nothing to copy across.
static class HueTraySettings
{
    static readonly string Path = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "hue-tray", "config.json");
    static DateTime? readDate;
    static (int Port, string Token)? cached;

    public static (int Port, string Token)? Read()
    {
        var date = File.Exists(Path) ? File.GetLastWriteTimeUtc(Path) : (DateTime?)null;
        if (date == readDate) return cached;
        readDate = date;
        cached = null;
        try
        {
            var json = JsonNode.Parse(File.ReadAllText(Path));
            int port = json?["apiPort"]?.GetValue<int>() ?? 8765;
            if (json?["apiToken"]?.GetValue<string>() is { Length: > 0 } token) cached = (port, token);
        }
        catch (Exception e) when (e is IOException or JsonException or InvalidOperationException) { }
        return cached;
    }
}
