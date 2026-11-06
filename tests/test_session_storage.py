"""Run the embedded sync engine against synthetic provider and session data."""
import contextlib
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "sync-codex-history.ps1"


def load_engine():
    source = SCRIPT.read_text(encoding="utf-8-sig")
    embedded = source.split("$PythonCode = @'", 1)[1].split("\n'@", 1)[0]
    namespace = {"__name__": "sync_test"}
    exec(compile(embedded, str(SCRIPT), "exec"), namespace)
    return namespace


class SessionStorageTests(unittest.TestCase):
    def test_switches_preserve_paginated_sessions_and_recovery_backups(self):
        engine = load_engine()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            codex = root / "codex"
            codex.mkdir()
            cc_db = root / "cc-switch.db"
            settings = root / "settings.json"
            config_path = codex / "config.toml"
            config_path.write_text('model_provider = "transit"\n', encoding="utf8")

            with contextlib.closing(sqlite3.connect(cc_db)) as con, con:
                con.executescript("""
                    create table providers (
                        id text, name text, category text, app_type text,
                        settings_config text
                    );
                    create table settings (key text, value text);
                """)
                for provider_id, category in (("transit", None), ("official", "official")):
                    con.execute("insert into providers values (?, ?, ?, 'codex', ?)", (
                        provider_id, provider_id, category,
                        json.dumps({"config": 'model_provider = "transit"\n'}),
                    ))

            # New Codex files may have two UUIDs and nonzero ordinals.
            session_id = "11111111-1111-7111-8111-111111111111"
            page_id = "22222222-2222-7222-8222-222222222222"
            protected = {}
            for folder in ("sessions", "archived_sessions"):
                rollout = codex / folder / f"rollout-2026-11-03-{session_id}_{page_id}.jsonl"
                rollout.parent.mkdir()
                protected[rollout] = (json.dumps({
                    "ordinal": 17127, "type": "session_meta",
                    "payload": {"session_id": session_id, "history_mode": "paginated"},
                }) + "\n").encode()
            for name in ("state_5.sqlite", "state_5.sqlite-wal", "session_index.jsonl"):
                protected[codex / name] = b"private Codex data: do not open or rewrite\n"
            backup_root = codex / "history-sync-backups"
            recovery = backup_root / "20000101-session-repair" / "state_5.sqlite"
            legacy = backup_root / "20000101" / "rollout_session_meta_backup.jsonl"
            protected[recovery] = b"manual recovery snapshot"
            protected[legacy] = b"legacy metadata recovery snapshot"
            for path, content in protected.items():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            for day in range(2, 10):
                (backup_root / f"200001{day:02d}").mkdir()

            engine.update(CODEX_HOME=codex, CC_SWITCH_DB=cc_db,
                          CC_SWITCH_SETTINGS=settings, BACKUP_ROOT=backup_root)
            real_open = Path.open

            def guarded_open(path, *args, **kwargs):
                if path in protected:
                    raise AssertionError(f"sync accessed private session storage: {path}")
                return real_open(path, *args, **kwargs)

            for provider, target in (("transit", "ccs"), ("official", "openai"), ("transit", "ccs")):
                settings.write_text(json.dumps({"currentProviderCodex": provider}), encoding="utf8")
                output = io.StringIO()
                with patch.object(Path, "open", guarded_open), contextlib.redirect_stdout(output):
                    engine["main"]()
                summary = json.loads(output.getvalue())
                self.assertEqual(summary["session_storage"], "preserved")
                self.assertEqual(summary["target_model_provider"], target)
                self.assertIn(f'model_provider = "{target}"', config_path.read_text())
                for path, content in protected.items():
                    self.assertEqual(path.read_bytes(), content)


if __name__ == "__main__":
    unittest.main()
