using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace JogScroll;

/// A kind of server that controls send to. Only HTTP so far; OSC, WebSocket or MQTT would be others.
interface IOutput
{
    /// `value` is the control's position, already scaled to the action's range.
    void Send(ControlAction action, double value);
}

/// Carries out actions: scrolling, requests to servers, and showing numbers on the controller's lights. It
/// makes an output for each server in the settings as it's first needed, and again after the settings change.
/// Everything runs on the UI thread.
public sealed class Outputs
{
    readonly Func<Dictionary<string, ServerConfig>> servers;
    readonly Dictionary<string, (ServerConfig Config, IOutput Output)> made = new();
    public readonly ScrollOutput Scroll = new();
    public readonly Lights Lights;

    /// Called after each request with the server's name (or "scroll" or "lights") and null, or why it failed.
    public Action<string, string?>? OnResult;

    public Outputs(Func<Dictionary<string, ServerConfig>> servers, Func<string> outputPort)
    {
        this.servers = servers;
        Lights = new Lights(outputPort, error => OnResult?.Invoke("lights", error));
    }

    /// For a jog wheel: it turned this many ticks, already sped up and inverted as the control says.
    public void Turn(MidiControl control, ControlAction action, double ticks)
    {
        if (action.IsScroll) Scroll.Turn(action, ticks);
        else if (action.Type != null) OnResult?.Invoke(action.Type, $"{control.Name}: there's no action type called \"{action.Type}\"");
        else OnResult?.Invoke(action.Server ?? "", $"{control.Name}: a jog wheel can only scroll so far");
    }

    /// For a fader or knob: it's at this position, from 0 at the bottom to 1 at the top.
    public void SetPosition(MidiControl control, ControlAction action, double position)
    {
        if (action.IsScroll)
        {
            OnResult?.Invoke("scroll", $"{control.Name}: only a jog wheel can scroll");
            return;
        }
        if (action.Type != null)
        {
            OnResult?.Invoke(action.Type, $"{control.Name}: there's no action type called \"{action.Type}\"");
            return;
        }
        string name = action.Server ?? "";
        if (!servers().TryGetValue(name, out var config))
        {
            OnResult?.Invoke(name, $"There's no server called \"{name}\" in the settings");
            return;
        }
        if (!made.TryGetValue(name, out var entry) || entry.Config != config)
        {
            IOutput? output = config.Type.ToLowerInvariant() switch
            {
                "http" => new HttpOutput(name, config, result => OnResult?.Invoke(name, result), Answered),
                _ => null,
            };
            if (output == null)
            {
                OnResult?.Invoke(name, $"{name}: there's no server type called \"{config.Type}\"");
                return;
            }
            made[name] = entry = (config, output);
        }
        var range = action.Range ?? new double[] { 0, 1 };
        double low = range.ElementAtOrDefault(0), high = range.Length > 1 ? range[1] : 1;
        double value = Math.Round(low + position * (high - low), Math.Clamp(action.Decimals ?? 0, 0, 15));
        entry.Output.Send(action, value);
        if (action.Show is { } show && action.Response == null) Lights.Show(show, value);   // nothing to wait for
    }

    /// A server answered a request that this action was part of.
    void Answered(ControlAction action, JsonNode? answer)
    {
        if (action.Show is not { } show || action.Response is not { } path) return;
        if (Find(answer, path) is double number) Lights.Show(show, number);
        else OnResult?.Invoke("lights", $"The answer to {action.Method ?? "POST"} {action.Path} has no number at \"{path}\"");
    }

    /// The number at a key in a JSON answer, or at keys separated by dots ("scope.index") in objects inside it.
    public static double? Find(JsonNode? node, string path)
    {
        foreach (var key in path.Split('.'))
            node = node is JsonObject o ? o[key] : null;
        return node is JsonValue v && v.TryGetValue<double>(out var d) ? d : null;
    }

    /// Forgets what belonged to the old settings.
    public void Reset() => Scroll.Reset();
}

/// Shows numbers on the controller's lights: lights that many of a group, and turns them all off a moment after the last change.
public sealed class Lights
{
    readonly MidiOutput output = new();
    readonly Func<string> port;
    readonly Action<string?> report;
    readonly Dictionary<ShowConfig, CancellationTokenSource> timers = new(ReferenceEqualityComparer.Instance);

    public Lights(Func<string> port, Action<string?> report)
    {
        this.port = port;
        this.report = report;
    }

    public void Show(ShowConfig show, double number)
    {
        int count = (int)Math.Clamp(Math.Round(number), 0, show.Lights.Count);
        for (int i = 0; i < show.Lights.Count; i++)
            if (!Set(show.Lights[i], i < count ? show.On : show.Off)) return;
        report(null);

        if (timers.Remove(show, out var old)) old.Cancel();
        var cts = new CancellationTokenSource();
        timers[show] = cts;
        _ = OffAfter(show, cts.Token);
    }

