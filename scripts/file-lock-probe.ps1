[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDirectory,
    [Parameter(Mandatory = $true)][int]$ParentProcessId,
    [Parameter(Mandatory = $true)][long]$ParentStartFileTime,
    [Parameter(Mandatory = $true)][string]$OwnedProcessIdentityPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidateRange(1, 9000)][int]$BudgetMilliseconds = 9000
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$utf8 = New-Object Text.UTF8Encoding($false)
$result = [ordered]@{
    schemaVersion = 1; method = 'read-only-restart-manager'; status = 'failed'
    budgetMilliseconds = $BudgetMilliseconds; elapsedMilliseconds = 0
    selectedFileCount = 0; queriedFileCount = 0; files = @(); failureCode = $null
}
$timer = [Diagnostics.Stopwatch]::StartNew()

function ConvertTo-FileLockHolderEvidence([object]$Holder, [int]$RootProcessId, [long]$RootStartFileTime, [hashtable]$OwnedIdentities) {
    $processId = [int]$Holder.ProcessId
    $startFileTime = [long]$Holder.StartFileTime
    $key = [string]$processId
    $isParent = $processId -eq $RootProcessId -and $startFileTime -eq $RootStartFileTime
    # CIM creation timestamps may round native FILETIME by less than one millisecond.
    $isOwned = $OwnedIdentities.ContainsKey($key) -and [Math]::Abs($startFileTime - [long]$OwnedIdentities[$key]) -le 10000
    $name = [regex]::Replace([string]$Holder.ProcessName, '[^A-Za-z0-9._-]', '?')
    return [ordered]@{
        pid = $processId; name = $name.Substring(0, [Math]::Min(128, $name.Length))
        processStartFileTime = $startFileTime.ToString([Globalization.CultureInfo]::InvariantCulture)
        createdAt = [DateTime]::FromFileTimeUtc($startFileTime).ToString('o')
        currentProcessIdentityVerified = [bool]$Holder.CurrentIdentityVerified
        isParent = $isParent; isOwned = $isOwned
    }
}

$RestartManagerSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential)]
public struct LockProbeFileTime { public uint Low; public uint High; }
[StructLayout(LayoutKind.Sequential)]
public struct LockProbeUniqueProcess { public uint ProcessId; public LockProbeFileTime StartTime; }
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct LockProbeProcessInfo {
    public LockProbeUniqueProcess Process;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string ApplicationName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string ServiceShortName;
    public int ApplicationType; public uint ApplicationStatus; public uint SessionId;
    [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
}
public sealed class LockProbeHolder {
    public int ProcessId; public long StartFileTime; public string ProcessName = "";
    public bool CurrentIdentityVerified;
}
public sealed class LockProbeFileResult {
    public string Status = "not-queried"; public uint ErrorCode; public uint EndSessionCode;
    public bool SessionStarted; public LockProbeHolder[] Holders = new LockProbeHolder[0];
}
public static class NativeFileLockProbe {
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint RmStartSession(out uint session, uint flags, StringBuilder sessionKey);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint RmRegisterResources(uint session, uint fileCount,
        [In, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] filenames,
        uint applicationCount, [In] LockProbeUniqueProcess[] applications,
        uint serviceCount, [In, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] services);
    [DllImport("rstrtmgr.dll", ExactSpelling = true)]
    private static extern uint RmGetList(uint session, out uint needed, ref uint count,
        [In, Out] LockProbeProcessInfo[] applications, ref uint rebootReasons);
    [DllImport("rstrtmgr.dll", ExactSpelling = true)]
    private static extern uint RmEndSession(uint session);

    public static LockProbeFileResult Query(string filename) {
        var result = new LockProbeFileResult(); uint session;
        uint error = RmStartSession(out session, 0, new StringBuilder(33));
        if (error != 0) { result.Status = "session-start-failed"; result.ErrorCode = error; return result; }
        result.SessionStarted = true;
        try {
            error = RmRegisterResources(session, 1, new string[] { filename }, 0, null, 0, null);
            if (error != 0) { result.Status = "register-file-failed"; result.ErrorCode = error; return result; }
            uint needed, count = 0, reasons = 0;
            error = RmGetList(session, out needed, ref count, null, ref reasons);
            for (int attempt = 0; error == 234 && attempt < 3; attempt++) {
                if (needed > 128) { result.Status = "holder-limit-exceeded"; result.ErrorCode = error; return result; }
                var entries = new LockProbeProcessInfo[(int)needed]; count = needed;
                error = RmGetList(session, out needed, ref count, entries, ref reasons);
                if (error != 0) continue;
                var holders = new List<LockProbeHolder>();
                for (int i = 0; i < (int)count; i++) {
                    var identity = entries[i].Process;
                    var holder = new LockProbeHolder { ProcessId = (int)identity.ProcessId,
                        StartFileTime = unchecked((long)(((ulong)identity.StartTime.High << 32) | identity.StartTime.Low)) };
                    try {
                        using (var process = Process.GetProcessById(holder.ProcessId)) {
                            holder.CurrentIdentityVerified = process.StartTime.ToUniversalTime().ToFileTimeUtc() == holder.StartFileTime;
                            if (holder.CurrentIdentityVerified) holder.ProcessName = process.ProcessName;
                        }
                    } catch (ArgumentException) { }
                      catch (InvalidOperationException) { }
                      catch (System.ComponentModel.Win32Exception) { }
                    holders.Add(holder);
                }
                result.Holders = holders.ToArray();
            }
            result.Status = error == 0 ? "queried" : "get-list-failed"; result.ErrorCode = error;
            return result;
        } finally { result.EndSessionCode = RmEndSession(session); }
    }
}
'@

try {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) { throw 'requires-native-windows-powershell-51' }
    if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'fixture-root-missing' }
    $target = [IO.Path]::GetFullPath($TargetDirectory).TrimEnd([char[]]'\/')
    $allowed = [IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP 'diag-app')).TrimEnd([char[]]'\/')
    if (-not [string]::Equals($target, $allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'target-outside-owned-fixture' }
    foreach ($directory in @($target, (Join-Path $target 'resources'), (Join-Path $target 'brand'))) {
        if (Test-Path -LiteralPath $directory) {
            $item = Get-Item -LiteralPath $directory -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'fixture-reparse-point-refused' }
        }
    }
    $known = @{}
    foreach ($identity in @(Get-Content -LiteralPath $OwnedProcessIdentityPath -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        $known[[string][int]$identity.pid] = [DateTime]::Parse([string]$identity.createdAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToFileTimeUtc()
    }
    $names = @(
        'ai-canvas.exe', 'resources/app.asar', 'Uninstall ai-canvas.exe',
        'installer-resolve-channel.ps1', 'installer-asset-library.ps1', 'installer-fix-shortcut-icon.ps1', 'installer-manage-process.ps1',
        'channel.ico', 'channel-binding-install.json', 'channel-code.txt', 'channel-name.txt', 'channel-shortcut-name.txt',
        'channel-app-user-model-id.txt', 'channel-shortcut-icon-name.txt', 'channel-install-mode.txt', 'channel-install-diagnostics.json', 'channel-slug.txt'
    )
    foreach ($folder in @('', 'brand')) {
        $directory = if ($folder -eq '') { $target } else { Join-Path $target $folder }
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        foreach ($icon in @(Get-ChildItem -LiteralPath $directory -Filter 'channel*.ico' -File -Force | Select-Object -First 32)) {
            $relative = if ($folder -eq '') { $icon.Name } else { $folder + '/' + $icon.Name }
            if ($names -notcontains $relative -and $names.Count -lt 32) { $names += $relative }
        }
    }
    $result.selectedFileCount = $names.Count
    Add-Type -TypeDefinition $RestartManagerSource
    foreach ($relative in $names) {
        if ($timer.ElapsedMilliseconds -ge $BudgetMilliseconds) { $result.status = 'partial-time-budget'; break }
        $path = Join-Path $target $relative
        $entry = [ordered]@{ relativePath = $relative; status = 'missing'; holders = @() }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            if (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $entry.status = 'reparse-point-refused'
            } else {
                $native = [NativeFileLockProbe]::Query($path)
                $entry.status = $native.Status; $entry.errorCode = $native.ErrorCode
                $entry.sessionStarted = $native.SessionStarted; $entry.endSessionCode = $native.EndSessionCode
                $entry.holders = @($native.Holders | ForEach-Object { ConvertTo-FileLockHolderEvidence $_ $ParentProcessId $ParentStartFileTime $known })
                $result.queriedFileCount++
            }
        }
        $result.files += $entry
    }
    if ($result.status -eq 'failed') { $result.status = 'completed' }
} catch {
    $result.failureCode = if ($_.Exception.Message -match '^[a-z0-9-]+$') { $_.Exception.Message } else { $_.Exception.GetType().Name }
} finally {
    $result.elapsedMilliseconds = $timer.ElapsedMilliseconds
    [IO.File]::WriteAllText($OutputPath, ($result | ConvertTo-Json -Depth 9), $utf8)
}
if ($result.status -eq 'failed') { exit 1 }
exit 0
