Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (!('Gojira.FileLinks' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Gojira {
    public static class FileLinks {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Modified;
            public uint VolumeSerial, SizeHigh, SizeLow, LinkCount, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation info);
        public static uint Count(SafeFileHandle file) {
            FileInformation info;
            if (!GetFileInformationByHandle(file, out info)) throw new Win32Exception();
            return info.LinkCount;
        }
    }
}
'@
}

function Get-GojiraPath([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')) {
        throw "A fully qualified local path is required: $Path"
    }
    [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
}

function Test-GojiraWithin([string]$Path, [string]$Root) {
    $prefix = $Root.TrimEnd('\')
    $Path.Equals($prefix, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($prefix + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-GojiraPlain([string]$Path) {
    $cursor = $Path
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point in path: $cursor"
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function Get-GojiraEntry([string]$Path) {
    Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Assert-GojiraSource([string]$Path) {
    $root = [IO.Path]::GetPathRoot($Path)
    $parent = [IO.Path]::GetDirectoryName($Path)
    if ($Path -eq $root -or $parent -eq $root) { throw "Select an individual app below a dedicated parent directory." }
    $excludedTrees = @($env:windir, $env:ProgramData, "$env:ProgramFiles\WindowsApps",
        "$env:ProgramFiles\Common Files", "${env:ProgramFiles(x86)}\Common Files")
    $excludedRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:USERPROFILE,
        $env:LOCALAPPDATA, $env:APPDATA, "$env:USERPROFILE\AppData", "$env:SystemDrive\Users",
        "$env:PUBLIC", [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('DesktopDirectory'))
    foreach ($tree in $excludedTrees) {
        if ($tree -and ((Test-GojiraWithin $Path $tree) -or (Test-GojiraWithin $tree $Path))) {
            throw "Protected directory: $Path"
        }
    }
    foreach ($protected in $excludedRoots) {
        if ($protected -and (Test-GojiraWithin $protected $Path)) { throw "Shared directory: $Path" }
    }
}

function Get-GojiraVolume([string]$Path, [switch]$Fixture) {
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path))
    if (!$drive.IsReady -or $drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -ne 'NTFS') {
        throw "A ready fixed NTFS volume is required: $Path"
    }
    $id = @(& "$env:windir\System32\mountvol.exe" $drive.Name /L 2>$null |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\\\\\?\\Volume\{' })
    if ($id.Count -ne 1) { throw "Cannot verify volume identity for $($drive.Name)." }
    $partition = $null
    if (!$Fixture) {
        $partition = Get-Partition -DriveLetter $drive.Name[0]
        $disk = Get-Disk -Number $partition.DiskNumber
        if ($disk.HealthStatus -ne 'Healthy' -or $disk.IsOffline -or $disk.IsReadOnly) {
            throw "Disk for $($drive.Name) must be healthy, online and writable."
        }
    }
    [pscustomobject]@{ Id=$id[0]; Free=$drive.AvailableFreeSpace; Disk=$(if ($partition) { $partition.DiskNumber }) }
}

function Assert-GojiraIdle([string[]]$Paths) {
    foreach ($process in Get-Process) {
        $path = $null
        try { $path = $process.Path } catch {}
        foreach ($root in $Paths) {
            if ($path -and (Test-GojiraWithin $path $root)) {
                throw "Close $($process.ProcessName) (PID $($process.Id)) before proceeding."
            }
        }
    }
}

function Get-GojiraManifest([string]$Root, [switch]$WithoutAudit) {
    Assert-GojiraPlain $Root
    if (![IO.Directory]::Exists($Root)) { throw "Missing directory: $Root" }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    $records = [Collections.Generic.List[object]]::new()
    $bytes = 0L
    while ($pending.Count) {
        $path = $pending.Pop()
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band ([IO.FileAttributes]'ReparsePoint,Encrypted,Compressed,SparseFile,Offline')) {
            throw "Unsupported reparse point or storage attributes: $path"
        }
        if (@(Get-Item -LiteralPath $path -Force -Stream '*' | Where-Object Stream -ne ':$DATA').Count) {
            throw "Named NTFS stream detected: $path"
        }
        $acl = Get-Acl -LiteralPath $path -Audit:(!$WithoutAudit)
        $security = $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
        $relative = [IO.Path]::GetRelativePath($Root, $path)
        $hash = ''
        $length = 0L
        if ($item.PSIsContainer) {
            foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($path)) { $pending.Push($child) }
        } else {
            $stream = [IO.File]::Open($path, 'Open', 'Read', 'None')
            try {
                if ([Gojira.FileLinks]::Count($stream.SafeFileHandle) -ne 1) { throw "Hard-linked file: $path" }
                $length = $stream.Length
                $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))
            } finally { $stream.Dispose() }
            $bytes += $length
        }
        $records.Add([pscustomobject]@{ Path=$relative; Directory=$item.PSIsContainer; Bytes=$length; Hash=$hash;
            Attributes=[int]$item.Attributes; Created=$item.CreationTimeUtc.Ticks;
            Modified=$item.LastWriteTimeUtc.Ticks; Security=$security })
    }
    $json = ConvertTo-Json -InputObject @($records.ToArray() | Sort-Object Path -CaseSensitive) -Compress
    [pscustomobject]@{ Bytes=$bytes; Count=$records.Count;
        Digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))) }
}

