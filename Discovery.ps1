[CmdletBinding()]
param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$warnings = [Collections.Generic.List[string]]::new()
if (!('Gojira.FileAllocation' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Gojira {
    public static class FileAllocation {
        [StructLayout(LayoutKind.Sequential)]
        private struct StandardInfo {
            public long AllocationSize, EndOfFile;
            public uint NumberOfLinks;
            public byte DeletePending, Directory;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int informationClass,
            out StandardInfo info, uint size);
        public static long ExclusiveBytes(string path) {
            using (var file = CreateFile(path, 128, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
                if (file.IsInvalid) throw new Win32Exception();
                StandardInfo info;
                if (!GetFileInformationByHandleEx(file, 1, out info, (uint)Marshal.SizeOf(typeof(StandardInfo))))
                    throw new Win32Exception();
                return info.NumberOfLinks == 1 ? info.AllocationSize : 0;
            }
        }
    }
}
'@
}
function Read-Safely($Label, [scriptblock]$Query) {
    try { & $Query } catch { $warnings.Add("$Label - $($_.Exception.Message)") }
}
function Test-Within($Path, $Directory) {
    if (!$Path -or !$Directory) { return $false }
    $base = $Directory.TrimEnd('\')
    return $Path.Equals($base, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Get-AppPath($Entry) {
    $candidates = @($Entry.InstallLocation)
    if ($Entry.DisplayIcon) {
        $icon = [Environment]::ExpandEnvironmentVariables($Entry.DisplayIcon).Trim()
        $icon = ($icon -replace ',\s*-?\d+$','').Trim('"')
        if ([IO.Path]::IsPathFullyQualified($icon) -and [IO.File]::Exists($icon)) {
            $candidates += [IO.Path]::GetDirectoryName($icon)
        }
    }
    foreach ($candidate in $candidates) {
        if (!$candidate) { continue }
        $path = [Environment]::ExpandEnvironmentVariables($candidate).Trim().Trim('"')
        if ([IO.Path]::IsPathFullyQualified($path) -and [IO.Directory]::Exists($path)) {
            return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($path))
        }
    }
}
function Measure-App($Path) {
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    $result = [pscustomobject]@{ LogicalBytes = 0L; AllocatedBytes = 0L; Links = @(); Complete = $true }
    $links = [Collections.Generic.List[object]]::new()
    while ($pending.Count) {
        $directory = $pending.Pop()
        try {
            $item = Get-Item -LiteralPath $directory -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $links.Add([pscustomobject]@{Path=$item.FullName; Type=$item.LinkType; Target=$item.Target})
                $result.Complete = $false
                continue
            }
            foreach ($entry in [IO.DirectoryInfo]::new($directory).EnumerateFileSystemInfos()) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $link = Get-Item -LiteralPath $entry.FullName -Force
                    $links.Add([pscustomobject]@{Path=$link.FullName; Type=$link.LinkType; Target=$link.Target})
                    $result.Complete = $false
                } elseif ($entry -is [IO.DirectoryInfo]) {
                    $pending.Push($entry.FullName)
                } else {
                    $result.LogicalBytes += $entry.Length
                    try { $result.AllocatedBytes += [Gojira.FileAllocation]::ExclusiveBytes($entry.FullName) }
                    catch { $result.Complete = $false }
                }
            }
        } catch { $result.Complete = $false }
    }
    $result.Links = $links.ToArray()
    $result
}

$volumes = @([IO.DriveInfo]::GetDrives() | Where-Object IsReady | ForEach-Object {
    [pscustomobject]@{Root=$_.Name; Type="$($_.DriveType)"; Filesystem=$_.DriveFormat;
        TotalBytes=$_.TotalSize; FreeBytes=$_.AvailableFreeSpace}
})
$disks = @(Read-Safely 'Physical disks' { Get-Disk | Select-Object Number,FriendlyName,BusType,PartitionStyle,HealthStatus,OperationalStatus,Size })
$physical = @(Read-Safely 'Physical health' { Get-PhysicalDisk | Select-Object FriendlyName,MediaType,HealthStatus,OperationalStatus,Size })
$partitions = @(Read-Safely 'Partitions' { Get-Partition | Select-Object DiskNumber,PartitionNumber,DriveLetter,Type,Size })
$processes = @(Get-Process | ForEach-Object {
    try { if ($_.Path) { [pscustomobject]@{Name=$_.ProcessName; Path=$_.Path} } } catch {}
})
$serviceReadable = $false
$services = @(Read-Safely 'Services' {
    Get-CimInstance Win32_Service | Select-Object Name,PathName,State
})
$serviceReadable = $services.Count -gt 0
$tasks = @(Read-Safely 'Scheduled tasks' { Get-ScheduledTask | ForEach-Object {
    $task = $_
    foreach ($action in $task.Actions) {
        [pscustomobject]@{Name=$task.TaskPath + $task.TaskName; Execute=$action.Execute; Arguments=$action.Arguments}
    }
} })
$packages = @(Read-Safely 'AppX/MSIX packages' { Get-AppxPackage | Select-Object Name,Publisher,Version,InstallLocation,IsFramework,NonRemovable,IsPartOfSystem })
$registry = @(foreach ($key in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)) {
    $errorsFromKey = @()
    foreach ($subkey in Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue -ErrorVariable +errorsFromKey) {
        Read-Safely 'Uninstall entry' {
            $entry = Get-ItemProperty -LiteralPath $subkey.PSPath
            if ($entry.DisplayName) { $entry }
        }
    }
    if ($errorsFromKey.Count) { $warnings.Add("Incomplete uninstall registry view $key ($($errorsFromKey.Count) errors).") }
})
$roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")
$rootDirectories = @(foreach ($root in $roots) {
    if ($root -and [IO.Directory]::Exists($root)) {
        Read-Safely "Installation directory $root" { Get-ChildItem -LiteralPath $root -Directory -Force }
    }
})
$protected = @($env:windir, $env:ProgramData, "$env:ProgramFiles\WindowsApps",
    "$env:ProgramFiles\Common Files", "${env:ProgramFiles(x86)}\Common Files")
