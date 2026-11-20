#requires -Version 7.2
param([switch]$SmokeTest, [switch]$StorageSmokeTest)
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start Gojira with pwsh -STA -File Gojira.ps1.' }
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Import-Module (Join-Path $PSScriptRoot 'Engine.psm1') -Force
$journal = Join-Path $env:LOCALAPPDATA 'GojiraMigration\Journal'
$script:report = $null
$script:work = $null
$script:approvedPlan = $null
$script:scanCompleted = $false
$script:storageReport = $null
$script:storageScanCompleted = $false
$script:dark = $false
$queue = [Collections.Generic.List[object]]::new()
$form = [Windows.Forms.Form]@{Text='Gojira  |  Storage Management'; Width=1420; Height=850;
    MinimumSize=[Drawing.Size]::new(1000,650); StartPosition='CenterScreen'; Font=[Drawing.Font]::new('Segoe UI',10)}
$tabs = [Windows.Forms.TabControl]@{ Dock='Fill'; Padding=[Drawing.Point]::new(16,8) }
$status = [Windows.Forms.StatusStrip]::new()
$statusText = [Windows.Forms.ToolStripStatusLabel]@{Text='Ready'; Spring=$true; TextAlign='MiddleLeft'}
$progress = [Windows.Forms.ToolStripProgressBar]@{Visible=$false; Style='Marquee'}
[void]$status.Items.Add($statusText)
[void]$status.Items.Add($progress)
$form.Controls.Add($tabs)
$form.Controls.Add($status)

function New-Page($Title) {
    $page = [Windows.Forms.TabPage]@{Text=$Title; Padding=[Windows.Forms.Padding]::new(14)}
    [void]$tabs.TabPages.Add($page)
    $page
}
function New-Bar($Parent) {
    $bar = [Windows.Forms.FlowLayoutPanel]@{Dock='Top'; Height=47; WrapContents=$false; AutoScroll=$true}
    $Parent.Controls.Add($bar)
    $bar.BringToFront()
    $bar
}
function New-Button($Parent,$Title,[scriptblock]$Click) {
    $button = [Windows.Forms.Button]@{Text=$Title; AutoSize=$true; Height=34; FlatStyle='Flat';
        Margin=[Windows.Forms.Padding]::new(0,4,10,4)}
    $button.Add_Click({
        try { & $this.Tag } catch { Show-Error $_.Exception.Message }
    })
    $button.Tag = $Click
    $Parent.Controls.Add($button)
    $button
}
function New-Grid($Parent, $Columns, [switch]$Check) {
    $grid = [Windows.Forms.DataGridView]@{Dock='Fill'; AllowUserToAddRows=$false; AllowUserToDeleteRows=$false;
        AllowUserToResizeRows=$false; RowHeadersVisible=$false; BorderStyle='None'; ReadOnly=!$Check;
        SelectionMode='FullRowSelect'; MultiSelect=$true; AutoSizeColumnsMode='Fill'; EnableHeadersVisualStyles=$false}
    $grid.RowTemplate.Height = 30
    if ($Check) {
        $box = [Windows.Forms.DataGridViewCheckBoxColumn]@{Name='Selected'; HeaderText='Select';
            AutoSizeMode='None'; Width=62; SortMode='NotSortable'}
        [void]$grid.Columns.Add($box)
        $grid.Add_CurrentCellDirtyStateChanged({ if ($this.IsCurrentCellDirty) { [void]$this.CommitEdit('Commit') } })
    }
    foreach ($label in $Columns) {
        $column = [Windows.Forms.DataGridViewTextBoxColumn]@{Name=$label; HeaderText=$label;
            SortMode='Automatic'; ReadOnly=$true; MinimumWidth=70}
        [void]$grid.Columns.Add($column)
    }
    $Parent.Controls.Add($grid)
    $grid
}
function Add-Row($Grid,[object[]]$Values,$Tag) {
    $index = $Grid.Rows.Add($Values)
    $Grid.Rows[$index].Tag = $Tag
    $Grid.Rows[$index]
}
function Show-Error($Message) {
    [void][Windows.Forms.MessageBox]::Show($form, $Message, 'Gojira', 'OK', 'Warning')
}
function Confirm-Action($Message) {
    [Windows.Forms.MessageBox]::Show($form, $Message, 'Gojira', 'YesNo', 'Warning',
        [Windows.Forms.MessageBoxDefaultButton]::Button2) -eq 'Yes'
}
function Format-GiB($Bytes) { '{0:N2}' -f ($Bytes / 1GB) }
function New-Combo($Parent,$Width) {
    $combo = [Windows.Forms.ComboBox]@{Width=$Width; DropDownStyle='DropDownList';
        Margin=[Windows.Forms.Padding]::new(0,8,10,4)}
    $Parent.Controls.Add($combo)
    $combo
}
function Set-Choices($Combo,[object[]]$Values) {
    $previous = $Combo.SelectedItem
    $Combo.Items.Clear()
    foreach ($value in $Values) { [void]$Combo.Items.Add($value) }
    if ($Combo.Items.Contains($previous ?? '')) { $Combo.SelectedItem = $previous }
    elseif ($Combo.Items.Count) { $Combo.SelectedIndex = 0 }
}

