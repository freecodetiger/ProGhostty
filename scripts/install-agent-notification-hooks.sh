#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"
CLAUDE_HOME_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
PROGHOSTTY_HOOKS_DIR="${PROGHOSTTY_HOOKS_DIR:-${HOME}/.proghostty/hooks}"

CODEX_HOOK_SCRIPT="${PROGHOSTTY_HOOKS_DIR}/codex_stop_notify.sh"
CLAUDE_HOOK_SCRIPT="${PROGHOSTTY_HOOKS_DIR}/claude_stop_notify.sh"
NOTIFY_HELPER_SCRIPT="${PROGHOSTTY_HOOKS_DIR}/notify_agent.sh"
PG_HELPER_PATH_FILE="${PROGHOSTTY_HOOKS_DIR}/pg-helper-path"

shell_quote() {
  printf "'"
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

CODEX_HOOK_COMMAND="/bin/sh $(shell_quote "${CODEX_HOOK_SCRIPT}")"
CLAUDE_HOOK_COMMAND="/bin/sh $(shell_quote "${CLAUDE_HOOK_SCRIPT}")"

PG_HELPER_PATH="$(command -v pg || true)"
if [ -z "${PG_HELPER_PATH}" ]; then
  if [ -d "${ROOT_DIR}/.build" ]; then
    PG_HELPER_PATH="$(
      find "${ROOT_DIR}/.build" -path '*/ProGhostty.app/Contents/MacOS/pg' -type f -perm -111 2>/dev/null | head -1 || true
    )"
  fi
fi

mkdir -p \
  "${ROOT_DIR}/.codex/hooks" \
  "${ROOT_DIR}/.claude/hooks" \
  "${CODEX_HOME_DIR}" \
  "${CLAUDE_HOME_DIR}" \
  "${PROGHOSTTY_HOOKS_DIR}"

cat >"${NOTIFY_HELPER_SCRIPT}" <<'SH'
#!/bin/sh

title="${1:-ProGhostty}"
body="${2:-Waiting for input}"
hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

dedupe_root="${TMPDIR:-/tmp}/proghostty-agent-notify-${USER:-user}"
mkdir -p "$dedupe_root" 2>/dev/null || true

dedupe_key=$(printf '%s:%s:%s' "${PWD:-}" "$title" "$body" | cksum | awk '{print $1}')
dedupe_file="$dedupe_root/$dedupe_key"
now=$(date +%s)
last=
if [ -r "$dedupe_file" ]; then
  last=$(cat "$dedupe_file" 2>/dev/null || true)
fi

if [ "$last" = "$now" ]; then
  exit 0
fi

printf '%s\n' "$now" >"$dedupe_file" 2>/dev/null || true

pg_helper=$(cat "$hook_dir/pg-helper-path" 2>/dev/null || true)
if command -v pg >/dev/null 2>&1; then
  pg notify --title "$title" --body "$body" >/dev/null 2>&1 || true
elif [ -n "$pg_helper" ] && [ -x "$pg_helper" ]; then
  "$pg_helper" notify --title "$title" --body "$body" >/dev/null 2>&1 || true
fi
SH

printf '%s\n' "${PG_HELPER_PATH}" >"${PG_HELPER_PATH_FILE}"

cat >"${CODEX_HOOK_SCRIPT}" <<'SH'
#!/bin/sh

hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
/bin/sh "$hook_dir/notify_agent.sh" "Codex" "Waiting for input"

printf '{"continue":true}\n'
SH

cat >"${CLAUDE_HOOK_SCRIPT}" <<'SH'
#!/bin/sh

hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
/bin/sh "$hook_dir/notify_agent.sh" "Claude Code" "Waiting for input"
SH

cat >"${ROOT_DIR}/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/bin/sh \"${PROGHOSTTY_HOOKS_DIR:-$HOME/.proghostty/hooks}/codex_stop_notify.sh\""
          }
        ]
      }
    ]
  }
}
JSON

cat >"${ROOT_DIR}/.codex/hooks/proghostty_codex_stop_notify.sh" <<'SH'
#!/bin/sh