function Copy-GojiraTree($Source, $Destination, $Log, [switch]$Fixture) {
    if (Get-GojiraEntry $Destination) { throw "Destination already exists: $Destination" }
    Assert-GojiraPlain $Destination
    $copy = if ($Fixture) { '/COPY:DATS' } else { '/COPYALL' }
    & "$env:windir\System32\robocopy.exe" $Source $Destination /E $copy /DCOPY:DATE /XJ /SL /R:0 /W:0 /NP "/UNILOG+:$Log" | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Robocopy exited $LASTEXITCODE. See $Log" }
    $root = [IO.DirectoryInfo]::new($Source)
    [IO.Directory]::SetCreationTimeUtc($Destination,$root.CreationTimeUtc)
    [IO.Directory]::SetLastWriteTimeUtc($Destination,$root.LastWriteTimeUtc)
}

function Initialize-GojiraContainer($Transaction) {
    $container = [IO.Path]::GetDirectoryName($Transaction.Destination)
    Assert-GojiraPlain $container
    if (Get-GojiraEntry $container) { throw "Destination container already exists: $container" }
    $sourceParent = [IO.Path]::GetDirectoryName($Transaction.Source)
    $acl = Get-Acl -LiteralPath $sourceParent -Audit:(!$Transaction.Fixture)
    $acl.SetAccessRuleProtection($true, $true)
    if (!$Transaction.Fixture) { $acl.SetAuditRuleProtection($true, $true) }
    [IO.Directory]::CreateDirectory($container) | Out-Null
    Set-Acl -LiteralPath $container -AclObject $acl
}

function Write-GojiraState($Transaction, [string]$Stage, [string]$Journal) {
    $Transaction.Stage = $Stage
    $Transaction.UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $Transaction.Events = @($Transaction.Events) + @([pscustomobject]@{Stage=$Stage; At=$Transaction.UpdatedAt})
    $path = Join-Path $Journal "$($Transaction.Id).json"
    $temp = "$path.tmp"
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Transaction | ConvertTo-Json -Depth 8))
    $stream = [IO.File]::Open($temp, 'Create', 'Write', 'None')
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    [IO.File]::Move($temp, $path, $true)
    Write-Information "$($Transaction.Name) · $Stage" -Tags 'GojiraStatus'
}

function Confirm-GojiraJunction($Transaction) {
    $link = Get-GojiraEntry $Transaction.Source
    if (!$link -or $link.LinkType -ne 'Junction' -or !$link.Target -or
        (Get-GojiraPath ([string]$link.Target)) -ne $Transaction.Destination) {
        throw "The original path does not resolve to the recorded destination."
    }
    Assert-GojiraPlain $Transaction.Destination
    if (![IO.Directory]::Exists($Transaction.Destination)) { throw 'Recorded destination unavailable.' }
}

function Assert-GojiraSpace($Manifest, [long]$Available) {
    $required = $Manifest.Bytes + [math]::Max(64MB, $Manifest.Count * 64KB)
    if ($Available -lt $required) { throw "Insufficient space. Required with filesystem allowance: $required bytes." }
}

