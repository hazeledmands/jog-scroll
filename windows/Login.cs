namespace JogScroll;

/// Starts the tray app at login with a per-user Run registry entry.
static class LoginItem
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "Jog Scroll";

    public static string TrayExe => Path.Combine(AppContext.BaseDirectory, "JogScroll.exe");

    public static bool Enabled
    {
        get
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) != null;
        }
        set
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(ValueName, $"\"{TrayExe}\"");
            else key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }
}