    async Task OffAfter(ShowConfig show, CancellationToken token)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(Math.Max(0, show.Seconds)), token); }
        catch (TaskCanceledException) { return; }
        timers.Remove(show);
        foreach (var light in show.Lights)
            if (!Set(light, show.Off)) return;
    }

    bool Set(MidiMatch light, int value)
    {
        output.Port = port();
        var error = output.Send(light.Status, light.Data1, (byte)Math.Clamp(value, 0, 127));
        if (error != null) report(error);
        return error == null;
    }
}

/// Scrolls the window under the mouse. While Shift is held, apps scroll sideways instead.
public sealed class ScrollOutput
{
    public const double DefaultWheelUnitsPerTick = 5;

    // Sub-unit scroll carried over to the next tick, for each scroll action.
    readonly Dictionary<ControlAction, (double Remainder, bool Horizontal)> carried = new(ReferenceEqualityComparer.Instance);

    public bool Enabled = true;

    public void Turn(ControlAction action, double ticks)
    {
        if (!Enabled) return;
        double distance = ticks * (action.WheelUnitsPerTick ?? DefaultWheelUnitsPerTick);
        bool horizontal = Scroller.KeyboardShiftHeld;

        // Carry fractions forward so low sensitivities still move, but drop them on a direction change.
        var (remainder, wasHorizontal) = carried.GetValueOrDefault(action);
        if ((remainder < 0) != (distance < 0) || horizontal != wasHorizontal) remainder = 0;
        remainder += distance;
        int whole = (int)Math.Truncate(remainder);
        carried[action] = (remainder - whole, horizontal);
        Scroller.Scroll(whole);
    }

    public void Reset() => carried.Clear();
}

static class Scroller
{
    /// Positive scrolls up. Sideways scrolling needs nothing extra: like a real mouse, we send a vertical
    /// wheel event while Shift is held, and apps turn that into scrolling left (positive) or right.
    /// A horizontal wheel event doesn't work here, because apps such as Chrome swap its axis when Shift is down.
    public static void Scroll(int units)
    {
        if (units == 0) return;
        var input = new Native.INPUT
        {
            type = Native.INPUT_MOUSE,
            mi = new Native.MOUSEINPUT
            {
                mouseData = unchecked((uint)Math.Clamp(units, -10_000, 10_000)),
                dwFlags = Native.MOUSEEVENTF_WHEEL,
            },
        };
        Native.SendInput(1, new[] { input }, System.Runtime.InteropServices.Marshal.SizeOf<Native.INPUT>());
    }

    /// Whether either physical Shift key is down.
    public static bool KeyboardShiftHeld =>
        (Native.GetAsyncKeyState(Native.VK_LSHIFT) & 0x8000) != 0 || (Native.GetAsyncKeyState(Native.VK_RSHIFT) & 0x8000) != 0;
}