function New-GojiraPlan($Application, [string]$DestinationRoot, [switch]$Fixture, [switch]$DryRun) {
    if ($Application.Risk -notin 'Low','Moderate' -or !$Application.SizeComplete -or
        @($Application.Services).Count -or @($Application.Tasks).Count -or @($Application.Related).Count -or $Application.Source -eq 'AppX') {
        throw 'This application is not eligible for junction migration.'
    }
    $source = Get-GojiraPath $Application.Path
    Assert-GojiraSource $source
    Assert-GojiraPlain $source
    $root = Get-GojiraPath $DestinationRoot
    if ($root -ne [IO.Path]::GetPathRoot($root) -and !$Fixture) { throw 'Select a destination volume root.' }
    $from = Get-GojiraVolume $source -Fixture:$Fixture
    $to = Get-GojiraVolume $root -Fixture:$Fixture
    if (!$Fixture -and ($from.Id -eq $to.Id -or $from.Disk -eq $to.Disk)) {
        throw 'Select a destination on a different physical disk.'
    }
    $id = [guid]::NewGuid().ToString('N')
    $destination = Join-Path (Join-Path (Join-Path $root 'GojiraApps') $id) ([IO.Path]::GetFileName($source))
    Assert-GojiraPlain $destination
    if ((Test-GojiraWithin $destination $source) -or (Test-GojiraWithin $source $destination)) {
        throw 'Source and destination overlap.'
    }
    Assert-GojiraIdle @($source)
    $manifest = Get-GojiraManifest $source -WithoutAudit:($Fixture -or $DryRun)
    Assert-GojiraSpace $manifest $to.Free
    [pscustomobject]@{ Id=$id; Name=$Application.Name; Source=$source; Destination=$destination;
        Backup="$source.gojira-backup-$id"; Restore="$source.gojira-restore-$id"; Fixture=[bool]$Fixture;
        FromVolume=$from.Id; ToVolume=$to.Id; Bytes=$manifest.Bytes;
        RequiredBytes=($manifest.Bytes + [math]::Max(64MB, $manifest.Count * 64KB)); Digest=$manifest.Digest;
        Stage='Planned'; UpdatedAt=''; Events=@(); LaunchConfirmed=$false; BatchId='' }
}

