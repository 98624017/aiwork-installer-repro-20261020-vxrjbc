# Run with Windows PowerShell 5.1 or pwsh; installer/process operations are isolated fixtures.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$driver = Join-Path $PSScriptRoot 'verify-windows-installer.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($driver, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'driver-parse-error' }
foreach ($name in @('Assert-True', 'Write-Json', 'Get-SafeFailureEvidence', 'Invoke-FixtureCase', 'Invoke-Case', 'Test-OwnedInstallerIdentity', 'Test-OwnedInstallerParent', 'Stop-OwnedInstallerProcesses', 'Get-InstallerProcesses', 'Invoke-HarnessCleanup')) {
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($null -ne $fn) { . ([scriptblock]::Create($fn.Extent.Text)) }
}
$FixtureExecutable = 'FIXTURE.exe'; $TargetExecutable = 'TEST_INSTALL/ai-canvas.exe'; $BackupExecutable = 'PROTECTED_BACKUP.exe'
$ExpectedInstalled = @{ exe = ('a' * 64); asar = 'asar'; helper = 'helper' }; $Candidate = @{}
$GracefulFixtureDelayMilliseconds = 6000
$Cases = New-Object Collections.ArrayList
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
if (-not ('NativeInstallerProbe' -as [type])) { Add-Type -TypeDefinition 'public static class NativeInstallerProbe { public static int Resume(int pid) { return 0; } }' }
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
    }
} finally { if (Test-Path -LiteralPath $OutputDirectory) { Remove-Item -LiteralPath $OutputDirectory -Recurse -Force } }
Write-Output 'No native Windows execution claimed.'
