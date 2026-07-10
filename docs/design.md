# Design

## Core idea

Codex local history is not a single file. The visible session list depends on:

- rollout JSONL files under `~\.codex\sessions` and `~\.codex\archived_sessions`
- `~\.codex\state_5.sqlite`
- `~\.codex\session_index.jsonl`

When cc-switch changes the active Codex provider, the effective `model_provider` may change. This can make sessions appear split by provider. The tool scans cc-switch's current `providers` table at runtime, keeps official Codex providers as `openai`, and normalizes all non-official Codex providers to `ccs`.

Some cc-switch provider configs can also lag behind the current Codex config. For example, a provider may still contain an older top-level `model = "gpt-5.5"` after the user has moved to `gpt-5.6-*`. The sync step treats older known model IDs as legacy values and replaces them with the active defaults from `~\.codex\config.toml`, but only for providers in the same class as the current provider: transit defaults update transit configs, official defaults update official configs. Runtime defaults such as sandbox and approval mode are inherited only when they already exist in the active config; the tool does not hard-code permissive settings.

## Components

- `sync-codex-history.ps1`: performs backup, config normalization, rollout metadata repair, SQLite repair, and session index rebuild.
- `watch-cc-switch-codex-provider.ps1`: watches cc-switch provider changes and launches the UI wrapper in automatic mode. It does not hold the run mutex; the UI wrapper owns that lock.
- `run-codex-history-sync-ui.ps1`: shows a minimal progress window, closes Codex automatically when launched by the watcher, clears stale transit-provider auth cache when needed, runs sync, then starts Codex.
- `install.ps1`: installs scripts into Codex home and registers startup.
- `restore.ps1`: stops and removes the tool; optionally restores the latest install backup.

## Safety model

The first sync of each day creates a small backup under `~\.codex\history-sync-backups`.

When stale Codex Desktop web auth cache is cleared, the removed cache entries are copied to `~\.codex\web-cache-backups\history-sync-token-clear-*` first. Only the most recent five automatic token-cache backups are kept.

Install creates a separate backup under `~\.codex\history-sync-tool-backups`.

Restore is conservative by default: it disables the tool but does not overwrite Codex or cc-switch state unless `-RestoreLatestBackup` is provided and confirmed.

The tool does not copy `auth.json`, API keys, or login tokens into the repository or any cloud location. It may remove a user-level `CODEX_API_KEY` environment variable because Codex gives that override priority over `auth.json`.
