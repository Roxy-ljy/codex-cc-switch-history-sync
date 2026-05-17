param(
    [string]$ProviderId
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

function Open-Codex {
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        Start-Process -FilePath $cmd.Source -ArgumentList "app" -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\codex-open.out" -RedirectStandardError "$env:TEMP\codex-open.err"
        return
    }

    try {
        Start-Process -FilePath "codex" -ArgumentList "app" -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\codex-open.out" -RedirectStandardError "$env:TEMP\codex-open.err"
        return
    } catch {}

    $codexExe = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin\codex.exe"
    if (Test-Path -LiteralPath $codexExe) {
        Start-Process -FilePath $codexExe -ArgumentList "app" -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\codex-open.out" -RedirectStandardError "$env:TEMP\codex-open.err"
    }
}

function Get-CodexProcesses {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.ProcessName -eq "Codex" -or $_.ProcessName -eq "codex") -and
            $_.Id -ne $PID
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
        "检测到 Codex 正在运行。切换中转前建议先关闭，避免旧 provider 状态残留。是否关闭 Codex？",
        "关闭 Codex？",
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

    if (Confirm-CloseCodex) {
        Close-Codex
        Show-Bar 5
    }

    $job = Start-Job -ScriptBlock {
        param([string]$ScriptPath)
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = ($out | Out-String)
        }
    } -ArgumentList $SyncScript

    $percent = 0
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