$raw = @(foreach ($entry in $registry) {
    [pscustomobject]@{Name=$entry.DisplayName; Publisher=$entry.Publisher; Version=$entry.DisplayVersion;
        Path=(Get-AppPath $entry); Kind='Registry'; System=[bool]($entry.SystemComponent -or $entry.ReleaseType);
        Msi=[bool]$entry.WindowsInstaller; DeclaredKiB=$entry.EstimatedSize; Evidence=$entry.PSChildName}
}
foreach ($package in $packages) {
    [pscustomobject]@{Name=$package.Name; Publisher=$package.Publisher; Version="$($package.Version)";
        Path=$package.InstallLocation; Kind='AppX'; System=[bool]($package.IsFramework -or $package.NonRemovable -or $package.IsPartOfSystem);
        Msi=$false; DeclaredKiB=$null; Evidence='AppX/MSIX registration'}
})
$registered = @($raw.Path | Where-Object { $_ })
$raw += @(foreach ($dir in $rootDirectories) {
    if (@($registered | Where-Object { (Test-Within $_ $dir.FullName) -or (Test-Within $dir.FullName $_) }).Count -eq 0) {
        [pscustomobject]@{Name=$dir.Name; Publisher=''; Version=''; Path=$dir.FullName; Kind='Directory';
            System=$false; Msi=$false; DeclaredKiB=$null; Evidence='Top-level installation directory'}
    }
})
$raw = @($raw | Sort-Object Name,Version,Path,Kind -Unique)
$measurements = @{}
$inventory = @(foreach ($app in $raw) {
    $path = $app.Path
    $risk = 'Moderate'
    $reason = 'Conventional desktop registration. Installer, updater and settings behavior require review.'
    $native = 'No supported relocation verified'
    $bounded = $path -and @($roots | Where-Object { $_ -and $_.TrimEnd('\') -eq $path.TrimEnd('\') }).Count -eq 0
    $matchesProcess = @($processes | Where-Object { Test-Within $_.Path $path } | ForEach-Object Name)
    $matchesService = @($services | Where-Object { $path -and $_.PathName -and $_.PathName.IndexOf($path+'\',[StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object Name)
    $matchesTask = @($tasks | Where-Object { $path -and ("$($_.Execute) $($_.Arguments)").IndexOf($path+'\',[StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object Name | Sort-Object -Unique)
    $related = @($raw | Where-Object { $bounded -and $_ -ne $app -and $_.Path -and ((Test-Within $_.Path $path) -or (Test-Within $path $_.Path)) } | ForEach-Object Name)
    $isProtected = @($protected | Where-Object { Test-Within $path $_ }).Count -gt 0
    if ($app.System -or $isProtected -and $app.Kind -ne 'AppX' -or
        $app.Name -match '(?i)\b(drivers?|redistributable|antivirus|defender|endpoint security|bitlocker|windows update|cumulative update|runtime|firmware|VPN|anti.cheat|PhysX|vanguard|codecs)\b|^Microsoft Windows\b') {
        $risk = 'Excluded'; $reason = 'System, shared component, driver or security indicator.'
    } elseif ($app.Kind -eq 'AppX') {
        $risk = 'High'; $reason = 'Package-managed installation. Windows controls relocation eligibility.'
        $native = 'Check Settings > Apps > Installed apps > Move'
    } elseif ($app.Name -match '^(Steam( Client)?|Battle\.net|Ubisoft Connect|Epic Games Launcher|EA app|Riot Client|GOG Galaxy)$') {
        $risk = 'High'; $reason = 'Game launcher manages separate libraries, updates and shared components.'
        if ($app.Name -like 'Steam*') { $native = 'Steam Settings > Storage > Move for games; see Steam Support for client relocation' }
    } elseif ($app.Name -match '(?i)\b(Office|Diagnostics Tool|Docker|Hyper-V|VirtualBox|VMware|Android Studio|Visual Studio (?!Code)|SQL Server|Thunderbolt|Lenovo Vantage|Service|Discord|GitHub Desktop)\b') {
        $risk = 'High'; $reason = 'Shared tooling, device integration, background services or complex servicing are likely.'
    } elseif (!$bounded -or $matchesService.Count -or $matchesTask.Count -or $related.Count) {
        $risk = 'High'; $reason = 'Unresolved or overlapping installation path, service or scheduled-task dependency.'
    } elseif ($app.Kind -eq 'Directory') {
        if ([IO.File]::Exists((Join-Path $path 'App\AppInfo\appinfo.ini')) -and $serviceReadable -and $tasks.Count) {
            $risk = 'Low'; $reason = 'PortableApps metadata is present. No service, task or overlapping install path was matched.'
            $native = 'Portable app folder; confirm settings stay within the folder'
        } else {
            $risk = 'High'; $reason = 'Unregistered directory. Standalone or portable status requires confirmation.'
        }
    } elseif ($app.Msi -or !$serviceReadable -or !$tasks.Count) {
        $risk = 'High'; $reason = 'Windows Installer registration or incomplete service/task visibility.'
    }
    $measurement = $null
    if ($bounded -and !$isProtected -and $app.Kind -ne 'AppX' -and [IO.Directory]::Exists($path)) {
        if (!$measurements.ContainsKey($path)) { $measurements[$path] = Measure-App $path }
        $measurement = $measurements[$path]
        if (!$measurement.Complete -and $risk -ne 'Excluded') {
            $risk = 'High'; $reason = 'Reparse point or unreadable installation content.'
        }
    }
    [pscustomobject]@{Name=$app.Name; Publisher=$app.Publisher; Version=$app.Version; Path=$path;
        Drive=$(if ($path) { [IO.Path]::GetPathRoot($path) }); Risk=$risk; Reason=$reason;
        LogicalBytes=$measurement.LogicalBytes; AllocatedBytes=$measurement.AllocatedBytes; SizeComplete=[bool]$measurement.Complete;
        DeclaredKiB=$app.DeclaredKiB; Source=$app.Kind; Evidence=$app.Evidence; NativeRelocation=$native;
        Processes=$matchesProcess; Services=$matchesService; Tasks=$matchesTask; Related=$related;
        Links=@($measurement.Links | Where-Object { $_ })}
})
$report = [pscustomobject]@{
    Host=[Environment]::MachineName; Timestamp=(Get-Date).ToString('o')
    Volumes=$volumes; Disks=$disks; PhysicalHealth=$physical; Partitions=$partitions
    MountPoints=@(& mountvol.exe 2>$null)
    ServicesObserved=$services.Count; TaskActionsObserved=$tasks.Count; ProcessPathsObserved=$processes.Count
    Warnings=@($warnings | Sort-Object -Unique); Applications=$inventory
}
if ($OutputDirectory) {
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'discovery.json') -Encoding utf8
    $inventory | Select-Object Name,Publisher,Version,Path,Drive,Risk,Reason,LogicalBytes,AllocatedBytes,SizeComplete,Source,NativeRelocation,
        @{n='Processes';e={$_.Processes -join '; '}},@{n='Services';e={$_.Services -join '; '}},
        @{n='Tasks';e={$_.Tasks -join '; '}},@{n='Related';e={$_.Related -join '; '}} |
        Export-Csv -LiteralPath (Join-Path $OutputDirectory 'applications.csv') -NoTypeInformation -Encoding utf8
} else { $report }