$dashboard = New-Page 'Dashboard'
$driveGrid = New-Grid $dashboard @('Volume','Filesystem','Capacity GiB','Free GiB','Used','Disk','Health')
$dashBar = New-Bar $dashboard
[void](New-Button $dashBar 'Scan this PC' { Start-Scan })
$dashNote = [Windows.Forms.TextBox]@{Dock='Bottom'; Height=120; Multiline=$true; ReadOnly=$true; ScrollBars='Vertical'}
$dashboard.Controls.Add($dashNote)
$dashNote.BringToFront()

$storagePage = New-Page 'Storage'
$storageGrid = New-Grid $storagePage @('Folder','Area','GiB','Path','Action')
$storageGrid.MultiSelect = $false
$storageGrid.Columns['GiB'].ValueType = [double]
$storageGrid.Columns['Folder'].FillWeight = 135
$storageGrid.Columns['Path'].FillWeight = 240
$storageGrid.Columns['Action'].FillWeight = 150
$storageBar = New-Bar $storagePage
[void](New-Button $storageBar 'Scan storage' { Start-StorageScan })
$storageFilter = New-Combo $storageBar 160
Set-Choices $storageFilter @('All folders','Personal folders','AppData')
$storageQuery = [Windows.Forms.TextBox]@{Width=190; PlaceholderText='Find a folder'; Margin=[Windows.Forms.Padding]::new(0,8,10,4)}
$storageBar.Controls.Add($storageQuery)
$storageAction = New-Button $storageBar 'Open action' { Open-StorageAction }
$storageAction.Enabled = $false
[void](New-Button $storageBar 'Windows Storage' { Start-Process 'ms-settings:storagesense' })
[void](New-Button $storageBar 'New content locations' { Start-Process 'ms-settings:savelocations' })
$storageNote = [Windows.Forms.Label]@{Dock='Bottom'; Height=78; Padding=[Windows.Forms.Padding]::new(0,8,0,0);
    Text='Scan storage to see your personal folders and AppData usage.'}
$storagePage.Controls.Add($storageNote)
$storageNote.BringToFront()

$installed = New-Page 'Installed Applications'
$appGrid = New-Grid $installed @('Application','Publisher','Version','MiB','Path','Risk','Relocation') -Check
$appGrid.Columns['Path'].FillWeight = 220
$appGrid.Columns['Application'].FillWeight = 160
$appGrid.Columns['Relocation'].FillWeight = 140
$appGrid.Columns['MiB'].ValueType = [double]
$appBar = New-Bar $installed
$search = [Windows.Forms.TextBox]@{Width=220; PlaceholderText='Search applications'; Margin=[Windows.Forms.Padding]::new(0,8,10,4)}
$appBar.Controls.Add($search)
$sourceFilter = New-Combo $appBar 115
$riskFilter = New-Combo $appBar 110
$sizeFilter = New-Combo $appBar 125
Set-Choices $riskFilter @('Any risk','Low','Moderate','High','Excluded')
Set-Choices $sizeFilter @('Any size','100 MiB or more','1 GiB or more')
[void](New-Button $appBar 'Add checked to queue' { Add-Queue })
[void](New-Button $appBar 'App details' { Show-AppDetails })
[void](New-Button $appBar 'Windows app settings' { Start-Process 'ms-settings:appsfeatures' })

