#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$SourceParent = [IO.Path]::GetTempPath(),
    [string]$DestinationParent = $SourceParent,
    [string]$ResumeJournal,
    [switch]$PauseForWindowsRestart
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Engine.psm1') -Force

function Assert-Test($Condition,[string]$Description) {
    if (!$Condition) { throw "FAIL: $Description" }
    Write-Output "PASS: $Description"
}
function Assert-Fails([scriptblock]$Code,[string]$Pattern) {
    try { & $Code | Out-Null } catch {
        Assert-Test ($_.Exception.Message -match $Pattern) "Expected failure: $Pattern"
        return
    }
    throw "FAIL: Expected failure matching $Pattern"
}
function New-Fixture([string]$Name) {
    $source = Join-Path $sourceRoot $Name
    $nested = [IO.Directory]::CreateDirectory((Join-Path $source 'data'))
    [IO.File]::WriteAllText((Join-Path $nested 'settings.txt'),'version 1')
    [IO.File]::Copy((Join-Path $env:windir 'System32\hostname.exe'),(Join-Path $source 'demo.exe'))
    [IO.File]::SetAttributes((Join-Path $nested 'settings.txt'),[IO.FileAttributes]'Archive,Hidden')
    [pscustomobject]@{Name=$Name; Path=$source; Risk='Low'; SizeComplete=$true; Source='Fixture';
        Services=@(); Tasks=@(); Related=@()}
}
if ($ResumeJournal) {
    $entry = Get-GojiraHistory $ResumeJournal | Where-Object Name -eq 'restart' | Select-Object -First 1
    if (!$entry) { throw 'Missing restart fixture.' }
    $restored = Invoke-GojiraRecovery $entry.Id $ResumeJournal
    Assert-Test ($restored.Stage -eq 'RolledBack' -and
        [IO.File]::ReadAllText((Join-Path $restored.Source 'data\settings.txt')) -eq 'version 1') 'Recovered from persistent journal'
    return
}
$tag = 'gojira-fixture-' + [guid]::NewGuid().ToString('N')
$sourceRoot = [IO.Directory]::CreateDirectory((Join-Path $SourceParent $tag)).FullName
$destinationRoot = [IO.Directory]::CreateDirectory((Join-Path $DestinationParent "$tag-target")).FullName
$journal = Join-Path $sourceRoot 'journal'
Write-Output "Fixture source $sourceRoot"
Write-Output "Fixture destination $destinationRoot"

$app = New-Fixture 'normal'
$settingsPath = Join-Path $app.Path 'data\settings.txt'
$before = (Get-Acl -LiteralPath $settingsPath).Sddl
$plan = Invoke-GojiraMigration $app $destinationRoot $journal -DryRun -Fixture
Assert-Test ($plan.Bytes -gt 0 -and !(Test-Path -LiteralPath $journal) -and !(Test-Path -LiteralPath $plan.Destination)) 'Dry run writes nothing'
$tx = Invoke-GojiraMigration $app $destinationRoot $journal -Fixture
Assert-Test ((Get-Item -LiteralPath $app.Path).LinkType -eq 'Junction' -and
    [IO.File]::ReadAllText($settingsPath) -eq 'version 1' -and
    (Get-Acl -LiteralPath $settingsPath).Sddl -eq $before -and
    ([IO.File]::GetAttributes($settingsPath) -band [IO.FileAttributes]::Hidden)) 'Junction, bytes, ACL, ownership and attributes verified'
Assert-Fails { Invoke-GojiraRecovery $tx.Id $journal Reclaim } 'Verify app launch'
$restored = Invoke-GojiraRecovery $tx.Id $journal
Assert-Test ($restored.Stage -eq 'RolledBack' -and !(Get-Item -LiteralPath $app.Path).LinkType -and
    [IO.File]::ReadAllText($settingsPath) -eq 'version 1') 'Rollback restores original layout and data'

