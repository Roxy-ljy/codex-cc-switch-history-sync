param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$CcSwitchDb = Join-Path $env:USERPROFILE ".cc-switch\cc-switch.db"
$TmpDir = Join-Path $CodexHome ".tmp"
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null

$PythonCode = @'
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import time

CODEX_HOME = Path(os.environ.get("CODEX_HOME") or (Path.home() / ".codex"))
CC_SWITCH_DB = Path(os.environ.get("CC_SWITCH_DB") or (Path.home() / ".cc-switch" / "cc-switch.db"))
CC_SWITCH_SETTINGS = Path(os.environ.get("CC_SWITCH_SETTINGS") or (Path.home() / ".cc-switch" / "settings.json"))
BACKUP_ROOT = CODEX_HOME / "history-sync-backups"
KEEP_BACKUPS = 5
OFFICIAL_MODEL_PROVIDER = "openai"
TRANSIT_MODEL_PROVIDER = "ccs"
OFFICIAL_PROVIDER_IDS = None
LEGACY_MODEL_VALUES = {
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.2",
}

def log(msg):
    if os.environ.get("CODEX_HISTORY_SYNC_QUIET") != "1":
        print(msg)

def backup_sqlite(src, dst):
    src = Path(src)
    if not src.exists():
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    source = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    try:
        target = sqlite3.connect(str(dst))
        try:
            source.backup(target)
        finally:
            target.close()
    finally:
        source.close()
    return True

def make_backup():
    stamp = time.strftime("%Y%m%d")
    backup_dir = BACKUP_ROOT / stamp
    already_exists = backup_dir.exists()
    backup_dir.mkdir(parents=True, exist_ok=True)
    if not already_exists:
        # Session storage belongs to Codex, including paginated rollouts.
        for name in ("config.toml",):
            src = CODEX_HOME / name
            if src.exists():
                shutil.copy2(src, backup_dir / name)
        if CC_SWITCH_DB.exists():
            backup_sqlite(CC_SWITCH_DB, backup_dir / "cc-switch.db")
        if CC_SWITCH_SETTINGS.exists():
            shutil.copy2(CC_SWITCH_SETTINGS, backup_dir / "cc-switch-settings.json")
    # Keep legacy recovery snapshots and manually named repair directories.
    dirs = sorted([
        p for p in BACKUP_ROOT.iterdir()
        if p.is_dir() and re.fullmatch(r"\d{8}", p.name)
        and not (p / "state_5.sqlite").exists()
        and not (p / "rollout_session_meta_backup.jsonl").exists()
    ], key=lambda p: p.name, reverse=True)
    for old in dirs[KEEP_BACKUPS:]:
        shutil.rmtree(old, ignore_errors=True)
    return backup_dir

def strip_disable_storage(text):
    return re.sub(r"(?m)^\s*disable_response_storage\s*=\s*true\s*\r?\n?", "", text or "")

def ensure_history_save_all(text):
    text = text or ""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.strip() == "[history]":
            start = i
            break
    if start is None:
        if text and not text.endswith("\n"):
            text += "\n"
        return text + "\n[history]\npersistence = \"save-all\"\n"
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if re.match(r"^\s*\[.+\]\s*$", lines[j]):
            end = j
            break
    found = False
    for j in range(start + 1, end):
        if re.match(r"^\s*persistence\s*=", lines[j]):
            lines[j] = 'persistence = "save-all"'
            found = True
            break
    if not found:
        lines.insert(start + 1, 'persistence = "save-all"')
    return "\n".join(lines) + "\n"

def ensure_top_level_setting(text, key, value):
    text = text or ""
    lines = text.splitlines()
    pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=")
    first_table = len(lines)
    for i, line in enumerate(lines):
        if re.match(r"^\s*\[.+\]\s*$", line):
            first_table = i
            break
    for i in range(first_table):
        if pattern.match(lines[i]):
            lines[i] = f'{key} = "{value}"'
            return "\n".join(lines) + "\n"
    insert_at = first_table
    while insert_at > 0 and lines[insert_at - 1].strip() == "":
        insert_at -= 1
    lines.insert(insert_at, f'{key} = "{value}"')
    return "\n".join(lines) + "\n"

def top_level_setting(text, key):
    lines = (text or "").splitlines()
    pattern = re.compile(r"^\s*" + re.escape(key) + r'\s*=\s*"([^"]*)"\s*$')
    for line in lines:
        if re.match(r"^\s*\[.+\]\s*$", line):
            break
        m = pattern.match(line)
        if m:
            return m.group(1)
    return None

