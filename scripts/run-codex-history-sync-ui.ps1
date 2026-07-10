param(
    [string]$ProviderId,
    [switch]$Automatic
)

$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "Codex 会话同步中"

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$SyncScript = Join-Path $CodexHome "sync-codex-history.ps1"
$syncMutexCreated = $false
$syncMutex = New-Object System.Threading.Mutex($true, "Local\CodexCcSwitchHistorySync-Run", [ref]$syncMutexCreated)
if (-not $syncMutexCreated) {
    exit 0
}

$script:barLine = 3
$script:footerLine = 5
$script:clearFromLine = 6
$script:layoutReady = $false
$script:originalCursorVisible = $true

Add-Type -AssemblyName System.Windows.Forms

function Initialize-Display {
    if ($script:layoutReady) {
        return
    }

    try {
        $script:originalCursorVisible = [Console]::CursorVisible
        [Console]::CursorVisible = $false
    } catch {}

    Clear-Host
    Write-Host ""
    Write-Host "  正在同步历史会话" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ""
    Write-Host ""
    $script:layoutReady = $true
}

function Write-FixedLine {
    param(
        [int]$Line,
        [string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )

    $width = [Math]::Max(1, [Console]::WindowWidth - 1)
    if ($Text.Length -gt $width) {
        $Text = $Text.Substring(0, $width)
    }
    $padded = $Text.PadRight($width)
    [Console]::SetCursorPosition(0, $Line)
    Write-Host $padded -NoNewline -ForegroundColor $Color
}

function Clear-LowerArea {
    $width = [Math]::Max(1, [Console]::WindowWidth - 1)
    $blank = "".PadRight($width)
    $maxLine = [Math]::Min([Console]::WindowHeight - 1, $script:clearFromLine + 8)
    for ($line = $script:clearFromLine; $line -le $maxLine; $line++) {
        [Console]::SetCursorPosition(0, $line)
        Write-Host $blank -NoNewline
    }
}

function Show-Bar {
    param(
        [int]$Percent,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan,
        [string]$Footer = ""
    )

    $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
    $width = 34
    $filled = [Math]::Floor(($Percent / 100) * $width)
    if ($Percent -ge 100) {
        $bar = "[" + ("=" * $width) + "]"
    } else {
        $left = if ($filled -gt 0) { "=" * $filled } else { "" }
        $right = " " * [Math]::Max(0, $width - $filled - 1)
        $bar = "[" + $left + ">" + $right + "]"
    }

    Initialize-Display
    Write-FixedLine -Line $script:barLine -Text ("  {0} {1,3}%" -f $bar, $Percent) -Color $Color
    Write-FixedLine -Line $script:footerLine -Text ($(if ($Footer) { "  $Footer" } else { "" })) -Color $Color
    Clear-LowerArea
}

function Get-CodexDesktopExe {
    $windowsApps = Join-Path $env:ProgramFiles "WindowsApps"
    if (Test-Path -LiteralPath $windowsApps) {
        $packages = Get-ChildItem -LiteralPath $windowsApps -Directory -Filter "OpenAI.Codex_*" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending

        foreach ($package in $packages) {
            foreach ($relative in @("app\ChatGPT.exe", "app\Codex.exe")) {
                $candidate = Join-Path $package.FullName $relative
                if (Test-Path -LiteralPath $candidate) {
                    return $candidate
                }
            }
        }
    }

    return $null
}

function Get-CodexWebRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    try {
        $packages = @(Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue)
        foreach ($package in $packages) {
            $candidate = Join-Path $env:LOCALAPPDATA ("Packages\{0}\LocalCache\Roaming\Codex\web\Codex" -f $package.PackageFamilyName)
            if (Test-Path -LiteralPath $candidate) {
                $roots.Add($candidate)
            }
        }
    } catch {}

    $packageRoot = Join-Path $env:LOCALAPPDATA "Packages"
    if (Test-Path -LiteralPath $packageRoot) {
        Get-ChildItem -LiteralPath $packageRoot -Directory -Filter "OpenAI.Codex_*" -ErrorAction SilentlyContinue |
            ForEach-Object {
                $candidate = Join-Path $_.FullName "LocalCache\Roaming\Codex\web\Codex"
                if (Test-Path -LiteralPath $candidate) {
                    $roots.Add($candidate)
                }
            }
    }

    foreach ($candidate in @(
        (Join-Path $env:APPDATA "Codex\web\Codex"),
        (Join-Path $env:LOCALAPPDATA "Codex\web\Codex")
    )) {
        if (Test-Path -LiteralPath $candidate) {
            $roots.Add($candidate)
        }
    }

    return $roots | Select-Object -Unique
}

