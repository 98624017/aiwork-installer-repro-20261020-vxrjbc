[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$DebuggerPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$startedAt = [DateTime]::UtcNow
$report = [ordered]@{ schemaVersion = 1; startedAt = $startedAt.ToString('o'); verdict = 'harness-error'; dumpsUploaded = $false }
$warnings = [Collections.Generic.List[string]]::new()
$registryBackups = [Collections.Generic.List[object]]::new()
$observations = [Collections.Generic.List[object]]::new()
$handles = @{}
$setupPath = $null
$parent = $null
$debugger = $null
$dumpDirectory = $null
$privateDebuggerLog = $null
$registryPath = 'SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\setup.exe'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$outputPath = Join-Path $OutputDirectory 'wer-capture.json'

function Get-ExitEvidence([Diagnostics.Process]$Process) {
    $Process.Refresh()
    if ($Process.HasExited) { $Process.WaitForExit() }
    $code = if ($Process.HasExited) { $Process.ExitCode } else { $null }
    $hex = if ($null -ne $code) { '0x' + ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$code), 0)).ToString('X8') } else { $null }
    return [ordered]@{ pid = $Process.Id; exited = $Process.HasExited; exitCode = $code; exitCodeHex = $hex }
}

function Get-SetupProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'setup.exe'" | Where-Object {
        [string]::Equals([string]$_.ExecutablePath, $setupPath, [StringComparison]::OrdinalIgnoreCase) -and
        $_.CreationDate.ToUniversalTime() -ge $startedAt
    })
}

function Update-SetupEvidence([Diagnostics.Stopwatch]$Timer) {
    $live = @(Get-SetupProcesses)
    foreach ($item in $live) {
        $processId = [int]$item.ProcessId
        if ($handles.ContainsKey($processId)) { continue }
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        try { $null = $process.Handle } catch { continue }
        $handles[$processId] = $process
        $observations.Add([ordered]@{ seconds = [Math]::Round($Timer.Elapsed.TotalSeconds, 2); pid = $processId; parentPid = [int]$item.ParentProcessId; executablePath = [string]$item.ExecutablePath; commandLine = [string]$item.CommandLine })
    }
    return $live
}

function Enable-LocalDumps([Microsoft.Win32.RegistryView]$View) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View)
    $key = $null
    try {
        $key = $base.OpenSubKey($registryPath, $true)
        $existed = $null -ne $key
        $values = @{}
        if ($existed) {
            foreach ($name in @('DumpFolder', 'DumpType', 'DumpCount')) {
                if ($key.GetValueNames() -contains $name) {
                    $values[$name] = @{ value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); kind = $key.GetValueKind($name) }
                }
            }
        } else { $key = $base.CreateSubKey($registryPath, $true) }
        # Register the backup before the first mutation, including partial setup failures.
        $registryBackups.Add(@{ view = $View; existed = $existed; values = $values })
        $key.SetValue('DumpFolder', $dumpDirectory, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $key.SetValue('DumpType', 2, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('DumpCount', 2, [Microsoft.Win32.RegistryValueKind]::DWord)
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $base.Dispose()
    }
}

