// jog-scroll for Windows: turn a DJ controller's jog wheel into mouse-wheel scrolling.
// A port of ../macos/main.swift; see README.md in this folder.
//
// Builds as two programs:
//   JogScroll.exe            the tray app (what runs at login)
//   jog-scroll.exe run       same, without the tray icon, logging to the terminal
//   jog-scroll.exe learn     record which MIDI messages your jog wheel sends
//   jog-scroll.exe learn-control NAME  record which jog wheel, fader or knob a control uses
//   jog-scroll.exe monitor   print every incoming MIDI message
//   jog-scroll.exe login on|off  start (or stop starting) the tray app at login

namespace JogScroll;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());

#if CLI
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        Console.CancelKeyPress += (_, _) => { Console.WriteLine("\nBye."); Environment.Exit(0); };
        switch (args.FirstOrDefault())
        {
            case "run": return RunScroller();
            case "learn": return RunLearn();
            case "learn-control": return RunLearnControl(string.Join(' ', args.Skip(1)));
            case "monitor": return RunMonitor();
            case "login":
                bool on = args.ElementAtOrDefault(1) != "off";
                LoginItem.Enabled = on;
                Console.WriteLine(on ? "Jog Scroll will start at login." : "Jog Scroll will no longer start at login.");
                return 0;
            default:
                Console.WriteLine($"""
                    Usage:
                      jog-scroll run          run without the tray icon, logging to the terminal
                      jog-scroll learn        record which MIDI messages your jog wheel sends
                      jog-scroll learn-control NAME  record which jog wheel, fader or knob the control NAME uses
                      jog-scroll monitor      print every incoming MIDI message
                      jog-scroll login on|off start (or stop starting) the tray app at login
                    The tray app is JogScroll.exe.
                    Settings: {ConfigFile.Path}
                    """);
                return 1;
        }
#else
        // Only one copy at a time. (A second copy couldn't open the controller anyway.)
        using var mutex = new Mutex(true, @"Local\jog-scroll", out bool first);
        if (!first) return 0;
        Application.Run(new TrayApp());
        return 0;
#endif
    }

#if CLI
    static int RunScroller()
    {
        var controls = new ControlRouter(ConfigFile.Load()) { OnResult = (_, error) => { if (error != null) Log.Write(error); } };
        var learned = controls.Cfg.Controls.Where(c => c.Midi != null).ToList();
        if (learned.Count == 0)
        {
            Console.WriteLine("No jog wheel learned yet. Run:  jog-scroll learn");
            return 1;
        }
        foreach (var c in learned)
        {
            string touch = c.Touch is { } t ? $" (touch: {t.Description})" : "";
            string actions = string.Join(", ", c.Actions.Select(a => a.IsScroll ? "scroll" : $"{a.Server} {a.Path}"));
            Log.Write($"{c.Name}: {c.Midi!.Description}{touch} → {actions}");
        }
        Log.Write("Running. Press Ctrl-C to quit.");
        using var input = new MidiInput(controls.Handle, controls.MatchesPort);
        Application.Run();
        return 0;
    }

    static int RunMonitor()
    {
        Log.Write("Showing all incoming MIDI (Ctrl-C to quit)…");
        using var input = new MidiInput(m => Log.Write($"{Log.Hex(m)}   from \"{m.Source}\""), _ => true);
        Application.Run();
        return 0;
    }

    static int RunLearn()
    {
        var controls = new ControlRouter(ConfigFile.Load());
        return Learn(controls, controls.MainJogToLearn());
    }

    static int RunLearnControl(string name)
    {
        var controls = new ControlRouter(ConfigFile.Load());
        if (controls.Find(name) is not { } control)
        {
            var names = controls.Cfg.Controls.Select(c => $"\"{c.Name}\"").ToList();
            Console.WriteLine(names.Count == 0
                ? $"No controls yet. Add them to {ConfigFile.Path}"
                : $"Usage: jog-scroll learn-control NAME, where NAME is one of {string.Join(", ", names)}");
            return 1;
        }
        if (!controls.CanLearn(control))
        {
            Console.WriteLine($"{control.Name}: there's no control type called \"{control.Type}\". Use \"jog\" or \"fader\".");
            return 1;
        }
        return Learn(controls, control);
    }

    /// Prints each step of learning a control, and saves it once it's learned.
    static int Learn(ControlRouter controls, MidiControl control)
    {
        string? shown = null;
        controls.OnChange = () =>
        {
            if (controls.LearnPrompt is not { } prompt || prompt == shown) return;
            shown = prompt;
            Console.WriteLine($"\n{prompt}");
        };
        controls.OnLearned = c =>
        {
            Console.WriteLine($"  ✓ {c.Name} = {c.Midi!.Description}");
            if (c.Touch is { } touch) Console.WriteLine($"  ✓ Touch = {touch.Description}");
            if (c.IsJog) Console.WriteLine($"  ✓ Device = {controls.Cfg.PortName}");
            Console.WriteLine($"\nSaved to {ConfigFile.Path}\n");
            Environment.Exit(0);
        };
        controls.StartLearning(control);
        using var input = new MidiInput(controls.Handle, name => controls.ListensEverywhere || controls.MatchesPort(name)) { Verbose = false };
        Application.Run();
        return 0;
    }
#endif
}
