using System.Text.Json.Nodes;
using JogScroll;
using Xunit;

public class MergeSettingsTests
{
    static JsonNode J(string text) => JsonNode.Parse(text)!;

    static void Same(JsonNode? want, JsonNode? got) =>
        Assert.True(JsonNode.DeepEquals(want, got), $"want: {want?.ToJsonString()}\ngot:  {got?.ToJsonString()}");

    public static TheoryData<string, string, string?, string> Merges => new()
    {
        { "no local file: the synced settings as they are",
          """{"portName": "Reloop Ready", "controls": [{"name": "Jog", "type": "jog"}]}""", null,
          """{"portName": "Reloop Ready", "controls": [{"name": "Jog", "type": "jog"}]}""" },
        { "settings in the local file win",
          """{"portName": "Reloop Ready", "connectionAlerts": true}""",
          """{"connectionAlerts": false, "outputPortName": "Lights"}""",
          """{"portName": "Reloop Ready", "connectionAlerts": false, "outputPortName": "Lights"}""" },
        { "a local server replaces the whole synced server with its name, and others are added",
          """{"servers": {"hue": {"url": "http://a/", "headers": {"X": "1"}}, "other": {"url": "http://o/"}}}""",
          """{"servers": {"hue": {"url": "http://b/"}, "zoom": {"url": "http://z/"}}}""",
          """{"servers": {"hue": {"url": "http://b/"}, "other": {"url": "http://o/"}, "zoom": {"url": "http://z/"}}}""" },
        { "a local control replaces the synced control with its name (ignoring case) where it is, and others go at the end",
          """{"controls": [{"name": "Jog", "type": "jog"}, {"name": "Desk", "invert": false}, {"name": "Scope"}]}""",
          """{"controls": [{"name": "Mute"}, {"name": "desk", "invert": true}]}""",
          """{"controls": [{"name": "Jog", "type": "jog"}, {"name": "desk", "invert": true}, {"name": "Scope"}, {"name": "Mute"}]}""" },
        { "only a local file",
          "{}", """{"controls": [{"name": "Mute"}], "servers": {"z": {}}}""",
          """{"controls": [{"name": "Mute"}], "servers": {"z": {}}}""" },
    };

    [Theory, MemberData(nameof(Merges))]
    public void Merge(string what, string synced, string? local, string want)
    {
        _ = what;
        Same(J(want), ConfigFile.MergeSettings(J(synced), local == null ? null : J(local)));
    }

    [Fact]
    public void SplitWithoutLocalFile()
    {
        var merged = J("""{"portName": "X", "controls": [{"name": "Jog"}]}""");
        var (synced, local) = ConfigFile.SplitSettings(merged, J("{}"), null);
        Same(merged, synced);
        Assert.Null(local);
    }

    [Fact]
    public void SplitAfterChanges()
    {
        var synced = J("""{"portName": "Reloop Ready", "connectionAlerts": true, "servers": {"hue": {"url": "http://a/"}}, "controls": [{"name": "Jog", "type": "jog"}, {"name": "Desk", "invert": false}]}""");
        var local = J("""{"connectionAlerts": false, "servers": {"hue": {"url": "http://b/"}}, "controls": [{"name": "Desk", "invert": true}]}""");
        // What the app does: learns the local Desk fader, then adds a new jog wheel at the start.
        var merged = ConfigFile.MergeSettings(synced, local);
        var controls = merged["controls"]!.AsArray();
        controls[1] = J("""{"name": "Desk", "invert": true, "low": 3}""");
        controls.Insert(0, J("""{"name": "Jog 2", "type": "jog"}"""));
        merged["portName"] = "Reloop Ready In";

        var (syncedOut, localOut) = ConfigFile.SplitSettings(merged, synced, local);
        Same(J("""{"portName": "Reloop Ready In", "connectionAlerts": true, "servers": {"hue": {"url": "http://a/"}}, "controls": [{"name": "Jog 2", "type": "jog"}, {"name": "Jog", "type": "jog"}, {"name": "Desk", "invert": false}]}"""), syncedOut);
        Same(J("""{"connectionAlerts": false, "servers": {"hue": {"url": "http://b/"}}, "controls": [{"name": "Desk", "invert": true, "low": 3}]}"""), localOut);
    }

    [Theory]
    [InlineData("""{"controls": [{"name": "A"}, {"name": "B"}]}""", """{"controls": [{"name": "b", "x": 1}, {"name": "Z"}, {"name": "a", "x": 2}]}""")]
    [InlineData("""{"controls": [{"name": "Jog"}]}""", """{"portName": "Here"}""")]
    public void SplitKeepsBothFiles(string synced, string local) => RoundTrip(J(synced), J(local));

