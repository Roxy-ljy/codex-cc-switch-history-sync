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

If only provider visibility changed, a manual configuration sync may help:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CODEX_HOME\sync-codex-history.ps1"
```

If `CODEX_HOME` is not set, replace it with `~\.codex`.

## `failed to read session metadata` / 无法加载消息

Older versions of this tool rewrote session metadata and rebuilt indexes using IDs derived from rollout filenames. This is incompatible with newer paginated Codex sessions.

1. Disable the watcher with `scripts/restore.ps1` (without `-RestoreLatestBackup`) and close Codex. Keep a copy of current session storage and backups before recovery.
2. Identify the daily backup immediately before the failed switch under `history-sync-backups`. A legacy backup may contain `rollout_session_meta_backup.jsonl`, `state_5.sqlite`, and `session_index.jsonl`.
3. Restore the recorded original metadata lines for the matching rollouts together with the matching SQLite state and index, while Codex is fully stopped. Preserve/quarantine the current SQLite database and its WAL/SHM together; replacing an open database or mixing old state with a current WAL is unsafe. Do not delete message content or infer IDs from filenames.
4. Install this version and reopen Codex. It preserves session storage on future switches.

The ordinary `-RestoreLatestBackup` option restores an *installation* backup, not the daily pre-switch metadata backup. Recovery must match the affected files and backup time; a fresh sync does not repair already corrupted metadata. Existing backups may contain secrets and should not be posted in issues.

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
