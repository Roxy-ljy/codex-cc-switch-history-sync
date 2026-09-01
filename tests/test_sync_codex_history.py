import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SYNC_SCRIPT = REPO_ROOT / "scripts" / "sync-codex-history.ps1"
SYNC_UI_SCRIPT = REPO_ROOT / "scripts" / "run-codex-history-sync-ui.ps1"
WATCHER_SCRIPT = REPO_ROOT / "scripts" / "watch-cc-switch-codex-provider.ps1"
THREAD_ID = "11111111-1111-1111-1111-111111111111"
TRANSIT_THREAD_ID = "22222222-2222-2222-2222-222222222222"


def embedded_python_source():
    text = SYNC_SCRIPT.read_text(encoding="utf-8")
    match = re.search(r"\$PythonCode = @'\r?\n(.*?)\r?\n'@", text, re.DOTALL)
    if not match:
        raise AssertionError("Could not find the embedded Python sync core")
    return match.group(1)


class SyncHistoryProviderTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.codex_home = self.root / ".codex"
        self.cc_switch_home = self.root / ".cc-switch"
        self.codex_home.mkdir()
        self.cc_switch_home.mkdir()
        self.provider_db = self.cc_switch_home / "cc-switch.db"
        self.settings_path = self.cc_switch_home / "settings.json"
        self.state_db = self.codex_home / "state_5.sqlite"
        self.rollout_path = self._rollout_path(THREAD_ID)
        self.core_path = self.root / "sync_core.py"
        self.core_path.write_text(embedded_python_source(), encoding="utf-8")
        self._create_provider_db("codex-official")
        self._write_settings("codex-official")
        self._write_config("ccs")
        self._create_state_db("ccs")
        self._write_rollout("ccs")

    def _rollout_path(self, thread_id):
        return (
            self.codex_home
            / "sessions"
            / "2026"
            / "01"
            / "01"
            / f"rollout-2026-01-01T00-00-00-{thread_id}.jsonl"
        )

    def tearDown(self):
        self.temp_dir.cleanup()

    @staticmethod
    def _provider_config(provider):
        return json.dumps(
            {
                "config": (
                    f'model_provider = "{provider}"\n'
                    'model = "gpt-5.6-codex"\n'
                    'model_reasoning_effort = "high"\n\n'
                    f"[model_providers.{provider}]\n"
                    f'name = "{provider}"\n'
                )
            }
        )

    def _create_provider_db(self, current_provider):
        con = sqlite3.connect(self.provider_db)
        try:
            con.executescript(
                """
                create table providers (
                    id text primary key,
                    name text,
                    category text,
                    settings_config text,
                    app_type text,
                    is_current integer
                );
                create table settings (key text primary key, value text);
                """
            )
            con.executemany(
                """
                insert into providers
                (id, name, category, settings_config, app_type, is_current)
                values (?, ?, ?, ?, 'codex', ?)
                """,
                [
                    (
                        "codex-official",
                        "OpenAI Official",
                        "official",
                        self._provider_config("openai"),
                        int(current_provider == "codex-official"),
                    ),
                    (
                        "transit-one",
                        "Transit One",
                        "custom",
                        self._provider_config("ccs"),
                        int(current_provider == "transit-one"),
                    ),
                ],
            )
            con.commit()
        finally:
            con.close()

    def _set_db_provider(self, provider_id):
        con = sqlite3.connect(self.provider_db)
        try:
            con.execute("update providers set is_current=0 where app_type='codex'")
            if provider_id:
                con.execute(
                    "update providers set is_current=1 where app_type='codex' and id=?",
                    (provider_id,),
                )
            con.commit()
        finally:
            con.close()

    def _write_settings(self, provider_id):
        self.settings_path.write_text(
            json.dumps({"currentProviderCodex": provider_id}), encoding="utf-8"
        )

    def _write_config(self, provider):
        (self.codex_home / "config.toml").write_text(
            (
                f'model_provider = "{provider}"\n'
                'model = "gpt-5.6-codex"\n'
                'model_reasoning_effort = "high"\n\n'
                f"[model_providers.{provider}]\n"
                f'name = "{provider}"\n'
            ),
            encoding="utf-8",
        )

    def _create_state_db(self, provider):
        con = sqlite3.connect(self.state_db)
        try:
            con.execute(
                """
                create table threads (
                    id text primary key,
                    rollout_path text,
                    created_at integer,
                    updated_at integer,
                    source text,
                    model_provider text,
                    cwd text,
                    title text,
                    sandbox_policy text,
                    approval_mode text,
                    tokens_used integer,
                    has_user_event integer,
                    archived integer,
                    archived_at integer,
                    cli_version text,
                    first_user_message text,
                    model text,
                    reasoning_effort text,
                    created_at_ms integer,
                    updated_at_ms integer,
                    thread_source text,
                    preview text
                )
                """
            )
            con.execute(
                "insert into threads (id, title, model_provider, updated_at) values (?, ?, ?, ?)",
                (THREAD_ID, "Fixture session", provider, 1767225600),
            )
            con.commit()
        finally:
            con.close()

    def _write_rollout(self, provider, thread_id=THREAD_ID, title="Fixture session"):
        rollout_path = self._rollout_path(thread_id)
        rollout_path.parent.mkdir(parents=True, exist_ok=True)
        rows = [
            {
                "timestamp": "2026-01-01T00:00:00Z",
                "type": "session_meta",
                "payload": {
                    "id": thread_id,
                    "timestamp": "2026-01-01T00:00:00Z",
                    "model_provider": provider,
                    "cwd": str(self.root),
                    "source": "vscode",
                    "model": "gpt-5.6-codex",
                },
            },
            {
                "timestamp": "2026-01-01T00:00:01Z",
                "type": "event_msg",
                "payload": {"type": "user_message", "message": title},
            },
        ]
        rollout_path.write_text(
            "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
        )
        return rollout_path

    def _run_core(self, provider_override=None):
        env = os.environ.copy()
        env.update(
            {
                "CODEX_HOME": str(self.codex_home),
                "CC_SWITCH_DB": str(self.provider_db),
                "CC_SWITCH_SETTINGS": str(self.settings_path),
                "CODEX_HISTORY_SYNC_QUIET": "1",
            }
        )
        if provider_override:
            env["CODEX_HISTORY_SYNC_PROVIDER_ID"] = provider_override
        else:
            env.pop("CODEX_HISTORY_SYNC_PROVIDER_ID", None)
        return subprocess.run(
            [sys.executable, str(self.core_path)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def _state_provider(self, thread_id=THREAD_ID):
        con = sqlite3.connect(self.state_db)
        try:
            return con.execute(
                "select model_provider from threads where id=?", (thread_id,)
            ).fetchone()[0]
        finally:
            con.close()

    def _rollout_provider(self, rollout_path=None):
        with (rollout_path or self.rollout_path).open("r", encoding="utf-8") as stream:
            return json.loads(next(stream))["payload"]["model_provider"]

    def _config_provider(self):
        text = (self.codex_home / "config.toml").read_text(encoding="utf-8")
        match = re.search(r'^\s*model_provider\s*=\s*"([^"]+)"', text, re.MULTILINE)
        self.assertIsNotNone(match)
        return match.group(1)

    def _index_thread_ids(self):
        index_path = self.codex_home / "session_index.jsonl"
        with index_path.open("r", encoding="utf-8") as stream:
            return {json.loads(line)["id"] for line in stream if line.strip()}

    def _index_rows(self):
        index_path = self.codex_home / "session_index.jsonl"
        with index_path.open("r", encoding="utf-8") as stream:
            return {
                row["id"]: row
                for line in stream
                if line.strip()
                for row in (json.loads(line),)
            }

    def _assert_history_provider(self, expected):
        self.assertEqual(expected, self._state_provider())
        self.assertEqual(expected, self._rollout_provider())
        self.assertEqual(expected, self._config_provider())

    def _assert_history_visible(self, expected):
        self._assert_history_provider(expected)
        self.assertIn(THREAD_ID, self._index_thread_ids())

    def test_round_trip_rewrites_rollout_and_state_in_both_directions(self):
        result = self._run_core()
        self.assertEqual(0, result.returncode, result.stderr)
        self._assert_history_visible("openai")

        self._set_db_provider("transit-one")
        self._write_settings("transit-one")
        result = self._run_core()
        self.assertEqual(0, result.returncode, result.stderr)
        self._assert_history_visible("ccs")

        self._set_db_provider("codex-official")
        self._write_settings("codex-official")
        result = self._run_core()
        self.assertEqual(0, result.returncode, result.stderr)
        self._assert_history_visible("openai")

        rollout_before = self.rollout_path.read_bytes()
        result = self._run_core()
        self.assertEqual(0, result.returncode, result.stderr)
        self._assert_history_visible("openai")
        self.assertEqual(rollout_before, self.rollout_path.read_bytes())

    def test_transit_created_rollout_is_visible_after_switching_to_official(self):
        result = self._run_core()
        self.assertEqual(0, result.returncode, result.stderr)

        self._set_db_provider("transit-one")
        self._write_settings("transit-one")
        result = self._run_core()
        self.assertEqual(0, result.returncode, result.stderr)

        transit_rollout = self._write_rollout(
            "ccs", TRANSIT_THREAD_ID, "Transit-created session"
        )
        original_message = transit_rollout.read_text(encoding="utf-8").splitlines()[1]

        self._set_db_provider("codex-official")
        self._write_settings("codex-official")
        result = self._run_core()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("openai", self._state_provider(THREAD_ID))
        self.assertEqual("openai", self._state_provider(TRANSIT_THREAD_ID))
        self.assertEqual("openai", self._rollout_provider(self.rollout_path))
        self.assertEqual("openai", self._rollout_provider(transit_rollout))
        index_rows = self._index_rows()
        self.assertEqual({THREAD_ID, TRANSIT_THREAD_ID}, set(index_rows))
        self.assertEqual(
            "Transit-created session", index_rows[TRANSIT_THREAD_ID]["thread_name"]
        )
        self.assertEqual(
            original_message,
            transit_rollout.read_text(encoding="utf-8").splitlines()[1],
        )

    def test_database_current_provider_wins_when_settings_is_stale(self):
        self._write_settings("transit-one")
        result = self._run_core()
        self.assertEqual(0, result.returncode, result.stderr)
        self._assert_history_provider("openai")

    def test_database_current_provider_wins_over_stale_explicit_id(self):
        result = self._run_core(provider_override="transit-one")
        self.assertEqual(0, result.returncode, result.stderr)
        self._assert_history_provider("openai")

    def test_explicit_provider_id_is_used_when_database_has_no_current_row(self):
        self._set_db_provider(None)
        result = self._run_core(provider_override="transit-one")
        self.assertEqual(0, result.returncode, result.stderr)
        self._assert_history_provider("ccs")

    def test_unknown_explicit_provider_fails_without_changes(self):
        self._set_db_provider(None)
        config_before = (self.codex_home / "config.toml").read_bytes()
        rollout_before = self.rollout_path.read_bytes()

        result = self._run_core(provider_override="typo-provider")

        self.assertNotEqual(0, result.returncode)
        self.assertIn("was not found in cc-switch.db", result.stderr)
        self.assertEqual(config_before, (self.codex_home / "config.toml").read_bytes())
        self.assertEqual(rollout_before, self.rollout_path.read_bytes())
        self._assert_history_provider("ccs")
        self.assertFalse((self.codex_home / "history-sync-backups").exists())

    def test_missing_provider_fails_before_history_is_changed(self):
        self._set_db_provider(None)
        self.settings_path.unlink()
        config_before = (self.codex_home / "config.toml").read_bytes()
        before = self.rollout_path.read_bytes()

        result = self._run_core()

        self.assertNotEqual(0, result.returncode)
        self.assertIn("Unable to determine the active Codex provider", result.stderr)
        self.assertEqual(config_before, (self.codex_home / "config.toml").read_bytes())
        self.assertEqual(before, self.rollout_path.read_bytes())
        self._assert_history_provider("ccs")
        self.assertFalse((self.codex_home / "history-sync-backups").exists())

    def test_powershell_wrapper_preserves_provider_and_validates_before_auth_cleanup(self):
        sync_text = SYNC_SCRIPT.read_text(encoding="utf-8")
        ui_text = SYNC_UI_SCRIPT.read_text(encoding="utf-8")
        watcher_text = WATCHER_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("$env:CODEX_HISTORY_SYNC_PROVIDER_ID = $ProviderId", sync_text)
        self.assertIn("-ProviderId $TargetProviderId", ui_text)
        self.assertIn('return $providerClass -eq "transit"', ui_text)
        self.assertIn('"cc-switch.db-wal"', watcher_text)
        self.assertLess(
            sync_text.index('$env:CODEX_HISTORY_SYNC_VALIDATE_ONLY = "1"'),
            sync_text.index('[Environment]::SetEnvironmentVariable("CODEX_API_KEY"'),
        )


if __name__ == "__main__":
    unittest.main()