$queuePage = New-Page 'Migration Queue'
$queueGrid = New-Grid $queuePage @('Application','Original path','Risk','Estimated GiB')
$queueBar = New-Bar $queuePage
$destination = New-Combo $queueBar 155
[void](New-Button $queueBar 'Dry run' { Start-Batch $true })
[void](New-Button $queueBar 'Migrate selected queue' { Start-Batch $false })
[void](New-Button $queueBar 'Clear queue' { $queue.Clear(); Refresh-Queue })
$queueNote = [Windows.Forms.Label]@{Dock='Bottom'; Height=38}
$queuePage.Controls.Add($queueNote)
$queueNote.BringToFront()

$historyPage = New-Page 'Migration History'
$historyGrid = New-Grid $historyPage @('Application','Stage','Original path','Destination','Updated (UTC)','Transaction')
$historyBar = New-Bar $historyPage
[void](New-Button $historyBar 'Refresh history' { Refresh-History })
$recovery = New-Page 'Recovery and Rollback'
$recoveryGrid = New-Grid $recovery @('Application','Stage','Original path','Destination','Transaction')
$recoveryBar = New-Bar $recovery
[void](New-Button $recoveryBar 'Refresh' { Refresh-History })
[void](New-Button $recoveryBar 'Roll back selected' { Start-Recovery 'Rollback' })
[void](New-Button $recoveryBar 'Roll back batch' { Start-Recovery 'Rollback' -WholeBatch })
[void](New-Button $recoveryBar 'Verify launch' { Verify-Launch })
[void](New-Button $recoveryBar 'Reclaim original space' { Start-Recovery 'Reclaim' })

$settings = New-Page 'Settings and Logs'
$log = [Windows.Forms.TextBox]@{Dock='Fill'; Multiline=$true; ReadOnly=$true; ScrollBars='Both';
    Font=[Drawing.Font]::new('Consolas',10)}
$settings.Controls.Add($log)
$settingsBar = New-Bar $settings
[void](New-Button $settingsBar 'Toggle dark and light' { $script:dark = !$script:dark; Set-Theme $form })
[void](New-Button $settingsBar 'Open logs' {
    if (Test-Path -LiteralPath $journal) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $journal) }
    else { Show-Error 'Transaction logs appear after the first migration.' }
})
[void](New-Button $settingsBar 'Restart as administrator' {
    if ($script:work) { throw 'Wait for the current operation to finish.' }
    if (Test-Elevated) { throw 'Gojira already has administrator access.' }
    Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -Verb RunAs -ArgumentList (
        '-NoProfile -STA -File "{0}"' -f $PSCommandPath)
    $form.Close()
})

