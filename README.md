# wsl-distro-backup

PowerShell utility to back up, schedule, and manage WSL 2 distribution exports. Version 2.0.0.

## Requirements

- PowerShell 5.1 or later
- WSL 2
- `gzip` in PATH (provided by Git for Windows) for compressed `.tar.gz` output; without it, exports are uncompressed `.tar`

## Usage

```powershell
.\WSL-Backup.ps1 [[-Action] <string>] [-BackupRoot <string>] [-RetentionCount <int>] [-TargetDistros <string[]>] [-Parallel]
```

Run without arguments to open the interactive menu.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Action` | string | `Menu` | `Menu`, `Status`, `BackupAll`, `BackupSelect`, `AddTask`, `Help` |
| `-BackupRoot` | string | `%USERPROFILE%\WSL-Backups` | Backup output directory |
| `-RetentionCount` | int | `5` | Number of backups to retain per distro (rolling) |
| `-TargetDistros` | string[] | `kali-linux`, `Ubuntu` | Override default distro list for `BackupAll` |
| `-Parallel` | switch | false | Export all distros concurrently (`BackupAll` only) |

## Actions

**Menu** (default) - Interactive menu with numbered options for all operations.

**Status** - Lists all installed WSL distributions with name, state (Running/Stopped/Exporting), and WSL version. Marks the default distro with `*`.

**BackupAll** - Backs up the target distro list. Terminates each distro before export. Prunes old backups after each successful export to stay within `RetentionCount`. Supports `-Parallel` for concurrent exports.

**BackupSelect** - Interactive selection from all installed distros; prompts for parallel mode if multiple are selected.

**AddTask** - Registers a Windows scheduled task (`WSL Backup`) to run `BackupAll` automatically. Prompts for frequency (weekly/daily) and time. Requires elevation if Task Scheduler access is restricted.

**Help** - Prints parameter reference and examples to the console.

## Examples

```powershell
# Interactive menu
.\WSL-Backup.ps1

# Back up all default distros in parallel (non-interactive)
.\WSL-Backup.ps1 -Action BackupAll -Parallel

# Back up kali-linux only to a custom path, keep 7 backups
.\WSL-Backup.ps1 -Action BackupAll -TargetDistros kali-linux -BackupRoot D:\Backups -RetentionCount 7

# Show distro states
.\WSL-Backup.ps1 -Action Status

# Register a scheduled task
.\WSL-Backup.ps1 -Action AddTask
```

## Output

Backups are written to `BackupRoot` with the naming pattern `<distro>-<yyyy-MM-dd_HHmm>.tar.gz` (or `.tar` without gzip). A `backup.log` is maintained in the same directory.

Progress is printed inline during export (MB written and elapsed seconds). Parallel mode shows all jobs simultaneously.

## Stuck-export recovery

If a distro is left in `Exporting` state (e.g., after an interrupted run), the script detects this and prompts to run `wsl --shutdown` and optionally restart `LxssManager`. In non-interactive mode (scheduled task), it logs a warning and exits without attempting cleanup.

## Default distros

The default target list is `kali-linux` and `Ubuntu`. Override per-run with `-TargetDistros`, or modify `$Script:DefaultDistros` at line 50 of the script to change the persistent default.

## Versioning

| Version | Notes |
|---|---|
| 2.0.0 | Current. Added parallel export, interactive menu, scheduled task registration, stuck-state recovery, rolling retention, gzip detection. |
| 1.x | Initial single-distro export script. |
