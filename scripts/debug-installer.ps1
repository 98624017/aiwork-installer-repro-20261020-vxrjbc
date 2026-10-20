[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('direct', 'current-user', 'all-users', 'compat-invoker', 'debugger', 'original-name')][string]$Mode,
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$DebuggerPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$startedAt = [DateTime]::UtcNow
$report = [ordered]@{ schemaVersion = 1; mode = $Mode; startedAt = $startedAt.ToString('o'); verdict = 'harness-error' }
$warnings = [Collections.Generic.List[string]]::new()
$observations = [Collections.Generic.List[object]]::new()
$handles = @{}
$parent = $null
$setupPath = $null
$setupName = if ($Mode -eq 'original-name') { 'ai-canvas-0.7.0-setup.exe' } else { 'setup.exe' }
$targetDirectory = $null
$debuggerLog = $null
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$outputPath = Join-Path $OutputDirectory ($Mode + '.json')

function Get-ExitEvidence([Diagnostics.Process]$Process) {
    $Process.Refresh()
    $exited = $Process.HasExited
    if ($exited) { $Process.WaitForExit() }
    $code = if ($exited) { $Process.ExitCode } else { $null }
    $hex = if ($null -ne $code) { '0x' + ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$code), 0)).ToString('X8') } else { $null }
    return [ordered]@{ pid = $Process.Id; exited = $exited; exitCode = $code; exitCodeHex = $hex }
}

