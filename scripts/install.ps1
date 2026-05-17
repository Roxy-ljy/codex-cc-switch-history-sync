param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" })
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupRoot = Join-Path $CodexHome "history-sync-tool-backups"
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupDir = Join-Path $BackupRoot "install_$Stamp"
$StartupDir = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupDir "Codex History Sync.lnk"
$WatcherPath = Join-Path $CodexHome "watch-cc-switch-codex-provider.ps1"
$VbsPath = Join-Path $CodexHome "start-codex-history-sync.vbs"

function Copy-IfExists {
    param([string]$Path, [string]$Destination)
    if (Test-Path -LiteralPath $Path) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
        try {
            Copy-Item -LiteralPath $Path -Destination $Destination -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not back up '$Path': $($_.Exception.Message)"
        }
    }
}

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

New-Item -ItemType Directory -Force -Path $CodexHome,$BackupDir | Out-Null
Stop-ToolProcesses

foreach ($name in @(
    "sync-codex-history.ps1",
    "watch-cc-switch-codex-provider.ps1",
    "run-codex-history-sync-ui.ps1",
    "start-codex-history-sync.vbs",
    "config.toml",
    "session_index.jsonl",
    "state_5.sqlite"
)) {
    Copy-IfExists -Path (Join-Path $CodexHome $name) -Destination (Join-Path $BackupDir $name)
}

$CcSwitchHome = Join-Path $env:USERPROFILE ".cc-switch"
Copy-IfExists -Path (Join-Path $CcSwitchHome "cc-switch.db") -Destination (Join-Path $BackupDir "cc-switch.db")
Copy-IfExists -Path (Join-Path $CcSwitchHome "settings.json") -Destination (Join-Path $BackupDir "cc-switch-settings.json")

foreach ($name in @(
    "sync-codex-history.ps1",
    "watch-cc-switch-codex-provider.ps1",
    "run-codex-history-sync-ui.ps1"
)) {
    Copy-Item -LiteralPath (Join-Path $ScriptRoot $name) -Destination (Join-Path $CodexHome $name) -Force
}

$template = Get-Content -LiteralPath (Join-Path $ScriptRoot "start-codex-history-sync.vbs.template") -Raw -Encoding UTF8
$template.Replace("{{WATCHER_PATH}}", $WatcherPath) | Set-Content -LiteralPath $VbsPath -Encoding UTF8

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = $VbsPath
$shortcut.WorkingDirectory = $CodexHome
$shortcut.Description = "Watch cc-switch provider changes and sync Codex history"
$shortcut.Save()

Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$WatcherPath) -WindowStyle Hidden

Write-Host "Installed Codex cc-switch history sync."
Write-Host "Backup: $BackupDir"
