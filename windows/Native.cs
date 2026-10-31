using System.Runtime.InteropServices;

namespace JogScroll;

static class Native
{
    // MARK: WinMM MIDI input

    public const uint CALLBACK_FUNCTION = 0x30000;
    public const uint MIM_DATA = 0x3C3;
    public const uint MMSYSERR_ALLOCATED = 4;   // another program has the device open

    public delegate void MidiInProc(IntPtr hMidiIn, uint wMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MIDIINCAPS
    {
        public ushort wMid;
        public ushort wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
        public uint dwSupport;
    }

    [DllImport("winmm.dll")] public static extern uint midiInGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Unicode, EntryPoint = "midiInGetDevCapsW")]
    public static extern uint midiInGetDevCaps(UIntPtr uDeviceID, out MIDIINCAPS caps, uint cbMidiInCaps);
    [DllImport("winmm.dll")]
    public static extern uint midiInOpen(out IntPtr hMidiIn, uint uDeviceID, MidiInProc callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] public static extern uint midiInStart(IntPtr hMidiIn);
    [DllImport("winmm.dll")] public static extern uint midiInStop(IntPtr hMidiIn);
    [DllImport("winmm.dll")] public static extern uint midiInReset(IntPtr hMidiIn);
    [DllImport("winmm.dll")] public static extern uint midiInClose(IntPtr hMidiIn);

    // MARK: WinMM MIDI output

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MIDIOUTCAPS
    {
        public ushort wMid;
        public ushort wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
        public ushort wTechnology;
        public ushort wVoices;
        public ushort wNotes;
        public ushort wChannelMask;
        public uint dwSupport;
    }

    [DllImport("winmm.dll")] public static extern uint midiOutGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Unicode, EntryPoint = "midiOutGetDevCapsW")]
    public static extern uint midiOutGetDevCaps(UIntPtr uDeviceID, out MIDIOUTCAPS caps, uint cbMidiOutCaps);
    [DllImport("winmm.dll")]
    public static extern uint midiOutOpen(out IntPtr hMidiOut, uint uDeviceID, IntPtr callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] public static extern uint midiOutShortMsg(IntPtr hMidiOut, uint dwMsg);
    [DllImport("winmm.dll")] public static extern uint midiOutClose(IntPtr hMidiOut);

    // MARK: Mouse and keyboard

    public const uint INPUT_MOUSE = 0;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;
    public const int VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1;

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    // MOUSEINPUT is the largest member of the INPUT union, so this has the right size.
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public MOUSEINPUT mi;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] inputs, int cbSize);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
}