function Enter-GojiraJournal([string]$Journal) {
    $path = Get-GojiraPath $Journal
    Assert-GojiraPlain $path
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $lockPath = Join-Path $path 'operation.lock'
    Assert-GojiraPlain $lockPath
    [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
}

function Invoke-GojiraMigration($Application, [string]$DestinationRoot, [string]$Journal,
    [switch]$DryRun, [switch]$Fixture, [ValidateSet('Copied','SourceRenamed','JunctionCreated')][string]$InterruptAfter,
    [ValidatePattern('^[0-9a-f]{32}$')][string]$BatchId) {
    if ($InterruptAfter -and !$Fixture) { throw 'Fault injection requires a dummy fixture.' }
    if ($DryRun) { return New-GojiraPlan $Application $DestinationRoot -Fixture:$Fixture -DryRun }
    $lock = Enter-GojiraJournal $Journal
    try {
        $tx = New-GojiraPlan $Application $DestinationRoot -Fixture:$Fixture
        $tx.BatchId = $BatchId
        Write-GojiraState $tx 'Copying' $Journal
        Initialize-GojiraContainer $tx
        Copy-GojiraTree $tx.Source $tx.Destination (Join-Path $Journal "$($tx.Id).log") -Fixture:$Fixture
        if ((Get-GojiraManifest $tx.Destination -WithoutAudit:$tx.Fixture).Digest -ne $tx.Digest) { throw 'Destination verification failed.' }
        Write-GojiraState $tx 'Copied' $Journal
        if ($InterruptAfter -eq 'Copied') { throw 'Simulated interruption after copy.' }
        Assert-GojiraIdle @($tx.Source, $tx.Destination)
        if ((Get-GojiraManifest $tx.Source -WithoutAudit:$tx.Fixture).Digest -ne $tx.Digest) { throw 'Source changed during copy.' }
        Write-GojiraState $tx 'Switching' $Journal
        [IO.Directory]::Move($tx.Source, $tx.Backup)
        if ($InterruptAfter -eq 'SourceRenamed') { throw 'Simulated interruption after source rename.' }
        try {
            if ((Get-GojiraManifest $tx.Backup -WithoutAudit:$tx.Fixture).Digest -ne $tx.Digest) { throw 'Source changed during switch.' }
            New-Item -Path $tx.Source -ItemType Junction -Target $tx.Destination | Out-Null
            if ($InterruptAfter -eq 'JunctionCreated') { throw 'Simulated interruption after junction creation.' }
            Confirm-GojiraJunction $tx
            if ((Get-GojiraManifest $tx.Destination -WithoutAudit:$tx.Fixture).Digest -ne $tx.Digest) { throw 'Destination changed during switch.' }
        } catch {
            if (!$InterruptAfter -and !(Get-GojiraEntry $tx.Source)) { [IO.Directory]::Move($tx.Backup, $tx.Source) }
            throw
        }
        Write-GojiraState $tx 'ActiveWithBackup' $Journal
        $tx
    } finally { $lock.Dispose() }
}

function Get-GojiraHistory([string]$Journal) {
    if (![IO.Directory]::Exists($Journal)) { return }
    Assert-GojiraPlain $Journal
    foreach ($file in Get-ChildItem -LiteralPath $Journal -Filter '*.json' -File) {
        Assert-GojiraPlain $file.FullName
        Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    }
}

function Invoke-GojiraRecovery([string]$Id, [string]$Journal,
    [ValidateSet('Rollback','ConfirmLaunch','Reclaim')][string]$Action = 'Rollback',
    [string]$Executable) {
    if ($Id -notmatch '^[0-9a-f]{32}$') { throw 'Invalid transaction ID.' }
    $lock = Enter-GojiraJournal $Journal
    try {
        $journalFile = Join-Path $Journal "$Id.json"
        Assert-GojiraPlain $journalFile
        $tx = Get-Content -LiteralPath $journalFile -Raw | ConvertFrom-Json
        if ($tx.Id -ne $Id -or $tx.Stage -in 'RolledBack','Abandoned') { throw 'Transaction is already closed or invalid.' }
        Assert-GojiraSource (Get-GojiraPath $tx.Source)
        $container = Split-Path $tx.Destination -Parent
        if ($tx.Backup -ne "$($tx.Source).gojira-backup-$Id" -or $tx.Restore -ne "$($tx.Source).gojira-restore-$Id" -or
            (Split-Path $tx.Destination -Leaf) -ne [IO.Path]::GetFileName($tx.Source) -or
            (Split-Path $container -Leaf) -ne $Id -or
            (Split-Path (Split-Path $container -Parent) -Leaf) -ne 'GojiraApps') { throw 'Invalid journal paths.' }
        if ((Get-GojiraVolume $tx.Source -Fixture:$tx.Fixture).Id -ne $tx.FromVolume -or
            (Get-GojiraVolume $tx.Destination -Fixture:$tx.Fixture).Id -ne $tx.ToVolume) { throw 'Recorded volume identity changed.' }
        Assert-GojiraPlain ([IO.Path]::GetDirectoryName($tx.Source))
        Assert-GojiraPlain $tx.Backup
        Assert-GojiraPlain $tx.Restore
        Assert-GojiraPlain $tx.Destination
        if ($Action -eq 'ConfirmLaunch') {
            if ($tx.Stage -ne 'ActiveWithBackup') { throw 'An active migration is required.' }
            Confirm-GojiraJunction $tx
            $path = Get-GojiraPath $Executable
            if (!(Test-GojiraWithin $path $tx.Source) -or [IO.Path]::GetExtension($path) -ne '.exe' -or
                ![IO.File]::Exists($path)) { throw 'Choose an executable within the original app directory.' }
            $tx.LaunchConfirmed = $true
            Write-GojiraState $tx $tx.Stage $Journal
            return $tx
        }
        Assert-GojiraIdle @($tx.Source, $tx.Destination, $tx.Backup)
        if ($Action -eq 'Reclaim') {
            if ($tx.Stage -notin 'ActiveWithBackup','Reclaiming' -or !$tx.LaunchConfirmed) {
                throw 'Verify app launch through the original path before reclaiming space.'
            }
            Confirm-GojiraJunction $tx
            $live = Get-GojiraManifest $tx.Destination -WithoutAudit:$tx.Fixture
            if ($tx.Stage -eq 'ActiveWithBackup' -and
                ((Get-GojiraManifest $tx.Backup -WithoutAudit:$tx.Fixture).Digest -ne $tx.Digest -or $live.Digest -ne $tx.Digest)) {
                throw 'App content changed since migration. Keep the backup or roll back to preserve current data.'
            }
            if ($live.Digest -ne $tx.Digest) { throw 'Destination verification failed.' }
            Write-GojiraState $tx 'Reclaiming' $Journal
            if (Get-GojiraEntry $tx.Backup) { [IO.Directory]::Delete($tx.Backup, $true) }
            Write-GojiraState $tx 'Reclaimed' $Journal
            return $tx
        }
        $source = Get-GojiraEntry $tx.Source
        if ($source -and $source.LinkType -ne 'Junction') {
            Assert-GojiraPlain $tx.Source
            if ($tx.Stage -in 'Copying','Copied','Switching' -and !(Get-GojiraEntry $tx.Backup)) {
                Write-GojiraState $tx 'Abandoned' $Journal
                return $tx
            }
            if ($tx.Stage -in 'Restoring','RestoringOriginal' -and !(Get-GojiraEntry $tx.Restore) -and
                (Get-GojiraManifest $tx.Source -WithoutAudit:$tx.Fixture).Digest -eq $tx.Digest) {
                Write-GojiraState $tx 'RolledBack' $Journal
                return $tx
            }
            throw 'An unexpected real directory already occupies the original path.'
        }
        if ($source) { Confirm-GojiraJunction $tx }
        if ($tx.Stage -eq 'Switching' -and !$source -and (Get-GojiraEntry $tx.Backup)) {
            if ((Get-GojiraManifest $tx.Backup -WithoutAudit:$tx.Fixture).Digest -eq $tx.Digest) {
                Write-GojiraState $tx 'RestoringOriginal' $Journal
            } else {
                throw 'Retained originals changed. Inspect the backup and destination before proceeding.'
            }
        }
        if ($tx.Stage -eq 'RestoringOriginal' -and !$source) {
            [IO.Directory]::Move($tx.Backup, $tx.Source)
            Write-GojiraState $tx 'RolledBack' $Journal
            return $tx
        }
        $current = Get-GojiraManifest $tx.Destination -WithoutAudit:$tx.Fixture
        $restore = $tx.Backup
        if ($tx.Stage -in 'Reclaimed','Reclaiming','Restoring' -or !(Get-GojiraEntry $restore) -or
            (Get-GojiraManifest $restore -WithoutAudit:$tx.Fixture).Digest -ne $current.Digest) {
            $restore = $tx.Restore
            if (!(Get-GojiraEntry $restore)) {
                Assert-GojiraSpace $current (Get-GojiraVolume $tx.Source -Fixture:$tx.Fixture).Free
                Write-GojiraState $tx 'PreparingRestore' $Journal
                Copy-GojiraTree $tx.Destination $restore (Join-Path $Journal "$Id.log") -Fixture:$tx.Fixture
            }
        }
        if ((Get-GojiraManifest $restore -WithoutAudit:$tx.Fixture).Digest -ne $current.Digest -or
            (Get-GojiraManifest $tx.Destination -WithoutAudit:$tx.Fixture).Digest -ne $current.Digest) {
            throw "Restore verification failed. Preserve $restore and the live destination for review."
        }
        $tx.Digest = $current.Digest
        Write-GojiraState $tx 'Restoring' $Journal
        if ($source) { [IO.Directory]::Delete($tx.Source, $false) }
        [IO.Directory]::Move($restore, $tx.Source)
        Write-GojiraState $tx 'RolledBack' $Journal
        $tx
    } finally { $lock.Dispose() }
}

Export-ModuleMember -Function Invoke-GojiraMigration, Invoke-GojiraRecovery, Get-GojiraHistory
