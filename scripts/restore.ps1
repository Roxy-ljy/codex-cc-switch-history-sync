param(
    [switch]$RestoreLatestBackup,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" })
)

$ErrorActionPreference = "Stop"

$StartupDir = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupDir "Codex History Sync.lnk"
$BackupRoot = Join-Path $CodexHome "history-sync-tool-backups"

function Stop-ToolProcesses {
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match 'powershell|wscript|cscript' -and
            $_.CommandLine -match 'watch-cc-switch-codex-provider|run-codex-history-sync-ui|sync-codex-history-loop'
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Restore-IfExists {
    param([string]$Source, [string]$Destination)
    if (Test-Path -LiteralPath $Source) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
}

Stop-ToolProcesses

if (Test-Path -LiteralPath $ShortcutPath) {
    Remove-Item -LiteralPath $ShortcutPath -Force
}

foreach ($name in @(
    "watch-cc-switch-codex-provider.ps1",
    "run-codex-history-sync-ui.ps1",
    "start-codex-history-sync.vbs"
)) {
    $path = Join-Path $CodexHome $name
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

if (-not $RestoreLatestBackup) {
    Write-Host "Tool disabled. No Codex or cc-switch data was restored."
    Write-Host "Run with -RestoreLatestBackup to restore the latest install backup."
    exit 0
}

$latest = Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "install_*" } |
    Sort-Object Name -Descending |
    Select-Object -First 1

if (-not $latest) {
    throw "No install backup found under $BackupRoot"
}

$answer = Read-Host "Restore backup '$($latest.FullName)'? Close Codex and cc-switch first. This may overwrite local state. Type RESTORE to continue"
if ($answer -ne "RESTORE") {
    Write-Host "Restore cancelled."
    exit 0
}

foreach ($name in @("config.toml", "session_index.jsonl", "state_5.sqlite", "sync-codex-history.ps1")) {
    Restore-IfExists -Source (Join-Path $latest.FullName $name) -Destination (Join-Path $CodexHome $name)
}

$CcSwitchHome = Join-Path $env:USERPROFILE ".cc-switch"
Restore-IfExists -Source (Join-Path $latest.FullName "cc-switch.db") -Destination (Join-Path $CcSwitchHome "cc-switch.db")
Restore-IfExists -Source (Join-Path $latest.FullName "cc-switch-settings.json") -Destination (Join-Path $CcSwitchHome "settings.json")

Write-Host "Restored latest install backup: $($latest.FullName)"
