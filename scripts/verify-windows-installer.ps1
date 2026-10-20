[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$PayloadDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$StartedAt = [DateTime]::UtcNow
$Cases = New-Object System.Collections.ArrayList
$OwnedInstallerIds = New-Object 'System.Collections.Generic.HashSet[int]'
$SuspendedIds = New-Object 'System.Collections.Generic.HashSet[int]'
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('aiwork-installer-validation-' + [Guid]::NewGuid().ToString('N'))
$InstallDirectory = Join-Path (Join-Path $TestRoot ('Install with spaces ' + [char]0x6D4B + [char]0x8BD5)) 'ai-canvas'
$TargetExecutable = Join-Path $InstallDirectory 'ai-canvas.exe'
$AssetDirectory = Join-Path $TestRoot 'External assets'
$UserDataDirectory = Join-Path $env:APPDATA 'AIwork'
$Failure = $null
$FailureLine = $null
$Candidate = $null
$Baseline = $null
$ExpectedInstalled = $null
$PackagedHelpers = @{}
$OriginalAppId = $null
$FixtureProcess = $null
$OtherProcess = $null
$BackupExecutable = Join-Path $TestRoot 'protected-app-backup.exe'
$ExpectedCaseCount = 18
$GracefulFixtureDelayMilliseconds = 6000
$Report = [ordered]@{
    schemaVersion = 1
    startedAt = $StartedAt.ToString('o')
    powershellEdition = [string]$PSVersionTable.PSEdition
    powershellVersion = [string]$PSVersionTable.PSVersion
    osVersion = [Environment]::OSVersion.VersionString
    runnerImage = [string]$env:ImageOS
    runnerImageVersion = [string]$env:ImageVersion
    sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    host64Bit = [Environment]::Is64BitProcess
    os64Bit = [Environment]::Is64BitOperatingSystem
    channelCode = 'XINBAO-AI'
    cases = $Cases
    limitations = @(
        'Installer --updated mode is not the renderer-to-production-feed updater E2E.',
        'Synthetic process cases are separate from actual protected Electron smoke/force.',
        'Windows client editions, other users/sessions, antivirus and enterprise policies are not covered.'
    )
}

function Assert-True([bool]$Condition, [string]$Code) {
    if (-not $Condition) { throw ('ASSERT:' + $Code) }
}

function Write-Json([string]$Path, [object]$Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 14), $Utf8)
}

function Get-Hash([string]$Path) {
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) 'expected-file-missing'
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-OpenStreamHash([IO.FileStream]$Stream) {
    $Stream.Position = 0
    $digest = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($digest.ComputeHash($Stream)).Replace('-', '').ToLowerInvariant() }
    finally { $digest.Dispose() }
}