def current_model_defaults():
    path = CODEX_HOME / "config.toml"
    if not path.exists():
        return {}
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return {}
    return {
        "model": top_level_setting(text, "model"),
        "model_reasoning_effort": top_level_setting(text, "model_reasoning_effort"),
        "sandbox_mode": top_level_setting(text, "sandbox_mode"),
        "approval_policy": top_level_setting(text, "approval_policy"),
    }

def sync_model_defaults(text, defaults):
    text = text or ""
    model = (defaults or {}).get("model")
    if model:
        current_model = top_level_setting(text, "model")
        if not current_model or current_model in LEGACY_MODEL_VALUES:
            text = ensure_top_level_setting(text, "model", model)
    effort = (defaults or {}).get("model_reasoning_effort")
    if effort:
        current_effort = top_level_setting(text, "model_reasoning_effort")
        if not current_effort:
            text = ensure_top_level_setting(text, "model_reasoning_effort", effort)
    for key in ("sandbox_mode", "approval_policy"):
        value = (defaults or {}).get(key)
        if value and not top_level_setting(text, key):
            text = ensure_top_level_setting(text, key, value)
    return text

def active_provider_name(text):
    m = re.search(r'(?m)^\s*model_provider\s*=\s*"([^"]+)"\s*$', text or "")
    return m.group(1) if m else None

def current_codex_provider_id():
    if not CC_SWITCH_SETTINGS.exists():
        return None
    try:
        data = json.loads(CC_SWITCH_SETTINGS.read_text(encoding="utf-8"))
    except Exception:
        return None
    value = data.get("currentProviderCodex")
    return value if isinstance(value, str) and value else None

def is_official_provider_row(row):
    provider_id = (row["id"] or "").strip().lower()
    name = (row["name"] or "").strip().lower()
    keys = row.keys() if hasattr(row, "keys") else []
    category = ((row["category"] if "category" in keys else "") or "").strip().lower()
    return (
        provider_id == "codex-official"
        or category == "official"
        or (provider_id == "openai" and "official" in name)
    )

def official_provider_ids():
    global OFFICIAL_PROVIDER_IDS
    if OFFICIAL_PROVIDER_IDS is not None:
        return OFFICIAL_PROVIDER_IDS
    ids = set()
    if CC_SWITCH_DB.exists():
        try:
            con = sqlite3.connect(f"file:{CC_SWITCH_DB}?mode=ro", uri=True, timeout=5)
            con.row_factory = sqlite3.Row
            try:
                for row in con.execute("select id, name, category from providers where app_type='codex'"):
                    if is_official_provider_row(row):
                        ids.add(row["id"])
            finally:
                con.close()
        except Exception:
            pass
    ids.add("codex-official")
    OFFICIAL_PROVIDER_IDS = ids
    return OFFICIAL_PROVIDER_IDS

def target_provider_for_provider_id(provider_id):
    if provider_id in official_provider_ids():
        return OFFICIAL_MODEL_PROVIDER
    return TRANSIT_MODEL_PROVIDER

def target_provider_for_provider_row(row):
    if is_official_provider_row(row):
        return OFFICIAL_MODEL_PROVIDER
    return TRANSIT_MODEL_PROVIDER

def ensure_model_provider(text, provider):
    text = text or ""
    if re.search(r"(?m)^\s*model_provider\s*=", text):
        return re.sub(r'(?m)^\s*model_provider\s*=\s*"[^"]+"\s*$', f'model_provider = "{provider}"', text, count=1)
    return f'model_provider = "{provider}"\n' + text

def normalize_active_model_provider_block(text, target_provider):
    text = text or ""
    provider = active_provider_name(text)
    if not provider or provider == target_provider:
        return text
    pattern = r"(?m)^\[model_providers\." + re.escape(provider) + r"\]\s*$"
    return re.sub(pattern, f"[model_providers.{target_provider}]", text, count=1)

def normalize_codex_config(text, target_provider=None):
    text = strip_disable_storage(text)
    text = ensure_history_save_all(text)
    if target_provider:
        text = normalize_active_model_provider_block(text, target_provider)
        text = ensure_model_provider(text, target_provider)
    return text

def table_blocks(text):
    lines = (text or "").splitlines()
    starts = []
    for i, line in enumerate(lines):
        if re.match(r"^\s*\[[^\]]+\]\s*$", line):
            starts.append(i)
    blocks = {}
    prefixes = ("[projects.", "[plugins.", "[mcp_servers.", "[marketplaces.")
    for idx, start in enumerate(starts):
        end = starts[idx + 1] if idx + 1 < len(starts) else len(lines)
        header = lines[start].strip()
        if header.startswith(prefixes):
            blocks.setdefault(header, "\n".join(lines[start:end]).rstrip() + "\n")
    return blocks

