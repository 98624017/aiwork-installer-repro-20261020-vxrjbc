[CmdletBinding()]
param([ValidateSet('direct', 'current-user', 'all-users')][string]$Mode)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$utf8 = [Text.UTF8Encoding]::new($false)
$output = Join-Path $PWD 'lifecycle-evidence'
New-Item -ItemType Directory -Path $output | Out-Null
$manifest = Get-Content -LiteralPath './official-candidate.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$setup = (Resolve-Path -LiteralPath './payload/official-setup.exe').ProviderPath
$report = [ordered]@{
    mode = $Mode; status = 'failed'; image = $env:ImageOS; imageVersion = $env:ImageVersion
    powershell = [string]$PSVersionTable.PSVersion; setupSha256 = $null; stages = @(); errors = @()
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
    $child = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
    try {
        if (-not $child.WaitForExit(60000)) { $child.Kill(); throw 'installer-process-timeout' }
        if ($child.ExitCode -ne 0) { throw 'installer-process-nonzero-exit' }
        return $child.ExitCode
    } finally { $child.Dispose() }
}

try {
    $report.setupSha256 = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($report.setupSha256 -cne $manifest.candidate.sha256) { throw 'setup-hash-mismatch' }
    & ./scripts/debug-installer.ps1 -Mode $Mode -InstallerPath $setup -OutputDirectory $output
    $initial = Get-Content -LiteralPath (Join-Path $output ($Mode + '.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($initial.verdict -ne 'application-files-present' -or $initial.parent.exitCode -ne 0 -or $initial.timedOut) {
        throw 'fresh-install-failed'
    }
    $target = [string]$initial.files.directory
    $report.freshHashes = Test-Payload $target
    $report.stages += 'fresh-install-hashes-passed'

    $name = [IO.File]::ReadAllText((Join-Path $target 'channel-shortcut-name.txt'), [Text.Encoding]::Unicode).Trim()
    $folders = @(
        [Environment]::GetFolderPath('DesktopDirectory'), [Environment]::GetFolderPath('Programs'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('CommonPrograms')
    )
    $shell = New-Object -ComObject WScript.Shell
    $links = @()
    $ownedLinks = @()
    foreach ($folder in $folders) {
        $linkPath = Join-Path $folder ($name + '.lnk')
        if (-not (Test-Path -LiteralPath $linkPath -PathType Leaf)) { continue }
        $link = $shell.CreateShortcut($linkPath)
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