    static void RoundTrip(JsonNode synced, JsonNode? local)
    {
        var (s, l) = ConfigFile.SplitSettings(ConfigFile.MergeSettings(synced, local), synced, local);
        Same(synced, s);
        Same(local, l);
    }

    // Splitting merged settings without changing them gives back both files, for any pair of files
    // without two controls of the same name in one file.
    [Fact]
    public void SplitKeepsAnyFiles()
    {
        var random = new Random();
        string[] names = ["Jog", "jog", "Desk", "DESK", "Scope", "Mute", "Puck", "Dictate"];
        JsonNode File()
        {
            var o = new JsonObject();
            foreach (var key in new[] { "portName", "connectionAlerts", "outputPortName" })
                if (random.Next(2) == 0) o[key] = $"{key}-{random.Next(3)}";
            if (random.Next(2) == 0)
            {
                var servers = new JsonObject();
                foreach (var s in new[] { "hue", "zoom", "amp" })
                    if (random.Next(2) == 0) servers[s] = new JsonObject { ["url"] = $"http://{random.Next(9)}/" };
                o["servers"] = servers;
            }
            if (random.Next(2) == 0)
            {
                var seen = new HashSet<string>();
                var controls = new JsonArray();
                foreach (var name in names.OrderBy(_ => random.Next()).Take(random.Next(6)))
                    if (seen.Add(name.ToLowerInvariant())) controls.Add(new JsonObject { ["name"] = name, ["n"] = random.Next(9) });
                o["controls"] = controls;
            }
            return o;
        }
        for (int i = 0; i < 2000; i++) RoundTrip(File(), random.Next(2) == 0 ? File() : null);
    }
}

public sealed class ConfigFileTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "jog-scroll-tests-" + Guid.NewGuid());
    readonly ConfigFiles files;

    public ConfigFileTests()
    {
        Directory.CreateDirectory(dir);
        files = new ConfigFiles(Path.Combine(dir, "config.json"), Path.Combine(dir, "config.local.json"));
    }

    public void Dispose() => Directory.Delete(dir, true);

    [Fact]
    public void LoadsAndSavesBothFiles()
    {
        File.WriteAllText(files.Synced, """{"portName": "Reloop Ready", "controls": [{"name": "Jog", "type": "jog", "actions": [{"type": "scroll", "wheelUnitsPerTick": 5}]}]}""");
        File.WriteAllText(files.Local, """{"servers": {"amp": {"url": "http://localhost:1/"}}, "controls": [{"name": "Puck", "type": "button"}]}""");
        var cfg = ConfigFile.Load(files);
        Assert.Null(ConfigFile.LoadError);
        Assert.Equal(["Jog", "Puck"], cfg.Controls.Select(c => c.Name));
        Assert.Equal("http://localhost:1/", cfg.Servers["amp"].Url);

        cfg.Controls[1].Midi = new MidiMatch { Status = 0x90, Data1 = 7 };
        cfg.Controls[0].Invert = true;
        ConfigFile.Save(cfg, files);
        var local = JsonNode.Parse(File.ReadAllText(files.Local))!;
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse("""[{"actions": [], "invert": false, "midi": {"data1": 7, "status": 144}, "name": "Puck", "type": "button"}]"""), local["controls"]),
            local.ToJsonString());
        var synced = JsonNode.Parse(File.ReadAllText(files.Synced))!;
        Assert.Equal(true, (bool?)synced["controls"]![0]!["invert"]);
        Assert.Null(synced["servers"]);
    }

    [Fact]
    public void SavingDoesNotMakeALocalFile()
    {
        File.WriteAllText(files.Synced, """{"portName": "Reloop Ready"}""");
        ConfigFile.Save(ConfigFile.Load(files), files);
        Assert.False(File.Exists(files.Local));
    }

    [Fact]
    public void ALocalFileThatCantBeReadStopsSaving()
    {
        string syncedText = """{"portName": "Reloop Ready"}""", localText = """{"controls": [{"name": "Puck"}""";
        File.WriteAllText(files.Synced, syncedText);
        File.WriteAllText(files.Local, localText);
        var cfg = ConfigFile.Load(files);
        Assert.NotNull(ConfigFile.LoadError);
        Assert.Equal(files.Local, ConfigFile.LoadErrorPath);
        Assert.Empty(cfg.Controls);
        cfg.PortName = "Changed";
        ConfigFile.Save(cfg, files);
        Assert.Equal(syncedText, File.ReadAllText(files.Synced));
        Assert.Equal(localText, File.ReadAllText(files.Local));
    }

    [Fact]
    public void ANewLocalFileIsAChange()
    {
        File.WriteAllText(files.Synced, "{}");
        var before = ConfigFile.Modified(files);
        File.WriteAllText(files.Local, "{}");
        Assert.NotEqual(before, ConfigFile.Modified(files));
    }
}
