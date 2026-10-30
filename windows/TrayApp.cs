using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Reflection;

namespace JogScroll;

/// The notification-area icon and its menu: the Windows version of the macOS menu bar app.
sealed class TrayApp : ApplicationContext
{
    static readonly double[] SensitivityPresets = { 2, 3, 5, 8, 12, 20, 30, 60, 120 };

    readonly JogEngine engine = new(ConfigFile.Load());
    readonly MidiInput input;
    readonly NotifyIcon tray;
    readonly ContextMenuStrip menu = new();
    readonly TrayIcons icons = new();
    readonly System.Windows.Forms.Timer poll = new() { Interval = 2000 };
    DateTime? configDate = ConfigFile.Modified();
    JogEngine.LearnStep shownStep = JogEngine.LearnStep.None;
    bool wasConnected;
    bool quiet;   // no connection alerts while we change which devices are open ourselves

    public TrayApp()
    {
        tray = new NotifyIcon { ContextMenuStrip = menu, Text = "Jog Scroll" };
        menu.Opening += (_, _) => BuildMenu();
        // Open the menu on a left click too, like a macOS menu bar item.
        tray.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left)
                typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)
                    ?.Invoke(tray, null);
        };

        engine.OnChange = Refresh;
        engine.OnLearned = () =>
        {
            configDate = ConfigFile.Modified();
            Notify("Learned ✓", $"Jog = {engine.Cfg.Jog!.Description}");
        };
        input = new MidiInput(m => engine.Handle(m), WantDevice) { Verbose = false };
        wasConnected = DeviceConnected;   // no alert for the state at launch
        input.OnSourcesChanged = SourcesChanged;

        // Every 2 s: pick up hand edits to config.json.
        poll.Tick += (_, _) => PollConfig();
        poll.Start();

        tray.Visible = true;
        if (!engine.IsConfigured) engine.StartLearning();
        Refresh();
    }

    // Learning listens to every input to find the controller. Otherwise open only the controller,
    // because opening a MIDI device on Windows keeps other programs from using it.
    bool WantDevice(string name) => engine.Step != JogEngine.LearnStep.None || engine.MatchesPort(name);

    bool DeviceConnected => input.SourceNames.Any(engine.MatchesPort);
    bool DeviceBusy => input.BusyNames.Any(engine.MatchesPort);

    string DeviceLabel => engine.Cfg.PortName.Length == 0 ? "MIDI controller" : engine.Cfg.PortName;

    void PollConfig()
    {
        var date = ConfigFile.Modified();
        if (date != configDate && engine.Step == JogEngine.LearnStep.None)
        {
            configDate = date;
            engine.Cfg = ConfigFile.Load();
            Reconnect();
        }
        Refresh();   // also redraws the icon if the taskbar switched between light and dark
    }

    /// Reopens devices after a change to which ones we want, without alerting about it.
    void Reconnect()
    {
        quiet = true;
        input.Refresh();
        quiet = false;
        wasConnected = DeviceConnected;
    }

    void SourcesChanged()
    {
        bool connected = DeviceConnected;
        // Only alert when the controller's state actually flips.
        if (!quiet && connected != wasConnected && engine.Step == JogEngine.LearnStep.None && engine.Cfg.ConnectionAlerts)
        {
            Notify(connected ? $"{DeviceLabel} connected" : $"{DeviceLabel} disconnected",
                   connected ? "Jog scrolling is ready." : "Jog scrolling is paused until it's plugged back in.");
        }
        wasConnected = connected;
        Refresh();
    }

    // On Windows 10 and 11 these show as notifications. Showing a new one replaces the last.
    void Notify(string title, string body) => tray.ShowBalloonTip(5000, title, body, ToolTipIcon.None);

    void Refresh()
    {
        if (engine.Step != shownStep)
        {
            shownStep = engine.Step;
            switch (shownStep)
            {
                case JogEngine.LearnStep.Touch: Notify("Learn Jog Wheel", "Touch the top of the jog wheel, then let go."); break;
                case JogEngine.LearnStep.Spin: Notify("Learn Jog Wheel", "Now spin the jog wheel slowly by its edge."); break;
            }
            Reconnect();
        }

        bool dim = !engine.Enabled || !DeviceConnected;
        tray.Icon = icons.Get(engine.Fast, dim);
        var text = "Jog Scroll: " + Status();
        tray.Text = text.Length > 127 ? text[..127] : text;
    }

    string Status()
    {
        switch (engine.Step)
        {
            case JogEngine.LearnStep.Touch: return "Touch the jog top";
            case JogEngine.LearnStep.Spin: return "Now spin the jog edge";
        }
        if (!engine.IsConfigured) return "Jog wheel not learned yet";
        if (DeviceConnected) return engine.Enabled ? $"Connected: {engine.Cfg.PortName}" : "Paused";
        if (DeviceBusy) return $"{DeviceLabel} is in use by another program";
        return $"Waiting for {(engine.Cfg.PortName.Length == 0 ? "a MIDI device" : engine.Cfg.PortName)}…";
    }

    void BuildMenu()
    {
        menu.Items.Clear();
        string status = engine.Step != JogEngine.LearnStep.None ? "Learning: " + Status()
            : DeviceConnected ? $"Connected: {engine.Cfg.PortName}" : Status();
        menu.Items.Add(new ToolStripMenuItem(status) { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add(Item("Scrolling On", engine.Enabled, () => engine.Enabled = !engine.Enabled));
        menu.Items.Add(Item("Invert Direction", engine.Cfg.Invert, () => ChangeConfig(c => c.Invert = !c.Invert)));
        menu.Items.Add(SensitivityMenu());
        menu.Items.Add(Item("Connection Alerts", engine.Cfg.ConnectionAlerts,
                            () => ChangeConfig(c => c.ConnectionAlerts = !c.ConnectionAlerts)));
        menu.Items.Add(new ToolStripSeparator());

        if (engine.Step == JogEngine.LearnStep.None)
            menu.Items.Add(Item("Learn Jog Wheel…", false, engine.StartLearning));
        else
            menu.Items.Add(Item("Cancel Learning", false, () => { engine.CancelLearning(); engine.Cfg = ConfigFile.Load(); Reconnect(); Refresh(); }));
        menu.Items.Add(Item("Open Settings File", false, OpenSettings));
        menu.Items.Add(Item("Start at Login", LoginItem.Enabled, () => LoginItem.Enabled = !LoginItem.Enabled));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item("Quit Jog Scroll", false, Quit));
    }

    ToolStripMenuItem SensitivityMenu()
    {
        double current = engine.Cfg.WheelUnitsPerTick;
        var parent = new ToolStripMenuItem($"Sensitivity: {Formatted(current)}");
        var presets = SensitivityPresets.Contains(current) ? SensitivityPresets
            : SensitivityPresets.Append(current).Order().ToArray();   // hand-edited value
        foreach (var value in presets)
            parent.DropDownItems.Add(Item($"{Formatted(value)} per tick", value == current,
                                          () => ChangeConfig(c => c.WheelUnitsPerTick = value)));
        parent.DropDownItems.Add(new ToolStripSeparator());
        parent.DropDownItems.Add(new ToolStripMenuItem("120 = one mouse-wheel notch") { Enabled = false });
        return parent;
    }

    static string Formatted(double v) => v.ToString("0.##");

    static ToolStripMenuItem Item(string title, bool check, Action action)
    {
        var item = new ToolStripMenuItem(title) { Checked = check };
        item.Click += (_, _) => action();
        return item;
    }

    void ChangeConfig(Action<Config> change)
    {
        change(engine.Cfg);
        ConfigFile.Save(engine.Cfg);
        configDate = ConfigFile.Modified();
    }

    void OpenSettings()
    {
        if (!File.Exists(ConfigFile.Path)) ConfigFile.Save(engine.Cfg);
        Process.Start(new ProcessStartInfo("notepad.exe", $"\"{ConfigFile.Path}\"") { UseShellExecute = true });
    }

    void Quit()
    {
        tray.Visible = false;
        input.Dispose();
        ExitThread();
    }
}

