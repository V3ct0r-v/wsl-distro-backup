#Requires -Version 5.1
<#
.SYNOPSIS
    WSL backup utility with interactive menu.

.DESCRIPTION
    Backs up WSL distributions with gzip compression, parallel execution,
    rolling retention, and scheduled task registration.

.PARAMETER Action
    Action to run without the interactive menu.
    Valid values: Menu (default), Status, BackupAll, BackupSelect, AddTask, Help

.PARAMETER BackupRoot
    Directory for backup storage. Default: $env:USERPROFILE\WSL-Backups

.PARAMETER RetentionCount
    Number of backups to retain per distro. Default: 5

.PARAMETER TargetDistros
    Override the default distro list for BackupAll.
    Example: -TargetDistros kali-linux,Ubuntu

.PARAMETER Parallel
    Export all distros concurrently. Applies to BackupAll only.

.EXAMPLE
    .\WSL-Backup.ps1
    Interactive menu.

.EXAMPLE
    .\WSL-Backup.ps1 -Action BackupAll -Parallel

.EXAMPLE
    .\WSL-Backup.ps1 -Action BackupAll -BackupRoot D:\Backups -RetentionCount 7

.EXAMPLE
    .\WSL-Backup.ps1 -Action Status
#>
param(
    [ValidateSet('Menu', 'Status', 'BackupAll', 'BackupSelect', 'AddTask', 'Help')]
    [string]  $Action         = 'Menu',
    [string]  $BackupRoot     = "$env:USERPROFILE\WSL-Backups",
    [int]     $RetentionCount = 5,
    [string[]]$TargetDistros,
    [switch]  $Parallel
)

$Script:Version        = '2.0.0'
$Script:DefaultDistros = @('kali-linux', 'Ubuntu')
$Script:GzipAvailable  = $null -ne (Get-Command gzip -ErrorAction SilentlyContinue)

if (-not (Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
}
$Script:LogFile = Join-Path $BackupRoot 'backup.log'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message)
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $entry
    Add-Content -Path $Script:LogFile -Value $entry
}

function Get-WslDistroInfo {
    # Returns objects: Name, State, Version, Default
    $raw = (wsl --list --verbose 2>$null) -replace "`0", "" |
           Where-Object { $_.Trim() -ne "" } |
           Select-Object -Skip 1
    foreach ($line in $raw) {
        $trimmed   = $line.Trim()
        $isDefault = $trimmed.StartsWith('*')
        $parts     = ($trimmed -replace '^\*\s*', '') -split '\s+' |
                     Where-Object { $_ -ne "" }
        if ($parts.Count -ge 3) {
            [pscustomobject]@{
                Name    = $parts[0]
                State   = $parts[1]
                Version = $parts[2]
                Default = $isDefault
            }
        }
    }
}

function Get-DistroState {
    param([string]$Distro)
    $raw = (wsl --list --verbose 2>$null) -replace "`0", "" |
           Where-Object { $_ -match "(?i)\b$([regex]::Escape($Distro))\b" }
    if ($raw) { ($raw.Trim() -replace '^\*\s*', '' -split '\s+')[1] }
}