def append_missing_blocks(text, union_blocks):
    existing = set(table_blocks(text).keys())
    add = [block for header, block in union_blocks.items() if header not in existing]
    if not add:
        return text
    if text and not text.endswith("\n"):
        text += "\n"
    return text + "\n" + "\n".join(add)

def normalize_cc_switch_db(current_provider_id, model_defaults=None):
    if not CC_SWITCH_DB.exists():
        return {"providers": 0, "changed": 0}
    current_target_provider = target_provider_for_provider_id(current_provider_id)
    con = sqlite3.connect(str(CC_SWITCH_DB), timeout=10)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout=10000")
    rows = list(con.execute("select id, name, category, settings_config from providers where app_type='codex'"))
    union = {}
    parsed = []
    for row in rows:
        cfg = json.loads(row["settings_config"] or "{}")
        text = cfg.get("config", "")
        union.update(table_blocks(text))
        parsed.append((row, cfg, text))
    changed = 0
    for row, cfg, old_text in parsed:
        target_provider = target_provider_for_provider_row(row)
        text = normalize_codex_config(old_text, target_provider=target_provider)
        if target_provider == current_target_provider:
            text = sync_model_defaults(text, model_defaults)
        text = append_missing_blocks(text, union)
        if text != old_text:
            cfg["config"] = text
            con.execute("update providers set settings_config=? where id=?", (json.dumps(cfg, ensure_ascii=False), row["id"]))
            changed += 1
    common = con.execute("select value from settings where key='common_config_codex'").fetchone()
    if common:
        new_common = normalize_codex_config(common["value"], target_provider=None)
        if new_common != common["value"]:
            con.execute("update settings set value=? where key='common_config_codex'", (new_common,))
            changed += 1
    con.commit()
    con.close()
    return {
        "providers": len(rows),
        "changed": changed,
        "current_provider_id": current_provider_id,
        "current_target_model_provider": current_target_provider,
    }

def normalize_current_config(current_provider_id, model_defaults=None):
    path = CODEX_HOME / "config.toml"
    if not path.exists():
        return False
    old = path.read_text(encoding="utf-8")
    new = normalize_codex_config(old, target_provider=target_provider_for_provider_id(current_provider_id))
    new = sync_model_defaults(new, model_defaults)
    if new != old:
        tmp = path.with_suffix(".toml.tmp")
        tmp.write_text(new, encoding="utf-8")
        os.replace(tmp, path)
        return True
    return False

def main():
    CODEX_HOME.mkdir(parents=True, exist_ok=True)
    current_provider_id = current_codex_provider_id()
    target_provider = target_provider_for_provider_id(current_provider_id)
    backup_dir = make_backup()
    model_defaults = current_model_defaults()
    cc = normalize_cc_switch_db(current_provider_id, model_defaults)
    config_changed = normalize_current_config(current_provider_id, model_defaults)
    log(json.dumps({
        "backup_dir": str(backup_dir),
        "auth_overrides_cleared": os.environ.get("CODEX_AUTH_OVERRIDES_CLEARED") == "1",
        "current_provider_id": current_provider_id,
        "target_model_provider": target_provider,
        "model_defaults": model_defaults,
        "cc_switch": cc,
        "config_changed": config_changed,
        "session_storage": "preserved",
    }, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
'@

$PyPath = Join-Path $TmpDir "sync-codex-history.py"
Set-Content -LiteralPath $PyPath -Value $PythonCode -Encoding UTF8

if ($Quiet) {
    $env:CODEX_HISTORY_SYNC_QUIET = "1"
} else {
    Remove-Item Env:\CODEX_HISTORY_SYNC_QUIET -ErrorAction SilentlyContinue
}

$authOverridesCleared = $false
try {
    if (Test-Path Env:\CODEX_API_KEY) {
        Remove-Item Env:\CODEX_API_KEY -ErrorAction SilentlyContinue
        $authOverridesCleared = $true
    }
} catch {}
try {
    if ([Environment]::GetEnvironmentVariable("CODEX_API_KEY", "User")) {
        [Environment]::SetEnvironmentVariable("CODEX_API_KEY", $null, "User")
        $authOverridesCleared = $true
    }
} catch {}

$env:CODEX_AUTH_OVERRIDES_CLEARED = if ($authOverridesCleared) { "1" } else { "0" }
$env:CODEX_HOME = $CodexHome
$env:CC_SWITCH_DB = $CcSwitchDb

python $PyPath