/// Draws the tray icon at runtime: a dial, filled while fast mode is on, faded while inactive,
/// in white or black to suit the taskbar.
sealed class TrayIcons
{
    readonly Dictionary<(bool fast, bool dim), Icon> cache = new();
    bool lightTaskbar;
    int size;

    public Icon Get(bool fast, bool dim)
    {
        bool light = LightTaskbar();
        int s = SystemInformation.SmallIconSize.Width;
        if (light != lightTaskbar || s != size)
        {
            foreach (var icon in cache.Values) icon.Dispose();
            cache.Clear();
            lightTaskbar = light;
            size = s;
        }
        if (!cache.TryGetValue((fast, dim), out var result))
        {
            var color = light ? Color.FromArgb(32, 32, 32) : Color.White;
            if (dim) color = Color.FromArgb(110, color);
            cache[(fast, dim)] = result = Draw(size, color, fast);
        }
        return result;
    }

    static bool LightTaskbar()
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int v && v != 0;
    }

    static Icon Draw(int size, Color color, bool fast)
    {
        using var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float stroke = Math.Max(1.5f, size / 10f);
            float inset = size * 0.08f + stroke / 2;
            var ring = new RectangleF(inset, inset, size - 2 * inset, size - 2 * inset);
            float c = size / 2f, r = ring.Width / 2;
            // The marker points up and to the right, like a knob turned partway.
            double angle = -Math.PI / 4;
            var tip = new PointF(c + (float)(Math.Cos(angle) * r * 0.62), c + (float)(Math.Sin(angle) * r * 0.62));
            using var pen = new Pen(color, stroke) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            if (fast)
            {
                using var brush = new SolidBrush(color);
                g.FillEllipse(brush, RectangleF.Inflate(ring, stroke / 2, stroke / 2));
                // Cut the marker out of the filled disc.
                g.CompositingMode = CompositingMode.SourceCopy;
                using var cut = new Pen(Color.Transparent, stroke) { StartCap = LineCap.Round, EndCap = LineCap.Round };
                g.DrawLine(cut, c, c, tip.X, tip.Y);
            }
            else
            {
                g.DrawEllipse(pen, ring);
                g.DrawLine(pen, c, c, tip.X, tip.Y);
            }
        }
        IntPtr h = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(h).Clone();
        Native.DestroyIcon(h);
        return icon;
    }
}
