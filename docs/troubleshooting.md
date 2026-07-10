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

## The model list still does not show GPT-5.6

For API-key / transit-provider routes, Codex Desktop may show a custom model label instead of a first-class GPT-5.6 preset. The sync script preserves the active top-level `model` and `model_reasoning_effort` from `~\.codex\config.toml`, and propagates them into legacy cc-switch provider configs that still contain older values such as `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, or `gpt-5.2`.

Check the active config:

```powershell
Get-Content "$env:USERPROFILE\.codex\config.toml" -TotalCount 8
```

Then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CODEX_HOME\sync-codex-history.ps1"
```

## Codex Desktop reports `token_expired`

If Codex Desktop crashes or reports:

```text
failed to refresh available models ... 401 Unauthorized ... token_expired
```

the cached ChatGPT web token inside the Codex Desktop Chromium profile is stale. Automatic cc-switch provider changes now close Codex, clear the stale web cache for transit providers, and restart Codex.

The cleanup also removes a user-level `CODEX_API_KEY` environment override, because that variable can silently override `~\.codex\auth.json`.

Manual UI sync uses a confirmation dialog. If you click **No**, the web cache cleanup is skipped until Codex is closed and the sync is run again.

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
