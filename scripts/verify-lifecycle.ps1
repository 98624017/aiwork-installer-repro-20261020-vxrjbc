[CmdletBinding()]
param(
    [ValidateSet('direct', 'current-user', 'all-users')][string]$Mode,
    [switch]$UninstallUpdatedDiagnostic,
    [switch]$DiagnosticSilent
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'shortcut-probe.ps1')
. (Join-Path $PSScriptRoot 'lifecycle-probe.ps1')
$utf8 = [Text.UTF8Encoding]::new($false)
$output = Join-Path $PWD 'lifecycle-evidence'
New-Item -ItemType Directory -Path $output | Out-Null
$manifest = Get-Content -LiteralPath './branding-candidate.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$setup = (Resolve-Path -LiteralPath (Join-Path './payload' $manifest.candidate.file)).ProviderPath
$report = [ordered]@{
    mode = $Mode; status = 'failed'; image = $env:ImageOS; imageVersion = $env:ImageVersion
    powershell = [string]$PSVersionTable.PSVersion; setupSha256 = $null; stages = @(); errors = @()
    environment = [ordered]@{
        tempVolume = Get-LifecycleVolume ([IO.Path]::GetTempPath())
        targetVolume = Get-LifecycleVolume (Join-Path $env:RUNNER_TEMP 'diag-app')
    }
}

function Test-Payload([string]$Target) {
    $pins = @{
        'ai-canvas.exe' = $manifest.candidate.exeSha256
        'resources/app.asar' = $manifest.candidate.asarSha256
        'installer-manage-process.ps1' = $manifest.candidate.helperSha256
    }
    $observed = [ordered]@{}
    foreach ($name in $pins.Keys) {
        $file = Join-Path $Target $name
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $observed[$name] = $hash
        if ($hash -cne $pins[$name]) { throw 'installed-payload-hash-mismatch' }
    }
    return $observed
}

function Invoke-SettledInstaller([string]$File, [string]$Arguments) {
    $startedAt = [DateTime]::UtcNow
    $child = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
    $ids = New-Object 'Collections.Generic.HashSet[int]'
    $ids.Add($child.Id) | Out-Null
    $observed = @{}
    $trace = New-Object Collections.ArrayList
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastLive = ''
    try {
        while ($timer.ElapsedMilliseconds -lt 180000) {
            $live = @(Get-LifecycleOwnedProcesses $ids $startedAt @(Get-CimInstance Win32_Process) $File)
            foreach ($item in $live) {
                if (-not $observed.ContainsKey([int]$item.ProcessId)) {
                    $observed[[int]$item.ProcessId] = Get-LifecycleProcessEvidence $item $child.Id
                }
            }
            $liveKey = (@($live | ForEach-Object { [int]$_.ProcessId } | Sort-Object) -join ',')
            if ($liveKey -cne $lastLive) {
                $trace.Add([ordered]@{ elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2); livePids = @($live | ForEach-Object { [int]$_.ProcessId }) }) | Out-Null
                if ($trace.Count -gt 120) { $trace.RemoveAt(0) }
                $lastLive = $liveKey
            }
            if ($child.WaitForExit(1000)) { break }
        }
        if (-not $child.HasExited) {
            $fixturePaths = @($File, $target, $env:RUNNER_TEMP, $env:TEMP, $env:USERPROFILE)
            $report.timeoutWindow = Protect-LifecycleText ([string]$child.MainWindowTitle) $fixturePaths
            $report.timeoutProcesses = @($observed.Values | Sort-Object { $_.pid })
            $report.timeoutProcessTrace = @($trace)
            try {
                $live = @(Get-LifecycleOwnedProcesses $ids $startedAt @(Get-CimInstance Win32_Process) $File)
                $report.timeoutLivePids = @($live | ForEach-Object { [int]$_.ProcessId })
                foreach ($item in $live) {
                    if (-not $observed.ContainsKey([int]$item.ProcessId)) {
                        $observed[[int]$item.ProcessId] = Get-LifecycleProcessEvidence $item $child.Id
                    }
                }
                $report.timeoutProcesses = @($observed.Values | Sort-Object { $_.pid })
                $report.timeoutControls = @(Get-LifecycleWindowEvidence $report.timeoutLivePids $fixturePaths)
            } catch {
                $report.timeoutDiagnosticsError = $_.Exception.GetType().Name
            }
            $child.Kill()
            throw 'installer-process-timeout'
        }
        if ($child.ExitCode -ne 0) { throw 'installer-process-nonzero-exit' }
        return $child.ExitCode
    } finally { $child.Dispose() }
}

