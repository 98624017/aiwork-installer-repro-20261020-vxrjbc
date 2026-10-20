[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('original', 'ascii', 'spaces', 'chinese', 'baseline-ascii')][string]$Scenario,
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidatePattern('^$|^[a-fA-F0-9]{64}$')][string]$ExpectedInstallerSha256 = '',
    [ValidatePattern('^$|^[a-fA-F0-9]{64}$')][string]$ExpectedAppExeSha256 = '',
    [ValidatePattern('^$|^[a-fA-F0-9]{64}$')][string]$ExpectedAppAsarSha256 = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$startedAt = [DateTime]::UtcNow
$owned = [Collections.Generic.HashSet[int]]::new()
$handles = @{}
$observations = [Collections.Generic.List[object]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$parent = $null
$werOriginal = $null
$werKeyExisted = $false
$werConfigured = $false
$report = [ordered]@{ schemaVersion = 1; scenario = $Scenario; startedAt = $startedAt.ToString('o'); verdict = 'harness-error' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputPath = Join-Path $OutputDirectory ($Scenario + '.json')
$installName = switch ($Scenario) {
    'original' { 'AIwork ' + [char]0x4E2D + [char]0x6587 + ' ' + [char]0x7A7A + [char]0x683C }
    'chinese' { 'AIwork-' + [char]0x4E2D + [char]0x6587 }
    'spaces' { 'AIwork with spaces' }
    default { 'aiwork-install' }
}
if (-not $env:RUNNER_TEMP) { throw 'RUNNER_TEMP-required' }
$installDirectory = Join-Path $env:RUNNER_TEMP $installName
$targetExecutable = Join-Path $installDirectory 'ai-canvas.exe'
$dumpDirectory = Join-Path $env:RUNNER_TEMP ('installer-private-dumps-' + $Scenario)
$werPath = $null
$report.environment = [ordered]@{ powershell = [string]$PSVersionTable.PSVersion; edition = $PSVersionTable.PSEdition; image = $env:ImageOS; imageVersion = $env:ImageVersion; sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId; os = [Environment]::OSVersion.VersionString }
$report.installDirectory = $installDirectory
$report.requestedInstallDirectory = $installDirectory

function Get-FileEvidence([string]$Path, [string]$Expected = '') {
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $hash = if ($exists) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    return [ordered]@{ path = $Path; exists = $exists; sha256 = $hash; expectedSha256 = $Expected; expectedMatches = $(if ($Expected) { $hash -eq $Expected.ToLowerInvariant() } else { $null }) }
}

function Update-ProcessEvidence([Diagnostics.Stopwatch]$Timer) {
    $all = @(Get-CimInstance Win32_Process)
    foreach ($item in $all) {
        if ([string]::Equals([string]$item.ExecutablePath, $InstallerPath, [StringComparison]::OrdinalIgnoreCase)) { $owned.Add([int]$item.ProcessId) | Out-Null }
    }
    for ($pass = 0; $pass -lt 4; $pass++) {
        foreach ($item in $all) {
            if ($owned.Contains([int]$item.ParentProcessId)) { $owned.Add([int]$item.ProcessId) | Out-Null }
        }
    }
    $live = @($all | Where-Object { $owned.Contains([int]$_.ProcessId) })
    foreach ($item in $live) {
        $processId = [int]$item.ProcessId
        if ($handles.ContainsKey($processId)) { continue }
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        try { $null = $process.Handle; $handles[$processId] = $process } catch { continue }
        # Only the setup command is known to contain exclusively test-supplied arguments.
        $command = if ([string]::Equals([string]$item.ExecutablePath, $InstallerPath, [StringComparison]::OrdinalIgnoreCase)) { [string]$item.CommandLine } else { '[descendant arguments omitted]' }
        $observations.Add([ordered]@{ elapsedSeconds = [Math]::Round($Timer.Elapsed.TotalSeconds, 2); pid = $processId; parentPid = [int]$item.ParentProcessId; name = $item.Name; commandLine = $command })
    }
    return $live
}

function Get-ShortcutEvidence {
    $shell = New-Object -ComObject WScript.Shell
    $explorer = New-Object -ComObject Shell.Application
    $roots = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms')) | Select-Object -Unique
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue)) {
            try {
                $link = $shell.CreateShortcut($file.FullName)
                if (-not [string]::Equals([string]$link.TargetPath, $targetExecutable, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $folder = $explorer.NameSpace($file.DirectoryName)
                $appId = if ($null -ne $folder) { [string]$folder.ParseName($file.Name).ExtendedProperty('System.AppUserModel.ID') } else { '' }
                [ordered]@{ name = $file.Name; path = $file.FullName; target = $link.TargetPath; icon = $link.IconLocation; appUserModelId = $appId }
            } catch { $warnings.Add('shortcut-read-failed-' + $_.Exception.GetType().Name) }
        }
    }
}

function Get-UninstallEvidence {
    foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $value = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $value) { continue }
            $locationProperty = $value.PSObject.Properties['InstallLocation']
            $uninstallProperty = $value.PSObject.Properties['UninstallString']
            $location = if ($null -ne $locationProperty) { [string]$locationProperty.Value } else { '' }
            $uninstall = if ($null -ne $uninstallProperty) { [string]$uninstallProperty.Value } else { '' }
            if (-not $location.StartsWith($installDirectory, [StringComparison]::OrdinalIgnoreCase) -and -not $uninstall.Contains($installDirectory)) { continue }
            $record = [ordered]@{ key = $key.Name }
            foreach ($field in @('DisplayName', 'DisplayVersion', 'InstallLocation', 'UninstallString', 'QuietUninstallString', 'Publisher')) {
                $prop = $value.PSObject.Properties[$field]
                if ($null -ne $prop) { $record[$field] = [string]$prop.Value }
            }
            $record
        }
    }
}

