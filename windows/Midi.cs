using System.Collections.Concurrent;
using static JogScroll.Native;

namespace JogScroll;

public readonly record struct MidiMessage(byte Status, byte Data1, byte Data2, string Source);

/// Opens the MIDI inputs that `wanted` accepts and checks every second for devices being plugged
/// in or out. WinMM gives one program a device at a time, so it leaves the others alone, and it
/// keeps retrying a device another program is using.
public sealed class MidiInput : IDisposable
{
    readonly Action<MidiMessage> handler;
    readonly SynchronizationContext ui;
    readonly MidiInProc callback;   // kept in a field so the GC doesn't collect it while WinMM holds it
    readonly ConcurrentDictionary<IntPtr, string> handleNames = new();
    readonly Dictionary<int, IntPtr> open = new();      // device id -> handle
    readonly System.Windows.Forms.Timer timer = new() { Interval = 1000 };
    List<string> devices = new();                       // device names, indexed by id
    Dictionary<string, uint> failed = new();            // devices we couldn't open, with the error

    public Func<string, bool> Wanted;
    public Action? OnSourcesChanged;
    public bool Verbose = true;

    public IEnumerable<string> SourceNames => open.Keys.Select(id => devices[id]);
    public IEnumerable<string> BusyNames => failed.Where(f => f.Value == MMSYSERR_ALLOCATED).Select(f => f.Key);

    public MidiInput(Action<MidiMessage> handler, Func<string, bool> wanted)
    {
        this.handler = handler;
        Wanted = wanted;
        ui = SynchronizationContext.Current ?? throw new InvalidOperationException("MidiInput needs a UI thread");
        callback = OnMidi;
        timer.Tick += (_, _) => Refresh();
        timer.Start();
        Refresh();
    }

    public void Refresh()
    {
        bool changed = false;
        var now = Enumerate();
        if (!now.SequenceEqual(devices))
        {
            // Device ids shift when anything is plugged in or out, so start over.
            CloseAll();
            devices = now;
            changed = true;
        }
        foreach (var id in open.Keys.ToList())
        {
            if (!Wanted(devices[id])) { Close(id); changed = true; }
        }

        // The Windows MIDI Service lists each device twice under the same name, with the same messages
        // on both, so open one input per name. (This would also treat two identical controllers as one.)
        var openNames = SourceNames.ToHashSet();
        var nowFailed = new Dictionary<string, uint>();
        for (int id = 0; id < devices.Count; id++)
        {
            var name = devices[id];
            if (open.ContainsKey(id) || openNames.Contains(name) || !Wanted(name)) continue;
            uint err = midiInOpen(out var h, (uint)id, callback, IntPtr.Zero, CALLBACK_FUNCTION);
            if (err == 0)
            {
                handleNames[h] = name;
                midiInStart(h);
                open[id] = h;
                openNames.Add(name);
                nowFailed.Remove(name);
                changed = true;
                if (Verbose) Log.Write($"Listening to \"{name}\"");
            }
            else
            {
                nowFailed[name] = err;
                if (Verbose && !failed.ContainsKey(name))
                {
                    Log.Write(err == MMSYSERR_ALLOCATED
                        ? $"\"{name}\" is in use by another program. Waiting for it to be free…"
                        : $"Couldn't open \"{name}\" (error {err})");
                }
            }
        }
        if (!nowFailed.OrderBy(f => f.Key).SequenceEqual(failed.OrderBy(f => f.Key))) changed = true;
        failed = nowFailed;

        if (changed)
        {
            if (devices.Count == 0 && Verbose) Log.Write("No MIDI inputs found. Waiting for a device…");
            OnSourcesChanged?.Invoke();
        }
    }

    static List<string> Enumerate()
    {
        var names = new List<string>();
        uint count = midiInGetNumDevs();
        for (uint i = 0; i < count; i++)
        {
            var size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<MIDIINCAPS>();
            names.Add(midiInGetDevCaps((UIntPtr)i, out var caps, size) == 0 ? caps.szPname : "Unknown");
        }
        return names;
    }

    // Runs on a WinMM thread. WinMM has already expanded running status into whole messages.
    void OnMidi(IntPtr h, uint msg, IntPtr instance, IntPtr param1, IntPtr param2)
    {
        if (msg != MIM_DATA) return;
        uint packed = (uint)param1.ToInt64();
        byte status = (byte)packed;
        if (status < 0x80 || status >= 0xF0) return;   // skip system and realtime messages
        var m = new MidiMessage(status, (byte)(packed >> 8), (byte)(packed >> 16),
                                handleNames.TryGetValue(h, out var name) ? name : "?");
        ui.Post(_ => handler(m), null);
    }

    void Close(int id)
    {
        var h = open[id];
        midiInStop(h);
        midiInReset(h);
        midiInClose(h);
        handleNames.TryRemove(h, out _);
        open.Remove(id);
    }

    void CloseAll()
    {
        foreach (var id in open.Keys.ToList()) Close(id);
    }

    public void Dispose()
    {
        timer.Dispose();
        CloseAll();
    }
}

/// Sends MIDI to the controller, for its lights. Opens the output whose name contains `Port` when it's
/// first needed, and again after an error such as the controller being unplugged. Runs on the UI thread.
public sealed class MidiOutput : IDisposable
{
    IntPtr handle;
    string openPort = "";

    /// The output's name, or part of it. Changing it opens a different output next time.
    public string Port = "";

    /// Sends one message. Returns null, or why it couldn't.
    public string? Send(byte status, byte data1, byte data2)
    {
        if (handle != IntPtr.Zero && openPort != Port) Close();
        if (handle == IntPtr.Zero && Open() is { } error) return error;
        uint err = midiOutShortMsg(handle, (uint)(status | (data1 << 8) | (data2 << 16)));
        if (err == 0) return null;
        Close();   // try again next time, in case it was unplugged and comes back
        return $"Couldn't send to \"{Port}\" (error {err})";
    }

    string? Open()
    {
        uint count = midiOutGetNumDevs();
        var size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<MIDIOUTCAPS>();
        for (uint id = 0; id < count; id++)
        {
            if (midiOutGetDevCaps((UIntPtr)id, out var caps, size) != 0) continue;
            if (Port.Length == 0 || !caps.szPname.Contains(Port, StringComparison.OrdinalIgnoreCase)) continue;
            uint err = midiOutOpen(out handle, id, IntPtr.Zero, IntPtr.Zero, 0);
            if (err != 0)
            {
                handle = IntPtr.Zero;
                return err == MMSYSERR_ALLOCATED
                    ? $"\"{caps.szPname}\" is in use by another program"
                    : $"Couldn't open \"{caps.szPname}\" (error {err})";
            }
            openPort = Port;
            return null;
        }
        return $"There's no MIDI output called \"{Port}\" to light the controller with";
    }

    void Close()
    {
        if (handle != IntPtr.Zero) midiOutClose(handle);
        handle = IntPtr.Zero;
    }

    public void Dispose() => Close();
}

public static class Log
{
    public static void Write(string s) => Console.WriteLine($"[{DateTime.Now:T}] {s}");

    public static string Hex(MidiMessage m) => $"{m.Status:X2} {m.Data1:X2} {m.Data2:X2}";
}
