$ErrorActionPreference = "Stop"

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$CcSwitchHome = Join-Path $env:USERPROFILE ".cc-switch"
$SettingsPath = Join-Path $CcSwitchHome "settings.json"
$DbPath = Join-Path $CcSwitchHome "cc-switch.db"
$SyncUiScript = Join-Path $CodexHome "run-codex-history-sync-ui.ps1"

function Get-SettingsProvider {
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return $null
    }
    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return $settings.currentProviderCodex
    } catch {
        return $null
    }
}

function Get-DbProvider {
    if (-not (Test-Path -LiteralPath $DbPath)) {
        return $null
    }
    $env:CC_SWITCH_WATCH_DB = $DbPath
    $python = 'import os, sqlite3; p=os.environ["CC_SWITCH_WATCH_DB"]; con=sqlite3.connect("file:"+p+"?mode=ro", uri=True, timeout=3); row=con.execute("select id from providers where app_type=''codex'' and is_current=1 limit 1").fetchone(); print(row[0] if row else ""); con.close()'
    try {
        $result = $python | python -
        $result = ($result | Select-Object -First 1).Trim()
        if ($result) { return $result }
    } catch {
        return $null
    }
    return $null
}

function Get-CurrentCodexProvider {
    $settingsProvider = Get-SettingsProvider
    if ($settingsProvider) {
        return $settingsProvider
    }
    return Get-DbProvider
}

function Invoke-CodexHistorySync {
    param([string]$ProviderId)

    $syncMutexCreated = $false
    $syncMutex = New-Object System.Threading.Mutex($true, "Local\CodexCcSwitchHistorySync-Run", [ref]$syncMutexCreated)
    if (-not $syncMutexCreated) {
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $SyncUiScript)) {
            return
        }

        $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $SyncUiScript)
        if ($ProviderId) {
            $args += @("-ProviderId", $ProviderId)
        }
        Start-Process -FilePath "powershell.exe" -ArgumentList $args -WindowStyle Normal
    } catch {
        return
    } finally {
        try {
            $syncMutex.ReleaseMutex() | Out-Null
        } catch {}
        $syncMutex.Dispose()
    }
}

$watcherMutexCreated = $false
$watcherMutex = New-Object System.Threading.Mutex($true, "Local\CodexCcSwitchHistorySync-Watcher", [ref]$watcherMutexCreated)
if (-not $watcherMutexCreated) {
    exit 0
}

if (-not (Test-Path -LiteralPath $CcSwitchHome)) {
    exit 1
}

$script:lastProvider = Get-CurrentCodexProvider

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $CcSwitchHome
$watcher.Filter = "*"
$watcher.IncludeSubdirectories = $false
$watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'
$watcher.EnableRaisingEvents = $true

$subs = @()
$subs += Register-ObjectEvent -InputObject $watcher -EventName Changed
$subs += Register-ObjectEvent -InputObject $watcher -EventName Created
$subs += Register-ObjectEvent -InputObject $watcher -EventName Renamed

try {
    while ($true) {
        $event = Wait-Event -Timeout 1
        if (-not $event) {
            continue
        }

        $hasRelevantEvent = $false
        while ($event) {
            $name = $event.SourceEventArgs.Name
            if ($name -eq "settings.json" -or $name -eq "cc-switch.db") {
                $hasRelevantEvent = $true
            }
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
            $event = Get-Event | Select-Object -First 1
        }

        if (-not $hasRelevantEvent) {
            continue
        }

        Start-Sleep -Milliseconds 1500
        $current = Get-CurrentCodexProvider
        if (-not $current -or $current -eq $script:lastProvider) {
            continue
        }

        $script:lastProvider = $current
        Invoke-CodexHistorySync -ProviderId $current
    }
} finally {
    foreach ($sub in $subs) {
        Unregister-Event -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
        Remove-Job -Id $sub.Id -Force -ErrorAction SilentlyContinue
    }
    $watcher.Dispose()
    $watcherMutex.ReleaseMutex() | Out-Null
    $watcherMutex.Dispose()
}