function Test-IsOfficialCodexProvider {
    param([string]$ProviderId)

    if (-not $ProviderId) {
        return $false
    }
    if ($ProviderId -eq "codex-official") {
        return $true
    }

    $dbPath = Join-Path $env:USERPROFILE ".cc-switch\cc-switch.db"
    if (-not (Test-Path -LiteralPath $dbPath)) {
        return $false
    }

    try {
        $env:CODEX_SYNC_PROVIDER_DB = $dbPath
        $env:CODEX_SYNC_PROVIDER_ID = $ProviderId
        $python = @'
import os
import sqlite3

con = sqlite3.connect(os.environ["CODEX_SYNC_PROVIDER_DB"], timeout=5)
try:
    row = con.execute(
        "select id, name, category from providers where app_type='codex' and id=? limit 1",
        (os.environ["CODEX_SYNC_PROVIDER_ID"],),
    ).fetchone()
finally:
    con.close()

if not row:
    print("0")
else:
    provider_id = (row[0] or "").strip().lower()
    name = (row[1] or "").strip().lower()
    category = (row[2] or "").strip().lower()
    official = (
        provider_id == "codex-official"
        or category == "official"
        or (provider_id == "openai" and "official" in name)
    )
    print("1" if official else "0")
'@
        $result = $python | python -
        return (($result | Select-Object -First 1).Trim() -eq "1")
    } catch {
        return $false
    } finally {
        Remove-Item Env:\CODEX_SYNC_PROVIDER_DB -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_SYNC_PROVIDER_ID -ErrorAction SilentlyContinue
    }
}

function Test-ShouldClearCodexAuthCache {
    param([string]$ProviderId)

    if ($ProviderId) {
        return -not (Test-IsOfficialCodexProvider -ProviderId $ProviderId)
    }

    $configPath = Join-Path $CodexHome "config.toml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return $false
    }

    try {
        $text = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $match = [regex]::Match($text, '(?m)^\s*model_provider\s*=\s*"([^"]+)"\s*$')
        return $match.Success -and $match.Groups[1].Value -eq "ccs"
    } catch {
        return $false
    }
}

function Clear-CodexExpiredAuthCache {
    try {
        Remove-Item Env:\CODEX_API_KEY -ErrorAction SilentlyContinue
    } catch {}
    try {
        [Environment]::SetEnvironmentVariable("CODEX_API_KEY", $null, "User")
    } catch {}

    $webRoots = @(Get-CodexWebRoots)
    if ($webRoots.Count -eq 0) {
        return [pscustomobject]@{
            Cleared = 0
            BackupRoot = $null
        }
    }

    $backupRoot = Join-Path $CodexHome ("web-cache-backups\history-sync-token-clear-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    $targets = @(
        "Default\Network\Cookies",
        "Default\Network\Cookies-journal",
        "Default\Local Storage",
        "Default\Session Storage",
        "Default\IndexedDB",
        "Default\Service Worker",
        "Default\GCM Store",
        "Default\Sync Data",
        "Default\Safe Browsing Network",
        "Default\WebStorage"
    )

    $cleared = 0
    foreach ($webRoot in $webRoots) {
        $defaultRoot = Join-Path $webRoot "Default"
        if (-not (Test-Path -LiteralPath $defaultRoot)) {
            continue
        }

        $resolvedRoot = (Resolve-Path -LiteralPath $webRoot).Path
        foreach ($relative in $targets) {
            $target = Join-Path $webRoot $relative
            if (-not (Test-Path -LiteralPath $target)) {
                continue
            }

            $resolvedTarget = (Resolve-Path -LiteralPath $target).Path
            if (-not $resolvedTarget.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "拒绝清理异常路径：$resolvedTarget"
            }

            $backupPath = Join-Path $backupRoot ((Split-Path -Leaf $webRoot) + "\" + $relative)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
            try {
                Copy-Item -LiteralPath $target -Destination $backupPath -Recurse -Force -ErrorAction SilentlyContinue
            } catch {}
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            $cleared += 1
        }
    }

    $webCacheBackupRoot = Join-Path $CodexHome "web-cache-backups"
    if (Test-Path -LiteralPath $webCacheBackupRoot) {
        Get-ChildItem -LiteralPath $webCacheBackupRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "history-sync-token-clear-*" } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 5 |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Cleared = $cleared
        BackupRoot = $(if ($cleared -gt 0) { $backupRoot } else { $null })
    }
}

function Open-Codex {
    $codexApp = Get-StartApps -ErrorAction SilentlyContinue |
        Where-Object { $_.AppID -like "OpenAI.Codex_*!App" } |
        Select-Object -First 1
    if ($codexApp) {
        Start-Process -FilePath "explorer.exe" -ArgumentList ("shell:AppsFolder\{0}" -f $codexApp.AppID)
        return
    }

    $codexDesktopExe = Get-CodexDesktopExe
    if ($codexDesktopExe) {
        Start-Process -FilePath $codexDesktopExe -WorkingDirectory $env:USERPROFILE
        return
    }

    $codexCli = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin\codex.exe"
    if (Test-Path -LiteralPath $codexCli) {
        Start-Process -FilePath $codexCli -ArgumentList "app" -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\codex-open.out" -RedirectStandardError "$env:TEMP\codex-open.err"
    }
}