/bin/sh "${PROGHOSTTY_HOOKS_DIR:-$HOME/.proghostty/hooks}/codex_stop_notify.sh"
SH

cat >"${ROOT_DIR}/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/bin/sh \"${PROGHOSTTY_HOOKS_DIR:-$HOME/.proghostty/hooks}/claude_stop_notify.sh\""
          }
        ]
      }
    ]
  }
}
JSON

cat >"${ROOT_DIR}/.claude/hooks/proghostty_claude_stop_notify.sh" <<'SH'
#!/bin/sh

/bin/sh "${PROGHOSTTY_HOOKS_DIR:-$HOME/.proghostty/hooks}/claude_stop_notify.sh"
SH

chmod +x \
  "${NOTIFY_HELPER_SCRIPT}" \
  "${CODEX_HOOK_SCRIPT}" \
  "${CLAUDE_HOOK_SCRIPT}" \
  "${ROOT_DIR}/.codex/hooks/proghostty_codex_stop_notify.sh" \
  "${ROOT_DIR}/.claude/hooks/proghostty_claude_stop_notify.sh"

export CODEX_HOOKS_JSON="${CODEX_HOME_DIR}/hooks.json"
export CLAUDE_SETTINGS_JSON="${CLAUDE_HOME_DIR}/settings.json"
export CODEX_HOOK_COMMAND
export CLAUDE_HOOK_COMMAND

python3 <<'PY'
import json
import os
import shutil
import time
from pathlib import Path


def load_json_object(path):
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise SystemExit(f"{path} must contain a JSON object")
    return value


def backup(path):
    if path.exists():
        suffix = time.strftime("%Y%m%d%H%M%S")
        shutil.copy2(path, path.with_name(f"{path.name}.proghostty.bak.{suffix}"))


def ensure_hook(settings, event, command, matcher, script_name):
    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise SystemExit("'hooks' must be a JSON object")

    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list):
        raise SystemExit(f"'hooks.{event}' must be a JSON array")

    changed = False
    exact_present = False
    next_groups = []
    for group in groups:
        if not isinstance(group, dict):
            next_groups.append(group)
            continue
        handlers = group.get("hooks", [])
        if not isinstance(handlers, list):
            next_groups.append(group)
            continue
        next_handlers = []
        removed_from_group = False
        for handler in handlers:
            if not isinstance(handler, dict):
                next_handlers.append(handler)
                continue
            handler_command = handler.get("command", "")
            if handler_command == command:
                exact_present = True
                next_handlers.append(handler)
            elif script_name in handler_command:
                changed = True
                removed_from_group = True
            else:
                next_handlers.append(handler)
        if next_handlers or not removed_from_group:
            if next_handlers != handlers:
                group = dict(group)
                group["hooks"] = next_handlers
            next_groups.append(group)
    if next_groups != groups:
        hooks[event] = next_groups
        groups = next_groups

    if exact_present:
        return changed

    group = {
        "hooks": [
            {
                "type": "command",
                "command": command,
            }
        ]
    }
    if matcher is not None:
        group["matcher"] = matcher
    groups.append(group)
    return True


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(tmp, path)


codex_path = Path(os.environ["CODEX_HOOKS_JSON"])
claude_path = Path(os.environ["CLAUDE_SETTINGS_JSON"])

codex = load_json_object(codex_path)
claude = load_json_object(claude_path)

codex_changed = ensure_hook(
    codex,
    "Stop",
    os.environ["CODEX_HOOK_COMMAND"],
    matcher=None,
    script_name="codex_stop_notify.sh",
)
claude_changed = ensure_hook(
    claude,
    "Stop",
    os.environ["CLAUDE_HOOK_COMMAND"],
    matcher="",
    script_name="claude_stop_notify.sh",
)

if codex_changed:
    backup(codex_path)
    write_json(codex_path, codex)
if claude_changed:
    backup(claude_path)
    write_json(claude_path, claude)

print(f"Codex user hook: {'installed' if codex_changed else 'already present'} -> {codex_path}")
print(f"Claude Code user hook: {'installed' if claude_changed else 'already present'} -> {claude_path}")
PY

printf 'ProGhostty agent notification hooks are installed for user-level Codex and Claude Code sessions.\n'