/// Sends actions as HTTP requests, one at a time for each method and path. Changes made while a request
/// is on its way are merged into the next one, so a fast fader sweep doesn't pile up requests, and two
/// controls changing the same thing (say brightness and color temperature) share requests.
sealed class HttpOutput : IOutput
{
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(3) };
    readonly string name;
    readonly ServerConfig config;
    readonly Action<string?> report;
    readonly Action<ControlAction, JsonNode?> answered;
    readonly Dictionary<(string Method, string Path), JsonNode?> pending = new();   // the body waiting to be sent
    readonly Dictionary<(string Method, string Path), HashSet<ControlAction>> pendingActions = new();   // the actions in it
    readonly HashSet<(string Method, string Path)> sending = new();

    /// `answered` is called with each action in a request that succeeded, and the server's answer.
    public HttpOutput(string name, ServerConfig config, Action<string?> report, Action<ControlAction, JsonNode?> answered)
    {
        this.name = name;
        this.config = config;
        this.report = report;
        this.answered = answered;
    }

    public void Send(ControlAction action, double value)
    {
        string text = value.ToString(CultureInfo.InvariantCulture);
        var key = ((action.Method ?? "POST").ToUpperInvariant(), (action.Path ?? "").Replace("$value", text));
        var body = Fill(action.Body?.DeepClone(), value, text);
        if (pending.TryGetValue(key, out var waiting) && waiting is JsonObject merged && body is JsonObject fields)
        {
            foreach (var (field, node) in fields.ToList())
            {
                fields.Remove(field);
                merged[field] = node;
            }
        }
        else
        {
            pending[key] = body;
        }
        if (!pendingActions.TryGetValue(key, out var actions)) pendingActions[key] = actions = new(ReferenceEqualityComparer.Instance);
        actions.Add(action);
        if (sending.Add(key)) _ = Run(key);
    }

    /// Puts the value into the body: a string that's exactly "$value" becomes the number, and "$value"
    /// inside a longer string is replaced as text.
    static JsonNode? Fill(JsonNode? node, double value, string text)
    {
        switch (node)
        {
            case JsonObject o:
                foreach (var field in o.Select(p => p.Key).ToList())
                {
                    var child = o[field];
                    var filled = Fill(child, value, text);
                    if (!ReferenceEquals(filled, child)) o[field] = filled;
                }
                return o;
            case JsonArray a:
                for (int i = 0; i < a.Count; i++)
                {
                    var child = a[i];
                    var filled = Fill(child, value, text);
                    if (!ReferenceEquals(filled, child)) a[i] = filled;
                }
                return a;
            case JsonValue v when v.TryGetValue<string>(out var s) && s.Contains("$value"):
                return s == "$value" ? JsonValue.Create(value) : JsonValue.Create(s.Replace("$value", text));
            default:
                return node;
        }
    }

    async Task Run((string Method, string Path) key)
    {
        try
        {
            while (pending.Remove(key, out var body))
            {
                pendingActions.Remove(key, out var actions);
                var (error, answer) = await Request(key.Method, key.Path, body);
                report(error);
                if (error == null && actions != null)
                    foreach (var action in actions) answered(action, answer);
            }
        }
        finally { sending.Remove(key); }
    }

    /// Returns why it failed, or null and the server's answer (null if it wasn't JSON).
    async Task<(string? Error, JsonNode? Answer)> Request(string method, string path, JsonNode? body)
    {
        HttpRequestMessage request;
        try
        {
            request = new HttpRequestMessage(new HttpMethod(method), Url(Substitutions.Apply(config.Url), path));
            foreach (var (header, value) in config.Headers)
                request.Headers.TryAddWithoutValidation(header, Substitutions.Apply(value));
        }
        catch (FormatException e) { return ($"{name}: {e.Message}", null); }   // UriFormatException is one too
        if (body != null) request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

        using (request)
        {
            try
            {
                using var response = await http.SendAsync(request);
                string text = await response.Content.ReadAsStringAsync();
                if (response.IsSuccessStatusCode)
                {
                    try { return (null, text.Length == 0 ? null : JsonNode.Parse(text)); }
                    catch (JsonException) { return (null, null); }
                }
                string? error = null;
                try { error = JsonNode.Parse(text)?["error"]?.GetValue<string>(); }
                catch (Exception e) when (e is JsonException or InvalidOperationException) { }
                return ($"{name}: couldn't {method} {path}: {error ?? ((int)response.StatusCode).ToString(CultureInfo.InvariantCulture)}", null);
            }
            catch (HttpRequestException) { return ($"Couldn't reach {name}. Is it running?", null); }
            catch (TaskCanceledException) { return ($"{name} didn't answer", null); }
        }
    }

    /// The server's URL with the path added. Each part of the path is escaped, so names can have spaces.
    static string Url(string url, string path)
    {
        if (path.Length == 0) return url;
        int q = path.IndexOf('?');
        string query = q < 0 ? "" : path[q..];
        string parts = string.Join('/', (q < 0 ? path : path[..q]).Split('/').Select(Uri.EscapeDataString));
        return url.TrimEnd('/') + "/" + parts.TrimStart('/') + query;
    }
}

/// Fills in ${file:PATH#key} (a top-level value from a JSON file, such as another program's settings)
/// and ${env:NAME} (an environment variable) in server URLs and headers.
static class Substitutions
{
    static readonly Regex pattern = new(@"\$\{(file|env):([^}]*)\}");
    static readonly Dictionary<string, (DateTime? Date, JsonNode? Json)> files = new();   // re-read when they change

    public static string Apply(string s) => pattern.Replace(s, m => m.Groups[1].Value == "env"
        ? Environment.GetEnvironmentVariable(m.Groups[2].Value)
            ?? throw new FormatException($"the environment variable {m.Groups[2].Value} isn't set")
        : FromFile(m.Groups[2].Value));

    static string FromFile(string spec)
    {
        int hash = spec.LastIndexOf('#');
        if (hash < 0) throw new FormatException($"${{file:{spec}}} needs #key after the file name");
        string path = Environment.ExpandEnvironmentVariables(spec[..hash]), key = spec[(hash + 1)..];

        var date = File.Exists(path) ? File.GetLastWriteTimeUtc(path) : (DateTime?)null;
        if (!files.TryGetValue(path, out var cached) || cached.Date != date)
        {
            JsonNode? json = null;
            try { json = JsonNode.Parse(File.ReadAllText(path)); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
            files[path] = cached = (date, json);
        }
        if (cached.Json is not JsonObject o) throw new FormatException($"couldn't read {path}");
        if (o[key] is not JsonValue v) throw new FormatException($"{path} has no \"{key}\"");
        return v.ToString();
    }
}