function Get-CodexProcessIds {
    try {
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.Name -in @("ChatGPT.exe", "Codex.exe", "codex.exe") -and
                ($_.CommandLine -match "OpenAI\.Codex" -or $_.CommandLine -match "AppData\\Local\\OpenAI\\Codex\\bin" -or $_.CommandLine -match "Codex\\web\\Codex")
            } |
            Select-Object -ExpandProperty ProcessId -Unique
    } catch {
        @()
    }
}

function Get-CodexProcesses {
    $ids = @(Get-CodexProcessIds)
    foreach ($id in $ids) {
        Get-Process -Id $id -ErrorAction SilentlyContinue
    }
}

function Confirm-CloseCodex {
    $processes = @(Get-CodexProcesses)
    if ($processes.Count -eq 0) {
        return $false
    }

    try {
        [Console]::CursorVisible = $script:originalCursorVisible
    } catch {}

    $choice = [System.Windows.Forms.MessageBox]::Show(
        "检测到 Codex 正在运行。切换中转需要关闭并清理过期登录缓存，避免 token_expired 和旧 provider 状态残留。是否关闭 Codex？",
        "关闭并清理 Codex？",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    try {
        [Console]::CursorVisible = $false
    } catch {}

    return $choice -eq [System.Windows.Forms.DialogResult]::Yes
}

function Close-Codex {
    $processes = @(Get-CodexProcesses)
    if ($processes.Count -eq 0) {
        return
    }

    foreach ($process in $processes) {
        try {
            if ($process.MainWindowHandle -ne 0) {
                [void]$process.CloseMainWindow()
            }
        } catch {}
    }

    Start-Sleep -Seconds 2

    $remaining = @(Get-CodexProcesses)
    foreach ($process in $remaining) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        } catch {}
    }

    Start-Sleep -Milliseconds 300
}

function Wait-OnFailure {
    Write-Host ""
    Write-Host "同步失败，按任意键关闭窗口..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
}

try {
    Show-Bar 0
    if (-not (Test-Path -LiteralPath $SyncScript)) {
        throw "同步脚本不存在：$SyncScript"
    }

    $shouldClearAuthCache = Test-ShouldClearCodexAuthCache -ProviderId $ProviderId
    if (@(Get-CodexProcesses).Count -gt 0) {
        if ($Automatic) {
            Show-Bar 3 Cyan "正在关闭 Codex"
            Close-Codex
            Show-Bar 5
        } elseif (Confirm-CloseCodex) {
            Close-Codex
            Show-Bar 5
        } elseif ($shouldClearAuthCache) {
            $shouldClearAuthCache = $false
            try {
                Remove-Item Env:\CODEX_API_KEY -ErrorAction SilentlyContinue
                [Environment]::SetEnvironmentVariable("CODEX_API_KEY", $null, "User")
            } catch {}
            Show-Bar 8 Yellow "已跳过缓存清理；Codex 重启后才会完全生效"
        }
    }

    if ($shouldClearAuthCache) {
        Show-Bar 8 Cyan "正在清理过期登录缓存"
        $cacheResult = Clear-CodexExpiredAuthCache
        if ($cacheResult.Cleared -gt 0) {
            Show-Bar 12 Cyan ("已清理 {0} 项登录缓存" -f $cacheResult.Cleared)
        } else {
            Show-Bar 12 Cyan "未发现需要清理的登录缓存"
        }
    }

    $job = Start-Job -ScriptBlock {
        param([string]$ScriptPath)
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = ($out | Out-String)
        }
    } -ArgumentList $SyncScript

    $percent = 12
    while ($job.State -eq "Running") {
        $percent = [Math]::Min(95, $percent + 2)
        Show-Bar $percent
        Start-Sleep -Milliseconds 120
    }

    $resultEnvelope = Receive-Job -Job $job -Wait
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

    $exitCode = $resultEnvelope.ExitCode
    $output = $resultEnvelope.Output
    if ($exitCode -ne 0) {
        $summary = (($output).Trim())
        if ($summary.Length -gt 1200) {
            $summary = $summary.Substring(0, 1200) + "..."
        }
        throw "同步脚本退出码 $exitCode。`n$summary"
    }

    Show-Bar 98
    $jsonText = (($output).Trim())
    if ($jsonText) {
        try {
            $null = $jsonText | ConvertFrom-Json
        } catch {
            throw "同步完成但结果 JSON 解析失败。原始输出：`n$jsonText"
        }
    }

    Show-Bar 100 Green "正在启动 Codex"
    Start-Sleep -Milliseconds 350
    Open-Codex
    Start-Sleep -Milliseconds 250
    exit 0
} catch {
    Show-Bar 100 Red
    Write-Host "同步失败" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Wait-OnFailure
    exit 1
} finally {
    try {
        [Console]::SetCursorPosition(0, $script:footerLine + 2)
        [Console]::CursorVisible = $script:originalCursorVisible
    } catch {}
    try {
        $syncMutex.ReleaseMutex() | Out-Null
    } catch {}
    $syncMutex.Dispose()
}