function Test-Elevated {
    $person = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $person.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Set-Theme($Control) {
    $background = [Drawing.Color]::FromArgb(245,247,252)
    $surface = [Drawing.Color]::White
    $foreground = [Drawing.Color]::FromArgb(28,36,52)
    if ($script:dark) {
        $background = [Drawing.Color]::FromArgb(28,32,43)
        $surface = [Drawing.Color]::FromArgb(38,44,58)
        $foreground = [Drawing.Color]::FromArgb(236,241,248)
    }
    $Control.BackColor = $background
    $Control.ForeColor = $foreground
    if ($Control -is [Windows.Forms.DataGridView]) {
        $Control.BackgroundColor = $background
        $Control.GridColor = $background
        $Control.DefaultCellStyle.BackColor = $surface
        $Control.DefaultCellStyle.ForeColor = $foreground
        $Control.ColumnHeadersDefaultCellStyle.BackColor = $background
        $Control.ColumnHeadersDefaultCellStyle.ForeColor = $foreground
        return
    }
    if ($Control -is [Windows.Forms.TextBox] -or $Control -is [Windows.Forms.ComboBox]) { $Control.BackColor = $surface }
    foreach ($child in $Control.Controls) { Set-Theme $child }
}
function Write-Log($Message) {
    $log.AppendText(("[$(Get-Date -Format 'HH:mm:ss')] $Message" + [Environment]::NewLine))
}
function Start-Work($Title,[scriptblock]$Code,[object[]]$Arguments,[scriptblock]$Complete,$Context) {
    if ($script:work) { throw 'Wait for the current operation to finish.' }
    $shell = [PowerShell]::Create()
    [void]$shell.AddScript('$InformationPreference = "Continue"', $false)
    [void]$shell.AddStatement()
    [void]$shell.AddScript($Code.ToString())
    foreach ($argument in $Arguments) { [void]$shell.AddArgument($argument) }
    $script:work = @{ Shell=$shell; Handle=$shell.BeginInvoke(); Complete=$Complete; Title=$Title; Context=$Context; Notices=0 }
    $statusText.Text = $Title
    $progress.Visible = $true
    Write-Log $Title
}
$timer = [Windows.Forms.Timer]@{Interval=250}
$timer.Add_Tick({
    if (!$script:work) { return }
    $information = $script:work.Shell.Streams.Information
    while ($script:work.Notices -lt $information.Count) {
        $notice = $information[$script:work.Notices]
        $script:work.Notices++
        if ($notice.Tags -contains 'GojiraStatus') {
            $statusText.Text = $notice.MessageData
            Write-Log $notice.MessageData
        }
    }
    if (!$script:work.Handle.IsCompleted) { return }
    $state = $script:work
    $script:work = $null
    $progress.Visible = $false
    try {
        $results = $state.Shell.EndInvoke($state.Handle)
        if ($state.Shell.HadErrors) { throw ($state.Shell.Streams.Error -join [Environment]::NewLine) }
        & $state.Complete $results $state.Context
        $statusText.Text = 'Ready'
    } catch {
        $statusText.Text = 'Operation requires review'
        Write-Log $_.Exception.Message
        if ($SmokeTest -or $StorageSmokeTest) { $script:scanFailure = $_.Exception.Message; $form.Close() }
        else { Show-Error $_.Exception.Message; Refresh-History }
    } finally { $state.Shell.Dispose() }
})

function Start-StorageScan {
    Start-Work 'Measuring personal folders and AppData' { param($scriptPath) & $scriptPath } @(
        (Join-Path $PSScriptRoot 'Storage.ps1')
    ) {
        param($result)
        $script:storageReport = $result[0]
        Refresh-Storage
        if ($StorageSmokeTest) {
            $personalRows = @($storageGrid.Rows | Where-Object { $_.Tag.Area -eq 'Personal folders' })
            $appRows = @($storageGrid.Rows | Where-Object { $_.Tag.Area -eq 'AppData' })
            if (!$personalRows.Count -or !$appRows.Count -or !$script:storageReport.AppDataRoots.Count) {
                throw 'The Storage tab did not render personal folders, AppData rows and totals.'
            }
            $storageFilter.SelectedItem = 'AppData'
            if ($storageGrid.Rows.Count -ne $appRows.Count) { throw 'The AppData filter did not select the expected rows.' }
            $storageFilter.SelectedItem = 'Personal folders'
            if ($storageGrid.Rows.Count -ne $personalRows.Count) { throw 'The personal-folders filter did not select the expected rows.' }
        }
        $script:storageScanCompleted = $true
        if ($StorageSmokeTest) { $form.Close() }
    }
}

function Refresh-Storage {
    if (!$script:storageReport) { return }
    $storageGrid.Rows.Clear()
    foreach ($row in $script:storageReport.Rows) {
        if ($storageFilter.SelectedIndex -gt 0 -and $row.Area -ne $storageFilter.SelectedItem) { continue }
        if ($storageQuery.Text -and $row.Name.IndexOf($storageQuery.Text,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $size = if (!$row.Skipped -or $row.Files) { [math]::Round($row.Bytes / 1GB, 2) }
        [void](Add-Row $storageGrid @($row.Name,$row.Area,$size,$row.Path,$row.Action) $row)
    }
    Update-StorageSelection
}

function Update-StorageSelection {
    if (!$script:storageReport) { return }
    $row = $storageGrid.CurrentRow.Tag
    $storageAction.Enabled = $null -ne $row
    $storageAction.Text = if ($row) { $row.Action } else { 'Open action' }
    $roots = $script:storageReport.AppDataRoots
    $used = Format-GiB ($roots | Measure-Object Bytes -Sum).Sum
    $breakdown = ($roots | ForEach-Object { "$($_.Name) $(Format-GiB $_.Bytes) GiB" }) -join '  ·  '
    $line = "AppData visible file sizes: $used GiB   ·   $breakdown"
    $detail = if ($row) { $row.Guidance } else { 'Select a folder to see its available action.' }
    if ($row -and $row.Skipped) { $detail += "  $($row.Skipped) linked, offline, or unreadable items skipped." }
    $storageNote.Text = $line + [Environment]::NewLine + $detail
}

function Open-StorageAction {
    $row = $storageGrid.CurrentRow.Tag
    if (!$row) { return }
    switch ($row.Kind) {
        'Location' {
            & (Join-Path $PSScriptRoot 'Storage.ps1') -ShowProperties $row.Path -OwnerWindow $form.Handle
        }
        'OneDrive' { Start-Process 'https://support.microsoft.com/en-gb/onedrive/change-the-location-of-your-onedrive-folder?nochrome=true' }
        'Chrome' { Start-Process 'https://chromeenterprise.google/policies/#DiskCacheDir' }
        'Edge' { Start-Process 'https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/diskcachedir' }
        'Nvidia' { Start-Process 'https://www.nvidia.com/content/Control-Panel-Help/vLatest/en-us/mergedProjects/nv3d/Manage_3D_Settings_%28reference%29.htm#Shader_Cache_Size' }
        'Temporary' { Start-Process 'ms-settings:storagesense' }
        'Packages' { Start-Process 'ms-settings:appsfeatures' }
        'Explore' {
            if (![IO.Directory]::Exists($row.Path)) { throw 'The folder is no longer available. Rescan Storage.' }
            $open = [Diagnostics.ProcessStartInfo]@{FileName=$row.Path; UseShellExecute=$true}
            [void][Diagnostics.Process]::Start($open)
        }
    }
}

function Start-Scan {
    Start-Work 'Scanning installed applications and drives' { param($scriptPath) $ErrorActionPreference='Stop'; & $scriptPath } @(
        (Join-Path $PSScriptRoot 'Discovery.ps1')
    ) {
        param($result)
        $script:report = $result[0]
        $driveGrid.Rows.Clear()
        foreach ($volume in $script:report.Volumes) {
            $partition = @($script:report.Partitions | Where-Object { $_.DriveLetter -eq $volume.Root[0] }) | Select-Object -First 1
            $disk = if ($partition) { $script:report.Disks | Where-Object Number -eq $partition.DiskNumber | Select-Object -First 1 }
            [void](Add-Row $driveGrid @($volume.Root,$volume.Filesystem,(Format-GiB $volume.TotalBytes),
                (Format-GiB $volume.FreeBytes),('{0:P0}' -f (1-$volume.FreeBytes/$volume.TotalBytes)),
                ${disk}?.FriendlyName, ${disk}?.HealthStatus) $volume)
        }
        Set-Choices $sourceFilter (@('Any drive') + @($script:report.Volumes.Root))
        Set-Choices $destination (@('Destination drive') + @($script:report.Volumes | Where-Object {
            $_.Type -eq 'Fixed' -and $_.Filesystem -eq 'NTFS'
        } | ForEach-Object Root))
        $dashNote.Text = "$($script:report.Applications.Count) inventory rows. " +
            "$($script:report.ServicesObserved) services and $($script:report.TaskActionsObserved) task actions observed." +
            [Environment]::NewLine + ($script:report.Warnings -join [Environment]::NewLine)
        Refresh-Apps
        Refresh-History
        $script:scanCompleted = $true
        if ($SmokeTest) { $form.Close() }
    }
}
function Refresh-Apps {
    if (!$script:report) { return }
    $history = @(Get-GojiraHistory $journal)
    $checked = @($appGrid.Rows | Where-Object { $_.Cells[0].Value } | ForEach-Object Tag)
    $appGrid.Rows.Clear()
    foreach ($app in $script:report.Applications) {
        if ($search.Text -and "$($app.Name) $($app.Publisher) $($app.Path)" -notlike ('*' + [WildcardPattern]::Escape($search.Text) + '*')) { continue }
        if ($sourceFilter.SelectedIndex -gt 0 -and $app.Drive -ne $sourceFilter.SelectedItem) { continue }
        if ($riskFilter.SelectedIndex -gt 0 -and $app.Risk -ne $riskFilter.SelectedItem) { continue }
        if ($sizeFilter.SelectedIndex -eq 1 -and $app.LogicalBytes -lt 100MB) { continue }
        if ($sizeFilter.SelectedIndex -eq 2 -and $app.LogicalBytes -lt 1GB) { continue }
        $prior = @($history | Where-Object { $_.Source -eq $app.Path -and $_.Stage -notin 'RolledBack','Abandoned' })
        $risk = if ($prior.Count) { 'Migrated / pending' } else { $app.Risk }
        $size = if ($app.SizeComplete) { [math]::Round($app.LogicalBytes / 1MB,2) }
        $row = Add-Row $appGrid @(($app -in $checked),$app.Name,$app.Publisher,$app.Version,$size,$app.Path,$risk,$app.NativeRelocation) $app
        $row.Cells['Risk'].ToolTipText = $app.Reason
        $row.Cells['Risk'].Style.ForeColor = switch ($app.Risk) {
            'Low' { if ($script:dark) { [Drawing.Color]::LightGreen } else { [Drawing.Color]::DarkGreen } }
            'Moderate' { if ($script:dark) { [Drawing.Color]::Khaki } else { [Drawing.Color]::DarkGoldenrod } }
            'High' { if ($script:dark) { [Drawing.Color]::LightSalmon } else { [Drawing.Color]::Firebrick } }
            default { [Drawing.Color]::Empty }
        }
    }
}
function Show-AppDetails {
    $app = $appGrid.CurrentRow.Tag
    if (!$app) { return }
    $details = @($app.Name, $app.Path, "$($app.Risk) — $($app.Reason)", $app.NativeRelocation,
        "Estimated reclaimable allocation: $(Format-GiB $app.AllocatedBytes) GiB",
        "Running processes: $($app.Processes -join ', ')", "Services: $($app.Services -join ', ')",
        "Tasks: $($app.Tasks -join ', ')", "Overlaps: $($app.Related -join ', ')",
        "Reparse points: $(@($app.Links).Count)")
    [void][Windows.Forms.MessageBox]::Show($form, ($details -join [Environment]::NewLine), 'Application details')
}
function Add-Queue {
    foreach ($row in $appGrid.Rows) {
        if (!$row.Cells[0].Value) { continue }
        $app = $row.Tag
        if ($row.Cells['Risk'].Value -notin 'Low','Moderate' -or !$app.SizeComplete) {
            Write-Log "Skipped $($app.Name): $($app.Reason)"
        } elseif (!@($queue | Where-Object Path -eq $app.Path).Count) { $queue.Add($app) }
    }
    Refresh-Queue
    $tabs.SelectedTab = $queuePage
}
function Refresh-Queue {
    $queueGrid.Rows.Clear()
    foreach ($app in $queue) {
        [void](Add-Row $queueGrid @($app.Name,$app.Path,$app.Risk,(Format-GiB $app.AllocatedBytes)) $app)
    }
    $total = ($queue | Measure-Object AllocatedBytes -Sum).Sum
    $queueNote.Text = "$($queue.Count) queued   ·   $(Format-GiB $total) GiB estimated recoverable after backup cleanup"
}
function Start-Batch([bool]$DryRun) {
    if (!$queue.Count -or $destination.SelectedIndex -lt 1) { throw 'Queue applications and select a destination drive first.' }
    if (!$DryRun -and !(Test-Elevated)) { throw 'Migration needs administrator access to preserve ownership and auditing. Use Settings and Logs to restart as administrator.' }
    if (!$DryRun -and !($script:approvedPlan -and $script:approvedPlan -eq (Get-QueueKey))) {
        throw 'Run a successful dry run for this queue and destination first.'
    }
    if (!$DryRun -and !(Confirm-Action "Approve migration of the $($queue.Count) queued app(s) to $($destination.SelectedItem)? Originals will be retained until you explicitly reclaim space.")) { return }
    $title = if ($DryRun) { 'Validating queue · dry run' } else { 'Copying and verifying application data' }
    $planKey = Get-QueueKey
    Start-Work $title {
        param($root,$apps,$target,$journalPath,$dry)
        $ErrorActionPreference = 'Stop'
        Import-Module (Join-Path $root 'Engine.psm1') -Force
        $fresh = & (Join-Path $root 'Discovery.ps1')
        $candidates = @(foreach ($app in $apps) {
            $matches = @($fresh.Applications | Where-Object { $_.Path -eq $app.Path -and $_.Name -eq $app.Name })
            if ($matches.Count -ne 1) { throw "Inventory changed for $($app.Name). Refresh and rebuild the queue." }
            $matches[0]
        })
        $plans = @(foreach ($app in $candidates) { Invoke-GojiraMigration $app $target $journalPath -DryRun })
        $sum = ($plans | Measure-Object RequiredBytes -Sum).Sum
        if ($sum -gt [IO.DriveInfo]::new($target).AvailableFreeSpace) { throw 'Combined queue exceeds destination capacity.' }
        if ($dry) { return $plans }
        $batch = [guid]::NewGuid().ToString('N')
        foreach ($app in $candidates) { Invoke-GojiraMigration $app $target $journalPath -BatchId $batch }
    } @($PSScriptRoot,$queue.ToArray(),[string]$destination.SelectedItem,$journal,$DryRun) {
        param($result,$context)
        foreach ($entry in $result) { Write-Log "$($entry.Name) | $($entry.Stage) | $($entry.Destination)" }
        if ($context.DryRun) {
            $script:approvedPlan = $context.PlanKey
            [void][Windows.Forms.MessageBox]::Show($form, (($result | ForEach-Object {
                "$($_.Name): $($_.Source) → $($_.Destination)"
            }) -join [Environment]::NewLine), 'Dry-run plan')
        } else { $script:approvedPlan = $null; $queue.Clear(); Refresh-Queue }
        Refresh-History
        Refresh-Apps
    } @{DryRun=$DryRun; PlanKey=$planKey}
}
function Get-QueueKey { "$($destination.SelectedItem)|" + (($queue | ForEach-Object Path) -join '|') }
function Refresh-History {
    $historyGrid.Rows.Clear()
    $recoveryGrid.Rows.Clear()
    foreach ($entry in Get-GojiraHistory $journal | Sort-Object UpdatedAt -Descending) {
        [void](Add-Row $historyGrid @($entry.Name,$entry.Stage,$entry.Source,$entry.Destination,$entry.UpdatedAt,$entry.Id) $entry)
        if ($entry.Stage -notin 'RolledBack','Abandoned') {
            [void](Add-Row $recoveryGrid @($entry.Name,$entry.Stage,$entry.Source,$entry.Destination,$entry.Id) $entry)
        }
    }
}
function Start-Recovery($Action,$Executable,[switch]$WholeBatch) {
    if (!(Test-Elevated)) { throw 'Use Settings and Logs to restart as administrator for recovery operations.' }
    $selected = @($recoveryGrid.SelectedRows | ForEach-Object Tag)
    if (!$selected.Count) { throw 'Select a transaction first.' }
    if ($WholeBatch) {
        $batch = @($selected | ForEach-Object BatchId | Sort-Object -Unique)
        if ($batch.Count -ne 1 -or !$batch[0]) { throw 'Select a transaction from one batch.' }
        $selected = @(Get-GojiraHistory $journal | Where-Object {
            $_.BatchId -eq $batch[0] -and $_.Stage -notin 'RolledBack','Abandoned'
        } | Sort-Object UpdatedAt -Descending)
    }
    if ($Action -ne 'ConfirmLaunch' -and !(Confirm-Action "$Action for $($selected.Count) selected transaction(s)?")) { return }
    Run-Recovery $Action $selected $Executable
}
function Run-Recovery($Action,$Selected,$Executable) {
    Start-Work "$Action · $($Selected.Count) transaction(s)" {
        param($root,$journalPath,$transactions,$operation,$exe)
        $ErrorActionPreference = 'Stop'
        Import-Module (Join-Path $root 'Engine.psm1') -Force
        foreach ($tx in $transactions) {
            try { Invoke-GojiraRecovery $tx.Id $journalPath $operation $exe }
            catch { [pscustomobject]@{Name=$tx.Name; Stage="Needs review — $($_.Exception.Message)"} }
        }
    } @($PSScriptRoot,$journal,@($Selected),$Action,$Executable) {
        param($result)
        foreach ($entry in $result) { Write-Log "$($entry.Name) | $($entry.Stage)" }
        $failures = @($result | Where-Object Stage -like 'Needs review*')
        if ($failures.Count) { Show-Error (($failures | ForEach-Object { "$($_.Name) | $($_.Stage)" }) -join [Environment]::NewLine) }
        Refresh-History
        Refresh-Apps
    }
}
function Verify-Launch {
    if ($recoveryGrid.SelectedRows.Count -ne 1) { throw 'Select one transaction.' }
    $tx = $recoveryGrid.SelectedRows[0].Tag
    if ($tx.Stage -ne 'ActiveWithBackup') { throw 'Select an active migration with a retained backup.' }
    if (!(Confirm-Action "Open $($tx.Name) using its usual shortcut or original executable, then close it. Record the launch only after you confirm that the app opened successfully.")) { return }
    $picker = [Windows.Forms.OpenFileDialog]@{InitialDirectory=$tx.Source; Filter='Applications (*.exe)|*.exe';
        Title='Choose the original executable you verified'}
    try {
        if ($picker.ShowDialog($form) -eq 'OK') { Run-Recovery 'ConfirmLaunch' @($tx) $picker.FileName }
    } finally { $picker.Dispose() }
}

$search.Add_TextChanged({ Refresh-Apps })
$storageQuery.Add_TextChanged({ Refresh-Storage })
$storageFilter.Add_SelectedIndexChanged({ Refresh-Storage })
$storageGrid.Add_SelectionChanged({ Update-StorageSelection })
foreach ($combo in @($sourceFilter,$riskFilter,$sizeFilter)) { $combo.Add_SelectedIndexChanged({ Refresh-Apps }) }
$appGrid.Add_CellDoubleClick({ if ($_.RowIndex -ge 0) { Show-AppDetails } })
$form.Add_FormClosing({ if ($script:work) { $_.Cancel = $true; Show-Error 'Wait for the current operation to finish.' } })
Set-Choices $sourceFilter @('Any drive')
Set-Choices $destination @('Destination drive')
Set-Theme $form
Refresh-Queue
$form.Add_Shown({
    try {
        if ($StorageSmokeTest) { $tabs.SelectedTab = $storagePage; Start-StorageScan }
        else { Start-Scan }
    } catch {
        if ($SmokeTest -or $StorageSmokeTest) { $script:scanFailure = $_.Exception.Message; $form.Close() }
        else { Show-Error $_.Exception.Message }
    }
})
$timer.Start()
try { [void]$form.ShowDialog() } finally { $timer.Dispose(); $form.Dispose() }
if ($SmokeTest) {
    if (!$script:scanCompleted) { throw "GUI scan did not complete. $script:scanFailure" }
    "PASS: GUI rendered $($script:report.Volumes.Count) volumes and $($script:report.Applications.Count) inventory rows."
}
if ($StorageSmokeTest) {
    if (!$script:storageScanCompleted) { throw "Storage scan did not complete. $script:scanFailure" }
    "PASS: Storage rendered and filtered $($script:storageReport.Rows.Count) rows."
}
