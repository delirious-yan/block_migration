#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GojiraFolderCheckPath {
    param([ValidateSet('Downloads','Desktop','Documents','Pictures','Music','Videos')][string]$Name,
        [string]$Store)
    Join-Path $Store "$Name.json"
}

function Get-GojiraFolderCheck {
    param([string]$Name,[string]$Store)
    $file = Get-GojiraFolderCheckPath $Name $Store
    if ([IO.File]::Exists($file)) {
        Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    }
}

function Write-FolderCheck($Record,[string]$File,[string]$ExpectedId) {
    $directory = [IO.Path]::GetDirectoryName($File)
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ([guid]::NewGuid().ToString('N')+'.tmp')
    $lock = [IO.File]::Open("$File.lock",'OpenOrCreate','ReadWrite','None')
    try {
        if ($ExpectedId) {
            $saved = Get-GojiraFolderCheck $Record.Name $directory
            if (!$saved -or $saved.Id -ne $ExpectedId) {
                throw 'The checklist was replaced during verification. Run the current check again.'
            }
        }
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Record -Depth 8))
        [IO.File]::Move($temporary,$File,$true)
    } finally {
        [IO.File]::Delete($temporary)
        $lock.Dispose()
    }
}

function Get-FolderManifest([string]$Path) {
    $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
    if (![IO.Directory]::Exists($root)) { throw 'The folder is no longer available.' }
    $volume = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
    if ($volume.DriveType -ne 'Fixed' -or $volume.DriveFormat -ne 'NTFS') {
        throw 'Full folder verification requires a fixed NTFS drive.'
    }
    for ($ancestor = $root; $ancestor; $ancestor = [IO.Path]::GetDirectoryName($ancestor)) {
        if ([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Use a direct local folder for verification. A parent path is redirected.'
        }
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    $entries = [Collections.Generic.List[object]]::new()
    $bytes = 0L
    $files = 0L
    $excluded = [int][IO.FileAttributes]'ReparsePoint,Offline' -bor 0x440000
    while ($pending.Count) {
        $item = Get-Item -LiteralPath $pending.Pop() -Force
        if ([int]$item.Attributes -band $excluded) { throw 'The folder contains linked or offline items. A complete check is unavailable.' }
        $relative = [IO.Path]::GetRelativePath($root,$item.FullName)
        if ($item.PSIsContainer) {
            foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($item.FullName)) { $pending.Push($child) }
        } else { $files++ }
        # Windows can generate or rewrite this folder-level metadata when it redirects the folder.
        if ($relative -ieq 'desktop.ini' -and !$item.PSIsContainer -and
            ($item.Attributes -band [IO.FileAttributes]::System) -and ($item.Attributes -band [IO.FileAttributes]::Hidden)) {
            $files--
            continue
        }
        $streams = @(foreach ($entry in Get-Item -LiteralPath $item.FullName -Force -Stream '*' | Sort-Object Stream -CaseSensitive) {
            if ($item.PSIsContainer -and $entry.Stream -eq ':$DATA') { continue }
            $streamPath = if ($entry.Stream -eq ':$DATA') { $item.FullName } else { $item.FullName + ':' + $entry.Stream }
            $handle = [IO.File]::Open($streamPath, 'Open', 'Read', 'Read')
            try {
                $bytes += $handle.Length
                [pscustomobject]@{Name=$entry.Stream; Bytes=$handle.Length;
                    SHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($handle))}
            } finally { $handle.Dispose() }
        })
        $entries.Add([pscustomobject]@{Path=$relative; IsDirectory=[bool]$item.PSIsContainer; Streams=$streams})
    }
    [pscustomobject]@{Path=$root; Entries=$entries.ToArray(); Files=$files; Bytes=$bytes}
}

function Start-GojiraFolderCheck {
    param([string]$Name,[string]$Path,[string]$Store)
    $file = Get-GojiraFolderCheckPath $Name $Store
    $manifest = Get-FolderManifest $Path
    $record = [pscustomobject]@{Version=1; Id=[guid]::NewGuid().ToString('N'); Name=$Name;
        Source=$manifest.Path; CapturedAt=[DateTimeOffset]::UtcNow; Manifest=$manifest;
        VerifiedAt=$null; Destination=$null; SourceStillPresent=$null}
    Write-FolderCheck $record $file
    $record
}

function Test-GojiraFolderCheck {
    param([string]$Name,[string]$CurrentPath,[string]$Store)
    $file = Get-GojiraFolderCheckPath $Name $Store
    $record = Get-GojiraFolderCheck $Name $Store
    if (!$record -or $record.Version -ne 1 -or $record.Name -ne $Name) { throw 'Prepare a new move check first.' }
    if ($record.Source -eq [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($CurrentPath))) {
        throw 'Windows still reports the original folder location. Complete the move in Windows before verifying.'
    }
    $current = Get-FolderManifest $CurrentPath
    $byPath = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $current.Entries) { $byPath.Add($entry.Path,$entry) }
    $missing = 0
    $changed = 0
    foreach ($entry in $record.Manifest.Entries) {
        $actual = $null
        if (!$byPath.TryGetValue($entry.Path,[ref]$actual)) {
            $missing++
        } elseif ($entry.IsDirectory -ne $actual.IsDirectory -or
            (ConvertTo-Json -InputObject @($entry.Streams) -Compress) -cne
            (ConvertTo-Json -InputObject @($actual.Streams) -Compress)) {
            $changed++
        }
    }
    if ($missing -or $changed) {
        throw "Move check found $missing missing and $changed changed entries. The original checklist is available for a retry."
    }
    $record.VerifiedAt = [DateTimeOffset]::UtcNow
    $record.Destination = $current.Path
    $record.SourceStillPresent = [IO.Directory]::Exists($record.Source)
    Write-FolderCheck $record $file $record.Id
    $record
}

Export-ModuleMember -Function Get-GojiraFolderCheck,Start-GojiraFolderCheck,Test-GojiraFolderCheck
