if (-not ('NativeLifecycleProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class LifecycleWindow {
    public int Pid; public long Handle; public long Parent; public int Id;
    public string Class; public string Text; public bool Visible; public bool Enabled; public bool TopLevel;
}
public static class NativeLifecycleProbe {
    private delegate bool EnumProc(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr window, EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] private static extern IntPtr GetParent(IntPtr window);
    [DllImport("user32.dll")] private static extern int GetDlgCtrlID(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder value, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder value, int count);
    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode)]
    private static extern IntPtr ReadText(IntPtr window, uint message, UIntPtr count, StringBuilder value, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW")]
    private static extern IntPtr SendButton(IntPtr window, uint message, UIntPtr value, IntPtr data, uint flags, uint timeout, out UIntPtr result);

    public static bool Click(long handle, int expectedPid) {
        var window = new IntPtr(handle); uint pid; GetWindowThreadProcessId(window, out pid);
        if ((int)pid != expectedPid || !IsWindowVisible(window) || !IsWindowEnabled(window)) return false;
        UIntPtr unused; return SendButton(window, 0x00F5, UIntPtr.Zero, IntPtr.Zero, 2, 1000, out unused) != IntPtr.Zero;
    }

    private static LifecycleWindow Describe(IntPtr window, bool topLevel) {
        uint pid; GetWindowThreadProcessId(window, out pid);
        var cls = new StringBuilder(128); GetClassName(window, cls, cls.Capacity);
        var text = new StringBuilder(1024);
        // Never read Edit controls, list output, clipboard contents, or application payloads.
        if (cls.ToString().Equals("Static", StringComparison.OrdinalIgnoreCase) || cls.ToString().Equals("Button", StringComparison.OrdinalIgnoreCase)) {
            UIntPtr unused; ReadText(window, 0x000D, (UIntPtr)text.Capacity, text, 2, 100, out unused);
        } else if (topLevel) GetWindowText(window, text, text.Capacity);
        return new LifecycleWindow { Pid = (int)pid, Handle = window.ToInt64(), Parent = GetParent(window).ToInt64(),
            Id = GetDlgCtrlID(window), Class = cls.ToString(), Text = text.ToString(), Visible = IsWindowVisible(window),
            Enabled = IsWindowEnabled(window), TopLevel = topLevel };
    }
    public static LifecycleWindow[] Windows(int[] pids) {
        var owners = new HashSet<int>(pids); var windows = new List<LifecycleWindow>();
        EnumWindows(delegate(IntPtr window, IntPtr state) {
            uint pid; GetWindowThreadProcessId(window, out pid);
            if (owners.Contains((int)pid) && windows.Count < 192) {
                windows.Add(Describe(window, true));
                EnumChildWindows(window, delegate(IntPtr child, IntPtr unused) {
                    if (windows.Count >= 192) return false;
                    windows.Add(Describe(child, false)); return true;
                }, IntPtr.Zero);
            }
            return windows.Count < 192;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
}
'@
}

function Protect-LifecycleText([string]$Text, [string[]]$FixturePaths) {
    $safe = $Text
    foreach ($root in @($FixturePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object { $_.Length } -Descending)) {
        $safe = [regex]::Replace($safe, [regex]::Escape($root), '<fixture-path>', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    if ($safe -match '(?i)\b(token|api.?key|authorization|password|secret|bearer)\b') { return '<redacted-credential-text>' }
    $safe = $safe -replace '(?i)https?://\S+', '<url>'
    $safe = $safe -replace '(?<![A-Za-z0-9_])[A-Za-z0-9_+/=-]{32,}(?![A-Za-z0-9_])', '<redacted-value>'
    return $safe.Substring(0, [Math]::Min($safe.Length, 512))
}

function Get-LifecycleOwnedProcesses([Collections.Generic.HashSet[int]]$Ids, [DateTime]$StartedAt, [object[]]$Processes, [string]$InstallerPath = '') {
    $recent = @($Processes | Where-Object { $null -ne $_.CreationDate -and $_.CreationDate.ToUniversalTime() -ge $StartedAt })
    if ($InstallerPath) {
        foreach ($item in $recent) {
            # UAC can re-parent an inner installer; this exact fixture path is unique to the invocation.
            if ([string]::Equals([string]$item.ExecutablePath, $InstallerPath, [StringComparison]::OrdinalIgnoreCase)) {
                $Ids.Add([int]$item.ProcessId) | Out-Null
            }
        }
    }
    do {
        $added = $false
        foreach ($item in $recent) {
            if ($Ids.Contains([int]$item.ParentProcessId)) {
                if ($Ids.Add([int]$item.ProcessId)) { $added = $true }
            }
        }
    } while ($added)
    return @($recent | Where-Object { $Ids.Contains([int]$_.ProcessId) })
}

function Get-LifecycleVolume([string]$Path) {
    $match = [regex]::Match($Path, '^([A-Za-z]:)[\\/]')
    if ($match.Success) { return $match.Groups[1].Value.ToUpperInvariant() }
    return 'unknown'
}

function Get-LifecycleProcessEvidence([object]$Process, [int]$RootId) {
    $helper = ''
    foreach ($name in @('installer-resolve-channel.ps1', 'installer-asset-library.ps1', 'installer-fix-shortcut-icon.ps1', 'installer-manage-process.ps1')) {
        if ([string]$Process.CommandLine -match [regex]::Escape($name)) { $helper = $name; break }
    }
    $action = ''
    if ($helper -eq 'installer-manage-process.ps1' -and [string]$Process.CommandLine -match '(?i)(?:^|\s)-Action\s+(Inspect|Close|Force)(?:\s|$)') { $action = $Matches[1] }
    $role = if ([int]$Process.ProcessId -eq $RootId) { 'installer-root' }
        elseif ([string]$Process.Name -eq 'old-uninstaller.exe') { 'previous-uninstaller' }
        elseif ([string]$Process.Name -eq 'ai-canvas.exe') { 'installed-application' }
        elseif ($helper) { 'installer-helper' } else { 'owned-descendant' }
    return [ordered]@{
        pid = [int]$Process.ProcessId; parentPid = [int]$Process.ParentProcessId
        name = [string]$Process.Name; role = $role; helper = $helper; action = $action
        executableVolume = Get-LifecycleVolume ([string]$Process.ExecutablePath)
        createdAt = $Process.CreationDate.ToUniversalTime().ToString('o')
    }
}

function Get-LifecycleWindowEvidence([int[]]$ProcessIds, [string[]]$FixturePaths) {
    return @([NativeLifecycleProbe]::Windows($ProcessIds) | ForEach-Object {
        [ordered]@{
            ownerPid = $_.Pid; handle = $_.Handle; parentHandle = $_.Parent; id = $_.Id; class = $_.Class
            visible = $_.Visible; enabled = $_.Enabled; topLevel = $_.TopLevel
            text = Protect-LifecycleText $_.Text $FixturePaths
        }
    })
}

function Get-LifecycleUninstallDetails([object[]]$Windows, [string[]]$FixturePaths) {
    $rows = New-Object Collections.ArrayList
    $seen = New-Object 'Collections.Generic.HashSet[string]'
    foreach ($window in @($Windows | Where-Object { $_.topLevel -and $_.visible -and $_.class -eq '#32770' })) {
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]::new([long]$window.handle))
            if ($null -eq $root) { continue }
            $elements = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            for ($index = $elements.Count - 1; $index -ge [Math]::Max(0, $elements.Count - 256); $index--) {
                $element = $elements.Item($index)
                $kind = $element.Current.ControlType
                if ($kind -ne [System.Windows.Automation.ControlType]::ListItem -and $kind -ne [System.Windows.Automation.ControlType]::Text) { continue }
                $text = Protect-LifecycleText ([string]$element.Current.Name) $FixturePaths
                if (-not $text -or -not $seen.Add(([string]$window.ownerPid + '/' + $text))) { continue }
                $rows.Add([ordered]@{ ownerPid = $window.ownerPid; type = $kind.ProgrammaticName; text = $text }) | Out-Null
                if ($rows.Count -ge 128) { return @($rows) }
            }
        } catch {
            $rows.Add([ordered]@{ ownerPid = $window.ownerPid; type = 'uia-error'; errorType = $_.Exception.GetType().Name }) | Out-Null
        }
    }
    return @($rows)
}