try {
    Write-Host ('STAGE input ' + $Scenario)
    $InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).ProviderPath
    if (Test-Path -LiteralPath $installDirectory) { throw 'install-directory-must-not-exist' }
    $report.installer = Get-FileEvidence $InstallerPath $ExpectedInstallerSha256
    if ($ExpectedInstallerSha256 -and -not $report.installer.expectedMatches) { throw 'installer-hash-mismatch' }
    $setupDirectory = Join-Path $env:RUNNER_TEMP ('installer-input-' + $Scenario)
    New-Item -ItemType Directory -Path $setupDirectory -Force | Out-Null
    $originalInstallerPath = $InstallerPath
    $InstallerPath = Join-Path $setupDirectory 'setup.exe'
    Copy-Item -LiteralPath $originalInstallerPath -Destination $InstallerPath
    $werPath = 'HKCU:\Software\Microsoft\Windows\Windows Error Reporting\LocalDumps\setup.exe'
    $report.invocation = [ordered]@{ executable = $InstallerPath; argumentList = "/S /D=$installDirectory"; copiedBytesMatch = (Get-FileEvidence $InstallerPath).sha256 -eq $report.installer.sha256 }
    $report.wer = [ordered]@{ configured = $false; existingKey = $false; dumpsUploaded = $false }
    try {
        $werKeyExisted = Test-Path -LiteralPath $werPath
        if ($werKeyExisted) { $werOriginal = Get-ItemProperty -LiteralPath $werPath }
        New-Item -ItemType Directory -Path $dumpDirectory -Force | Out-Null
        New-Item -Path $werPath -Force | Out-Null
        $werConfigured = $true
        New-ItemProperty -LiteralPath $werPath -Name DumpFolder -Value $dumpDirectory -PropertyType ExpandString -Force | Out-Null
        New-ItemProperty -LiteralPath $werPath -Name DumpType -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -LiteralPath $werPath -Name DumpCount -Value 2 -PropertyType DWord -Force | Out-Null
        $report.wer.configured = $true
        $report.wer.existingKey = $werKeyExisted
    } catch { $warnings.Add('wer-config-failed-' + $_.Exception.GetType().Name) }

    Write-Host ('STAGE install ' + $installDirectory)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    # Preserve the exact original PowerShell7 Start-Process argument transport.
    $parent = Start-Process -FilePath $InstallerPath -ArgumentList "/S /D=$installDirectory" -PassThru
    $owned.Add($parent.Id) | Out-Null
    $null = $parent.Handle
    $handles[$parent.Id] = $parent
    $observations.Add([ordered]@{ elapsedSeconds = 0; pid = $parent.Id; parentPid = $PID; name = 'setup.exe'; commandLine = 'setup.exe /S /D=' + $installDirectory })
    $parentExitAt = $null
    $lastUi = ''
    $ui = [Collections.Generic.List[object]]::new()
    while ($timer.Elapsed.TotalSeconds -lt 240) {
        $live = @(Update-ProcessEvidence $timer)
        foreach ($item in $live) {
            $process = Get-Process -Id ([int]$item.ProcessId) -ErrorAction SilentlyContinue
            if ($null -eq $process -or -not $process.MainWindowTitle) { continue }
            $title = $process.MainWindowTitle
            if ($title -ne $lastUi) { $ui.Add([ordered]@{ seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2); pid = $process.Id; title = $title.Substring(0, [Math]::Min(200, $title.Length)) }); $lastUi = $title }
        }
        $parent.Refresh()
        if ($parent.HasExited -and $null -eq $parentExitAt) { $parent.WaitForExit(); $parentExitAt = $timer.Elapsed.TotalSeconds; Write-Host ('STAGE parent-exited ' + $parent.ExitCode) }
        if ($null -ne $parentExitAt -and $timer.Elapsed.TotalSeconds - $parentExitAt -ge 10 -and $live.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $report.elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2)
    $report.timedOut = $timer.Elapsed.TotalSeconds -ge 240
    $report.parent = [ordered]@{ pid = $parent.Id; exited = $parent.HasExited; exitCode = $(if ($parent.HasExited) { $parent.ExitCode } else { $null }) }
    $report.ui = @($ui.ToArray())
    $report.processes = @($observations.ToArray())
    $report.processExits = @(foreach ($entry in $handles.GetEnumerator()) {
        $entry.Value.Refresh()
        [ordered]@{ pid = $entry.Key; exited = $entry.Value.HasExited; exitCode = $(if ($entry.Value.HasExited) { $entry.Value.WaitForExit(); $entry.Value.ExitCode } else { $null }) }
    })

    Write-Host 'STAGE installed-evidence'
    $installedExecutables = @(if (Test-Path -LiteralPath $installDirectory) { Get-ChildItem -LiteralPath $installDirectory -Filter 'ai-canvas.exe' -Recurse -Depth 2 -File })
    $report.installationPathAmbiguous = $installedExecutables.Count -gt 1
    $report.discoveredExecutables = @($installedExecutables | ForEach-Object { $_.FullName })
    if ($installedExecutables.Count -eq 1) {
        $targetExecutable = $installedExecutables[0].FullName
        $installDirectory = $installedExecutables[0].DirectoryName
        $report.installDirectory = $installDirectory
    }
    $report.files = [ordered]@{
        exe = Get-FileEvidence $targetExecutable $ExpectedAppExeSha256
        asar = Get-FileEvidence (Join-Path $installDirectory 'resources\app.asar') $ExpectedAppAsarSha256
    }
    $report.uninstallers = @(if (Test-Path -LiteralPath $installDirectory) { Get-ChildItem -LiteralPath $installDirectory -Filter 'Uninstall*.exe' -File | ForEach-Object { Get-FileEvidence $_.FullName } })
    $report.agentCliFiles = @(if (Test-Path -LiteralPath (Join-Path $installDirectory 'resources\agent-cli')) { Get-ChildItem -LiteralPath (Join-Path $installDirectory 'resources\agent-cli') -Filter 'canvasai.exe' -Recurse -File | ForEach-Object { Get-FileEvidence $_.FullName } })
    $report.shortcuts = @(Get-ShortcutEvidence)
    $report.uninstallEntries = @(Get-UninstallEvidence)
    Write-Host 'STAGE crash-evidence'
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $startedAt.ToLocalTime(); Id = @(1000, 1001) } -ErrorAction SilentlyContinue)
    $report.crashEvents = @(foreach ($event in $events) {
        $xml = [xml]$event.ToXml()
        $data = @{}
        foreach ($node in $xml.SelectNodes("/*[local-name()='Event']/*[local-name()='EventData']/*[local-name()='Data']")) {
            $name = $node.GetAttribute('Name')
            if ($name) { $data[$name] = [string]$node.InnerText }
        }
        $app = [string]$data['AppName']
        if (-not $app) { $app = [string]$data['P1'] }
        if ($app -ne [IO.Path]::GetFileName($InstallerPath) -and $app -ne 'ai-canvas.exe') { continue }
        [ordered]@{ eventId = $event.Id; time = $event.TimeCreated.ToUniversalTime().ToString('o'); applicationName = $app; faultModule = $(if ($event.Id -eq 1000) { $data['ModuleName'] } else { $data['P4'] }); exceptionCode = $(if ($event.Id -eq 1000) { $data['ExceptionCode'] } else { $data['P7'] }); processId = $data['ProcessId'] }
    })
    $report.wer.dumps = @(Get-ChildItem -LiteralPath $dumpDirectory -Filter '*.dmp' -File -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; bytes = $_.Length } })
    $complete = $report.files.exe.exists -and $report.files.asar.exists -and $report.uninstallEntries.Count -gt 0 -and $report.uninstallers.Count -gt 0
    $hashMismatch = ($ExpectedAppExeSha256 -and $report.files.exe.exists -and -not $report.files.exe.expectedMatches) -or ($ExpectedAppAsarSha256 -and $report.files.asar.exists -and -not $report.files.asar.expectedMatches)
    $crash = @($report.processExits | Where-Object { $_.exitCode -eq -1073741819 }).Count -gt 0 -or @($report.crashEvents | Where-Object { $_.exceptionCode -match '^(0x)?c0000005$' }).Count -gt 0
    $report.installationComplete = $complete
    $report.observedAccessViolation = $crash
    $report.verdict = if ($report.timedOut) { 'timeout' } elseif ($report.installationPathAmbiguous) { 'ambiguous-installation-path' } elseif ($hashMismatch) { 'installed-file-hash-mismatch' } elseif ($crash -and $complete) { 'access-violation-with-complete-install' } elseif ($crash) { 'access-violation-with-incomplete-install' } elseif ($complete -and $report.parent.exitCode -eq 0) { 'installed' } elseif ($complete) { 'nonzero-parent-exit-with-complete-install' } else { 'incomplete-install-without-confirmed-access-violation' }
} catch {
    $report.harnessError = [ordered]@{ type = $_.Exception.GetType().Name; line = $_.InvocationInfo.ScriptLineNumber; code = $(if ($_.Exception.Message -match '^[a-z-]+$') { $_.Exception.Message } else { 'unexpected-error' }) }
} finally {
    Write-Host 'STAGE cleanup-and-report'
    foreach ($entry in $handles.GetEnumerator()) {
        try { if (-not $entry.Value.HasExited) { $entry.Value.Kill() } }
        catch { $warnings.Add('process-cleanup-' + $_.Exception.GetType().Name) }
    }
    if ($werConfigured) {
        if (-not $werKeyExisted) { Remove-Item -LiteralPath $werPath -ErrorAction SilentlyContinue }
        else {
            foreach ($field in @('DumpFolder', 'DumpType', 'DumpCount')) {
                $property = $werOriginal.PSObject.Properties[$field]
                if ($null -eq $property) { Remove-ItemProperty -LiteralPath $werPath -Name $field -ErrorAction SilentlyContinue }
                else { Set-ItemProperty -LiteralPath $werPath -Name $field -Value $property.Value -ErrorAction SilentlyContinue }
            }
        }
    }
    $report.warnings = @($warnings.ToArray())
    [IO.File]::WriteAllText($outputPath, ($report | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    Write-Host ('RESULT ' + $report.verdict)
}
if ($report.verdict -ne 'installed') { exit 1 }
