# Use the Unicode Shell Link interface so verification does not depend on WScript's locale handling.
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IProbeShellLinkW {
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int capacity, IntPtr findData, uint flags);
    void GetIDList(out IntPtr value);
    void SetIDList(IntPtr value);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int capacity);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string value);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int capacity);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string value);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int capacity);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string value);
    void GetHotkey(out short value);
    void SetHotkey(short value);
    void GetShowCmd(out int value);
    void SetShowCmd(int value);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int capacity, out int index);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string value, int index);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string value, uint reserved);
    void Resolve(IntPtr window, uint flags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string value);
}
public sealed class ProbeShortcut {
    public string TargetPath;
    public string WorkingDirectory;
    public string IconLocation;
}
public static class ShortcutProbe {
    static object NewLink() {
        return Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
    }
    public static ProbeShortcut Read(string file) {
        object instance = NewLink();
        try {
            ((IPersistFile)instance).Load(file, 0);
            IProbeShellLinkW link = (IProbeShellLinkW)instance;
            StringBuilder target = new StringBuilder(32768);
            StringBuilder directory = new StringBuilder(32768);
            StringBuilder icon = new StringBuilder(32768);
            int iconIndex;
            link.GetPath(target, target.Capacity, IntPtr.Zero, 0);
            link.GetWorkingDirectory(directory, directory.Capacity);
            link.GetIconLocation(icon, icon.Capacity, out iconIndex);
            return new ProbeShortcut { TargetPath = target.ToString(), WorkingDirectory = directory.ToString(), IconLocation = icon.ToString() };
        } finally { Marshal.FinalReleaseComObject(instance); }
    }
    public static void WriteFixture(string file, string target, string directory) {
        object instance = NewLink();
        try {
            IProbeShellLinkW link = (IProbeShellLinkW)instance;
            link.SetPath(target);
            link.SetWorkingDirectory(directory);
            link.SetIconLocation(target, 0);
            ((IPersistFile)instance).Save(file, true);
        } finally { Marshal.FinalReleaseComObject(instance); }
    }
}
'@
