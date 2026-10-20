# Run with Windows PowerShell 5.1 or pwsh; installer/process operations are isolated fixtures.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$driver = Join-Path $PSScriptRoot 'verify-windows-installer.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($driver, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'driver-parse-error' }
foreach ($name in @('Assert-True', 'Write-Json', 'Get-Payload', 'Get-SafeFailureEvidence', 'Save-InstallerExitEvidence', 'Invoke-FixtureCase', 'Invoke-Case', 'Test-OwnedInstallerIdentity', 'Test-OwnedInstallerParent', 'Stop-OwnedInstallerProcesses', 'Get-InstallerProcesses', 'Invoke-HarnessCleanup', 'Confirm-InstallerRunCheckbox', 'Get-ExpectedProcessFallback', 'Get-ProcessDialogButtons', 'Get-UiLabel', 'Get-SafeDialogText', 'Get-UiEvidence', 'Get-InstallerPageStage', 'Test-VisibleLossWarning')) {
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($null -ne $fn) { . ([scriptblock]::Create($fn.Extent.Text)) }
}
$FixtureExecutable = 'FIXTURE.exe'; $TargetExecutable = 'TEST_INSTALL/ai-canvas.exe'; $BackupExecutable = 'PROTECTED_BACKUP.exe'
$ExpectedInstalled = @{ exe = ('a' * 64); asar = 'asar'; helper = 'helper' }; $Candidate = @{}
$GracefulFixtureDelayMilliseconds = 6000
$Cases = New-Object Collections.ArrayList
$LastInstallerExitEvidence = $null
$LastRunCheckboxEvidence = $null
function Stop-TargetProcesses { $script:events.Add('stop-target-query') | Out-Null }
function Copy-Item {
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    if ($LiteralPath -eq $BackupExecutable) {
        $script:events.Add('restore-copy') | Out-Null
        if ($script:cleanupThrows) { throw (New-Object IO.IOException('private-path-and-token-must-not-be-exported')) }
        $script:targetHash = if ($script:badHash) { 'bad-restored-hash' } else { $ExpectedInstalled.exe }
    } else { $script:targetHash = 'synthetic-fixture-hash' }
}
function Start-Process {
    param([string]$FilePath, [string]$ArgumentList, [switch]$PassThru)
    if ($script:startThrows) { throw 'ASSERT:fixture-start-failed' }
    return $script:fakeFixture
}
function Wait-VisibleWindow { }
function Get-InstalledHashes { return @{ exe = $script:targetHash; asar = 'asar'; helper = 'helper' } }
function Get-Hash { param([string]$Path) $script:events.Add('verify-hash') | Out-Null; return $script:targetHash }
function Get-TargetProcesses {
    if ($null -ne $script:FixtureProcess -and -not $script:queryMisses -and -not $script:fakeFixture.HasExited) { return [pscustomobject]@{ ProcessId = 42 } }
}
function Invoke-Installer {
    if ($script:bodyThrows) { throw 'ASSERT:original-fixture-body' }
    return [ordered]@{ elapsedSeconds = 1 }
}
function Reset-Fixture {
    $script:events = New-Object Collections.ArrayList
    $script:targetHash = $ExpectedInstalled.exe
    $script:FixtureRecoveryFailed = $false
    $script:FixtureProcess = $null
    $script:bodyThrows = $true; $script:cleanupThrows = $false; $script:badHash = $false; $script:waitFails = $false; $script:queryMisses = $false; $script:startThrows = $false
    $script:fakeFixture = [pscustomobject]@{ Id = 42; Handle = [IntPtr]42; HasExited = $false; StartTime = [DateTime]::UtcNow; MainModule = [pscustomobject]@{ FileName = $TargetExecutable } }
    $script:fakeFixture | Add-Member ScriptMethod Refresh { }
    $script:fakeFixture | Add-Member ScriptMethod Kill { $script:events.Add('kill-owned-fixture') | Out-Null; if (-not $script:waitFails) { $this.HasExited = $true } }
    $script:fakeFixture | Add-Member ScriptMethod WaitForExit { param($timeout) $script:events.Add('wait-owned-fixture') | Out-Null; return -not $script:waitFails }
    $script:fakeFixture | Add-Member ScriptMethod Dispose { $script:events.Add('dispose-owned-fixture') | Out-Null }
    $script:OtherProcess = [pscustomobject]@{ HasExited = $false }
    $script:OtherProcess | Add-Member ScriptMethod Refresh { }
}
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw ('CHECK:' + $Name) }
    Write-Output ('PASS ' + $Name)
}
Reset-Fixture
$script:cleanupThrows = $true
$failure = ''
try { Invoke-FixtureCase 'standalone' 'responsive' | Out-Null } catch { $failure = $_.Exception.Message }
Check ($failure -ceq 'ASSERT:original-fixture-body') 'body error remains primary when cleanup also fails'
Check ($LastFixtureCaseEvidence.bodyFailure.code -ceq 'original-fixture-body' -and $LastFixtureCaseEvidence.cleanupFailure.exceptionType -ceq 'System.IO.IOException' -and $FixtureRecoveryFailed) 'body/cleanup failure recorded independently'
Check (($LastFixtureCaseEvidence | ConvertTo-Json -Depth 8) -notmatch 'private-path-and-token') 'failure evidence excludes raw messages'
Reset-Fixture
$failure = ''
try { Invoke-FixtureCase 'standalone' 'responsive' | Out-Null } catch { $failure = $_.Exception.Message }
Check ($failure -ceq 'ASSERT:original-fixture-body' -and $LastFixtureCaseEvidence.restoreVerified -and -not $FixtureRecoveryFailed) 'body failure with successful recovery'
Check ($events.IndexOf('kill-owned-fixture') -lt $events.IndexOf('wait-owned-fixture') -and $events.IndexOf('wait-owned-fixture') -lt $events.IndexOf('restore-copy') -and $events.IndexOf('restore-copy') -lt $events.IndexOf('verify-hash')) 'owned process settles before restore and hash verification'
Reset-Fixture
$script:bodyThrows = $false
$value = Invoke-FixtureCase 'standalone' 'cancel'
Check ($value.unchangedFiles -and $value.unrelatedCopySurvived -and $LastFixtureCaseEvidence.restoreVerified) 'original cancel assertions remain strict'
Reset-Fixture
$script:bodyThrows = $false; $script:cleanupThrows = $true
$failure = ''
try { Invoke-FixtureCase 'standalone' 'cancel' | Out-Null } catch { $failure = $_.Exception.GetType().FullName }
Check ($failure -ceq 'System.IO.IOException' -and $FixtureRecoveryFailed) 'cleanup failure fails an otherwise successful case'
Reset-Fixture
$script:waitFails = $true
$failure = ''
try { Invoke-FixtureCase 'standalone' 'responsive' | Out-Null } catch { $failure = $_.Exception.Message }
Check ($failure -ceq 'ASSERT:original-fixture-body' -and $FixtureRecoveryFailed -and -not $events.Contains('restore-copy')) 'wait timeout preserves body error and blocks overwrite'
Reset-Fixture
$script:bodyThrows = $false; $script:badHash = $true
$failure = ''
try { Invoke-FixtureCase 'standalone' 'cancel' | Out-Null } catch { $failure = $_.Exception.Message }
Check ($failure -ceq 'ASSERT:fixture-protected-exe-not-restored' -and $FixtureRecoveryFailed) 'restored EXE must match protected hash pin'
Reset-Fixture
$script:queryMisses = $true
try { Invoke-FixtureCase 'standalone' 'responsive' | Out-Null } catch { }
Check (-not $LastFixtureCaseEvidence.fixtureEnumeratedByTargetQuery -and $events.Contains('kill-owned-fixture') -and $LastFixtureCaseEvidence.restoreVerified) 'owned handle cleanup works even when target query misses'
Reset-Fixture
$script:startThrows = $true
$failure = ''
try { Invoke-FixtureCase 'standalone' 'responsive' | Out-Null } catch { $failure = $_.Exception.Message }
Check ($failure -ceq 'ASSERT:fixture-start-failed' -and $LastFixtureCaseEvidence.restoreVerified) 'startup failure still restores real executable'
Reset-Fixture
$script:cleanupThrows = $true
$ok = Invoke-Case 'standalone-responsive' { Invoke-FixtureCase 'standalone' 'responsive' } 6>$null
Check (-not $ok -and $Cases[-1].failureCode -ceq 'original-fixture-body' -and $null -ne $Cases[-1].fixtureEvidence.cleanupFailure) 'case report exposes both failures without replacing original'
$text = [IO.File]::ReadAllText($driver)
Check ($text.Contains("'fixture-recovery-failed-stopping-full-suite'")) 'failed recovery stops remaining full suite'
$identityStart = [DateTime]::UtcNow
$identityPath = 'OWNED_SETUP.exe'
$OwnedInstallerIdentities = @{}
$OwnedInstallerIds = New-Object 'Collections.Generic.HashSet[int]'
$ownedIds = New-Object 'Collections.Generic.HashSet[int]'
$script:processRecords = @{}
$script:processHandles = @{}
$script:killedOwnedIds = New-Object Collections.ArrayList
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, [string]$ErrorAction)
    if ([string]::IsNullOrWhiteSpace($Filter)) { return @($script:processRecords.Values) }
    $processId = [int]($Filter -replace '^ProcessId = ', '')
    if ($script:processRecords.ContainsKey($processId)) { return $script:processRecords[$processId] }
}
function Get-Process {
    param([int]$Id, [string]$ErrorAction)
    if ($script:processHandles.ContainsKey($Id)) { return $script:processHandles[$Id] }
}
foreach ($processId in @(42, 43, 44, 45, 46, 47, 48)) {
    $ownedIds.Add($processId) | Out-Null
    if ($processId -eq 48) { continue }
    $createdAt = if ($processId -eq 43) { $identityStart.AddSeconds(1) } else { $identityStart }
    $path = if ($processId -eq 44) { 'UNRELATED_IMAGE.exe' } else { $identityPath }
    $script:processRecords[$processId] = [pscustomobject]@{ ProcessId = $processId; ParentProcessId = 0; CreationDate = $createdAt; ExecutablePath = $path }
    if ($processId -ne 45) { $OwnedInstallerIdentities[$processId] = @{ startedAtFileTime = $identityStart.ToFileTimeUtc(); executablePath = $identityPath } }
    $handleStart = if ($processId -eq 46) { $identityStart.AddSeconds(2) } else { $identityStart }
    $handlePath = if ($processId -eq 47) { 'REUSED_AFTER_CIM.exe' } else { $identityPath }
    $handle = [pscustomobject]@{ Id = $processId; Handle = [IntPtr]$processId; StartTime = $handleStart; MainModule = [pscustomobject]@{ FileName = $handlePath }; HasExited = $false }
    $handle | Add-Member ScriptMethod Kill { $script:killedOwnedIds.Add($this.Id) | Out-Null; $this.HasExited = $true }
    $handle | Add-Member ScriptMethod WaitForExit { param($timeout) return $true }
    $handle | Add-Member ScriptMethod Refresh { }
    $handle | Add-Member ScriptMethod Dispose { }
    $script:processHandles[$processId] = $handle
}
Stop-OwnedInstallerProcesses $ownedIds
Check ($killedOwnedIds.Count -eq 1 -and $killedOwnedIds[0] -eq 42) 'installer cleanup skips stale PID/image and rechecks opened process identity'
Check (-not (Test-OwnedInstallerIdentity $processRecords[43]) -and -not (Test-OwnedInstallerIdentity $processRecords[44])) 'CIM birth time and image are both ownership requirements'
$LastInstallerInvocationStartedAt = $identityStart
$script:processRecords = @{
    100 = [pscustomobject]@{ ProcessId = 100; ParentProcessId = 0; CreationDate = $identityStart; ExecutablePath = $identityPath }
    101 = [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; CreationDate = $identityStart.AddMilliseconds(10); ExecutablePath = 'OWNED_CHILD.exe' }
    102 = [pscustomobject]@{ ProcessId = 102; ParentProcessId = 100; CreationDate = $identityStart.AddSeconds(-10); ExecutablePath = 'PREEXISTING_RUNNER.exe' }
    103 = [pscustomobject]@{ ProcessId = 103; ParentProcessId = 100; CreationDate = $identityStart.AddSeconds(1); ExecutablePath = $identityPath }
    104 = [pscustomobject]@{ ProcessId = 104; ParentProcessId = 100; CreationDate = $identityStart.AddMilliseconds(10); ExecutablePath = $TargetExecutable }
}
$OwnedInstallerIdentities = @{
    100 = @{ startedAtFileTime = $identityStart.ToFileTimeUtc(); executablePath = $identityPath }
    103 = @{ startedAtFileTime = $identityStart.AddSeconds(-2).ToFileTimeUtc(); executablePath = $identityPath }
}
$ids = New-Object 'Collections.Generic.HashSet[int]'
$ids.Add(100) | Out-Null; $ids.Add(103) | Out-Null
$observed = @(Get-InstallerProcesses $ids)
Check (($observed | ForEach-Object { [int]$_.ProcessId } | Sort-Object) -join ',' -ceq '100,101') 'installer discovery excludes preexisting runner, reused PID and target application'
Check ($OwnedInstallerIdentities.ContainsKey(101) -and -not $OwnedInstallerIdentities.ContainsKey(102)) 'discovered child ownership records image and creation time'
$OwnedInstallerIdentities = @{ 100 = @{ startedAtFileTime = $identityStart.ToFileTimeUtc(); executablePath = $identityPath } }
$ids = New-Object 'Collections.Generic.HashSet[int]'; $ids.Add(100) | Out-Null
$script:processRecords = @{
    100 = [pscustomobject]@{ ProcessId = 100; ParentProcessId = 0; CreationDate = $identityStart.AddSeconds(1); ExecutablePath = 'UNRELATED_REUSED_PARENT.exe' }
    105 = [pscustomobject]@{ ProcessId = 105; ParentProcessId = 100; CreationDate = $identityStart.AddSeconds(2); ExecutablePath = 'UNRELATED_NEW_CHILD.exe' }
}
$observed = @(Get-InstallerProcesses $ids)
Check ($observed.Count -eq 0 -and -not $OwnedInstallerIdentities.ContainsKey(105)) 'reused parent PID cannot claim a new unrelated child'
$rootHandle = [pscustomobject]@{ StartTime = $identityStart; ExitTime = $identityStart.AddSeconds(1); HasExited = $true; Handle = [IntPtr]100 }
foreach ($item in @(
    @{ name = 'original-child-before-root-exit'; childStart = $identityStart.AddMilliseconds(500); parentPresent = $true; accepted = $true },
    @{ name = 'unrelated-child-after-root-exit'; childStart = $identityStart.AddSeconds(3); parentPresent = $true; accepted = $false },
    @{ name = 'new-orphan-with-original-handle-proof'; childStart = $identityStart.AddMilliseconds(500); parentPresent = $false; accepted = $true }
)) {
    $OwnedInstallerIdentities = @{ 100 = @{ startedAtFileTime = $identityStart.ToFileTimeUtc(); executablePath = $identityPath; processHandle = $rootHandle } }
    $ids = New-Object 'Collections.Generic.HashSet[int]'; $ids.Add(100) | Out-Null
    $script:processRecords = @{ 105 = [pscustomobject]@{ ProcessId = 105; ParentProcessId = 100; CreationDate = $item.childStart; ExecutablePath = 'CHILD_TO_CLASSIFY.exe' } }
    if ($item.parentPresent) { $script:processRecords[100] = [pscustomobject]@{ ProcessId = 100; ParentProcessId = 0; CreationDate = $identityStart.AddSeconds(2); ExecutablePath = 'UNRELATED_REUSED_PARENT.exe' } }
    $observed = @(Get-InstallerProcesses $ids)
    Check (($observed.Count -eq 1) -eq $item.accepted -and $OwnedInstallerIdentities.ContainsKey(105) -eq $item.accepted) ('parent lifetime evidence ' + $item.name)
}
$OwnedInstallerIdentities = @{
    100 = @{ startedAtFileTime = $identityStart.ToFileTimeUtc(); executablePath = $identityPath }
    105 = @{ startedAtFileTime = $identityStart.AddMilliseconds(500).ToFileTimeUtc(); executablePath = 'KNOWN_ORPHAN.exe' }
}
$ids = New-Object 'Collections.Generic.HashSet[int]'; $ids.Add(100) | Out-Null; $ids.Add(105) | Out-Null
$script:processRecords = @{ 105 = [pscustomobject]@{ ProcessId = 105; ParentProcessId = 100; CreationDate = $identityStart.AddMilliseconds(500); ExecutablePath = 'KNOWN_ORPHAN.exe' } }
$observed = @(Get-InstallerProcesses $ids)
Check ($observed.Count -eq 1 -and $observed[0].ProcessId -eq 105) 'already-owned child remains tracked after parent disappears'
$getHashFunction = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-Hash' }, $true)
. ([scriptblock]::Create($getHashFunction.Extent.Text))
$payloadFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('aiwork-payload-identity-check-' + [Guid]::NewGuid().ToString('N'))
$payloadFixtureDirectory = Join-Path $payloadFixtureRoot 'payload'
[IO.Directory]::CreateDirectory($payloadFixtureDirectory) | Out-Null
$payloadFixtureFile = Join-Path $payloadFixtureDirectory 'fixture-setup.exe'
[IO.File]::WriteAllBytes($payloadFixtureFile, [byte[]]@(77, 90, 1, 2, 3))
$payloadPin = (Get-FileHash -LiteralPath $payloadFixtureFile -Algorithm SHA256).Hash.ToLowerInvariant()
Push-Location $payloadFixtureRoot
try {
    $PayloadDirectory = './payload'
    $payload = Get-Payload ([pscustomobject]@{ file = 'fixture-setup.exe'; sha256 = $payloadPin; version = '0.7.0' })
    $absoluteImage = (Resolve-Path -LiteralPath $payloadFixtureFile).ProviderPath
    Check ([IO.Path]::IsPathRooted($payload.path) -and $payload.path -ceq $absoluteImage) 'relative payload input resolves against the PowerShell location'
    $LastInstallerInvocationStartedAt = $identityStart
    $OwnedInstallerIdentities = @{ 200 = @{ startedAtFileTime = $identityStart.ToFileTimeUtc(); executablePath = $payload.path } }
    $ids = New-Object 'Collections.Generic.HashSet[int]'; $ids.Add(200) | Out-Null
    $script:processRecords = @{ 200 = [pscustomobject]@{ ProcessId = 200; ParentProcessId = 0; CreationDate = $identityStart; ExecutablePath = $absoluteImage } }
    $observed = @(Get-InstallerProcesses $ids)
    Check ($observed.Count -eq 1 -and $observed[0].ProcessId -eq 200 -and (Test-OwnedInstallerIdentity $processRecords[200])) 'resolved payload root matches absolute CIM image without relaxing identity checks'
} finally {
    Pop-Location
    Remove-Item -LiteralPath $payloadFixtureRoot -Recurse -Force
}
foreach ($item in @(
    @{ name = 'zero'; hasExited = $true; code = 0; succeeds = $true },
    @{ name = 'nonzero'; hasExited = $true; code = 2; succeeds = $false },
    @{ name = 'signed-native-failure'; hasExited = $true; code = -1073741819; succeeds = $false },
    @{ name = 'missing-code'; hasExited = $true; code = $null; succeeds = $false },
    @{ name = 'still-running'; hasExited = $false; code = $null; succeeds = $false }
)) {
    $exitProcess = [pscustomobject]@{ HasExited = $item.hasExited; ExitCode = $item.code }
    if (-not $item.hasExited) { $exitProcess | Add-Member -MemberType ScriptProperty -Name ExitCode -Value { throw 'exit-code-must-not-be-read-while-running' } -Force }
    $ok = Invoke-Case ('fixture-installer-exit-' + $item.name) {
        Save-InstallerExitEvidence $exitProcess 'standalone' 'no-target'
        Assert-True $exitProcess.HasExited 'installer-tracking-ended-before-process-exit'
        Assert-True ($exitProcess.ExitCode -eq 0) 'installer-nonzero-exit'
    } 6>$null
    $savedExit = $Cases[-1].installerExitEvidence
    Check ($ok -eq $item.succeeds -and $savedExit.hasExited -eq $item.hasExited -and $savedExit.exitCodePresent -eq ($null -ne $item.code) -and $savedExit.exitCode -ceq $item.code -and $savedExit.mode -ceq 'standalone' -and $savedExit.scenario -ceq 'no-target') ('failed and successful cases retain exact exit evidence: ' + $item.name)
}
& {
    foreach ($name in @('Get-TargetProcesses', 'Stop-TargetProcesses')) {
        $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $SuspendedIds = New-Object 'Collections.Generic.HashSet[int]'
    $script:targetEvents = New-Object Collections.ArrayList
    $script:targetHandles = @{}
    $script:targetQueryCount = 0; $script:targetTestMode = 'restart'; $script:targetWaitFails = $false
    $script:targetBirth = [DateTime]::UtcNow
    function Get-CimInstance {
        param([string]$ClassName, [string]$Filter)
        $script:targetQueryCount++
        if ($script:targetTestMode -eq 'stale' -and $script:targetQueryCount -gt 1) { return }
        foreach ($processId in @(301, 302, 303, 304)) {
            if ($script:targetTestMode -eq 'stale' -and $processId -gt 302) { continue }
            if ($processId -gt 302 -and -not $script:targetHandles[302].HasExited) { continue }
            if (-not $script:targetHandles[$processId].HasExited) {
                [pscustomobject]@{ ProcessId = $processId; CreationDate = $script:targetBirth; ExecutablePath = $TargetExecutable }
            }
        }
        [pscustomobject]@{ ProcessId = 999; CreationDate = $script:targetBirth; ExecutablePath = 'OTHER_DIRECTORY/ai-canvas.exe' }
    }
    function Get-Process {
        param([int]$Id, [string]$ErrorAction)
        return $script:targetHandles[$Id]
    }
    function Stop-Process { throw 'CHECK:target-fixture-must-use-verified-owned-handle' }
    foreach ($processId in @(301, 302, 303, 304)) {
        $handle = [pscustomobject]@{ Id = $processId; Handle = [IntPtr]$processId; HasExited = $false; StartTime = $script:targetBirth; MainModule = [pscustomobject]@{ FileName = $TargetExecutable } }
        $handle | Add-Member ScriptMethod Kill { $script:targetEvents.Add('kill-' + $this.Id) | Out-Null }
        $handle | Add-Member ScriptMethod WaitForExit { param($timeout) $script:targetEvents.Add('wait-' + $this.Id) | Out-Null; if ($script:targetWaitFails) { return $false }; $this.HasExited = $true; return $true }
        $handle | Add-Member ScriptMethod Refresh { }
        $handle | Add-Member ScriptMethod Dispose { $script:targetEvents.Add('dispose-' + $this.Id) | Out-Null }
        $script:targetHandles[$processId] = $handle
    }
    Stop-TargetProcesses
    Check (@($targetEvents | Where-Object { $_ -like 'wait-*' }).Count -eq 4 -and $targetQueryCount -ge 4) 'target cleanup waits for every Electron process and rechecks restarted descendants until empty'
    Check ($targetEvents.IndexOf('wait-302') -lt $targetEvents.IndexOf('kill-303') -and @($targetEvents | Where-Object { $_ -like '*999' }).Count -eq 0) 'target cleanup settles a new generation while preserving other install paths'
    $script:targetEvents.Clear(); $script:targetQueryCount = 0; $script:targetTestMode = 'stale'
    $script:targetHandles[301].HasExited = $false; $script:targetHandles[302].HasExited = $false
    $script:targetHandles[301].MainModule.FileName = 'REUSED_IMAGE.exe'
    $script:targetHandles[302].StartTime = $script:targetBirth.AddSeconds(2)
    $SuspendedIds.Add(301) | Out-Null
    Stop-TargetProcesses
    Check (@($targetEvents | Where-Object { $_ -like 'kill-*' }).Count -eq 0 -and $SuspendedIds.Contains(301)) 'target cleanup rechecks image and birth time before killing or resuming stale PIDs'
    $script:targetHandles[301].MainModule.FileName = $TargetExecutable
    $script:targetHandles[302].HasExited = $true
    $script:targetQueryCount = 0; $script:targetWaitFails = $true; $SuspendedIds.Clear()
    $failure = ''
    try { Stop-TargetProcesses 500 } catch { $failure = $_.Exception.Message }
    Check ($failure -ceq 'ASSERT:target-process-cleanup-exit-timeout' -and $targetEvents.Contains('dispose-301')) 'target wait failure fails cleanup and still releases its owned handle'
}
if (-not ('NativeInstallerProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class NativeInstallerProbe {
    public static bool State, Posted=true, Pending, ReadFails;
    public static int Reads, Clicks, ReadDelay, PendingReads;
    public static Dictionary<long,long> Parents=new Dictionary<long,long>();
    public static bool Checked(IntPtr h) {
        Reads++;
        if(ReadFails)throw new InvalidOperationException("synthetic-state-read-failed");
        if(Pending && PendingReads--<=0){State=!State;Pending=false;}
        return State;
    }
    public static bool Click(IntPtr h) { Clicks++;Pending=Posted;PendingReads=ReadDelay;return Posted; }
    public static bool IsChild(IntPtr parent, IntPtr child) { return Parents.ContainsKey(child.ToInt64()) && Parents[child.ToInt64()]==parent.ToInt64(); }
    public static int Resume(int pid) { return 0; }
}
'@
}
$box = [pscustomobject]@{ Id = 1203; Handle = [IntPtr]1203 }
foreach ($desired in @($false, $true)) {
    $script:LastRunCheckboxEvidence = New-Object Collections.ArrayList
    [NativeInstallerProbe]::State = -not $desired; [NativeInstallerProbe]::Pending = $false; [NativeInstallerProbe]::Posted = $true
    [NativeInstallerProbe]::Reads = 0; [NativeInstallerProbe]::Clicks = 0; [NativeInstallerProbe]::ReadDelay = 2
    Confirm-InstallerRunCheckbox $box $desired 500
    $savedBox = $LastRunCheckboxEvidence[0]
    Check ($savedBox.checkedBefore -eq (-not $desired) -and $savedBox.checkedAfter -eq $desired -and $savedBox.confirmed -and $savedBox.clickPosted -and [NativeInstallerProbe]::Reads -ge 4) ('run checkbox waits for asynchronous state confirmation: ' + $desired)
}
$script:LastRunCheckboxEvidence = New-Object Collections.ArrayList
[NativeInstallerProbe]::State = $false; [NativeInstallerProbe]::Pending = $false; [NativeInstallerProbe]::Clicks = 0
Confirm-InstallerRunCheckbox $box $false
Check ([NativeInstallerProbe]::Clicks -eq 0 -and $null -eq $LastRunCheckboxEvidence[0].clickPosted -and $LastRunCheckboxEvidence[0].confirmed) 'already-correct run checkbox is confirmed without toggling'
$ok = Invoke-Case 'rejected-checkbox-post' {
    $script:LastUiEvidence = @([ordered]@{ dialogText = 'sanitized-first-dialog' })
    $script:LastRunCheckboxEvidence = New-Object Collections.ArrayList
    [NativeInstallerProbe]::State = $true; [NativeInstallerProbe]::Posted = $false
    Confirm-InstallerRunCheckbox $box $false
    throw 'ASSERT:finish-must-not-run'
} 6>$null
$failedBoxCase = $Cases[-1]
$script:LastUiEvidence = @([ordered]@{ dialogText = 'later-dialog' })
Check (-not $ok -and $failedBoxCase.failureCode -ceq 'installer-run-checkbox-click-failed' -and -not $failedBoxCase.runCheckboxEvidence[0].confirmed) 'failed checkbox post blocks Finish and remains visible in its case'
Check ($failedBoxCase.uiEvidence[0].dialogText -ceq 'sanitized-first-dialog') 'case keeps its safe UI snapshot after later windows replace global evidence'
$ok = Invoke-Case 'failure-before-observing-ui' { throw 'ASSERT:pre-ui-failure' } 6>$null
Check (-not $ok -and $null -eq $Cases[-1].PSObject.Properties['uiEvidence']) 'failure before observing UI cannot inherit the previous case modal'
$ok = Invoke-Case 'unconfirmed-checkbox-state' {
    $script:LastRunCheckboxEvidence = New-Object Collections.ArrayList
    [NativeInstallerProbe]::State = $true; [NativeInstallerProbe]::Posted = $true; [NativeInstallerProbe]::Pending = $false; [NativeInstallerProbe]::ReadDelay = [int]::MaxValue
    Confirm-InstallerRunCheckbox $box $false 1
    throw 'ASSERT:finish-must-not-run'
} 6>$null
Check (-not $ok -and $Cases[-1].failureCode -ceq 'installer-run-checkbox-state-not-confirmed' -and $Cases[-1].runCheckboxEvidence[0].checkedAfter) 'unchanged asynchronous checkbox state fails before Finish'
$ok = Invoke-Case 'unreadable-checkbox-state' {
    $script:LastRunCheckboxEvidence = New-Object Collections.ArrayList
    [NativeInstallerProbe]::ReadFails = $true
    Confirm-InstallerRunCheckbox $box $false 1
    throw 'ASSERT:finish-must-not-run'
} 6>$null
[NativeInstallerProbe]::ReadFails = $false; [NativeInstallerProbe]::Pending = $false
Check (-not $ok -and -not $Cases[-1].runCheckboxEvidence[0].confirmed -and $null -eq $Cases[-1].runCheckboxEvidence[0].checkedBefore) 'unreadable checkbox state cannot be mistaken for unchecked'
$labelAssignment = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$Labels' }, $true)
$Labels = & ([scriptblock]::Create($labelAssignment.Right.Extent.Text))
$InstallDirectory = 'TEST_INSTALL'; $UserDataDirectory = 'USERDATA'; $TestRoot = 'FIXTURE_ROOT'
function New-ProbeWindow([int]$Handle, [int]$Id, [string]$Class, [string]$Text, [bool]$TopLevel, [bool]$Enabled, [int]$Parent = 0) {
    if ($Parent -ne 0) { [NativeInstallerProbe]::Parents[[long]$Handle] = [long]$Parent }
    return [pscustomobject]@{ Handle = [IntPtr]$Handle; Id = $Id; ClassName = $Class; Text = $Text; TopLevel = $TopLevel; Enabled = $Enabled; OwnerPid = 77; X = 0; Y = 0; Width = 100; Height = 100; ToolWindow = $false; ExtendedStyle = 0 }
}
function New-DialogFixture([string]$Body, [int[]]$Ids, [string]$Kind = '') {
    New-ProbeWindow 10 0 '#32770' 'Wizard' $true $false
    New-ProbeWindow 20 0 '#32770' 'Process dialog' $true $true
    New-ProbeWindow 2001 65535 'Static' $Body $false $true 20
    foreach ($id in $Ids) {
        $caption = switch ($id) { 1 { 'OK' }; 2 { 'Cancel' }; 6 { 'Yes' }; 7 { 'No' }; 4 { if ($Kind -eq 'force') { $Labels.retry } else { $Labels.normal } } }
        if ($Kind -ne '' -and $id -eq 6) { $caption = $Labels.force }
        if ($Kind -ne '' -and $id -eq 2) { $caption = $Labels.cancel }
        New-ProbeWindow (2010 + $id) $id 'Button' $caption $false $true 20
    }
}
$normalBody = [regex]::Unescape('\u8f6f\u4ef6\u6b63\u5728\u8fd0\u884c\uff0c\u8bf7\u5148\u5173\u95ed\u8f6f\u4ef6\u540e\u7ee7\u7eed\u3002\r\n\r\n\u786e\u5b9a\uff1a\u5173\u95ed\u8f6f\u4ef6\u5e76\u7ee7\u7eed\r\n\u53d6\u6d88\uff1a\u53d6\u6d88\u5b89\u88c5')
$forceBody = [regex]::Unescape('\u8f6f\u4ef6\u4ecd\u5728\u8fd0\u884c\u3002\u5f3a\u5236\u5173\u95ed\u53ef\u80fd\u4e22\u5931\u672a\u4fdd\u5b58\u7684\u5185\u5bb9\uff0c\u5e76\u4e2d\u65ad\u6b63\u5728\u8fdb\u884c\u7684\u4efb\u52a1\u3002\r\n\r\n\u662f\uff1a\u5f3a\u5236\u5173\u95ed\u5e76\u5347\u7ea7\r\n\u5426\uff1a\u91cd\u8bd5\u6b63\u5e38\u5173\u95ed\r\n\u53d6\u6d88\uff1a\u53d6\u6d88\u5b89\u88c5')
foreach ($body in @($normalBody, $normalBody.Replace("`r`n", "`n"))) {
    $windows = @(New-DialogFixture $body @(1, 2))
    $dialog = Get-ProcessDialogButtons $windows
    $ui = @(Get-UiEvidence $windows)
    Check ((Get-InstallerPageStage $windows) -ceq 'normal-close-prompt' -and $dialog.normal[0].Id -eq 1 -and $dialog.cancel[0].Id -eq 2 -and @($ui | Where-Object { $_.Contains('dialogText') -and -not $_.Contains('processDialogKind') }).Count -eq 0) 'exact normal MessageBox fallback maps OK to normal close for CRLF or LF'
}
$windows = @(New-DialogFixture $forceBody @(6, 7, 2))
$dialog = Get-ProcessDialogButtons $windows
Check ((Get-InstallerPageStage $windows) -ceq 'force-warning' -and $dialog.force[0].Id -eq 6 -and $dialog.retry[0].Id -eq 7 -and $dialog.cancel[0].Id -eq 2 -and (Test-VisibleLossWarning $windows)) 'exact force MessageBox fallback preserves loss warning and force/retry/cancel semantics'
foreach ($kind in @('normal', 'force')) {
    $ids = if ($kind -eq 'normal') { @(4, 2) } else { @(4, 6, 2) }
    $windows = @(New-DialogFixture 'TaskDialog body without an OK error button' $ids $kind)
    $dialog = Get-ProcessDialogButtons $windows
    $valid = if ($kind -eq 'normal') { $dialog.normal[0].Id -eq 4 } else { $dialog.force[0].Id -eq 6 -and $dialog.retry[0].Id -eq 4 }
    Check ($valid -and $null -eq (Get-ExpectedProcessFallback $windows)) ('custom TaskDialog action mapping remains unchanged: ' + $kind)
}
foreach ($item in @(
    @{ body = $normalBody + ' unexpected suffix'; ids = @(1, 2) },
    @{ body = 'Unknown asset error'; ids = @(1) },
    @{ body = $normalBody; ids = @(1, 2, 3) },
    @{ body = $normalBody; ids = @(1) }
)) {
    $windows = @(New-DialogFixture $item.body $item.ids)
    $ui = @(Get-UiEvidence $windows)
    Check ($null -eq (Get-ExpectedProcessFallback $windows) -and @($ui | Where-Object { $_.Contains('dialogText') -and -not $_.Contains('processDialogKind') }).Count -gt 0) 'unknown or malformed OK modal remains fatal instead of receiving blanket permission'
}
$windows = @(New-DialogFixture $normalBody @(1, 2))
[NativeInstallerProbe]::Parents[[long]2012] = 99
Check ($null -eq (Get-ExpectedProcessFallback $windows)) 'fallback buttons must belong to the same exact modal'
foreach ($item in @(
    @{ body = $normalBody; ids = @(1, 2, 6) },
    @{ body = $forceBody; ids = @(6, 4, 2) },
    @{ body = $forceBody.Replace($Labels.warning, ''); ids = @(6, 7, 2) }
)) {
    $windows = @(New-DialogFixture $item.body $item.ids)
    Check ($null -eq (Get-ExpectedProcessFallback $windows)) 'fallback requires its full loss warning and exact production button ID set'
}
$windows = @(New-DialogFixture $normalBody @(1, 2))
$windows += New-ProbeWindow 30 0 '#32770' 'Unknown error' $true $true
$windows += New-ProbeWindow 3001 65535 'Static' 'Unknown asset error' $false $true 30
$windows += New-ProbeWindow 3011 1 'Button' 'OK' $false $true 30
$ui = @(Get-UiEvidence $windows)
Check (@($ui | Where-Object { $_.Contains('processDialogKind') }).Count -eq 1 -and @($ui | Where-Object { $_.Contains('dialogText') -and -not $_.Contains('processDialogKind') }).Count -eq 1) 'known fallback cannot hide a separate unknown error modal'
function Stop-TargetProcesses { throw 'ASSERT:simulated-cim-cleanup-failure' }
$topTry = $ast.Find({ param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally -and $n.Finally.Extent.Text.Contains('$Report.completedAt') }, $true)
$cleanupText = $topTry.Finally.Extent.Text
$cleanupBlock = [scriptblock]::Create($cleanupText.Substring(1, $cleanupText.Length - 2))
$OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('aiwork-cleanup-report-check-' + [Guid]::NewGuid().ToString('N'))
$Utf8 = New-Object Text.UTF8Encoding($false)
$SuspendedIds = New-Object 'Collections.Generic.HashSet[int]'
$OwnedInstallerIds = New-Object 'Collections.Generic.HashSet[int]'
$OwnedInstallerIdentities = @{}
$OtherProcess = $null; $ChannelSwitch = $false; $SwitchChannel = $null
$StartedAt = [DateTime]::UtcNow; $FailureLine = $null; $ExpectedCaseCount = 1
$Cases = New-Object Collections.ArrayList
$Cases.Add([pscustomobject]@{ name = 'synthetic-passed-case'; status = 'passed'; elapsedSeconds = 0 }) | Out-Null
try {
    foreach ($Failure in @($null, 'original-main-failure')) {
        $Report = [ordered]@{ powershellVersion = 'fixture-no-native' }
        . $cleanupBlock
        $saved = Get-Content -LiteralPath (Join-Path $OutputDirectory 'report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Check ($saved.status -ceq 'failed' -and (Test-Path -LiteralPath (Join-Path $OutputDirectory 'report.txt'))) 'cleanup exception still writes failed JSON and text reports'
        Check ([string]$saved.failureCode -ceq [string]$Failure -and @($saved.cleanupFailures | Where-Object { $_.stage -ceq 'target-processes' -and $_.code -ceq 'simulated-cim-cleanup-failure' }).Count -eq 1) 'top cleanup records safe stage failure and preserves original failure'
        Check (-not $saved.lastInstallerExitEvidence.hasExited -and -not $saved.lastInstallerExitEvidence.exitCodePresent -and $null -eq $saved.lastInstallerExitEvidence.exitCode) 'final report preserves missing exit code without coercing it to zero'
    }
} finally { if (Test-Path -LiteralPath $OutputDirectory) { Remove-Item -LiteralPath $OutputDirectory -Recurse -Force } }
Write-Output 'No native Windows execution claimed.'
