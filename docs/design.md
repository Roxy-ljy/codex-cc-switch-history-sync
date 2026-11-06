# Design

## Core idea

Codex local history is not a single file. The visible session list depends on:

- rollout JSONL files under `~\.codex\sessions` and `~\.codex\archived_sessions`
- `~\.codex\state_5.sqlite`
- `~\.codex\session_index.jsonl`

When cc-switch changes the active Codex provider, the effective `model_provider` may change. This can make sessions appear split by provider. The tool scans cc-switch's current `providers` table at runtime, keeps official Codex providers as `openai`, and normalizes all non-official Codex providers to `ccs`.

Some cc-switch provider configs can also lag behind the current Codex config. For example, a provider may still contain an older top-level `model = "gpt-5.5"` after the user has moved to `gpt-5.6-*`. The sync step treats older known model IDs as legacy values and replaces them with the active defaults from `~\.codex\config.toml`, but only for providers in the same class as the current provider: transit defaults update transit configs, official defaults update official configs. Runtime defaults such as sandbox and approval mode are inherited only when they already exist in the active config; the tool does not hard-code permissive settings.

## Components

- `sync-codex-history.ps1`: backs up provider configuration and normalizes config files. It never reads or writes Codex session storage.
- `watch-cc-switch-codex-provider.ps1`: watches cc-switch provider changes and launches the UI wrapper in automatic mode. It does not hold the run mutex; the UI wrapper owns that lock.
- `run-codex-history-sync-ui.ps1`: shows a minimal progress window, closes Codex automatically when launched by the watcher, clears stale transit-provider auth cache when needed, runs sync, then starts Codex.
- `install.ps1`: installs scripts into Codex home and registers startup.
- `restore.ps1`: stops and removes the tool; optionally restores the latest install backup.

## Safety model

The first sync of each day backs up `config.toml` and cc-switch configuration under `~\.codex\history-sync-backups`. Rotation retains five configuration-only daily backups; legacy recovery snapshots containing state/metadata and manually named repair directories are preserved.

Codex owns rollout identities, paginated history, SQLite state, and the session index. A filename may contain a session UUID plus a page UUID; splitting its last five hyphen-separated parts does not yield a valid session ID. The old metadata mutation and index reconstruction helpers have been removed. Preserving storage avoids this corruption but does not guarantee provider-independent visibility of all existing sessions.

Run the synthetic regression check with `python -m unittest discover -s tests -v`. It switches transit/official/transit providers and checks that paginated rollout bytes, state files, session index, and recovery snapshots remain untouched.

When stale Codex Desktop web auth cache is cleared, the removed cache entries are copied to `~\.codex\web-cache-backups\history-sync-token-clear-*` first. Only the most recent five automatic token-cache backups are kept.

Install creates a separate backup under `~\.codex\history-sync-tool-backups`.

Restore is conservative by default: it disables the tool but does not overwrite Codex or cc-switch state unless `-RestoreLatestBackup` is provided and confirmed.

The tool does not upload local data. Configuration/database/cache backups can contain credentials and must remain private. It may remove a user-level `CODEX_API_KEY` environment variable because Codex gives that override priority over `auth.json`.
