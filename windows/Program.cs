// jog-scroll for Windows: turn a DJ controller's jog wheel into mouse-wheel scrolling.
// A port of ../macos/main.swift; see README.md in this folder.
//
// Builds as two programs:
//   JogScroll.exe            the tray app (what runs at login)
//   jog-scroll.exe run       same, without the tray icon, logging to the terminal
//   jog-scroll.exe learn     record which MIDI messages your jog wheel sends
//   jog-scroll.exe learn-control NAME  record which fader or knob a control uses
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
                      jog-scroll learn-control NAME  record which fader or knob the control NAME uses
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
        var engine = new JogEngine(ConfigFile.Load());
        if (engine.Cfg.Touch is not { } touch || engine.Cfg.Jog is not { } jog)
        {
            Console.WriteLine("No jog wheel learned yet. Run:  jog-scroll learn");
            return 1;
        }
        Log.Write($"Jog: {jog.Description}  |  Touch: {touch.Description}");
        var controls = new ControlRouter(engine) { OnResult = (_, error) => { if (error != null) Log.Write(error); } };
        foreach (var c in engine.Cfg.Controls.Where(c => c.Midi != null))
            Log.Write($"{c.Name}: {c.Midi!.Description} → {string.Join(", ", c.Actions.Select(a => $"{a.Server} {a.Path}"))}");
        Log.Write("Running. Press Ctrl-C to quit.");
        using var input = new MidiInput(m => { if (!controls.Handle(m)) engine.Handle(m); }, engine.MatchesPort);
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
        var engine = new JogEngine(ConfigFile.Load());
        var shown = JogEngine.LearnStep.None;
        engine.OnChange = () =>
        {
            if (engine.Step == shown) return;
            shown = engine.Step;
            switch (engine.Step)
            {
                case JogEngine.LearnStep.Touch:
                    Console.WriteLine("\nStep 1 of 2: Touch the TOP of the jog wheel you want to use, then let go.");
                    break;
                case JogEngine.LearnStep.Spin:
                    Console.WriteLine($"  ✓ Touch = {engine.Cfg.Touch!.Description}  (device: {engine.Cfg.PortName})");
                    Console.WriteLine("\nStep 2 of 2: Now spin the jog wheel slowly by its EDGE (don't touch the top).");
                    break;
            }
        };
        engine.OnLearned = () =>
        {
            Console.WriteLine($"  ✓ Jog = {engine.Cfg.Jog!.Description}");
            Console.WriteLine($"\nSaved to {ConfigFile.Path}\n");
            Environment.Exit(0);
        };
        using var input = new MidiInput(engine.Handle, _ => true) { Verbose = false };
        engine.StartLearning();
        Application.Run();
        return 0;
    }

    static int RunLearnControl(string name)
    {
        var engine = new JogEngine(ConfigFile.Load());
        var controls = new ControlRouter(engine);
        if (controls.Find(name) is not { } control)
        {
            var names = engine.Cfg.Controls.Select(c => $"\"{c.Name}\"").ToList();
            Console.WriteLine(names.Count == 0
                ? $"No controls yet. Add them to {ConfigFile.Path}"
                : $"Usage: jog-scroll learn-control NAME, where NAME is one of {string.Join(", ", names)}");
            return 1;
        }
        controls.OnLearned = c =>
        {
            Console.WriteLine($"  ✓ {c.Name} = {c.Midi!.Description}");
            Console.WriteLine($"\nSaved to {ConfigFile.Path}\n");
            Environment.Exit(0);
        };
        Console.WriteLine($"Move the fader or knob for {control.Name} all the way down and up. It saves when you stop.");
        using var input = new MidiInput(m => controls.Handle(m), engine.MatchesPort) { Verbose = false };
        controls.StartLearning(control);
        Application.Run();
        return 0;
    }
#endif
}
