# Gojira

Gojira is a native Windows 11 utility for reviewing storage and relocating eligible application directories between physical NTFS disks. It uses PowerShell 7, Windows Forms and Windows inbox tools.

## Run locally

Open `Launch.cmd`, or run:

```powershell
pwsh -NoProfile -STA -File .\Gojira.ps1
```

PowerShell 7.2 or newer is required. Open the app with your normal Windows account for discovery. Use **Settings and Logs → Restart as administrator** when an operation needs access to protected paths, ownership or NTFS audit rules. Use the same Windows account after elevation to see the same journal.

## Manage storage

- **Storage → Scan storage** shows the Windows locations of Downloads, Desktop, Documents, Pictures, Music and Videos. It also ranks folders in Local, Roaming and LocalLow AppData by visible file size. Sort by size, filter by area or search by folder name.
- For Downloads and other local personal folders, select **Prepare move check** before opening **Folder properties → Location → Move**. Windows applies the new location and prompts about moving existing files. Then select **Verify move** in Gojira. It reads the current Windows path and compares the original relative paths, file content and named NTFS streams against the saved checklist. Scan storage again to refresh the sizes. OneDrive-backed folders link to the OneDrive relocation procedure.
- Folder checks are read-only for the selected folder and persist locally under `%LOCALAPPDATA%\GojiraMigration\FolderChecks`. They require local folders on fixed NTFS drives and report unsupported links or offline entries. The check excludes the hidden, system-marked root `desktop.ini` that Windows can rewrite during redirection. The result checks content and location. Use Windows to manage permission inheritance and folder relocation itself.
- AppData rows link to supported controls or guidance where available, including browser cache settings, NVIDIA shader-cache limits, and Windows package and storage settings. These actions open the corresponding Windows window, folder or vendor guide and leave the decision to the person using Gojira.
- Sizes are logical file sizes. Linked, offline and unreadable items are skipped and counted. Browser and driver cache rows drill into the parent vendor folders, so those rows overlap. The AppData total comes from its three root scans.

To view the read-only report from PowerShell, run `pwsh -NoProfile -File .\Storage.ps1`. To verify the Storage tab on your PC, run `pwsh -NoProfile -STA -File .\Gojira.ps1 -StorageSmokeTest`.
Run `pwsh -NoProfile -File .\Test-GojiraFolderCheck.ps1` to exercise the before-and-after checks on dummy files.

## Audit and plan

```powershell
pwsh -NoProfile -File .\Discovery.ps1 -OutputDirectory .\local-audit
```

The Windows registry, current-user AppX/MSIX registration and installation directories provide the inventory. Disk, partition, service, scheduled-task and process queries add context. CSV rows explain each risk classification, and JSON records evidence, link targets and incomplete queries. The inventory is local and may contain personal paths. Sizes below accessible application roots include logical file lengths and exclusive NTFS file allocation. Allocation estimates exclude shared hard links, directory metadata, unreadable files and unobserved folders. Missing values and incomplete measurements mean the estimate is unavailable.

Use Windows Settings for AppX/MSIX packages that show a **Move** action. Steam games can move through Steam's **Settings → Storage**. Gojira surfaces these alternatives and lets the vendor or operating system handle the move. [Steam Support](https://help.steampowered.com/en/faqs/view/4BD4-4528-6B2E-8327)

Risk classifications reflect observed evidence. Review the app's updater, helpers, shared paths and configuration before choosing it. Service and task associations are path-based, so indirect dependencies may require manual review. The package feature itself determines native eligibility on the installed version.

## Migrate and recover

1. On **Installed Applications**, search or filter, check individual applications, then add them to the queue. Pick a destination volume on a separate healthy NTFS disk.
2. Run **Dry run**. Review the proposed source and destination and close each app and its helpers. The dry run probes file access and capacity and writes no journal or destination data.
3. Select **Migrate selected queue**, then approve the specific queue. Gojira rechecks the inventory and capacity. Every application has a separate persistent transaction with a shared batch ID.
4. Gojira copies and verifies the tree, renames the original to a sibling backup and validates the junction at the original path. It verifies SHA-256, file sizes, timestamps, attributes, owner, group and access control. Migration refuses nested reparse points, hard links, named streams and unsupported storage attributes. Production copies also request auditing metadata. [Microsoft Robocopy documentation](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy)
5. Open the app through its usual shortcut and check settings and expected behavior. Close the app and record the launch via **Recovery and Rollback → Verify launch**. Reclaim space only after you have verified launch, reviewed the transaction and confirmed backup removal. If app content changes, Gojira keeps the backup when it can no longer verify the original and destination match.
6. Use **Roll back selected** or **Roll back batch** to restore the original layout. If the live copy changed, rollback stages and verifies a current copy before replacing the junction. It retains the destination and any unused backup for inspection.

The journal is stored under `%LOCALAPPDATA%\GojiraMigration\Journal`. Reopen Gojira after an interruption and select the unfinished transaction in **Recovery and Rollback**. Keep both original volume identities mounted with their recorded letters. If unexpected paths, changed data or locks make automatic recovery unsafe, Gojira reports the blocker and preserves available copies. Windows components, security software and protected shared directories stay outside the migration flow.

## Dummy-directory verification

```powershell
pwsh -NoProfile -File .\Test-Gojira.ps1
pwsh -NoProfile -STA -File .\Gojira.ps1 -SmokeTest
```

To test across two real drives, pass existing writable parent folders on those drives using `-SourceParent` and `-DestinationParent`. The harness creates new uniquely named fixture folders and prints their paths. It exercises junction switching, integrity and access control, a real executable launch, capacity rejection, locked files, nested junctions, interruption recovery and rollback after source cleanup. Fixture copy mode uses the current user's permissions. An elevated production-path NTFS audit-rule check is a separate test.

For a Windows restart test, pass `-PauseForWindowsRestart` and retain the journal path printed at the end. After a planned Windows restart, run `Test-Gojira.ps1 -ResumeJournal <path>` to verify the retained dummy transaction. The default suite starts a new PowerShell process for the same journal recovery check.
