# Troubleshooting

## The watcher does not start

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

Then check Task Manager for a hidden `powershell.exe` process running `watch-cc-switch-codex-provider.ps1`.

## Switching provider does not open the progress window

Make sure cc-switch updates one of these files:

- `~\.cc-switch\settings.json`
- `~\.cc-switch\cc-switch.db`

The watcher only triggers when the active Codex provider actually changes.

## Codex history is still missing

Run a manual sync:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CODEX_HOME\sync-codex-history.ps1"
```

If `CODEX_HOME` is not set, replace it with `~\.codex`.

## The progress window shows a PNG/libpng warning

That warning comes from Codex/Electron startup output. The UI wrapper redirects Codex startup output and clears the lower terminal area during progress refresh. If it still appears briefly, it should be cleared by the next refresh.

## I want to undo everything

Disable the tool:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore.ps1
```

Restore latest install backup:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore.ps1 -RestoreLatestBackup
```