$guard = Get-Module Engine
Assert-Fails { & $guard { Assert-GojiraSpace ([pscustomobject]@{Bytes=80MB; Count=1}) 1MB } } 'Insufficient space'
$locked = New-Fixture 'locked'
$file = [IO.File]::Open((Join-Path $locked.Path 'data\settings.txt'),'Open','ReadWrite','None')
try {
    Assert-Fails { Invoke-GojiraMigration $locked $destinationRoot $journal -Fixture } 'another process|being used|sharing'
} finally { $file.Dispose() }
Assert-Test (!(Get-Item -LiteralPath $locked.Path).LinkType) 'Locked file leaves original intact'

$linked = New-Fixture 'linked'
New-Item -Path (Join-Path $linked.Path 'nested-link') -ItemType Junction -Target $locked.Path | Out-Null
Assert-Fails { Invoke-GojiraMigration $linked $destinationRoot $journal -Fixture } 'Reparse point|Unsupported reparse'
[IO.Directory]::Delete((Join-Path $linked.Path 'nested-link'),$false)

foreach ($checkpoint in 'Copied','SourceRenamed','JunctionCreated') {
    $app = New-Fixture $checkpoint
    Assert-Fails { Invoke-GojiraMigration $app $destinationRoot $journal -Fixture -InterruptAfter $checkpoint } 'Simulated interruption'
    $entry = Get-GojiraHistory $journal | Where-Object Name -eq $checkpoint
    $entry = Invoke-GojiraRecovery $entry.Id $journal
    Assert-Test ($entry.Stage -in 'Abandoned','RolledBack' -and !(Get-Item -LiteralPath $app.Path).LinkType -and
        [IO.File]::ReadAllText((Join-Path $app.Path 'data\settings.txt')) -eq 'version 1') "Recovered interruption at $checkpoint"
}

$app = New-Fixture 'reclaim'
$tx = Invoke-GojiraMigration $app $destinationRoot $journal -Fixture
& (Join-Path $app.Path 'demo.exe') | Out-Null
Assert-Test ($LASTEXITCODE -eq 0) 'Dummy executable launches through the original path'
$null = Invoke-GojiraRecovery $tx.Id $journal ConfirmLaunch (Join-Path $app.Path 'demo.exe')
$tx = Invoke-GojiraRecovery $tx.Id $journal Reclaim
Assert-Test ($tx.Stage -eq 'Reclaimed' -and !(Test-Path -LiteralPath $tx.Backup)) 'Explicit reclaim after launch attestation'
$stream = [IO.File]::Open((Join-Path $tx.Destination 'data\settings.txt'),'Open','Write','None')
try {
    $stream.SetLength(0)
    $stream.Write([Text.Encoding]::UTF8.GetBytes('version 2'))
} finally { $stream.Dispose() }
for ($attempt = 1; $attempt -le 8; $attempt++) {
    try { $null = Invoke-GojiraRecovery $tx.Id $journal; break }
    catch {
        if ($attempt -eq 8 -or $_.Exception.Message -notmatch 'another process|being used|sharing') { throw }
        Start-Sleep -Milliseconds 750
    }
}
Assert-Test ([IO.File]::ReadAllText((Join-Path $app.Path 'data\settings.txt')) -eq 'version 2') 'Rollback after reclaim preserves current app data'

$app = New-Fixture 'restart'
Assert-Fails { Invoke-GojiraMigration $app $destinationRoot $journal -Fixture -InterruptAfter SourceRenamed } 'Simulated interruption'
if ($PauseForWindowsRestart) {
    Write-Output "After restarting Windows: pwsh -NoProfile -File Test-Gojira.ps1 -ResumeJournal `"$journal`""
    return
}
& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $PSCommandPath -ResumeJournal $journal
if ($LASTEXITCODE) { throw 'A fresh PowerShell process could not recover the transaction.' }
Write-Output 'Fixture trees retained for inspection.'
