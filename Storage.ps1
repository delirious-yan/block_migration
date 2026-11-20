#requires -Version 7.2
[CmdletBinding(DefaultParameterSetName='Scan')]
param(
    [Parameter(ParameterSetName='Scan')][string]$AppDataRoot,
    [Parameter(ParameterSetName='Scan')][switch]$SkipPersonalFolders,
    [Parameter(ParameterSetName='Resolve',Mandatory)]
    [ValidateSet('Downloads','Desktop','Documents','Pictures','Music','Videos')][string]$ResolvePersonalFolder,
    [Parameter(ParameterSetName='Properties',Mandatory)][string]$ShowProperties,
    [Parameter(ParameterSetName='Properties')][IntPtr]$OwnerWindow = [IntPtr]::Zero
)
$ErrorActionPreference = 'Stop'
if (!('Gojira.StorageFolders' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
namespace Gojira {
    public static class StorageFolders {
        public sealed class Usage {
            public string Path;
            public long Bytes, Files, Skipped;
            public List<Usage> Children = new List<Usage>();
        }

        public static Usage Scan(string path, int detailDepth) {
            var usage = new Usage { Path = path };
            try {
                var root = new DirectoryInfo(path);
                if (Skip(root.Attributes)) {
                    usage.Skipped++;
                    return usage;
                }
                foreach (var item in root.EnumerateFileSystemInfos()) {
                    try {
                        var attributes = item.Attributes;
                        if (Skip(attributes)) {
                            usage.Skipped++;
                        } else if (item is DirectoryInfo) {
                            var child = Scan(item.FullName, detailDepth - 1);
                            usage.Bytes += child.Bytes;
                            usage.Files += child.Files;
                            usage.Skipped += child.Skipped;
                            if (detailDepth > 0) usage.Children.Add(child);
                        } else {
                            usage.Bytes += ((FileInfo)item).Length;
                            usage.Files++;
                        }
                    } catch (IOException) {
                        usage.Skipped++;
                    } catch (UnauthorizedAccessException) {
                        usage.Skipped++;
                    }
                }
            } catch (IOException) {
                usage.Skipped++;
            } catch (UnauthorizedAccessException) {
                usage.Skipped++;
            }
            return usage;
        }

        private static bool Skip(FileAttributes attributes) {
            const FileAttributes recallFlags = (FileAttributes)0x440000;
            return (attributes & (FileAttributes.ReparsePoint | FileAttributes.Offline | recallFlags)) != 0;
        }

        [DllImport("shell32.dll")]
        private static extern int SHGetKnownFolderPath(ref Guid folder, uint flags, IntPtr token, out IntPtr path);

        public static string KnownFolder(Guid folder) {
            IntPtr path;
            int status = SHGetKnownFolderPath(ref folder, 0x4000, IntPtr.Zero, out path);
            try { return status == 0 ? Marshal.PtrToStringUni(path) : null; }
            finally { if (path != IntPtr.Zero) Marshal.FreeCoTaskMem(path); }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct ShellInfo {
            public uint Size, Mask;
            public IntPtr Owner;
            public string Verb, File, Parameters, Directory;
            public int Show;
            public IntPtr Instance, Item;
            public string Class;
            public IntPtr ClassKey;
            public uint HotKey;
            public IntPtr Icon, Process;
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ShellExecuteEx(ref ShellInfo info);

        public static void ShowProperties(string path, IntPtr owner) {
            var info = new ShellInfo { Size = (uint)Marshal.SizeOf<ShellInfo>(), Mask = 0x0000000c,
                Owner = owner, Verb = "properties", File = path, Show = 1 };
            if (!ShellExecuteEx(ref info)) throw new Win32Exception();
        }
    }
}
'@
}

if ($PSCmdlet.ParameterSetName -eq 'Properties') {
    if (![IO.Directory]::Exists($ShowProperties)) { throw 'The folder is no longer available. Rescan Storage.' }
    [Gojira.StorageFolders]::ShowProperties($ShowProperties, $OwnerWindow)
    return
}

function New-StorageRow($Usage, $Area, $Name, $Action, $Guidance, $Kind) {
    [pscustomobject]@{Area=$Area; Name=$Name; Path=$Usage.Path; Bytes=$Usage.Bytes; Files=$Usage.Files;
        Skipped=$Usage.Skipped; Action=$Action; Guidance=$Guidance; Kind=$Kind}
}

$knownFolders = [ordered]@{
    Downloads='374DE290-123F-4565-9164-39C4925E467B'
    Desktop='B4BFCC3A-DB2C-424C-B029-7FE99A87C641'
    Documents='FDD39AD0-238F-46AF-ADB4-6C85480369C7'
    Pictures='33E28130-4E1E-4676-835A-98395C3BC3BB'
    Music='4BD8D571-6D19-48D3-BE97-422220080E43'
    Videos='18989B1D-99B5-455B-841C-AB7C74E4DDFC'
}
function Get-PersonalFolderLocations([string[]]$Names) {
    $syncRoots = @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)
    $syncRoots += @(Get-ChildItem -LiteralPath 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue |
        ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath -Name UserFolder -ErrorAction SilentlyContinue).UserFolder })
    foreach ($name in $Names) {
        $path = [Gojira.StorageFolders]::KnownFolder([guid]$knownFolders[$name])
        if (!$path -or ![IO.Directory]::Exists($path)) { continue }
        $synced = @($syncRoots | Where-Object { $_ -and ($path -eq $_ -or
            $path.StartsWith($_.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) }).Count -gt 0
        [pscustomobject]@{Name=$name;Path=$path;Synced=$synced}
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Resolve') {
    Get-PersonalFolderLocations @($ResolvePersonalFolder)
    return
}

$personal = @(if (!$SkipPersonalFolders) {
    foreach ($folder in Get-PersonalFolderLocations @($knownFolders.Keys)) {
        $usage = [Gojira.StorageFolders]::Scan($folder.Path, 0)
        if ($folder.Synced) {
            New-StorageRow $usage 'Personal folders' $folder.Name 'OneDrive guidance' 'Use OneDrive to change the sync location. Cloud placeholders are skipped.' 'OneDrive'
        } else {
            New-StorageRow $usage 'Personal folders' $folder.Name 'Folder properties' 'Use the Location tab in Windows to move this folder.' 'Location'
        }
    }
})

$appRoots = if ($AppDataRoot) {
    @{Local=(Join-Path $AppDataRoot 'Local'); Roaming=(Join-Path $AppDataRoot 'Roaming'); LocalLow=(Join-Path $AppDataRoot 'LocalLow')}
} else {
    @{Local=$env:LOCALAPPDATA; Roaming=$env:APPDATA;
        LocalLow=[Gojira.StorageFolders]::KnownFolder('A520A1A4-1780-4FF6-BD18-167343C5AF16')}
}
$rules = @{
    'Local\Google\Chrome'=@('Chrome cache policy','The browser policy redirects its disk cache. The profile contains separate settings and site data.','Chrome')
    'Local\Microsoft\Edge'=@('Edge cache policy','The browser policy redirects its disk cache. The profile contains separate settings and site data.','Edge')
    'Local\NVIDIA\DXCache'=@('NVIDIA guidance','Use the driver Shader Cache Size setting to control cache growth.','Nvidia')
    'Local\Temp'=@('Temporary files','Review the categories in Windows Storage before cleanup.','Temporary')
    'Local\Packages'=@('Installed apps settings','Windows manages these app data folders. Check Installed apps for eligible package moves.','Packages')
}
$roots = @(foreach ($area in 'Local','Roaming','LocalLow') {
    $path = $appRoots[$area]
    if (!$path -or ![IO.Directory]::Exists($path)) { continue }
    $usage = [Gojira.StorageFolders]::Scan($path, 2)
    [pscustomobject]@{Area=$area; Usage=$usage}
})
$folders = @(foreach ($root in $roots) {
    foreach ($entry in $root.Usage.Children) {
        $name = Split-Path -Leaf $entry.Path
        $relative = "$($root.Area)\$name"
        if ($rules.ContainsKey($relative)) {
            $action, $guidance, $kind = $rules[$relative]
        } else {
            $action, $guidance, $kind = 'Open folder', 'Check the app for a supported storage location or cleanup option.', 'Explore'
        }
        New-StorageRow $entry 'AppData' $relative $action $guidance $kind
        foreach ($child in $entry.Children) {
            $detail = "$relative\$(Split-Path -Leaf $child.Path)"
            if ($rules.ContainsKey($detail)) {
                $action, $guidance, $kind = $rules[$detail]
                New-StorageRow $child 'AppData' $detail $action $guidance $kind
            }
        }
    }
})
$entries = @($personal) + @($folders | Sort-Object Bytes -Descending)
[pscustomobject]@{Rows=$entries; AppDataRoots=@($roots | ForEach-Object {
        [pscustomobject]@{Name=$_.Area; Bytes=$_.Usage.Bytes; Skipped=$_.Usage.Skipped}
    })}
