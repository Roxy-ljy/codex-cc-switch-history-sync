# Design

## Core idea

Codex local history is not a single file. The visible session list depends on:

- rollout JSONL files under `~\.codex\sessions` and `~\.codex\archived_sessions`
- `~\.codex\state_5.sqlite`
- `~\.codex\session_index.jsonl`

When cc-switch changes the active Codex provider, the effective `model_provider` may change. This can make sessions appear split by provider. The tool scans cc-switch's current `providers` table at runtime, keeps official Codex providers as `openai`, and normalizes all non-official Codex providers to `ccs`.

## Components

- `sync-codex-history.ps1`: performs backup, config normalization, rollout metadata repair, SQLite repair, and session index rebuild.
- `watch-cc-switch-codex-provider.ps1`: watches cc-switch provider changes and launches the UI wrapper.
- `run-codex-history-sync-ui.ps1`: shows a minimal progress window, optionally closes Codex, runs sync, then starts Codex.
- `install.ps1`: installs scripts into Codex home and registers startup.
- `restore.ps1`: stops and removes the tool; optionally restores the latest install backup.

## Safety model

The first sync of each day creates a small backup under `~\.codex\history-sync-backups`.

Install creates a separate backup under `~\.codex\history-sync-tool-backups`.

Restore is conservative by default: it disables the tool but does not overwrite Codex or cc-switch state unless `-RestoreLatestBackup` is provided and confirmed.