function Invoke-UpdatedUninstallDiagnostic([string]$File) {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $staged = New-LifecycleUninstallerCopy $File
    $arguments = '/KEEP_APP_DATA --updated /currentuser _?=' + $target
    if ($DiagnosticSilent) { $arguments = '/S ' + $arguments }
    $startedAt = [DateTime]::UtcNow
    try {
        $child = Start-Process -FilePath $staged.executable -ArgumentList $arguments -PassThru
    } catch {
        Remove-Item -LiteralPath $staged.directory -Recurse -Force
        throw
    }
    $ids = New-Object 'Collections.Generic.HashSet[int]'
    $ids.Add($child.Id) | Out-Null
    $handles = @{ $child.Id = $child }
    $observed = @{}
    $clicked = New-Object 'Collections.Generic.HashSet[string]'
    $fixturePaths = @($File, $staged.executable, $staged.directory, $target, $env:RUNNER_TEMP, $env:TEMP, $env:USERPROFILE)
    $diagnostic = [ordered]@{
        mode = if ($DiagnosticSilent) { 'copied-silent-updated-uninstall' } else { 'copied-interactive-updated-uninstall' }
        outcome = 'not-completed'; exitCode = $null
        sourceUninstallerSha256 = $staged.sourceSha256; copiedUninstallerSha256 = $staged.copiedSha256
        executableVolume = Get-LifecycleVolume $staged.executable
        elapsedSeconds = 0; processes = @(); actions = @(); firstDetails = @(); lastDetails = @(); windows = @(); cleanupErrors = @()
    }
    $abortObservedAt = $null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($timer.Elapsed.TotalSeconds -lt 45) {
            $live = @(Get-LifecycleOwnedProcesses $ids $startedAt @(Get-CimInstance Win32_Process) $staged.executable)
            foreach ($item in $live) {
                $processId = [int]$item.ProcessId
                if (-not $observed.ContainsKey($processId)) { $observed[$processId] = Get-LifecycleProcessEvidence $item $child.Id }
                if (-not $handles.ContainsKey($processId)) {
                    $handle = Get-Process -Id $processId -ErrorAction SilentlyContinue
                    if ($null -ne $handle) {
                        try {
                            if ([Math]::Abs(($handle.StartTime.ToUniversalTime() - $item.CreationDate.ToUniversalTime()).TotalMilliseconds) -gt 1) { $handle.Dispose(); continue }
                            $null = $handle.Handle
                            $handles[$processId] = $handle
                        } catch { $handle.Dispose() }
                    }
                }
            }
            $windows = @(Get-LifecycleWindowEvidence @($live | ForEach-Object { [int]$_.ProcessId }) $fixturePaths)
            foreach ($control in @($windows | Where-Object { ($_.id -eq 1027 -and $_.class -eq 'Button') -or ($_.id -eq 1016 -and $_.class -eq 'SysListView32') })) {
                $key = 'details/' + [string]$control.handle
                if (-not $clicked.Add($key)) { continue }
                $shown = [NativeLifecycleProbe]::ShowUninstallDetails([long]$control.handle, [int]$control.ownerPid)
                if (-not $shown) { $clicked.Remove($key) | Out-Null; continue }
                $success = if ($shown -and $control.id -eq 1027) { [NativeLifecycleProbe]::Click([long]$control.handle, [int]$control.ownerPid) } else { $shown }
                if (-not $success) { $clicked.Remove($key) | Out-Null }
                $diagnostic.actions += [ordered]@{ elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2); action = 'show-uninstall-details'; controlId = $control.id; succeeded = $success }
            }
            $windows = @(Get-LifecycleWindowEvidence @($live | ForEach-Object { [int]$_.ProcessId }) $fixturePaths)
            $details = @(Get-LifecycleUninstallDetails $windows $fixturePaths)
            $diagnostic.windows = $windows
            if ($details.Count) {
                if (-not $diagnostic.firstDetails.Count) { $diagnostic.firstDetails = $details }
                $diagnostic.lastDetails = $details
            }
            $terminal = @($windows | Where-Object { $_.class -eq 'Button' -and $_.enabled -and $_.visible -and $_.id -eq 1 -and $_.text -match '(?i)Close|Finish|Complete|\u5173\u95ed|\u5b8c\u6210' })
            $abort = @($windows | Where-Object { $_.class -eq 'Static' -and $_.visible -and $_.text -match '(?i)uninstall.*abort|can.t rename|cannot remove|\u5378\u8f7d\u4e2d\u6b62' })
            $cancel = @($windows | Where-Object { $_.class -eq 'Button' -and $_.id -eq 2 -and $_.visible -and $_.enabled })
            $nextDisabled = @($windows | Where-Object { $_.class -eq 'Button' -and $_.id -eq 1 -and $_.visible -and -not $_.enabled })
            if ($abort.Count -and $cancel.Count -and $nextDisabled.Count) {
                if ($null -eq $abortObservedAt) { $abortObservedAt = $timer.Elapsed.TotalSeconds }
                if ($timer.Elapsed.TotalSeconds - $abortObservedAt -ge 2) { $diagnostic.outcome = 'abort-details-observed'; break }
            }
            if ($child.WaitForExit(250)) { $diagnostic.exitCode = $child.ExitCode; $diagnostic.outcome = 'process-exited'; break }
            if ($terminal.Count -and -not (Test-Path -LiteralPath (Join-Path $target 'ai-canvas.exe')) -and -not (Test-Path -LiteralPath (Join-Path $target 'resources/app.asar'))) {
                $button = $terminal[0]
                $success = [NativeLifecycleProbe]::Click([long]$button.handle, [int]$button.ownerPid)
                $diagnostic.actions += [ordered]@{ elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2); action = 'finish-observed-removal'; controlId = $button.id; succeeded = $success }
            }
            foreach ($button in @($windows | Where-Object { $_.class -eq 'Button' -and $_.enabled -and $_.visible -and $_.id -eq 1 -and $_.text -match '(?i)Uninstall|Next|\u5378\u8f7d|\u4e0b\u4e00\u6b65' })) {
                $key = [string]$button.handle + '/' + $button.text
                if (-not $clicked.Add($key)) { continue }
                $success = [NativeLifecycleProbe]::Click([long]$button.handle, [int]$button.ownerPid)
                $diagnostic.actions += [ordered]@{ elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2); controlId = $button.id; text = $button.text; succeeded = $success }
            }
        }
        $diagnostic.elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2)
        $diagnostic.processes = @($observed.Values | Sort-Object { $_.pid })
        $diagnostic.applicationFilesRemaining = @('ai-canvas.exe', 'resources/app.asar' | Where-Object { Test-Path -LiteralPath (Join-Path $target $_) })
        return $diagnostic
    } finally {
        # Process handles were captured only after matching this invocation's CIM creation time.
        foreach ($handle in $handles.Values) {
            try { if (-not $handle.HasExited) { $handle.Kill(); $null = $handle.WaitForExit(5000) } }
            catch { $diagnostic.cleanupErrors += $_.Exception.GetType().Name }
            finally { $handle.Dispose() }
        }
        try { Remove-Item -LiteralPath $staged.directory -Recurse -Force }
        catch { $diagnostic.cleanupErrors += $_.Exception.GetType().Name }
    }
}