function Get-Payload([object]$Item) {
    Assert-True ($null -ne $Item) 'manifest-payload-missing'
    Assert-True ([IO.Path]::GetFileName([string]$Item.file) -eq [string]$Item.file) 'manifest-file-must-be-basename'
    Assert-True ([string]$Item.sha256 -match '^[a-fA-F0-9]{64}$') 'manifest-invalid-hash'
    Assert-True ([string]$Item.version -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') 'manifest-invalid-version'
    $path = Join-Path $PayloadDirectory ([string]$Item.file)
    $hash = Get-Hash $path
    Assert-True ($hash -eq ([string]$Item.sha256).ToLowerInvariant()) 'payload-hash-mismatch'
    $result = [ordered]@{ path = $path; sha256 = $hash; version = [string]$Item.version }
    foreach ($field in @('exeSha256', 'asarSha256', 'helperSha256')) {
        $value = if ($null -ne $Item.PSObject.Properties[$field]) { [string]$Item.$field } else { '' }
        Assert-True ($value -eq '' -or $value -match '^[a-fA-F0-9]{64}$') 'manifest-invalid-installed-hash'
        $result[$field] = $value.ToLowerInvariant()
    }
    return [pscustomobject]$result
}

function Get-InstalledHashes {
    return [ordered]@{
        exe = Get-Hash $TargetExecutable
        asar = Get-Hash (Join-Path $InstallDirectory 'resources\app.asar')
        helper = Get-Hash (Join-Path $InstallDirectory 'installer-manage-process.ps1')
    }
}

function Get-TargetProcesses {
    $name = [IO.Path]::GetFileName($TargetExecutable).Replace("'", "''")
    return @(Get-CimInstance Win32_Process -Filter "Name = '$name'" | Where-Object {
        [string]::Equals([string]$_.ExecutablePath, $TargetExecutable, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Stop-TargetProcesses {
    foreach ($item in @(Get-TargetProcesses)) {
        if ($SuspendedIds.Contains([int]$item.ProcessId)) {
            [NativeInstallerProbe]::Resume([int]$item.ProcessId) | Out-Null
            $SuspendedIds.Remove([int]$item.ProcessId) | Out-Null
        }
        Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Case([string]$Name, [scriptblock]$Body) {
    $case = [ordered]@{ name = $Name; status = 'running'; elapsedSeconds = 0; observations = $null }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $case.observations = & $Body
        if ($case.observations -is [Collections.IDictionary] -and $case.observations.Contains('acceptanceFailureCode')) {
            throw ('ASSERT:' + $case.observations.acceptanceFailureCode)
        }
        $case.status = 'passed'
        Write-Host ('PASS ' + $Name)
    }
    catch {
        $case.status = 'failed'
        # Exception messages may contain resolver responses or paths; export a code only.
        $case.failureCode = if ($_.Exception.Message -match '^ASSERT:([a-z0-9-]+)$') { $Matches[1] } else { 'unexpected-' + $_.Exception.GetType().Name }
        $case.failureLine = $_.InvocationInfo.ScriptLineNumber
        $case.exceptionType = $_.Exception.GetType().FullName
        $case.errorCategory = [string]$_.CategoryInfo.Category
        if (Get-Variable LastInstallerTrace -Scope Script -ErrorAction SilentlyContinue) { $case.installerTrace = $script:LastInstallerTrace }
        if (Get-Variable LastInstalledVersionEvidence -Scope Script -ErrorAction SilentlyContinue) { $case.installedVersion = $script:LastInstalledVersionEvidence }
        if (Get-Variable LastShortcutEvidence -Scope Script -ErrorAction SilentlyContinue) { $case.shortcutEvidence = $script:LastShortcutEvidence }
        if (Get-Variable LastLockCaseEvidence -Scope Script -ErrorAction SilentlyContinue) { $case.lockEvidence = $script:LastLockCaseEvidence }
        Write-Host ('FAIL ' + $Name + ' [' + $case.failureCode + ']')
    }
    finally {
        $case.elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2)
        $Cases.Add([pscustomobject]$case) | Out-Null
    }
    return ($case.status -eq 'passed')
}

function Get-InstallerProcesses([System.Collections.Generic.HashSet[int]]$Ids) {
    $all = @(Get-CimInstance Win32_Process)
    for ($pass = 0; $pass -lt 4; $pass++) {
        foreach ($item in $all) {
            if ($Ids.Contains([int]$item.ParentProcessId) -and
                -not [string]::Equals([string]$item.ExecutablePath, $TargetExecutable, [StringComparison]::OrdinalIgnoreCase)) {
                $Ids.Add([int]$item.ProcessId) | Out-Null
                $OwnedInstallerIds.Add([int]$item.ProcessId) | Out-Null
            }
        }
    }
    return @($all | Where-Object { $Ids.Contains([int]$_.ProcessId) })
}

function Read-PackagedHelperEvidence([object[]]$Processes, [object]$Package) {
    $allowed = @('installer-resolve-channel.ps1', 'installer-asset-library.ps1', 'installer-fix-shortcut-icon.ps1', 'installer-manage-process.ps1')
    foreach ($process in $Processes) {
        if ([string]$process.CommandLine -notmatch '(?i)-File\s+"([^"]+\.ps1)"') { continue }
        $path = $Matches[1]
        if ($allowed -notcontains [IO.Path]::GetFileName($path)) { continue }
        foreach ($name in $allowed) {
            $key = $Package.sha256 + '/' + $name
            if ($PackagedHelpers.ContainsKey($key)) { continue }
            $source = Join-Path ([IO.Path]::GetDirectoryName($path)) $name
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
            try { $bytes = [IO.File]::ReadAllBytes($source) }
            catch [IO.FileNotFoundException] { continue }
            catch [IO.DirectoryNotFoundException] { continue }
            $ascii = @($bytes | Where-Object { $_ -gt 127 }).Count -eq 0
            $lfPath = Join-Path $TestRoot ($Package.sha256.Substring(0, 12) + '-' + $name)
            [IO.File]::WriteAllText($lfPath, ($Utf8.GetString($bytes) -replace "`r`n", "`n"), $Utf8)
            $tokens = $null; $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseFile($lfPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
            if ($Package.sha256 -eq $Candidate.sha256) {
                Assert-True $ascii 'candidate-packaged-helper-non-ascii'
                Assert-True ($parseErrors.Count -eq 0) 'candidate-packaged-helper-lf-parse-error'
            }
            $digest = [Security.Cryptography.SHA256]::Create()
            try { $sourceHash = [BitConverter]::ToString($digest.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
            finally { $digest.Dispose() }
            $PackagedHelpers[$key] = [ordered]@{ setupSha256 = $Package.sha256; filename = $name; sha256 = $sourceHash; asciiSource = $ascii; lfParserErrors = $parseErrors.Count; lfPath = $lfPath }
        }
    }
}

function Get-UiLabel([string]$Text) {
    $plain = $Text.Replace('&', '').Trim()
    if ($plain -eq $Labels.normal) { return 'normal' }
    if ($plain -eq $Labels.retry) { return 'retry' }
    if ($plain -eq $Labels.force) { return 'force' }
    if ($plain -eq $Labels.cancel) { return 'cancel' }
    if ($plain -match $Labels.nextPattern) { return 'wizard-next' }
    if ($plain -match $Labels.runPattern) { return 'wizard-run' }
    return 'other'
}

function Get-UiEvidence([object[]]$Windows) {
    return @($Windows | ForEach-Object {
        $item = [ordered]@{ ownerPid = $_.OwnerPid; id = $_.Id; class = $_.ClassName; label = Get-UiLabel $_.Text; enabled = $_.Enabled; topLevel = $_.TopLevel; x = $_.X; y = $_.Y; width = $_.Width; height = $_.Height; toolWindow = $_.ToolWindow; extendedStyle = $_.ExtendedStyle }
        if ($_.ClassName -eq 'Button' -or $_.ClassName.StartsWith('WindowsForms10.BUTTON', [StringComparison]::OrdinalIgnoreCase)) {
            $item.buttonText = $_.Text.Substring(0, [Math]::Min(128, $_.Text.Length))
        }
        $item
    })
}

function Test-VisibleLossWarning([object[]]$Windows) {
    $text = ($Windows | ForEach-Object { $_.Text }) -join ' '
    if ($text.Contains($Labels.warning)) { return $true }
    # TaskDialog can render its body inside DirectUI without an HWND caption.
    foreach ($window in @($Windows | Where-Object { $_.ClassName -eq '#32770' })) {
        $element = [System.Windows.Automation.AutomationElement]::FromHandle($window.Handle)
        if ($null -eq $element) { continue }
        $items = $element.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($item in $items) {
            if (([string]$item.Current.Name).Contains($Labels.warning)) { return $true }
        }
    }
    return $false
}

function Get-InstallerPageStage([object[]]$Windows) {
    if (@($Windows | Where-Object { $_.Id -eq 6 -and (Get-UiLabel $_.Text) -eq 'force' }).Count -gt 0) { return 'force-warning' }
    if (@($Windows | Where-Object { $_.Id -eq 4 -and (Get-UiLabel $_.Text) -eq 'normal' }).Count -gt 0) { return 'normal-close-prompt' }
    if (@($Windows | Where-Object { $_.Id -eq 1201 -and $_.ClassName -eq 'Edit' }).Count -gt 0 -and
        @($Windows | Where-Object { $_.Id -eq 1200 -and $_.ClassName -eq 'Static' }).Count -gt 0 -and
        @($Windows | Where-Object { $_.Id -eq 1202 -and $_.ClassName -eq 'Static' }).Count -gt 0) { return 'channel-input' }
    if (@($Windows | Where-Object { $_.ClassName -eq 'msctls_progress32' }).Count -gt 0) { return 'install-progress' }
    if (@($Windows | Where-Object { $_.Id -eq 1 -and (Get-UiLabel $_.Text) -eq 'wizard-next' }).Count -gt 0) { return 'wizard-navigation' }
    return 'waiting'
}

function Add-InstallerTrace([Collections.ArrayList]$Trace, [Diagnostics.Stopwatch]$Timer, [string]$Stage, [string]$Action, [string]$Transport, [int]$ControlId, [bool]$Succeeded) {
    $Trace.Add([ordered]@{ elapsedSeconds = [Math]::Round($Timer.Elapsed.TotalSeconds, 2); stage = $Stage; action = $Action; transport = $Transport; controlId = $ControlId; succeeded = $Succeeded }) | Out-Null
    if ($Trace.Count -gt 160) { $Trace.RemoveAt(0) }
    $script:LastInstallerTrace = @($Trace)
}

function Invoke-Installer([object]$Package, [string]$Mode, [string]$Scenario) {
    Assert-True (([DateTime]::UtcNow - $StartedAt).TotalMinutes -lt 25) 'overall-harness-time-budget-exhausted'
    $arguments = '/currentuser '
    if ($Mode -eq 'updated') { $arguments += '--updated --force-run ' }
    if ($Mode -eq 'silent') { $arguments += '/S ' }
    $arguments += '/D=' + $InstallDirectory
    $process = Start-Process -FilePath $Package.path -ArgumentList $arguments -PassThru
    $ids = New-Object 'System.Collections.Generic.HashSet[int]'
    $ids.Add($process.Id) | Out-Null
    $OwnedInstallerIds.Add($process.Id) | Out-Null
    $actions = New-Object System.Collections.ArrayList
    $trace = New-Object System.Collections.ArrayList
    $script:LastInstallerTrace = @()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastStage = ''
    $channelInputHandle = [IntPtr]::Zero
    $emptySince = $null
    $lastUi = @()
    $lastHandle = [IntPtr]::Zero
    $lastClickAt = [DateTime]::MinValue
    $retryCount = 0
    $normalCount = 0
    $forceCount = 0
    $warningCount = 0
    $lockCancelCount = 0
    $replacementWhileFixtureAlive = $false
    while ($timer.Elapsed.TotalSeconds -lt 240) {
        $live = @(Get-InstallerProcesses $ids)
        Read-PackagedHelperEvidence $live $Package
        $lastUi = @([NativeInstallerProbe]::Windows([int[]]@($live | ForEach-Object { [int]$_.ProcessId })))
        if ($lastUi.Count -gt 0) { $script:LastUiEvidence = Get-UiEvidence $lastUi }
        $stage = Get-InstallerPageStage $lastUi
        if ($stage -ne $lastStage) {
            Add-InstallerTrace $trace $timer $stage 'page-observed' 'enumeration' 0 $true
            $lastStage = $stage
        }
        if ($stage -eq 'channel-input') {
            $field = @($lastUi | Where-Object { $_.Id -eq 1201 -and $_.ClassName -eq 'Edit' })[0]
            if ($field.Handle -ne $channelInputHandle) {
                $set = [NativeInstallerProbe]::SetText($field.Handle, 'XINBAO-AI')
                $confirmed = $set -and [NativeInstallerProbe]::TextEquals($field.Handle, 'XINBAO-AI')
                Add-InstallerTrace $trace $timer $stage 'authorized-channel-input-confirmed' 'WM_SETTEXT' $field.Id $confirmed
                Assert-True $confirmed 'activation-page-channel-input-failed'
                $channelInputHandle = $field.Handle
            }
        }
        if ($null -ne $FixtureProcess -and -not $FixtureProcess.HasExited -and $null -ne $ExpectedInstalled -and (Test-Path -LiteralPath $TargetExecutable)) {
            if ((Get-Hash $TargetExecutable) -eq $ExpectedInstalled.exe) { $replacementWhileFixtureAlive = $true }
        }
        $buttons = @($lastUi | Where-Object { $_.ClassName -eq 'Button' -and $_.Enabled })
        $force = @($buttons | Where-Object { $_.Id -eq 6 -and (Get-UiLabel $_.Text) -eq 'force' })
        $normal = @($buttons | Where-Object { $_.Id -eq 4 -and (Get-UiLabel $_.Text) -eq 'normal' })
        $retry = @($buttons | Where-Object { $_.Id -eq 4 -and (Get-UiLabel $_.Text) -eq 'retry' })
        $chosen = $null
        $action = ''
        $dialogText = ($lastUi | ForEach-Object { $_.Text }) -join ' '
        if ($Scenario -eq 'replacement-lock' -and $dialogText -match $Labels.lockFailurePattern) {
            $cancel = @($buttons | Where-Object { ($_.Id -eq 2 -or $_.Id -eq 3) -and $_.Text.Replace('&', '') -match $Labels.cancelPattern })
            if ($cancel.Count -gt 0) { $chosen = $cancel[0]; $action = 'cancel-or-abort-locked-replacement' }
        }
        elseif ($Scenario -eq 'replacement-lock' -and $dialogText -match 'Failed to uninstall old application files\.') {
            # electron-builder acknowledges this terminal error, then exits with code 2.
            $acknowledge = @($buttons | Where-Object { $_.Id -eq 1 -and $_.Text.Replace('&', '') -match $Labels.okPattern })
            if ($acknowledge.Count -gt 0) { $chosen = $acknowledge[0]; $action = 'acknowledge-terminal-uninstall-failure' }
        }
        elseif ($force.Count -gt 0) {
            Assert-True ($Mode -ne 'silent') 'silent-showed-force-dialog'
            Assert-True ($retry.Count -gt 0) 'force-dialog-retry-missing'
            $cancel = @($buttons | Where-Object { $_.Id -eq 2 -and (Get-UiLabel $_.Text) -eq 'cancel' })
            Assert-True ($cancel.Count -gt 0) 'force-dialog-cancel-missing'
            Assert-True (Test-VisibleLossWarning $lastUi) 'force-dialog-loss-warning-missing'
            if ($Scenario -eq 'cancel') { $chosen = $cancel[0]; $action = 'cancel-after-warning' }
            elseif ($Scenario -eq 'force-retry' -and $retryCount -eq 0) { $chosen = $retry[0]; $action = 'retry-normal-close' }
            elseif ($Scenario -eq 'force-retry' -or $Scenario -eq 'real-force') { $chosen = $force[0]; $action = 'explicit-force-after-warning' }
            else { throw 'ASSERT:unexpected-force-dialog' }
        }
        elseif ($normal.Count -gt 0) {
            Assert-True ($Mode -eq 'standalone') 'updated-showed-initial-close-confirmation'
            Assert-True ($Scenario -ne 'no-target') 'absent-target-showed-close-prompt'
            $chosen = $normal[0]; $action = 'normal-close'
        }
        elseif ($Mode -ne 'silent') {
            foreach ($box in @($buttons | Where-Object { (Get-UiLabel $_.Text) -eq 'wizard-run' })) {
                $shouldRun = $Mode -eq 'updated'
                if ([NativeInstallerProbe]::Checked($box.Handle) -ne $shouldRun) { [NativeInstallerProbe]::Click($box.Handle) | Out-Null }
            }
            $next = @($buttons | Where-Object { $_.Id -eq 1 -and (Get-UiLabel $_.Text) -eq 'wizard-next' })
            if ($next.Count -gt 0) { $chosen = $next[0]; $action = 'wizard-next' }
        }
        if ($null -ne $chosen -and ($chosen.Handle -ne $lastHandle -or ([DateTime]::UtcNow - $lastClickAt).TotalSeconds -gt 2)) {
            if ($action -eq 'retry-normal-close') { $retryCount++; $warningCount++ }
            if ($action -eq 'explicit-force-after-warning') { $forceCount++; $warningCount++ }
            if ($action -eq 'cancel-after-warning') { $warningCount++ }
            if ($action -eq 'normal-close') { $normalCount++ }
            if ($action -eq 'cancel-or-abort-locked-replacement') { $lockCancelCount++ }
            $transport = if ($action -eq 'wizard-next') { 'WM_COMMAND-BN_CLICKED' } else { 'BM_CLICK' }
            $posted = if ($action -eq 'wizard-next') { [NativeInstallerProbe]::Command($chosen.Handle) } else { [NativeInstallerProbe]::Click($chosen.Handle) }
            Add-InstallerTrace $trace $timer $stage $action $transport $chosen.Id $posted
            Assert-True $posted 'button-post-failed'
            $actions.Add($action) | Out-Null
            $lastHandle = $chosen.Handle
            $lastClickAt = [DateTime]::UtcNow
        }
        if ($live.Count -eq 0) {
            if ($null -eq $emptySince) { $emptySince = [DateTime]::UtcNow }
            if (([DateTime]::UtcNow - $emptySince).TotalSeconds -ge 2) { break }
        }
        else { $emptySince = $null }
        Start-Sleep -Milliseconds 400
    }
    if ($lastUi.Count -gt 0) { $script:LastUiEvidence = Get-UiEvidence $lastUi }
    if ($timer.Elapsed.TotalSeconds -ge 240) {
        foreach ($item in @(Get-InstallerProcesses $ids)) { Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction SilentlyContinue }
        throw 'ASSERT:installer-timeout'
    }
    $process.Refresh()
    Assert-True (-not $replacementWhileFixtureAlive) 'replacement-before-fixture-exit'
    if ($Scenario -eq 'replacement-lock') {
        Assert-True ($forceCount -eq 0) 'lock-case-must-not-force'
        if ($process.ExitCode -ne 0) { Assert-True ($lockCancelCount -ge 1) 'locked-replacement-cancel-action-not-observed' }
    }
    elseif ($Scenario -eq 'cancel' -or $Mode -eq 'silent') {
        Assert-True ($process.ExitCode -ne 0) 'cancel-or-silent-block-returned-success'
        Assert-True ($forceCount -eq 0) 'unexpected-force-consent'
    }
    else { Assert-True ($process.ExitCode -eq 0) 'installer-nonzero-exit' }
    if ($Scenario -eq 'force-retry') {
        Assert-True ($retryCount -eq 1 -and $forceCount -eq 1) 'retry-force-actions-not-observed'
    }
    if ($Scenario -eq 'cancel') { Assert-True ($warningCount -eq 1) 'cancel-warning-not-observed' }
    if ($Scenario -eq 'real-force') { Assert-True ($forceCount -eq 1) 'real-app-force-not-observed' }
    if ($Mode -eq 'standalone' -and $Scenario -ne 'no-target') { Assert-True ($normalCount -ge 1) 'standalone-normal-prompt-missing' }
    if ($Mode -eq 'updated') { Assert-True ($normalCount -eq 0) 'updated-initial-prompt-not-skipped' }
    $result = [ordered]@{ mode = $Mode; scenario = $Scenario; actions = @($actions); exitCode = $process.ExitCode; elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2) }
    if ($Mode -eq 'updated' -and $Scenario -ne 'cancel' -and $process.ExitCode -eq 0) {
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        $mains = @()
        do {
            $mains = @(Get-TargetProcesses | Where-Object { [string]$_.CommandLine -notmatch '--type=' })
            if ($mains.Count -gt 0) { break }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert-True ($mains.Count -eq 1) 'updated-did-not-reopen-one-main-process'
        $result.reopenedMainProcessCount = $mains.Count
        $remainingSeconds = [Math]::Max(1, [Math]::Min(60, [Math]::Floor(240 - $timer.Elapsed.TotalSeconds)))
        $result.reopenedMainReadiness = Wait-ElectronMainReady ([int]$mains[0].ProcessId) $remainingSeconds
    }
    return $result
}

function Get-InstalledShortcutSnapshot([object[]]$Folders, [string]$Name, [string]$AppId, [object]$Package) {
    $defaultName = [regex]::Unescape('AI \u521b\u4f5c\u5de5\u4f5c\u53f0.lnk')
    $wscript = New-Object -ComObject WScript.Shell
    $shell = New-Object -ComObject Shell.Application
    $snapshot = [ordered]@{ setupSha256 = $Package.sha256; expectedFilename = $Name + '.lnk'; expectedAppUserModelId = $AppId; shortcutNameUtf16ByteLength = (Get-Item -LiteralPath (Join-Path $InstallDirectory 'channel-shortcut-name.txt')).Length; folders = @(); links = @(); unreadableLinkCount = 0 }
    $script:LastShortcutEvidence = $snapshot
    foreach ($folder in $Folders) {
        $exists = -not [string]::IsNullOrWhiteSpace($folder.path) -and (Test-Path -LiteralPath $folder.path -PathType Container)
        $entries = @()
        if ($exists) { $entries = @(Get-ChildItem -LiteralPath $folder.path -Filter '*.lnk' -File -Recurse) }
        $snapshot.folders += [ordered]@{ context = $folder.kind; exists = $exists; enumeratedLinkCount = $entries.Count }
        foreach ($entry in $entries) {
            $knownName = $entry.Name -eq ($Name + '.lnk') -or $entry.Name -eq $defaultName
            try { $link = $wscript.CreateShortcut($entry.FullName); $target = [string]$link.TargetPath }
            catch {
                $snapshot.unreadableLinkCount++
                if ($knownName) { $snapshot.links += [ordered]@{ context = $folder.kind; filename = $entry.Name; readable = $false; readErrorType = $_.Exception.GetType().Name } }
                continue
            }
            $targetMatch = [string]::Equals($target, $TargetExecutable, [StringComparison]::OrdinalIgnoreCase)
            $canonicalMatch = $targetMatch
            if (-not $targetMatch -and $target -match '^[A-Za-z]:\\' -and $target.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
                $canonicalMatch = [string]::Equals([NativeInstallerProbe]::LongPath($target), $TargetExecutable, [StringComparison]::OrdinalIgnoreCase)
            }
            if (-not ($knownName -or $targetMatch -or $canonicalMatch)) { continue }
            $icon = ([string]$link.IconLocation -replace ',\s*-?\d+$', '').Trim('"')
            $workingDirectory = [string]$link.WorkingDirectory
            $targetEmpty = [string]::IsNullOrWhiteSpace($target)
            $workingDirEmpty = [string]::IsNullOrWhiteSpace($workingDirectory)
            $iconWithin = $icon.StartsWith($InstallDirectory + '\', [StringComparison]::OrdinalIgnoreCase)
            $namespace = $shell.Namespace($entry.DirectoryName)
            $item = if ($null -ne $namespace) { $namespace.ParseName($entry.Name) } else { $null }
            $actualId = if ($null -ne $item) { [string]$item.ExtendedProperty('System.AppUserModel.ID') } else { '' }
            $snapshot.links += [ordered]@{
                context = $folder.kind; filename = $entry.Name; readable = $true
                rootEntry = [string]::Equals($entry.DirectoryName, $folder.path, [StringComparison]::OrdinalIgnoreCase)
                expectedNameMatch = $entry.Name -eq ($Name + '.lnk'); whiteLabelName = $entry.Name -eq $defaultName
                targetMatch = $targetMatch; targetCanonicalMatch = $canonicalMatch
                target = if ($targetMatch) { 'TEST_INSTALL\ai-canvas.exe' } else { $null }
                targetEmpty = $targetEmpty; targetBasename = ($target -split '[\\/]')[-1]; targetLength = $target.Length
                targetFileExists = -not $targetEmpty -and (Test-Path -LiteralPath $target -PathType Leaf)
                targetWithinTestRoot = $target.StartsWith($TestRoot + '\', [StringComparison]::OrdinalIgnoreCase)
                workingDirEmpty = $workingDirEmpty; workingDirExists = -not $workingDirEmpty -and (Test-Path -LiteralPath $workingDirectory -PathType Container)
                workingDirWithinTestRoot = $workingDirectory.StartsWith($TestRoot + '\', [StringComparison]::OrdinalIgnoreCase)
                workingDirectoryMatch = [string]::Equals($workingDirectory, $InstallDirectory, [StringComparison]::OrdinalIgnoreCase)
                iconWithinInstall = $iconWithin; iconExists = $iconWithin -and (Test-Path -LiteralPath $icon -PathType Leaf)
                iconRelative = if ($iconWithin) { $icon.Substring($InstallDirectory.Length + 1) } else { $null }
                iconBasename = ($icon -split '[\\/]')[-1]
                appUserModelId = $actualId; appUserModelIdMatch = $actualId -eq $AppId
            }
        }
    }
    return $snapshot
}

function Assert-InstalledIdentity([object]$Package = $Candidate, [bool]$StrictShortcuts = $true) {
    $binding = Get-Content -LiteralPath (Join-Path $InstallDirectory 'channel-binding-install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$binding.channelName)) 'channel-name-empty'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$binding.bindingToken)) 'channel-token-missing'
    if ($null -ne $manifest.PSObject.Properties['expectedChannelName']) {
        Assert-True ([string]$binding.channelName -ceq [string]$manifest.expectedChannelName) 'channel-name-not-expected'
    }
    $versionInfo = (Get-Item -LiteralPath $TargetExecutable).VersionInfo
    $version = [string]$versionInfo.FileVersion
    $nativeVersion = '{0}.{1}.{2}.{3}' -f $versionInfo.ProductMajorPart, $versionInfo.ProductMinorPart, $versionInfo.ProductBuildPart, $versionInfo.ProductPrivatePart
    $expectedNativeVersion = (($Package.version -split '[-+]', 2)[0]) + '.0'
    $script:LastInstalledVersionEvidence = [ordered]@{ setupSha256 = $Package.sha256; expectedVersion = $Package.version; observedProductVersion = [string]$versionInfo.ProductVersion; observedFileVersion = $version; observedNativeProductVersion = $nativeVersion; expectedNativeProductVersion = $expectedNativeVersion }
    $hashes = Get-InstalledHashes
    foreach ($pair in @(@{ manifest = 'exeSha256'; installed = 'exe' }, @{ manifest = 'asarSha256'; installed = 'asar' }, @{ manifest = 'helperSha256'; installed = 'helper' })) {
        $pin = [string]$Package.($pair.manifest)
        if ($pin -ne '') { Assert-True ($hashes[$pair.installed] -eq $pin) 'installed-package-hash-pin-mismatch' }
    }
    # Windows ProductVersion is numeric; electron-builder stores the full semver in FileVersion.
    Assert-True ($version -eq $Package.version) 'installed-file-version-mismatch'
    Assert-True ($nativeVersion -eq $expectedNativeVersion) 'installed-native-product-version-mismatch'
    $code = (Get-Content -LiteralPath (Join-Path $InstallDirectory 'channel-code.txt') -Raw -Encoding UTF8).Trim()
    Assert-True ($code -eq 'XINBAO-AI') 'channel-code-mismatch'
    $diagnostics = Get-Content -LiteralPath (Join-Path $InstallDirectory 'channel-install-diagnostics.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $mode = [string]$diagnostics.mode
    Assert-True ($mode -eq 'resolved') 'real-channel-not-resolved'
    $appId = (Get-Content -LiteralPath (Join-Path $InstallDirectory 'channel-app-user-model-id.txt') -Raw -Encoding UTF8).Trim()
    Assert-True (-not [string]::IsNullOrWhiteSpace($appId)) 'channel-appid-missing'
    if ($null -ne $OriginalAppId) { Assert-True ($appId -eq $OriginalAppId) 'upgrade-appid-changed' }
    $name = (Get-Content -LiteralPath (Join-Path $InstallDirectory 'channel-shortcut-name.txt') -Raw -Encoding Unicode).Trim()
    $folders = @(
        @{ kind = 'desktop-current'; path = [Environment]::GetFolderPath('DesktopDirectory') },
        @{ kind = 'programs-current'; path = [Environment]::GetFolderPath('Programs') },
        @{ kind = 'desktop-all'; path = [Environment]::GetFolderPath('CommonDesktopDirectory') },
        @{ kind = 'programs-all'; path = [Environment]::GetFolderPath('CommonPrograms') }
    )
    $shortcutEvidence = Get-InstalledShortcutSnapshot $folders $name $appId $Package
    $links = @($shortcutEvidence.links | Where-Object { $_.readable -and $_.rootEntry -and $_.expectedNameMatch -and $_.targetMatch })
    $gaps = @()
    foreach ($link in $links) {
        if (-not $link.iconWithinInstall) { $gaps += 'shortcut-icon-outside-install' }
        if (-not $link.iconExists) { $gaps += 'shortcut-icon-missing' }
        if (-not $link.appUserModelIdMatch) { $gaps += 'shortcut-appid-mismatch' }
        if (-not $link.workingDirectoryMatch) { $gaps += 'shortcut-working-directory-mismatch' }
    }
    if (@($links | Where-Object { $_.context -like 'desktop-*' }).Count -eq 0) { $gaps += 'actual-desktop-shortcut-missing' }
    if (@($links | Where-Object { $_.context -like 'programs-*' }).Count -eq 0) { $gaps += 'actual-start-menu-shortcut-missing' }
    $defaultName = [regex]::Unescape('AI \u521b\u4f5c\u5de5\u4f5c\u53f0.lnk')
    if ($name + '.lnk' -ne $defaultName) {
        foreach ($folder in $folders) {
            if (Test-Path -LiteralPath (Join-Path $folder.path $defaultName)) { $gaps += 'stale-white-label-shortcut' }
        }
    }
    $shortcutEvidence.acceptanceRole = if ($StrictShortcuts) { 'candidate-acceptance' } else { 'historical-baseline-observation' }
    $shortcutEvidence.brandingGaps = @($gaps | Select-Object -Unique)
    $shortcutEvidence.strictBrandingSatisfied = $gaps.Count -eq 0
    $script:LastShortcutEvidence = $shortcutEvidence
    if ($StrictShortcuts -and $gaps.Count -gt 0) { throw ('ASSERT:' + $gaps[0]) }
    Assert-True ((Get-Content -LiteralPath (Join-Path $AssetDirectory 'sentinel.txt') -Raw -Encoding UTF8) -eq 'external-asset-must-survive') 'external-assets-changed'
    $slug = if ($null -ne $binding.PSObject.Properties['channelSlug']) { [string]$binding.channelSlug } elseif ($null -ne $binding.PSObject.Properties['slug']) { [string]$binding.slug } else { '' }
    return [ordered]@{ version = $version; productVersion = [string]$versionInfo.ProductVersion; nativeProductVersion = $nativeVersion; channelName = [string]$binding.channelName; channelSlug = $slug; mode = $mode; bindingPresent = $true; appUserModelId = $appId; shortcuts = $links; shortcutEvidence = $shortcutEvidence; hashes = $hashes }
}

function Assert-CandidateFiles {
    $hashes = Get-InstalledHashes
    Assert-True ($hashes.exe -eq $ExpectedInstalled.exe) 'candidate-exe-not-restored'
    Assert-True ($hashes.asar -eq $ExpectedInstalled.asar) 'candidate-asar-not-restored'
    Assert-True ($hashes.helper -eq $ExpectedInstalled.helper) 'candidate-helper-changed'
    return $hashes
}

function Get-CurrentUserInstallRegistration {
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
        $base = $null; $install = $null; $uninstall = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $view)
            $install = $base.OpenSubKey(('Software\' + $manifest.appGuid), $false)
            $uninstall = $base.OpenSubKey(('Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $manifest.appGuid), $false)
            $location = if ($null -ne $install) { [string]$install.GetValue('InstallLocation', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { '' }
            [ordered]@{ view = $view.ToString(); installKeyPresent = $null -ne $install; installLocationMatchesTestDir = [string]::Equals($location.TrimEnd([char[]]'\/'), $InstallDirectory, [StringComparison]::OrdinalIgnoreCase); uninstallKeyPresent = $null -ne $uninstall }
        }
        finally {
            if ($null -ne $uninstall) { $uninstall.Dispose() }
            if ($null -ne $install) { $install.Dispose() }
            if ($null -ne $base) { $base.Dispose() }
        }
    }
}

function Invoke-FixtureCase([string]$Mode, [string]$Scenario) {
    Stop-TargetProcesses
    Copy-Item -LiteralPath $FixtureExecutable -Destination $TargetExecutable -Force
    $behavior = if ($Scenario -eq 'responsive') { 'normal' } elseif ($Scenario -eq 'delayed') { 'delayed' } else { 'hang' }
    $script:FixtureProcess = Start-Process -FilePath $TargetExecutable -ArgumentList ($behavior + ' ' + $GracefulFixtureDelayMilliseconds) -PassThru
    try {
        Wait-VisibleWindow $FixtureProcess.Id 20 | Out-Null
        $before = Get-InstalledHashes
        $result = Invoke-Installer $Candidate $Mode $Scenario
        $FixtureProcess.Refresh()
        if ($Scenario -eq 'cancel' -or $Mode -eq 'silent') {
            Assert-True (-not $FixtureProcess.HasExited) 'cancel-or-silent-killed-target'
            $after = Get-InstalledHashes
            Assert-True ($after.exe -eq $before.exe -and $after.asar -eq $before.asar) 'cancel-or-silent-replaced-files'
            $result.unchangedFiles = $true
        }
        else {
            Assert-True $FixtureProcess.HasExited 'fixture-survived-successful-replacement'
            $result.hashes = Assert-CandidateFiles
            if ($Scenario -eq 'delayed') {
                Assert-True ($result.elapsedSeconds * 1000 -ge $GracefulFixtureDelayMilliseconds) 'delayed-fixture-exited-before-grace-period'
                $result.requestedGracefulExitDelayMilliseconds = $GracefulFixtureDelayMilliseconds
                $result.forceWarningObserved = $false
            }
        }
        $OtherProcess.Refresh()
        Assert-True (-not $OtherProcess.HasExited) 'other-directory-process-terminated'
        $result.unrelatedCopySurvived = $true
        $result.processEvidence = 'synthetic-window-process'
        return $result
    }
    finally {
        Stop-TargetProcesses
        Copy-Item -LiteralPath $BackupExecutable -Destination $TargetExecutable -Force
        $script:FixtureProcess = $null
    }
}

function Wait-VisibleWindow([int]$ProcessId, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $windows = @([NativeInstallerProbe]::Windows([int[]]@($ProcessId)))
        if ($windows.Count -gt 0) { return $windows }
        Start-Sleep -Milliseconds 250
    }
    throw 'ASSERT:owned-visible-window-timeout'
}

function Wait-ElectronMainReady([int]$ProcessId, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $readyHandle = [IntPtr]::Zero
    $readySamples = 0
    while ([DateTime]::UtcNow -lt $deadline) {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        Assert-True ($null -ne $process -and -not $process.HasExited) 'electron-main-process-exited-before-ready'
        $windows = @([NativeInstallerProbe]::Windows([int[]]@($ProcessId)))
        if ($windows.Count -gt 0) { $script:LastUiEvidence = Get-UiEvidence $windows }
        $topLevel = @($windows | Where-Object { $_.TopLevel })
        Assert-True (@($topLevel | Where-Object { $_.ClassName -eq '#32770' }).Count -eq 0) 'electron-startup-dialog-before-ready'
        $chrome = @($topLevel | Where-Object { $_.ClassName -eq 'Chrome_WidgetWin_1' })
        $main = @($chrome | Where-Object { -not $_.ToolWindow -and $_.Width -ge 800 -and $_.Height -ge 500 })
        $splash = @($chrome | Where-Object { $_.ToolWindow -or $_.Width -lt 800 -or $_.Height -lt 500 })
        if ($main.Count -eq 1 -and $splash.Count -eq 0) {
            if ($main[0].Handle -eq $readyHandle) { $readySamples++ }
            else { $readyHandle = $main[0].Handle; $readySamples = 1 }
            if ($readySamples -ge 2) {
                return [ordered]@{ ownerPid = $ProcessId; rendererReadinessBarrierObserved = $true; class = $main[0].ClassName; width = $main[0].Width; height = $main[0].Height; toolWindow = $main[0].ToolWindow; extendedStyle = $main[0].ExtendedStyle; splashAbsent = $true; observedAt = [DateTime]::UtcNow.ToString('o') }
            }
        }
        else { $readyHandle = [IntPtr]::Zero; $readySamples = 0 }
        Start-Sleep -Milliseconds 400
    }
    throw 'ASSERT:electron-main-window-readiness-timeout'
}

try {
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    Assert-True ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1) 'requires-windows-powershell-51'
    Assert-True ([Environment]::OSVersion.Platform -eq 'Win32NT') 'requires-native-windows'
    Assert-True ([Environment]::Is64BitProcess) 'requires-native-64-bit-powershell-host'
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$manifest.channelCode -eq 'XINBAO-AI') 'only-authorized-channel-supported'
    Assert-True ($null -ne $manifest.PSObject.Properties['appGuid'] -and [string]$manifest.appGuid -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') 'manifest-invalid-app-guid'
    $Candidate = Get-Payload $manifest.candidate
    $Baseline = Get-Payload $manifest.baseline
    $Report.candidate = [ordered]@{ sha256 = $Candidate.sha256; version = $Candidate.version }
    $Report.baseline = [ordered]@{ sha256 = $Baseline.sha256; version = $Baseline.version }
    [IO.Directory]::CreateDirectory($TestRoot) | Out-Null
    [IO.Directory]::CreateDirectory($AssetDirectory) | Out-Null
    # This harness runs only on disposable hosted runners, never an existing customer profile.
    Assert-True (-not (Test-Path -LiteralPath $UserDataDirectory)) 'runner-userdata-not-empty'
    [IO.Directory]::CreateDirectory($UserDataDirectory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $UserDataDirectory 'channel-code.txt'), 'XINBAO-AI', $Utf8)
    [IO.File]::WriteAllText((Join-Path $AssetDirectory 'sentinel.txt'), 'external-asset-must-survive', $Utf8)
    Write-Json (Join-Path $UserDataDirectory 'xinbao-settings.json') @{ assetLibraryRootDir = $AssetDirectory }

    $nativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public sealed class ProbeWindow {
    public IntPtr Handle; public int OwnerPid; public int Id; public string ClassName; public string Text; public bool Enabled;
    public bool TopLevel; public int X; public int Y; public int Width; public int Height; public bool ToolWindow; public long ExtendedStyle;
}
public static class NativeInstallerProbe {
    [StructLayout(LayoutKind.Sequential)] private struct WindowRect { public int Left; public int Top; public int Right; public int Bottom; }
    private delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc fn, IntPtr p);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr h, EnumProc fn, IntPtr p);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint id);
    [DllImport("user32.dll")] private static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] private static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out WindowRect rect);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr h, StringBuilder b, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr h, StringBuilder b, int n);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] private static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode)] private static extern IntPtr SendTextTimeout(IntPtr h, uint msg, IntPtr w, string text, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode)] private static extern IntPtr ReadTextTimeout(IntPtr h, uint msg, IntPtr w, StringBuilder text, uint flags, uint timeout, out IntPtr result);
    [DllImport("kernel32.dll")] private static extern IntPtr OpenProcess(uint rights, bool inherit, int pid);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] private static extern uint GetLongPathName(string path, StringBuilder output, uint length);
    [DllImport("ntdll.dll")] private static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] private static extern int NtResumeProcess(IntPtr h);
    private static ProbeWindow Describe(IntPtr h, bool topLevel) {
        uint pid; GetWindowThreadProcessId(h, out pid);
        StringBuilder cls = new StringBuilder(256), text = new StringBuilder(4096);
        GetClassName(h, cls, cls.Capacity); GetWindowText(h, text, text.Capacity);
        WindowRect rect; GetWindowRect(h, out rect); long style=GetWindowLongPtr(h,-20).ToInt64();
        return new ProbeWindow { Handle=h, OwnerPid=(int)pid, Id=GetDlgCtrlID(h), ClassName=cls.ToString(), Text=text.ToString(), Enabled=IsWindowEnabled(h), TopLevel=topLevel, X=rect.Left, Y=rect.Top, Width=Math.Max(0,rect.Right-rect.Left), Height=Math.Max(0,rect.Bottom-rect.Top), ToolWindow=(style & 0x80)!=0, ExtendedStyle=style };
    }
    public static ProbeWindow[] Windows(int[] pids) {
        HashSet<int> owners = new HashSet<int>(pids); List<ProbeWindow> items = new List<ProbeWindow>();
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            uint id; GetWindowThreadProcessId(h, out id);
            if (owners.Contains((int)id) && IsWindowVisible(h)) {
                items.Add(Describe(h,true));
                EnumChildWindows(h, delegate(IntPtr child, IntPtr unused) { if (IsWindowVisible(child)) items.Add(Describe(child,false)); return true; }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
        return items.ToArray();
    }
    public static bool Click(IntPtr h) { return PostMessage(h, 0xF5, IntPtr.Zero, IntPtr.Zero); }
    public static bool Command(IntPtr h) { IntPtr parent=GetParent(h); return parent!=IntPtr.Zero && PostMessage(parent,0x111,new IntPtr(GetDlgCtrlID(h) & 0xffff),h); }
    public static bool SetText(IntPtr h, string text) { IntPtr result; return SendTextTimeout(h,0xC,IntPtr.Zero,text,2,1000,out result)!=IntPtr.Zero && result!=IntPtr.Zero; }
    public static bool TextEquals(IntPtr h, string expected) { IntPtr result; StringBuilder text=new StringBuilder(64); return ReadTextTimeout(h,0xD,new IntPtr(text.Capacity),text,2,1000,out result)!=IntPtr.Zero && text.ToString()==expected; }
    public static string LongPath(string path) { StringBuilder output=new StringBuilder(32768); uint length=GetLongPathName(path,output,(uint)output.Capacity); return length>0 && length<output.Capacity ? output.ToString() : path; }
    public static bool Checked(IntPtr h) { IntPtr result; SendMessageTimeout(h, 0xF0, IntPtr.Zero, IntPtr.Zero, 2, 1000, out result); return result.ToInt64()==1; }
    public static int Suspend(int pid) { IntPtr h=OpenProcess(0x800,false,pid); if(h==IntPtr.Zero)return -1; try{return NtSuspendProcess(h);}finally{CloseHandle(h);} }
    public static int Resume(int pid) { IntPtr h=OpenProcess(0x800,false,pid); if(h==IntPtr.Zero)return -1; try{return NtResumeProcess(h);}finally{CloseHandle(h);} }
}
'@
    Add-Type -TypeDefinition $nativeSource
    Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
    $fixtureSource = @'
using System;
using System.Windows.Forms;
public static class ValidationFixture {
    [STAThread] public static void Main(string[] args) {
        Application.EnableVisualStyles(); Form form = new Form(); form.Text="AIwork native validation fixture " + (Environment.Is64BitProcess ? "x64" : "x86");
        form.Width=360; form.Height=160;
        bool hang=args.Length>0 && args[0]=="hang";
        bool delayed=args.Length>0 && args[0]=="delayed";
        Timer exitTimer=new Timer(); exitTimer.Interval=args.Length>1 ? Int32.Parse(args[1]) : 1;
        exitTimer.Tick += delegate { exitTimer.Stop(); delayed=false; form.Close(); };
        form.FormClosing += delegate(object sender, FormClosingEventArgs e) {
            if(hang || delayed) { e.Cancel=true; if(delayed && !exitTimer.Enabled)exitTimer.Start(); }
        };
        Button button=new Button(); button.Text="Harness proceed"; button.Width=180; button.Top=30; button.Left=50;
        TextBox input=new TextBox(); input.Width=180; input.Top=70; input.Left=50; form.Controls.Add(input);
        button.Click += delegate { hang=false; delayed=false; form.Close(); }; form.Controls.Add(button); Application.Run(form);
    }
}
'@
    $FixtureExecutable = Join-Path $TestRoot 'fixture.exe'
    $compiler = New-Object Microsoft.CSharp.CSharpCodeProvider
    $compilerParameters = New-Object System.CodeDom.Compiler.CompilerParameters
    $compilerParameters.GenerateExecutable = $true
    $compilerParameters.OutputAssembly = $FixtureExecutable
    $compilerParameters.CompilerOptions = '/target:winexe /platform:x64'
    $compilerParameters.ReferencedAssemblies.AddRange([string[]]@('System.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll'))
    $compileResult = $compiler.CompileAssemblyFromSource($compilerParameters, $fixtureSource)
    Assert-True (-not $compileResult.Errors.HasErrors) 'x64-fixture-compilation-failed'
    $compiler.Dispose()
    $Report.fixtureArchitecture = 'x64'
    $Labels = @{
        normal = [regex]::Unescape('\u5173\u95ed\u8f6f\u4ef6\u5e76\u7ee7\u7eed')
        retry = [regex]::Unescape('\u91cd\u8bd5\u6b63\u5e38\u5173\u95ed')
        force = [regex]::Unescape('\u5f3a\u5236\u5173\u95ed\u5e76\u5347\u7ea7')
        cancel = [regex]::Unescape('\u53d6\u6d88\u5b89\u88c5')
        warning = [regex]::Unescape('\u5f3a\u5236\u5173\u95ed\u53ef\u80fd\u4e22\u5931\u672a\u4fdd\u5b58\u7684\u5185\u5bb9\uff0c\u5e76\u4e2d\u65ad\u6b63\u5728\u8fdb\u884c\u7684\u4efb\u52a1')
        nextPattern = [regex]::Unescape('^(\u4e0b\u4e00\u6b65|\u5b89\u88c5|\u5b8c\u6210|\u6211\u63a5\u53d7|Next|Install|Finish|I Agree)')
        runPattern = [regex]::Unescape('^(\u8fd0\u884c|\u542f\u52a8|Run |Launch )')
        lockFailurePattern = [regex]::Unescape('(\u65e0\u6cd5\u5173\u95ed|cannot be closed|Error opening file for writing|Error creating file|error writing file)')
        cancelPattern = [regex]::Unescape('^(\u53d6\u6d88|\u4e2d\u6b62|\u7ec8\u6b62|Cancel|Abort)')
        okPattern = [regex]::Unescape('^(OK|\u786e\u5b9a)')
    }
    $ok = Invoke-Case 'native-ui-driver-self-test' {
        $observations = @{ visibleWindow = $true }
        foreach ($transport in @('BM_CLICK', 'WM_COMMAND-BN_CLICKED')) {
            $self = Start-Process -FilePath $FixtureExecutable -ArgumentList normal -PassThru
            try {
                $windows = @(Wait-VisibleWindow $self.Id 20)
                Assert-True (@($windows | Where-Object { $_.Text -eq 'AIwork native validation fixture x64' }).Count -eq 1) 'fixture-not-running-as-x64'
                $button = @($windows | Where-Object { $_.Text -eq 'Harness proceed' })
                Assert-True ($button.Count -eq 1) 'ui-selftest-button-not-found'
                $input = @($windows | Where-Object { $_.ClassName.StartsWith('WindowsForms10.EDIT', [StringComparison]::OrdinalIgnoreCase) })
                Assert-True ($input.Count -eq 1) 'ui-selftest-input-not-found'
                Assert-True ([NativeInstallerProbe]::SetText($input[0].Handle, 'XINBAO-AI') -and [NativeInstallerProbe]::TextEquals($input[0].Handle, 'XINBAO-AI')) 'ui-selftest-input-not-confirmed'
                $posted = if ($transport -eq 'BM_CLICK') { [NativeInstallerProbe]::Click($button[0].Handle) } else { [NativeInstallerProbe]::Command($button[0].Handle) }
                Assert-True $posted 'ui-selftest-click-failed'
                Assert-True ($self.WaitForExit(10000)) 'ui-selftest-click-did-not-close'
                $observations[$transport] = $true
                $observations.WM_SETTEXT = $true
            }
            finally { if (-not $self.HasExited) { Stop-Process -Id $self.Id -Force } }
        }
        $roundTripDirectory = Join-Path $TestRoot ('Shortcut reader ' + [char]0x6D4B + [char]0x8BD5)
        [IO.Directory]::CreateDirectory($roundTripDirectory) | Out-Null
        $roundTripExe = Join-Path $roundTripDirectory 'ai-canvas.exe'
        $roundTripLink = Join-Path $roundTripDirectory 'reader-selftest.lnk'
        Copy-Item -LiteralPath $FixtureExecutable -Destination $roundTripExe
        $writerShell = New-Object -ComObject WScript.Shell
        $testLink = $writerShell.CreateShortcut($roundTripLink)
        try { $testLink.TargetPath = $roundTripExe }
        catch {
            $Report.shortcutReaderSelfTestFailure = [ordered]@{
                stage = 'set-target-path'; exceptionType = $_.Exception.GetType().FullName
                hresult = $_.Exception.HResult; syntheticTarget = $roundTripExe
                targetType = $roundTripExe.GetType().FullName; targetExists = (Test-Path -LiteralPath $roundTripExe)
                targetLength = $roundTripExe.Length; message = $_.Exception.Message
            }
            throw
        }
        $testLink.WorkingDirectory = $roundTripDirectory
        $testLink.IconLocation = $roundTripExe + ',0'
        $testLink.Save()
        $readerShell = New-Object -ComObject WScript.Shell
        $observedLink = $readerShell.CreateShortcut($roundTripLink)
        Assert-True ([string]::Equals([string]$observedLink.TargetPath, $roundTripExe, [StringComparison]::OrdinalIgnoreCase)) 'shortcut-reader-target-roundtrip-failed'
        Assert-True ([string]::Equals([string]$observedLink.WorkingDirectory, $roundTripDirectory, [StringComparison]::OrdinalIgnoreCase)) 'shortcut-reader-workingdir-roundtrip-failed'
        Assert-True ([string]::Equals(([string]$observedLink.IconLocation -replace ',\s*-?\d+$', '').Trim('"'), $roundTripExe, [StringComparison]::OrdinalIgnoreCase)) 'shortcut-reader-icon-roundtrip-failed'
        $observations.shortcutReaderUnicodeRoundTrip = $true
        return $observations
    }
    Assert-True $ok 'native-ui-prerequisite-failed'
    $ok = Invoke-Case 'protected-baseline-fresh-interactive-real-channel' {
        $flow = Invoke-Installer $Baseline 'standalone' 'no-target'
        $identity = Assert-InstalledIdentity $Baseline $false
        $script:OriginalAppId = $identity.appUserModelId
        return @{ flow = $flow; installed = $identity }
    }
    Assert-True $ok 'baseline-install-prerequisite-failed'
    Stop-TargetProcesses
    $ok = Invoke-Case 'protected-old-to-candidate-upgrade-no-running-target' {
        $before = Get-InstalledHashes
        $flow = Invoke-Installer $Candidate 'standalone' 'no-target'
        $identity = Assert-InstalledIdentity
        Assert-True ($before.asar -ne $identity.hashes.asar) 'old-to-new-asar-did-not-change'
        $script:ExpectedInstalled = $identity.hashes
        Copy-Item -LiteralPath $TargetExecutable -Destination $BackupExecutable -Force
        return @{ flow = $flow; baselineHashes = $before; installed = $identity }
    }
    Assert-True $ok 'candidate-install-prerequisite-failed'
    Invoke-Case 'candidate-packaged-helpers-native-lf-parse-and-resolver-execution' {
        $helpers = @($PackagedHelpers.Values | Where-Object { $_.setupSha256 -eq $Candidate.sha256 })
        Assert-True ($helpers.Count -eq 4) 'candidate-packaged-helpers-not-observed'
        $resolver = @($helpers | Where-Object { $_.filename -eq 'installer-resolve-channel.ps1' })[0]
        $stateDir = Join-Path $TestRoot 'lf-resolver-diagnostics'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $resolver.lfPath -StateDir $stateDir -ShortcutDiagnosticsOnly
        Assert-True ($LASTEXITCODE -eq 0) 'candidate-lf-resolver-execution-failed'
        Assert-True (Test-Path -LiteralPath (Join-Path $stateDir 'channel-install-diagnostics.json')) 'candidate-lf-resolver-diagnostics-missing'
        return @{ helperCount = $helpers.Count; nativeLFResolverExitCode = $LASTEXITCODE; helpers = @($helpers | ForEach-Object { @{ filename = $_.filename; sha256 = $_.sha256; asciiSource = $_.asciiSource; lfParserErrors = $_.lfParserErrors } }) }
    } | Out-Null
    $ok = Invoke-Case 'installed-powershell-51-lf-only-helper' {
        $helper = Join-Path $InstallDirectory 'installer-manage-process.ps1'
        $bytes = [IO.File]::ReadAllBytes($helper)
        Assert-True (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'installed-helper-non-ascii'
        $lf = Join-Path $TestRoot 'helper-lf.ps1'
        [IO.File]::WriteAllText($lf, ([IO.File]::ReadAllText($helper, $Utf8) -replace "`r`n", "`n"), $Utf8)
        $tokens = $null; $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile($lf, [ref]$tokens, [ref]$parseErrors) | Out-Null
        Assert-True ($parseErrors.Count -eq 0) 'installed-helper-lf-parse-failed'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lf -TargetExecutable $TargetExecutable -Action Inspect
        Assert-True ($LASTEXITCODE -eq 0) 'installed-helper-lf-execution-failed'
        return @{ installedHelperSha256 = Get-Hash $helper; lfCopySha256 = Get-Hash $lf; nativeParserErrors = 0; nativeInspectExitCode = $LASTEXITCODE }
    }
    Invoke-Case 'installed-helper-ownership-and-survivor-fixtures' {
        $helper = Join-Path $InstallDirectory 'installer-manage-process.ps1'
        $fixture = Join-Path $TestRoot 'classification-fixture.json'
        $state = Join-Path $TestRoot 'classification-state.json'
        $observations = @()
        foreach ($name in @('other-path', 'other-user', 'other-session', 'surviving-target', 'unverifiable')) {
            $record = [ordered]@{ pid = 12345; path = $TargetExecutable; owner = 'VALIDATION\runner'; sessionId = 1; accessible = $true; hasWindow = $true; closeSucceeds = $false; forceSucceeds = $false }
            $expectedExit = 20
            if ($name -eq 'other-path') { $record.path = Join-Path $TestRoot 'Other\ai-canvas.exe'; $expectedExit = 0 }
            if ($name -eq 'other-user') { $record.owner = 'VALIDATION\another-user' }
            if ($name -eq 'other-session') { $record.sessionId = 2 }
            if ($name -eq 'surviving-target') { $expectedExit = 10 }
            if ($name -eq 'unverifiable') { $record.accessible = $false; $record.path = $null; $expectedExit = 40 }
            Write-Json $fixture @($record)
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -TargetExecutable $TargetExecutable -Action Force -FixturePath $fixture -CurrentIdentity 'VALIDATION\runner' -CurrentSessionId 1 -WaitMilliseconds 0 -StatePath $state
            Assert-True ($LASTEXITCODE -eq $expectedExit) ('ownership-' + $name + '-unexpected-exit')
            $observations += @{ case = $name; exitCode = $LASTEXITCODE }
        }
        return @{ processEvidence = 'installed-helper-synthetic-classification-records'; results = $observations; installedHelperSha256 = Get-Hash $helper }
    } | Out-Null
    $otherDirectory = Join-Path $TestRoot 'Other copy'
    [IO.Directory]::CreateDirectory($otherDirectory) | Out-Null
    $otherExe = Join-Path $otherDirectory 'ai-canvas.exe'
    Copy-Item -LiteralPath $FixtureExecutable -Destination $otherExe
    $OtherProcess = Start-Process -FilePath $otherExe -ArgumentList hang -PassThru
    Wait-VisibleWindow $OtherProcess.Id 20 | Out-Null
    foreach ($mode in @('standalone', 'updated')) {
        foreach ($scenario in @('responsive', 'delayed', 'force-retry', 'cancel')) {
            Invoke-Case ($mode + '-' + $scenario) { Invoke-FixtureCase $mode $scenario } | Out-Null
        }
    }
    Invoke-Case 'silent-stuck-target-no-force-no-replacement' { Invoke-FixtureCase 'silent' 'silent-block' } | Out-Null
    Invoke-Case 'actual-protected-electron-visible-window-and-force-upgrade' {
        Stop-TargetProcesses
        $app = Start-Process -FilePath $TargetExecutable -ArgumentList '--no-sandbox' -PassThru
        try {
            $readiness = Wait-ElectronMainReady $app.Id 60
            Assert-True ([NativeInstallerProbe]::Suspend($app.Id) -eq 0) 'real-app-suspend-failed'
            $SuspendedIds.Add($app.Id) | Out-Null
            $flow = Invoke-Installer $Candidate 'updated' 'real-force'
            $app.Refresh()
            Assert-True $app.HasExited 'real-app-survived-force'
            $hashes = Assert-CandidateFiles
            $OtherProcess.Refresh()
            Assert-True (-not $OtherProcess.HasExited) 'real-case-terminated-unrelated-copy'
            return @{ flow = $flow; processEvidence = 'actual-protected-electron-main-suspended-after-renderer-ready-main-window'; startupReadiness = $readiness; installedHashes = $hashes; unrelatedCopySurvived = $true }
        }
        finally { Stop-TargetProcesses }
    } | Out-Null
    Invoke-Case 'actual-asar-exclusive-lock-safe-failure-or-atomic-replacement' {
        Stop-TargetProcesses
        $result = @{ outcome = 'preparing'; registrationBefore = @(Get-CurrentUserInstallRegistration) }
        $script:LastLockCaseEvidence = $result
        $result.identityBefore = Assert-InstalledIdentity
        $registrationBeforeValid = @($result.registrationBefore | Where-Object { $_.installKeyPresent -and $_.installLocationMatchesTestDir -and $_.uninstallKeyPresent }).Count -gt 0
        Assert-True $registrationBeforeValid 'lock-registration-prerequisite-missing'
        $asar = Join-Path $InstallDirectory 'resources\app.asar'
        $before = @{ exe = Get-Hash $TargetExecutable; asar = Get-Hash $asar }
        $lock = [IO.File]::Open($asar, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            Assert-True ((Get-OpenStreamHash $lock) -eq $before.asar) 'locked-asar-baseline-hash-mismatch'
            $flow = Invoke-Installer $Candidate 'updated' 'replacement-lock'
            Assert-True ((Get-OpenStreamHash $lock) -eq $before.asar) 'locked-old-asar-bytes-changed'
            if ($flow.exitCode -eq 0) {
                # A new readable ASAR while the old handle denies sharing proves a separate file object.
                $hashes = Assert-CandidateFiles
                $result.outcome = 'completed-atomic-replacement'
                $result.newAsarReadableWhileOldHandleExclusive = $true
                $result.installedHashes = $hashes
            }
            else {
                $result.outcome = 'explicitly-cancelled-locked-replacement'
            }
            $result.flow = $flow
            $result.oldOpenHandlePreserved = $true
        }
        finally { $lock.Dispose() }
        $result.registrationAfter = @(Get-CurrentUserInstallRegistration)
        if ($result.outcome -eq 'explicitly-cancelled-locked-replacement') {
            Assert-True ((Get-Hash $TargetExecutable) -eq $before.exe -and (Get-Hash $asar) -eq $before.asar) 'lock-failure-replaced-old-binaries'
            $result.unchangedExeAndAsar = $true
            $result.channelMetadataPreserved = Test-Path -LiteralPath (Join-Path $InstallDirectory 'channel-binding-install.json')
            $result.processHelperPreserved = Test-Path -LiteralPath (Join-Path $InstallDirectory 'installer-manage-process.ps1')
            if (-not $result.channelMetadataPreserved -or -not $result.processHelperPreserved) {
                $result.acceptanceFailureCode = 'locked-replacement-removed-installed-metadata'
            }
            $registrationAfterValid = @($result.registrationAfter | Where-Object { $_.installKeyPresent -and $_.installLocationMatchesTestDir -and $_.uninstallKeyPresent }).Count -gt 0
            $result.registrationPreserved = $registrationBeforeValid -and $registrationAfterValid -and (($result.registrationBefore | ConvertTo-Json -Compress) -ceq ($result.registrationAfter | ConvertTo-Json -Compress))
            if (-not $result.registrationPreserved -and -not $result.ContainsKey('acceptanceFailureCode')) {
                $result.acceptanceFailureCode = 'locked-replacement-registration-not-preserved'
            }
            try {
                $result.identityAfterBeforeRepair = Assert-InstalledIdentity
                $result.identityPreservedBeforeRepair = $true
            }
            catch {
                $result.identityPreservedBeforeRepair = $false
                $result.identityFailureCode = if ($_.Exception.Message -match '^ASSERT:([a-z0-9-]+)$') { $Matches[1] } else { 'unexpected-' + $_.Exception.GetType().Name }
                $result.identityFailureLine = $_.InvocationInfo.ScriptLineNumber
                if (Get-Variable LastShortcutEvidence -Scope Script -ErrorAction SilentlyContinue) { $result.shortcutsAfterBeforeRepair = $script:LastShortcutEvidence }
                if (-not $result.ContainsKey('acceptanceFailureCode')) { $result.acceptanceFailureCode = 'locked-replacement-identity-not-preserved' }
            }
            # Some historical uninstallers remove metadata before atomic cleanup; recover only this test install.
            $OtherProcess.Refresh()
            if (-not $OtherProcess.HasExited) { Stop-Process -Id $OtherProcess.Id -Force }
            $result.repairFlow = Invoke-Installer $Candidate 'standalone' 'no-target'
            Assert-CandidateFiles | Out-Null
        }
        return $result
    } | Out-Null
    Invoke-Case 'final-real-channel-shortcuts-assets' { Assert-InstalledIdentity } | Out-Null
}
catch {
    $Failure = if ($_.Exception.Message -match '^ASSERT:([a-z0-9-]+)$') { $Matches[1] } else { 'unexpected-' + $_.Exception.GetType().Name }
    $FailureLine = $_.InvocationInfo.ScriptLineNumber
    Write-Host ('HARNESS FAILURE [' + $Failure + ']')
}
finally {
    if ('NativeInstallerProbe' -as [type]) {
        Stop-TargetProcesses
        foreach ($id in @($SuspendedIds)) { [NativeInstallerProbe]::Resume($id) | Out-Null }
    }
    if ($null -ne $OtherProcess -and -not $OtherProcess.HasExited) { Stop-Process -Id $OtherProcess.Id -Force -ErrorAction SilentlyContinue }
    foreach ($id in @($OwnedInstallerIds)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    $Report.completedAt = [DateTime]::UtcNow.ToString('o')
    $Report.elapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $StartedAt).TotalSeconds, 2)
    $Report.failureCode = $Failure
    $Report.failureLine = $FailureLine
    $Report.failedCaseCount = @($Cases | Where-Object { $_.status -eq 'failed' }).Count
    $Report.status = if ($null -eq $Failure -and $Report.failedCaseCount -eq 0 -and $Cases.Count -eq $ExpectedCaseCount) { 'passed' } else { 'failed' }
    if (Get-Variable LastUiEvidence -Scope Script -ErrorAction SilentlyContinue) { $Report.lastUi = $script:LastUiEvidence }
    if (Get-Variable LastInstallerTrace -Scope Script -ErrorAction SilentlyContinue) { $Report.lastInstallerTrace = $script:LastInstallerTrace }
    if (Get-Variable LastInstalledVersionEvidence -Scope Script -ErrorAction SilentlyContinue) { $Report.lastInstalledVersion = $script:LastInstalledVersionEvidence }
    if (Get-Variable LastShortcutEvidence -Scope Script -ErrorAction SilentlyContinue) { $Report.lastShortcutEvidence = $script:LastShortcutEvidence }
    if (Get-Variable LastLockCaseEvidence -Scope Script -ErrorAction SilentlyContinue) { $Report.lockEvidence = $script:LastLockCaseEvidence }
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    Write-Json (Join-Path $OutputDirectory 'report.json') $Report
    $lines = @('Status: ' + $Report.status)
    $lines += 'PowerShell: ' + $Report.powershellVersion
    $lines += 'Channel: XINBAO-AI'
    $lines += @($Cases | ForEach-Object { $_.status.ToUpperInvariant() + ' ' + $_.name + ' (' + $_.elapsedSeconds + 's)' })
    if ($null -ne $Failure) { $lines += 'Harness failure: ' + $Failure }
    [IO.File]::WriteAllLines((Join-Path $OutputDirectory 'report.txt'), $lines, $Utf8)
}
if ($Report.status -ne 'passed') { exit 1 }
