#requires -Version 7.2
[CmdletBinding()]
param([string]$Parent=[IO.Path]::GetTempPath())
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'FolderVerification.psm1') -Force
$root = Join-Path (Resolve-Path -LiteralPath $Parent).ProviderPath ('gojira-folder-check-'+[guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'Original'
$target = Join-Path $root 'Moved'
$store = Join-Path $root 'Checks'
[void][IO.Directory]::CreateDirectory((Join-Path $source 'Empty folder'))
[void][IO.Directory]::CreateDirectory((Join-Path $target 'Empty folder'))
$originalFile=Join-Path $source 'test.txt'
$movedFile=Join-Path $target 'test.txt'
[IO.File]::WriteAllText($originalFile,'before')
Set-Content -LiteralPath $originalFile -Stream 'TestStream' -Value 'original extra data'
$before = Start-GojiraFolderCheck -Name Downloads -Path $source -Store $store
if ($before.Manifest.Files -ne 1) { throw 'Before-scan file count is incorrect.' }

function Assert-CheckFails([string]$Path,[string]$Expected) {
    try { [void](Test-GojiraFolderCheck -Name Downloads -CurrentPath $Path -Store $store) }
    catch {
        if ($_.Exception.Message -like "*$Expected*") { return }
        throw
    }
    throw "Expected move check to refuse: $Expected"
}
Assert-CheckFails $source 'original folder location'
Assert-CheckFails $target '1 missing'
[IO.File]::Copy($originalFile,$movedFile)
Set-Content -LiteralPath $movedFile -Stream 'TestStream' -Value 'changed extra data'
Assert-CheckFails $target '1 changed'
Set-Content -LiteralPath $movedFile -Stream 'TestStream' -Value 'original extra data'
[IO.File]::WriteAllText((Join-Path $target 'new.txt'),'new files can arrive after the move')
Import-Module (Join-Path $PSScriptRoot 'FolderVerification.psm1') -Force
$verified = Test-GojiraFolderCheck -Name Downloads -CurrentPath $target -Store $store
$saved = Get-GojiraFolderCheck -Name Downloads -Store $store
if (!$saved.VerifiedAt -or $verified.Destination -ne $target -or !$saved.SourceStillPresent -or $saved.Id -ne $before.Id) {
    throw 'The verification or persisted result is incomplete.'
}
'PASS: Saved checklist, unchanged location, missing file, altered stream, extra file, and final verification.'