try {
    if (-not $env:RUNNER_TEMP) { throw 'runner-temp-required' }
    if (-not $IsWindows) { throw 'windows-required' }
    $InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).ProviderPath
    $DebuggerPath = (Resolve-Path -LiteralPath $DebuggerPath).ProviderPath
    $inputDirectory = Join-Path $env:RUNNER_TEMP 'diag-input-wer'
    $targetDirectory = Join-Path $env:RUNNER_TEMP 'diag-app-wer'
    $dumpDirectory = Join-Path $env:RUNNER_TEMP ('diag-private-dumps-' + [Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $inputDirectory) { throw 'fresh-input-directory-required' }
    if (Test-Path -LiteralPath $targetDirectory) { throw 'fresh-install-directory-required' }
    New-Item -ItemType Directory -Path $inputDirectory, $dumpDirectory | Out-Null
    $setupPath = Join-Path $inputDirectory 'setup.exe'
    Copy-Item -LiteralPath $InstallerPath -Destination $setupPath
    $sourceHash = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $copiedHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHash -ne $copiedHash) { throw 'installer-copy-hash-mismatch' }
    $report.environment = [ordered]@{ powershell = [string]$PSVersionTable.PSVersion; image = $env:ImageOS; imageVersion = $env:ImageVersion; os = [Environment]::OSVersion.VersionString }
    $report.installer = [ordered]@{ sha256 = $sourceHash; copiedSha256 = $copiedHash; path = $setupPath }
    Enable-LocalDumps ([Microsoft.Win32.RegistryView]::Registry64)
    Enable-LocalDumps ([Microsoft.Win32.RegistryView]::Registry32)
    $report.wer = [ordered]@{ hive = 'HKLM'; registryViews = @('Registry64', 'Registry32'); dumpType = 2; configured = $true }
    $arguments = '/S /D=' + $targetDirectory
    $report.invocation = [ordered]@{ launcher = 'PowerShell Start-Process'; arguments = $arguments; debuggerAttachedAtLaunch = $false }
    Write-Host 'STAGE native-start'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $parent = Start-Process -FilePath $setupPath -ArgumentList $arguments -PassThru
    $null = $parent.Handle
    $handles[$parent.Id] = $parent
    $observations.Add([ordered]@{ seconds = 0; pid = $parent.Id; parentPid = $PID; executablePath = $setupPath; commandLine = '"' + $setupPath + '" ' + $arguments })
    $parentExitedAt = $null
    while ($timer.Elapsed.TotalSeconds -lt 60) {
        $live = @(Update-SetupEvidence $timer)
        $parent.Refresh()
        if ($parent.HasExited -and $null -eq $parentExitedAt) { $parent.WaitForExit(); $parentExitedAt = $timer.Elapsed.TotalSeconds }
        $dumps = @(Get-ChildItem -LiteralPath $dumpDirectory -Filter '*.dmp' -File)
        $parentDump = @($dumps | Where-Object { $_.Name -match ('\.' + $parent.Id + '\.dmp$') })
        if ($null -ne $parentExitedAt -and $parentDump.Count -gt 0 -and $timer.Elapsed.TotalSeconds - $parentExitedAt -ge 5) { break }
        if ($null -ne $parentExitedAt -and $live.Count -eq 0 -and $timer.Elapsed.TotalSeconds - $parentExitedAt -ge 10) { break }
        Start-Sleep -Milliseconds 250
    }
    $report.nativeElapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2)
    $report.parent = Get-ExitEvidence $parent
    $report.processes = @($observations.ToArray())
    $report.processExits = @(foreach ($entry in $handles.GetEnumerator()) { Get-ExitEvidence $entry.Value })
    $report.observedAccessViolation = @($report.processExits | Where-Object { $_.exitCodeHex -eq '0xC0000005' }).Count -gt 0
    $report.files = [ordered]@{ exeExists = (Test-Path -LiteralPath (Join-Path $targetDirectory 'ai-canvas.exe') -PathType Leaf); asarExists = (Test-Path -LiteralPath (Join-Path $targetDirectory 'resources\app.asar') -PathType Leaf) }
    $dumps = @(Get-ChildItem -LiteralPath $dumpDirectory -Filter '*.dmp' -File)
    $report.dumps = @($dumps | ForEach-Object { [ordered]@{ name = $_.Name; bytes = $_.Length; parentPidMatches = $_.Name -match ('\.' + $parent.Id + '\.dmp$') } })
    $selectedDump = @($dumps | Where-Object { $_.Name -match ('\.' + $parent.Id + '\.dmp$') } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($selectedDump.Count -eq 0) { $selectedDump = @($dumps | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1) }
    if ($selectedDump.Count -gt 0) {
        Write-Host 'STAGE analyze-private-dump'
        $commandFile = Join-Path $inputDirectory 'analyze-dump.cdb'
        $privateDebuggerLog = Join-Path $dumpDirectory 'private-cdb.log'
        $commands = @(
            '.symfix "' + (Join-Path $env:RUNNER_TEMP 'diag-wer-symbols') + '"'
            '.echo AIWORK_DUMP_ANALYSIS_BEGIN'
            '.exr -1'
            '.ecxr'
            'r'
            'kv'
            'lm'
            'u @eip-20 L40'
            '!address @ecx'
            '!address @edx'
            '.echo AIWORK_NSIS_STATE_FIXED_BASE_00400000'
            'dd 0041e62c L1'
            'dd poi(0041e62c)-4 L7'
            'dd 0047af30 L1'
            'dd 0047aef4 L1'
            '.echo AIWORK_DUMP_ANALYSIS_END'
            'q'
        )
        [IO.File]::WriteAllLines($commandFile, $commands, [Text.UTF8Encoding]::new($false))
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $DebuggerPath
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @('-z', $selectedDump[0].FullName, '-logo', $privateDebuggerLog, '-cf', $commandFile)) { $startInfo.ArgumentList.Add($argument) }
        $debugger = [Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $debugger.StandardOutput.ReadToEndAsync()
        $stderrTask = $debugger.StandardError.ReadToEndAsync()
        $completed = $debugger.WaitForExit(90000)
        if (-not $completed) { $debugger.Kill(); $null = $debugger.WaitForExit(5000) }
        $report.debugger = [ordered]@{ version = (Get-Item -LiteralPath $DebuggerPath).VersionInfo.FileVersion; exitedWithinLimit = $completed; exit = Get-ExitEvidence $debugger; analyzedDumpName = $selectedDump[0].Name; parentDump = $selectedDump[0].Name -match ('\.' + $parent.Id + '\.dmp$'); fixedBase = '0x00400000'; globalsOnlyValidForRecordedInstallerSha256 = $sourceHash }
        $null = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        $log = if (Test-Path -LiteralPath $privateDebuggerLog) { [IO.File]::ReadAllText($privateDebuggerLog) } else { '' }
        $match = [regex]::Match($log, '(?ms)^\s*AIWORK_DUMP_ANALYSIS_BEGIN\s*\r?\n(.*?)^\s*AIWORK_DUMP_ANALYSIS_END\s*$')
        $report.debugger.completeAnalysisMarkers = $match.Success
        if ($match.Success) {
            [IO.File]::WriteAllText((Join-Path $OutputDirectory 'wer-stack.txt'), $match.Groups[1].Value, [Text.UTF8Encoding]::new($false))
        }
        $report.verdict = if ($report.observedAccessViolation -and $match.Success) { 'native-access-violation-dump-analyzed' } elseif ($match.Success) { 'dump-analyzed-without-recorded-access-violation-exit' } else { 'dump-present-analysis-incomplete' }
    } else {
        $report.verdict = if ($report.observedAccessViolation) { 'native-access-violation-without-dump' } elseif ($report.files.exeExists -and $report.files.asarExists) { 'application-files-present-without-crash' } else { 'no-dump-incomplete-install' }
    }
} catch {
    $report.harnessError = [ordered]@{ type = $_.Exception.GetType().Name; line = $_.InvocationInfo.ScriptLineNumber; code = $(if ($_.Exception.Message -match '^[a-z-]+$') { $_.Exception.Message } else { 'unexpected-error' }) }
} finally {
    Write-Host 'STAGE cleanup-and-report'
    if ($null -ne $debugger) {
        try { if (-not $debugger.HasExited) { $debugger.Kill(); $null = $debugger.WaitForExit(5000) } }
        catch { $warnings.Add('debugger-cleanup-' + $_.Exception.GetType().Name) }
    }
    if ($setupPath) {
        try { foreach ($item in @(Get-SetupProcesses)) { Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction SilentlyContinue } }
        catch { $warnings.Add('setup-cleanup-' + $_.Exception.GetType().Name) }
    }
    # Reverse order also restores correctly if the two registry views share this key.
    $restoreOrder = @($registryBackups.ToArray())
    [Array]::Reverse($restoreOrder)
    foreach ($backup in $restoreOrder) {
        $base = $null
        $key = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $backup.view)
            if (-not $backup.existed) { $base.DeleteSubKey($registryPath, $false) }
            else {
                $key = $base.CreateSubKey($registryPath, $true)
                foreach ($name in @('DumpFolder', 'DumpType', 'DumpCount')) {
                    if ($backup.values.ContainsKey($name)) { $key.SetValue($name, $backup.values[$name].value, $backup.values[$name].kind) }
                    else { $key.DeleteValue($name, $false) }
                }
            }
        } catch { $warnings.Add('registry-restore-' + $backup.view + '-' + $_.Exception.GetType().Name) }
        finally { if ($null -ne $key) { $key.Dispose() }; if ($null -ne $base) { $base.Dispose() } }
    }
    $report.registryRestored = @($warnings | Where-Object { $_ -like 'registry-restore-*' }).Count -eq 0
    $report.warnings = @($warnings.ToArray())
    $report.totalElapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $startedAt).TotalSeconds, 2)
    [IO.File]::WriteAllText($outputPath, ($report | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    Write-Host ('RESULT ' + $report.verdict)
}
if ($report.verdict -eq 'harness-error') { exit 1 }