function Get-SetupProcesses {
    # This fresh, dedicated input path belongs only to this test. Never kill by basename.
    return @(Get-CimInstance Win32_Process -Filter ("Name = '" + $setupName + "'") | Where-Object {
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
        # Only this exact fixture path has known, non-secret command-line arguments.
        $observations.Add([ordered]@{
            elapsedSeconds = [Math]::Round($Timer.Elapsed.TotalSeconds, 2)
            pid = $processId; parentPid = [int]$item.ParentProcessId
            executablePath = [string]$item.ExecutablePath
            commandLine = [string]$item.CommandLine
        })
    }
    return $live
}

function Get-InstallationEvidence {
    $exePath = Join-Path $targetDirectory 'ai-canvas.exe'
    $asarPath = Join-Path $targetDirectory 'resources\app.asar'
    $directoryExists = Test-Path -LiteralPath $targetDirectory -PathType Container
    $exeExists = Test-Path -LiteralPath $exePath -PathType Leaf
    $asarExists = Test-Path -LiteralPath $asarPath -PathType Leaf
    $children = @(if ($directoryExists) { Get-ChildItem -LiteralPath $targetDirectory -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name })
    $stage = if ($exeExists -and $asarExists) { 'application-files-present' } elseif ($exeExists) { 'executable-present-without-asar' } elseif ($directoryExists) { 'install-directory-present' } else { 'before-install-directory' }
    return [ordered]@{ directory = $targetDirectory; directoryExists = $directoryExists; exeExists = $exeExists; asarExists = $asarExists; topLevelNames = $children; lastObservedStage = $stage }
}

try {
    if (-not $env:RUNNER_TEMP) { throw 'runner-temp-required' }
    if (-not $IsWindows) { throw 'windows-required' }
    $InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).ProviderPath
    $sourceHash = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $inputDirectory = Join-Path $env:RUNNER_TEMP 'diag-input'
    $targetDirectory = Join-Path $env:RUNNER_TEMP 'diag-app'
    if (Test-Path -LiteralPath $inputDirectory) { throw 'fresh-input-directory-required' }
    if (Test-Path -LiteralPath $targetDirectory) { throw 'fresh-install-directory-required' }
    New-Item -ItemType Directory -Path $inputDirectory | Out-Null
    $setupPath = Join-Path $inputDirectory $setupName
    Copy-Item -LiteralPath $InstallerPath -Destination $setupPath
    $copyHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($copyHash -ne $sourceHash) { throw 'installer-copy-hash-mismatch' }
    $report.environment = [ordered]@{
        powershell = [string]$PSVersionTable.PSVersion; image = $env:ImageOS; imageVersion = $env:ImageVersion
        os = [Environment]::OSVersion.VersionString; sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        is64BitProcess = [Environment]::Is64BitProcess
    }
    $report.installer = [ordered]@{ sha256 = $sourceHash; copiedSha256 = $copyHash; executablePath = $setupPath }
    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('/S')
    if ($Mode -eq 'current-user') { $arguments.Add('/currentuser') }
    if ($Mode -eq 'all-users') { $arguments.Add('/allusers') }
    $arguments.Add('/D=' + $targetDirectory)
    $report.invocation = [ordered]@{ arguments = @($arguments.ToArray()); launcher = $(if ($Mode -eq 'debugger') { 'CDB via ProcessStartInfo' } else { 'PowerShell Start-Process' }); compatLayer = $(if ($Mode -eq 'compat-invoker') { 'RunAsInvoker' } else { $null }) }
    $limitSeconds = 60

    if ($Mode -eq 'debugger') {
        if (-not $DebuggerPath) { throw 'debugger-path-required' }
        $DebuggerPath = (Resolve-Path -LiteralPath $DebuggerPath).ProviderPath
        $report.debugger = [ordered]@{ path = $DebuggerPath; version = (Get-Item -LiteralPath $DebuggerPath).VersionInfo.FileVersion; followsChildren = $false; breaksOn = 'second-chance access violation' }
        $commandFile = Join-Path $inputDirectory 'diagnose.cdb'
        $symbolCache = Join-Path $env:RUNNER_TEMP 'diag-symbols'
        $debuggerLog = Join-Path $OutputDirectory 'debugger-stack.txt'
        $commands = @(
            '.symfix "' + $symbolCache + '"'
            'sxd -c2 ".echo AIWORK_UNHANDLED_AV; .exr -1; .ecxr; r; kv; lm; u @eip-20 L40; .echo AIWORK_NSIS_STATE; dd setup+1e62c L1; dd poi(setup+1e62c)-4 L7; dd setup+7af30 L1; dd setup+7aef4 L1; .echo AIWORK_STACK_END; q" av'
            'g'
        )
        [IO.File]::WriteAllLines($commandFile, $commands, [Text.UTF8Encoding]::new($false))
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.UseShellExecute = $false
        $startInfo.WorkingDirectory = $inputDirectory
        $startInfo.FileName = $DebuggerPath
        foreach ($argument in @('-G', '-logo', $debuggerLog, '-cf', $commandFile, $setupPath)) { $startInfo.ArgumentList.Add($argument) }
        foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
        $limitSeconds = 180
    }
    Write-Host ('STAGE start ' + $Mode)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    if ($Mode -eq 'debugger') {
        $parent = [Diagnostics.Process]::Start($startInfo)
    } else {
        # Keep the original reproduction's Start-Process argument transport.
        $launch = @{ FilePath = $setupPath; ArgumentList = ($arguments -join ' '); PassThru = $true }
        if ($Mode -eq 'compat-invoker') { $launch.Environment = @{ __COMPAT_LAYER = 'RunAsInvoker' } }
        $parent = Start-Process @launch
    }
    $null = $parent.Handle
    if ($Mode -ne 'debugger') {
        $handles[$parent.Id] = $parent
        $observations.Add([ordered]@{ elapsedSeconds = 0; pid = $parent.Id; parentPid = $PID; executablePath = $setupPath; commandLine = '"' + $setupPath + '" ' + ($arguments -join ' ') })
    }
    $parentExitedAt = $null
    while ($timer.Elapsed.TotalSeconds -lt $limitSeconds) {
        $live = @(Update-SetupEvidence $timer)
        $parent.Refresh()
        if ($parent.HasExited -and $null -eq $parentExitedAt) {
            $parent.WaitForExit()
            $parentExitedAt = $timer.Elapsed.TotalSeconds
            Write-Host ('STAGE parent-exit ' + (Get-ExitEvidence $parent).exitCodeHex)
        }
        if ($null -ne $parentExitedAt -and $live.Count -eq 0 -and $timer.Elapsed.TotalSeconds - $parentExitedAt -ge 2) { break }
        Start-Sleep -Milliseconds 250
    }
    $report.elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2)
    $report.timedOut = $timer.Elapsed.TotalSeconds -ge $limitSeconds
    $report.parent = Get-ExitEvidence $parent
    $report.processes = @($observations.ToArray())
    $report.processExits = @(foreach ($entry in $handles.GetEnumerator()) { Get-ExitEvidence $entry.Value })
    $report.files = Get-InstallationEvidence
    $hasAccessViolation = @($report.processExits | Where-Object { $_.exitCodeHex -eq '0xC0000005' }).Count -gt 0
    $report.observedAccessViolation = $hasAccessViolation
    $report.verdict = if ($report.timedOut) { 'timeout' } elseif ($hasAccessViolation) { 'access-violation' } elseif ($report.files.exeExists -and $report.files.asarExists) { 'application-files-present' } else { 'incomplete-install' }
} catch {
    $report.harnessError = [ordered]@{ type = $_.Exception.GetType().Name; line = $_.InvocationInfo.ScriptLineNumber; code = $(if ($_.Exception.Message -match '^[a-z-]+$') { $_.Exception.Message } else { 'unexpected-error' }) }
} finally {
    Write-Host 'STAGE cleanup-and-report'
    if ($null -ne $parent -and $Mode -eq 'debugger') {
        try { if (-not $parent.HasExited) { $parent.Kill(); $null = $parent.WaitForExit(5000) } }
        catch { $warnings.Add('debugger-cleanup-' + $_.Exception.GetType().Name) }
    }
    if ($setupPath) {
        try {
            foreach ($item in @(Get-SetupProcesses)) {
                # Re-check exact executable path and creation time immediately before terminating.
                Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction SilentlyContinue
            }
        } catch { $warnings.Add('setup-cleanup-' + $_.Exception.GetType().Name) }
    }
    if ($debuggerLog -and (Test-Path -LiteralPath $debuggerLog -PathType Leaf)) {
        try {
            $logText = [IO.File]::ReadAllText($debuggerLog)
            $unhandled = $logText -match '(?m)^\s*AIWORK_UNHANDLED_AV\s*$'
            $completeStack = $logText -match '(?m)^\s*AIWORK_STACK_END\s*$'
            $report.debugger.unhandledAccessViolationMarker = $unhandled
            $report.debugger.stackEndMarker = $completeStack
            $report.debugger.logFile = [IO.Path]::GetFileName($debuggerLog)
            if ($unhandled) { $report.observedAccessViolation = $true; $report.verdict = 'debugger-captured-unhandled-access-violation' }
        } catch { $warnings.Add('debugger-log-read-' + $_.Exception.GetType().Name) }
    }
    $report.warnings = @($warnings.ToArray())
    [IO.File]::WriteAllText($outputPath, ($report | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    Write-Host ('RESULT ' + $report.verdict)
}
if ($report.verdict -eq 'harness-error') { exit 1 }