try {
    if ($DiagnosticSilent -and -not $UninstallUpdatedDiagnostic) { throw 'diagnostic-silent-requires-updated-uninstall-diagnostic' }
    $report.setupSha256 = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($report.setupSha256 -cne $manifest.candidate.sha256) { throw 'setup-hash-mismatch' }
    & ./scripts/debug-installer.ps1 -Mode $Mode -InstallerPath $setup -OutputDirectory $output
    $initial = Get-Content -LiteralPath (Join-Path $output ($Mode + '.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($initial.verdict -ne 'application-files-present' -or $initial.parent.exitCode -ne 0 -or $initial.timedOut) {
        throw 'fresh-install-failed'
    }
    $target = [string]$initial.files.directory
    $report.environment.targetVolume = Get-LifecycleVolume $target
    $report.freshHashes = Test-Payload $target
    $report.stages += 'fresh-install-hashes-passed'

    $name = [IO.File]::ReadAllText((Join-Path $target 'channel-shortcut-name.txt'), [Text.Encoding]::Unicode).Trim()
    $folders = @(
        [Environment]::GetFolderPath('DesktopDirectory'), [Environment]::GetFolderPath('Programs'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('CommonPrograms')
    )
    $links = @()
    $ownedLinks = @()
    foreach ($folder in $folders) {
        $linkPath = Join-Path $folder ($name + '.lnk')
        if (-not (Test-Path -LiteralPath $linkPath -PathType Leaf)) { continue }
        $link = [ShortcutProbe]::Read($linkPath)
        $icon = ([string]$link.IconLocation -replace ',\s*-?\d+$', '').Trim('"')
        $matches = [string]::Equals([string]$link.TargetPath, (Join-Path $target 'ai-canvas.exe'), [StringComparison]::OrdinalIgnoreCase)
        $iconWithin = $icon.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)
        $links += [ordered]@{ filename = $name + '.lnk'; targetMatches = $matches; iconWithinInstall = $iconWithin; iconExists = $iconWithin -and (Test-Path -LiteralPath $icon -PathType Leaf) }
        if ($matches) { $ownedLinks += $linkPath }
    }
    $report.shortcuts = $links
    if ($ownedLinks.Count -lt 2 -or @($links | Where-Object { -not $_.targetMatches -or -not $_.iconExists }).Count) {
        $report.errors += 'shortcut-contract-failed'
    } else { $report.stages += 'shortcut-targets-and-icons-passed' }

    if ($UninstallUpdatedDiagnostic) {
        $report.updatedUninstallDiagnostic = Invoke-UpdatedUninstallDiagnostic (Join-Path $target 'Uninstall ai-canvas.exe')
        # This diagnostic branch deliberately never certifies the normal lifecycle suite.
        throw 'updated-uninstall-diagnostic-only'
    }

    $arguments = '/S '
    if ($Mode -eq 'current-user') { $arguments += '/currentuser ' }
    if ($Mode -eq 'all-users') { $arguments += '/allusers ' }
    $arguments += '/D=' + $target
    $report.reinstallExit = Invoke-SettledInstaller (Join-Path $env:RUNNER_TEMP 'diag-input/setup.exe') $arguments
    $report.reinstallHashes = Test-Payload $target
    $report.stages += 'reinstall-hashes-passed'

    $dataDirectory = Join-Path $target 'AIworkData'
    New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
    $sentinel = Join-Path $dataDirectory 'lifecycle-sentinel.txt'
    [IO.File]::WriteAllText($sentinel, 'owned-test-data', $utf8)
    $uninstaller = Join-Path $target 'Uninstall ai-canvas.exe'
    $report.uninstallExit = Invoke-SettledInstaller $uninstaller ('/S _?=' + $target)
    if ((Test-Path -LiteralPath (Join-Path $target 'ai-canvas.exe')) -or (Test-Path -LiteralPath (Join-Path $target 'resources/app.asar'))) {
        throw 'uninstall-left-application-files'
    }
    if ([IO.File]::ReadAllText($sentinel) -cne 'owned-test-data') { throw 'uninstall-did-not-preserve-data' }
    if (@($ownedLinks | Where-Object { Test-Path -LiteralPath $_ }).Count) { throw 'uninstall-left-owned-shortcuts' }
    $report.stages += 'uninstall-preserved-data-and-removed-application'
    $report.status = if ($report.errors.Count -eq 0) { 'passed' } else { 'failed' }
} catch {
    $report.errors += $_.Exception.Message
} finally {
    [IO.File]::WriteAllText((Join-Path $output 'lifecycle.json'), ($report | ConvertTo-Json -Depth 9), $utf8)
    Write-Host ('Lifecycle ' + $Mode + ': ' + $report.status)
}
if ($report.status -ne 'passed') { exit 1 }
