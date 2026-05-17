param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" })
)

& (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "restore.ps1") -CodexHome $CodexHome