function Repair-WslStuckState {
    param([string]$Distro, [string]$FilePath, [string]$FileName)

    Write-Host ""
    Write-Host "WARNING: $Distro is stuck in 'Exporting' state."

    if (-not [System.Environment]::UserInteractive) {
        Write-Log "WARNING: $Distro stuck in Exporting state. Remediate manually: wsl --shutdown"
        return
    }

    $response = Read-Host "  Run cleanup? (wsl --shutdown; restart LxssManager if needed) [Y/N]"
    if ($response -match '^[Yy]') {
        Write-Log "Running WSL cleanup for stuck $Distro..."
        wsl --shutdown
        Start-Sleep -Seconds 3
        $newState = Get-DistroState $Distro
        if ($newState -ne 'Exporting') {
            Write-Log "Cleanup complete. $Distro is now: $newState"
        } else {
            Write-Log "$Distro still Exporting after wsl --shutdown; restarting LxssManager..."
            Restart-Service LxssManager -Force
            Write-Log "LxssManager restarted. Verify with: wsl --list --verbose"
        }
    } else {
        Write-Log "Cleanup skipped. $Distro remains in Exporting state."
    }

    if ($FilePath -and (Test-Path $FilePath)) {
        $partialMB = [math]::Round((Get-Item $FilePath).Length / 1MB, 1)
        $delResp   = Read-Host "  Remove incomplete backup $FileName ($partialMB MB)? [Y/N]"
        if ($delResp -match '^[Yy]') {
            Remove-Item $FilePath -Force
            Write-Log "Removed incomplete backup: $FileName"
        }
    }
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Show-WslStatus {
    Write-Host ""
    Write-Host "WSL Distribution Status"
    Write-Host ("-" * 50)
    $distros = @(Get-WslDistroInfo)
    if ($distros.Count -eq 0) {
        Write-Host "  No WSL distributions found."
        return
    }
    foreach ($d in $distros) {
        $marker = if ($d.Default) { '*' } else { ' ' }
        $color  = switch ($d.State) {
            'Running'   { 'Green'  }
            'Stopped'   { 'Gray'   }
            'Exporting' { 'Yellow' }
            default     { 'White'  }
        }
        Write-Host ("  {0} {1,-22}" -f $marker, $d.Name) -NoNewline
        Write-Host ("{0,-12}" -f $d.State) -ForegroundColor $color -NoNewline
        Write-Host "WSL$($d.Version)"
    }
    Write-Host ""
}

function Invoke-DistroBackup {
    param(
        [string]$Distro,
        [string]$BackupRoot,
        [int]   $RetentionCount,
        [string]$Timestamp
    )

    Write-Log "--- $Distro ---"
    Write-Log "Terminating $Distro..."
    wsl --terminate $Distro 2>$null
    Start-Sleep -Seconds 2

    $job      = $null
    $filename = $null
    $filepath = $null
    $start    = Get-Date

    try {
        if ($Script:GzipAvailable) {
            $filename = "$Distro-$Timestamp.tar.gz"
            $filepath = Join-Path $BackupRoot $filename
            Write-Log "Exporting and compressing: $filename"
            $job = Start-Job -ScriptBlock {
                param($d, $fp)
                cmd /c "wsl --export $d - | gzip > `"$fp`""
            } -ArgumentList $Distro, $filepath
        } else {
            $filename = "$Distro-$Timestamp.tar"
            $filepath = Join-Path $BackupRoot $filename
            Write-Log "Exporting (uncompressed): $filename"
            $job = Start-Job -ScriptBlock {
                param($d, $fp)
                wsl --export $d $fp
            } -ArgumentList $Distro, $filepath
        }

        while ($job.State -eq 'Running') {
            if (Test-Path $filepath) {
                $sizeMB  = [Math]::Round((Get-Item $filepath).Length / 1MB, 1)
                $elapsed = [Math]::Round(((Get-Date) - $start).TotalSeconds)
                Write-Host "`r  $sizeMB MB written  (${elapsed}s elapsed)..." -NoNewline
            } else {
                Write-Host "`r  Starting export..." -NoNewline
            }
            Start-Sleep -Milliseconds 500
        }
        Write-Host ""
        Receive-Job $job | Out-Null
        Remove-Job $job
        $job = $null

        $duration = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
        if (Test-Path $filepath) {
            $sizeMB = [math]::Round((Get-Item $filepath).Length / 1MB, 0)
            Write-Log "Done: $filename | $sizeMB MB | $duration min"
        } else {
            Write-Log "ERROR: Export failed for $Distro - check disk space"
            return $false
        }

        $pattern  = if ($Script:GzipAvailable) { "$Distro-*.tar.gz" } else { "$Distro-*.tar" }
        $existing = Get-ChildItem -Path $BackupRoot -Filter $pattern |
                    Sort-Object LastWriteTime -Descending
        if ($existing.Count -gt $RetentionCount) {
            $existing | Select-Object -Skip $RetentionCount | ForEach-Object {
                Remove-Item $_.FullName -Force
                Write-Log "Pruned: $($_.Name)"
            }
        }
        Write-Log "Retained backups: $([Math]::Min($existing.Count, $RetentionCount))"
        return $true

    } finally {
        if ($null -ne $job) {
            if ($job.State -eq 'Running') { Stop-Job $job }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
        if ((Get-DistroState $Distro) -eq 'Exporting') {
            Repair-WslStuckState -Distro $Distro -FilePath $filepath -FileName $filename
        }
    }
}

function Invoke-BackupParallel {
    param(
        [string[]]$Distros,
        [string]  $BackupRoot,
        [int]     $RetentionCount,
        [string]  $Timestamp
    )

    foreach ($d in $Distros) {
        Write-Log "Terminating $d..."
        wsl --terminate $d 2>$null
    }
    Start-Sleep -Seconds 2

    $jobs = [ordered]@{}
    foreach ($d in $Distros) {
        $fn = if ($Script:GzipAvailable) { "$d-$Timestamp.tar.gz" } else { "$d-$Timestamp.tar" }
        $fp = Join-Path $BackupRoot $fn
        Write-Log "Starting export: $fn"
        $j = if ($Script:GzipAvailable) {
            Start-Job -ScriptBlock {
                param($dist, $path)
                cmd /c "wsl --export $dist - | gzip > `"$path`""
            } -ArgumentList $d, $fp
        } else {
            Start-Job -ScriptBlock {
                param($dist, $path)
                wsl --export $dist $path
            } -ArgumentList $d, $fp
        }
        $jobs[$d] = @{ Job = $j; FilePath = $fp; FileName = $fn; Start = Get-Date }
    }

    try {
        Write-Host ""
        while ($true) {
            $anyRunning = $false
            foreach ($d in $jobs.Keys) {
                if ($null -ne $jobs[$d].Job -and $jobs[$d].Job.State -eq 'Running') {
                    $anyRunning = $true
                    break
                }
            }
            if (-not $anyRunning) { break }

            $parts = foreach ($d in $jobs.Keys) {
                $info    = $jobs[$d]
                $elapsed = [Math]::Round(((Get-Date) - $info.Start).TotalSeconds)
                if ($null -ne $info.Job -and $info.Job.State -eq 'Running') {
                    $mb = if (Test-Path $info.FilePath) {
                        [Math]::Round((Get-Item $info.FilePath).Length / 1MB, 0)
                    } else { 0 }
                    "[${d}: ${mb}MB ${elapsed}s]"
                } else {
                    "[${d}: done]"
                }
            }
            Write-Host "`r  $($parts -join '  ')" -NoNewline
            Start-Sleep -Milliseconds 500
        }
        Write-Host ""

        foreach ($d in $jobs.Keys) {
            $info = $jobs[$d]
            Receive-Job $info.Job | Out-Null
            Remove-Job $info.Job
            $jobs[$d].Job = $null
            $duration = [math]::Round(((Get-Date) - $info.Start).TotalMinutes, 1)

            if (Test-Path $info.FilePath) {
                $sizeMB = [math]::Round((Get-Item $info.FilePath).Length / 1MB, 0)
                Write-Log "Done: $($info.FileName) | $sizeMB MB | $duration min"
            } else {
                Write-Log "ERROR: Export failed for $d - check disk space"
            }

            $pattern  = if ($Script:GzipAvailable) { "$d-*.tar.gz" } else { "$d-*.tar" }
            $existing = Get-ChildItem -Path $BackupRoot -Filter $pattern |
                        Sort-Object LastWriteTime -Descending
            if ($existing.Count -gt $RetentionCount) {
                $existing | Select-Object -Skip $RetentionCount | ForEach-Object {
                    Remove-Item $_.FullName -Force
                    Write-Log "Pruned: $($_.Name)"
                }
            }
            Write-Log "Retained backups for ${d}: $([Math]::Min($existing.Count, $RetentionCount))"
        }

    } finally {
        foreach ($d in $jobs.Keys) {
            $j = $jobs[$d].Job
            if ($null -ne $j) {
                if ($j.State -eq 'Running') { Stop-Job $j }
                Remove-Job $j -Force -ErrorAction SilentlyContinue
                $jobs[$d].Job = $null
            }
        }
        foreach ($d in $jobs.Keys) {
            if ((Get-DistroState $d) -eq 'Exporting') {
                Repair-WslStuckState -Distro $d -FilePath $jobs[$d].FilePath -FileName $jobs[$d].FileName
            }
        }
    }
}

function Invoke-BackupAll {
    param(
        [string[]]$Distros,
        [switch]  $Parallel
    )

    if (-not $Script:GzipAvailable) {
        Write-Log "WARNING: gzip not found - exports will be uncompressed .tar"
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $installed = @((Get-WslDistroInfo).Name)
    $list      = @($Distros | Where-Object { $installed -contains $_ })

    foreach ($d in ($Distros | Where-Object { $installed -notcontains $_ })) {
        Write-Log "SKIP: $d not found in WSL"
    }

    if ($list.Count -eq 0) {
        Write-Host "  No target distros found in WSL."
        return
    }

    if ($Parallel -and $list.Count -gt 1) {
        Invoke-BackupParallel -Distros $list -BackupRoot $BackupRoot `
                              -RetentionCount $RetentionCount -Timestamp $timestamp
    } else {
        foreach ($d in $list) {
            Invoke-DistroBackup -Distro $d -BackupRoot $BackupRoot `
                                -RetentionCount $RetentionCount -Timestamp $timestamp
        }
    }
    Write-Log "=== Run complete ==="
}

function Invoke-BackupSelect {
    Write-Host ""
    $distros = @(Get-WslDistroInfo)
    if ($distros.Count -eq 0) {
        Write-Host "  No WSL distributions found."
        return
    }

    Write-Host "Installed distros:"
    for ($i = 0; $i -lt $distros.Count; $i++) {
        Write-Host ("  [{0}] {1,-22} ({2})" -f ($i + 1), $distros[$i].Name, $distros[$i].State)
    }
    Write-Host ""

    $raw = (Read-Host "  Select numbers (e.g. 1,2) [all]").Trim()
    $selected = if ($raw -eq "") {
        $distros
    } else {
        @($raw -split '[,\s]+' | ForEach-Object {
            if ($_ -match '^\d+$') {
                $idx = [int]$_ - 1
                if ($idx -ge 0 -and $idx -lt $distros.Count) { $distros[$idx] }
            }
        })
    }

    if ($selected.Count -eq 0) {
        Write-Host "  No valid selection."
        return
    }

    $runParallel = $false
    if ($selected.Count -gt 1) {
        $p = (Read-Host "  Run in parallel? [Y/N]").Trim()
        $runParallel = $p -match '^[Yy]'
    }

    $names = @($selected | ForEach-Object { $_.Name })
    Invoke-BackupAll -Distros $names -Parallel:$runParallel
}

function Add-BackupScheduledTask {
    Write-Host ""
    Write-Host "Schedule WSL Backup"
    Write-Host ("-" * 40)

    $freq = (Read-Host "  Frequency: [1] Weekly  [2] Daily  [1]").Trim()
    if ($freq -eq "") { $freq = "1" }

    $dayName = $null
    if ($freq -eq "1") {
        $days = @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')
        Write-Host ""
        for ($i = 0; $i -lt $days.Count; $i++) {
            Write-Host ("    [{0}] {1}" -f ($i + 1), $days[$i])
        }
        $raw = (Read-Host "  Day [1=Sunday]").Trim()
        if ($raw -eq "") { $raw = "1" }
        $dayName = $days[[int]$raw - 1]
    }

    $timeStr = (Read-Host "  Time HH:MM 24h [02:00]").Trim()
    if ($timeStr -eq "") { $timeStr = "02:00" }
    $parts  = $timeStr -split ':'
    $atTime = "{0:D2}:{1:D2}" -f ([int]$parts[0]), (if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 })

    $scriptPath = $PSCommandPath
    $taskArgs   = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass " +
                  "-File `"$scriptPath`" -Action BackupAll " +
                  "-BackupRoot `"$BackupRoot`" -RetentionCount $RetentionCount"

    $action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgs
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    $trigger  = if ($freq -eq "1") {
        New-ScheduledTaskTrigger -Weekly -DaysOfWeek $dayName -At $atTime
    } else {
        New-ScheduledTaskTrigger -Daily -At $atTime
    }

    $taskName = "WSL Backup"
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action `
            -Trigger $trigger -Settings $settings -RunLevel Limited -Force | Out-Null
        $schedule = if ($freq -eq "1") { "weekly ($dayName) at $atTime" } else { "daily at $atTime" }
        Write-Host ""
        Write-Host "  Task '$taskName' registered ($schedule)."
        Write-Log "Scheduled task registered: $taskName ($schedule)"
    } catch {
        Write-Host ""
        Write-Host "  ERROR: $_"
        Write-Host "  If access is denied, re-run as administrator."
    }
}

function Show-Help {
    Write-Host ""
    Write-Host "WSL Backup Utility  v$($Script:Version)"
    Write-Host ""
    Write-Host "USAGE"
    Write-Host "  .\WSL-Backup.ps1 [[-Action] <string>] [-BackupRoot <string>]"
    Write-Host "                   [-RetentionCount <int>] [-TargetDistros <string[]>]"
    Write-Host "                   [-Parallel]"
    Write-Host ""
    Write-Host "PARAMETERS"
    Write-Host "  -Action           Menu (default), Status, BackupAll, BackupSelect,"
    Write-Host "                    AddTask, Help"
    Write-Host ("  -BackupRoot       Backup directory.  Default: {0}\WSL-Backups" -f $env:USERPROFILE)
    Write-Host "  -RetentionCount   Backups to keep per distro.  Default: 5"
    Write-Host "  -TargetDistros    Override the default distro list for BackupAll."
    Write-Host "                    Example: -TargetDistros kali-linux,Ubuntu"
    Write-Host "  -Parallel         Export all distros concurrently (BackupAll only)."
    Write-Host ""
    Write-Host "EXAMPLES"
    Write-Host "  .\WSL-Backup.ps1"
    Write-Host "      Interactive menu."
    Write-Host ""
    Write-Host "  .\WSL-Backup.ps1 -Action BackupAll -Parallel"
    Write-Host "      Back up all default distros in parallel."
    Write-Host ""
    Write-Host "  .\WSL-Backup.ps1 -Action BackupAll -TargetDistros kali-linux -BackupRoot D:\Backups"
    Write-Host "      Back up kali-linux only to D:\Backups."
    Write-Host ""
    Write-Host "  .\WSL-Backup.ps1 -Action Status"
    Write-Host "      Show WSL distribution states."
    Write-Host ""
    Write-Host "  .\WSL-Backup.ps1 -Action AddTask"
    Write-Host "      Register a Windows scheduled task for automated backup."
    Write-Host ""
    Write-Host "REQUIREMENTS"
    Write-Host "  gzip in PATH (Git for Windows) enables compressed .tar.gz exports."
    Write-Host "  Without gzip, exports are uncompressed .tar."
    if (-not $Script:GzipAvailable) {
        Write-Host ""
        Write-Host "  NOTE: gzip not found in PATH. Exports will be uncompressed." -ForegroundColor Yellow
    }
    Write-Host ""
}

function Show-Menu {
    while ($true) {
        Write-Host ""
        Write-Host ("  WSL Backup Utility  v{0}" -f $Script:Version)
        Write-Host ("  " + ("-" * 36))
        Write-Host "  [1]  WSL status"
        Write-Host "  [2]  Backup all distros"
        Write-Host "  [3]  Backup selected distros"
        Write-Host "  [4]  Add scheduled task"
        Write-Host "  [H]  Help"
        Write-Host "  [Q]  Quit"
        Write-Host ""
        $choice = (Read-Host "  Select").Trim().ToUpper()

        switch ($choice) {
            '1' { Show-WslStatus }
            '2' {
                $p = (Read-Host "  Run in parallel? [Y/N]").Trim()
                $distroList = if ($TargetDistros) { $TargetDistros } else { $Script:DefaultDistros }
                Invoke-BackupAll -Distros $distroList -Parallel:($p -match '^[Yy]')
            }
            '3' { Invoke-BackupSelect }
            '4' { Add-BackupScheduledTask }
            'H' { Show-Help }
            'Q' { return }
            default { Write-Host "  Invalid selection. Enter 1-4, H, or Q." }
        }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

$distroList = if ($TargetDistros) { $TargetDistros } else { $Script:DefaultDistros }

switch ($Action) {
    'Menu'         { Show-Menu }
    'Status'       { Show-WslStatus }
    'BackupAll'    { Invoke-BackupAll -Distros $distroList -Parallel:$Parallel }
    'BackupSelect' { Invoke-BackupSelect }
    'AddTask'      { Add-BackupScheduledTask }
    'Help'         { Show-Help }
}
