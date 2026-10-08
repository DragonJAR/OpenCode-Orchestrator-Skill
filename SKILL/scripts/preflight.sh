#!/bin/sh
# Preflight: one-shot discovery of the OpenCode V2 instance for orchestration runs.
# Emits: endpoint, version, server pid, /openapi.json guard, canonical directory,
# projectID, agent catalogs by mode, default model pair (orchestrator profile),
# root session hint. Never prints credentials. No hardcoded models, endpoints or
# paths: everything is resolved from the live instance at run time.
# Dependencies: POSIX sh, awk, curl, tr. Works on any OS supporting opencode V2
# (Git Bash/WSL included; LF line endings enforced by .gitattributes).
# Usage: preflight.sh [directory]   (default: $PWD)
# Env:   OPENCODE_CLI (default opencode), OPENCODE_STATE_ROOT,
#        OPENCODE_SESSION_ID (root session hint when orchestrating in-session).
# Exit codes: 0 = ok, 1 = discovery failure, 2 = usage/environment error.
set -u
# shellcheck disable=SC1007  # CDPATH= cd ... | pwd -- the space after = is part of the command substitution syntax (false positive: shellcheck treats = as plain assignment).
# shellcheck source-path=scripts
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DIR="${1:-$PWD}"
CLI="${OPENCODE_CLI:-opencode}"
STATE_ROOT="${OPENCODE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/opencode}"
# Prefer the CLI (OS-agnostic); the state-root fallback covers CLI-less setups.
if command -v "$CLI" >/dev/null 2>&1; then
  SR=$("$CLI" debug paths state 2>/dev/null | head -1)
  [ -n "$SR" ] && [ -d "$SR" ] && STATE_ROOT="$SR"
fi
REG="$STATE_ROOT/service.json"

# 1) endpoint + version: prefer CLI, else active registration under state root
URL=""; VERSION=""
if command -v "$CLI" >/dev/null 2>&1; then
  URL=$("$CLI" service status 2>/dev/null | awk '/^https?:\/\//{print $1; exit}')
fi
if [ -z "$URL" ] && [ -f "$REG" ]; then
  URL=$(awk 'match($0,/"url":"https?:[^"]+/){print substr($0,RSTART+7,RLENGTH-7); exit}' "$REG" | tr -d '\\')
  VERSION=$(awk 'match($0,/"version":"[^"]+/){print substr($0,RSTART+11,RLENGTH-11); exit}' "$REG")
fi
[ -n "$URL" ] || { printf '%s\n' "ERROR: no endpoint (CLI with no active service nor $REG)"; exit 1; }
case "$URL" in
  http://127.0.0.1*|http://localhost*|https://*) ;;
  *) printf '%s\n' "ERROR: non-loopback/https endpoint: rejected"; exit 1 ;;
esac
printf 'endpoint=%s\n' "$URL"

# 2) auth: registration password, else config (never echoed)
AUTH=""
PW=""
[ -f "$REG" ] && PW=$(awk 'match($0,/"password":"[^"]+/){print substr($0,RSTART+12,RLENGTH-12); exit}' "$REG" 2>/dev/null)
[ -z "$PW" ] && [ -f "$HOME/.config/opencode/service.json" ] && \
  PW=$(awk 'match($0,/"password":"[^"]+/){print substr($0,RSTART+12,RLENGTH-12); exit}' "$HOME/.config/opencode/service.json")
[ -n "$PW" ] && AUTH="-u opencode:$PW"

# 3) /api/info (version/pid) + openapi guard (an HTML body is not a schema)
INFO=$(curl -s -m 10 "$AUTH" "$URL/api/info" | tr -d ' \n')
[ -n "$VERSION" ] || VERSION=$(printf '%s' "$INFO" | awk 'match($0,/"version":"[^"]+/){print substr($0,RSTART+11,RLENGTH-11); exit}')
PID=$(printf '%s' "$INFO" | awk 'match($0,/"pid":[0-9]+/){print substr($0,RSTART+6,RLENGTH-6); exit}')
printf 'version=%s\nserver_pid=%s\n' "$VERSION" "${PID:-unknown}"
SCHEMA=$(curl -s -m 10 "$AUTH" "$URL/openapi.json" | tr -d ' \n' | awk 'match($0,/"openapi":"[^"]+/){print substr($0,RSTART+11,RLENGTH-11); exit}')
case "$SCHEMA" in
  3.*) printf 'openapi=%s\n' "$SCHEMA" ;;
  *) printf '%s\n' "ERROR: /openapi.json is not a valid schema (HTML or empty)"; exit 1 ;;
esac

# 4) canonical location + projectID for DIR (deepObject query)
LOC=$(curl -s -m 10 -G "$AUTH" "$URL/api/location" --data-urlencode "location[directory]=$DIR" | tr -d ' \n')
CANON=$(printf '%s' "$LOC" | awk 'match($0,/"canonical":"[^"]+/){print substr($0,RSTART+13,RLENGTH-13); exit}')
PROJ=$(printf '%s' "$LOC" | awk 'match($0,/"project":\{"id":"[^"]+/){print substr($0,RSTART+17,RLENGTH-17); exit}')
printf 'canonical_directory=%s\nprojectID=%s\n' "$CANON" "${PROJ:-none}"

# 5) agent catalog split by mode (records are split at boundaries; first id per record)
AG=$(curl -s -m 10 "$AUTH" "$URL/api/agent" | tr -d ' \n')
P=$(printf '%s' "$AG" | sed 's/},{"id":"/\n{"id":"/g' | awk '/"mode":"primary"/{if(match($0,/"id":"[^"]+"/))print substr($0,RSTART+6,RLENGTH-7)}' | paste -sd, -)
S=$(printf '%s' "$AG" | sed 's/},{"id":"/\n{"id":"/g' | awk '/"mode":"subagent"/{if(match($0,/"id":"[^"]+"/))print substr($0,RSTART+6,RLENGTH-7)}' | paste -sd, -)
printf 'agents_primary=%s\nagents_subagent=%s\n' "${P:-none}" "${S:-none}"

# 6) default model pair (orchestrator profile; resolves exact ids, never hardcoded)
MD=$(curl -s -m 10 "$AUTH" "$URL/api/model/default" | tr -d ' \n')
MID=$(printf '%s' "$MD" | awk 'match($0,/"modelID":"[^"]+/){print substr($0,RSTART+11,RLENGTH-11); exit}')
PROV=$(printf '%s' "$MD" | awk 'match($0,/"providerID":"[^"]+/){print substr($0,RSTART+14,RLENGTH-14); exit}')
printf 'model_default=%s@%s\n' "${MID:-none}" "${PROV:-none}"

# 7) root session hint
if [ -n "${OPENCODE_SESSION_ID:-}" ]; then
  printf 'root_session_hint=%s (env)\n' "$OPENCODE_SESSION_ID"
  if [ -n "${ORCHESTRATE_CACHE_DIR:-}" ]; then
    # Caches the orchestrator root: init-run REUSES it instead of trying to
    # create another one, which collided with the live orchestrator session
    # (fail-closed on collision and the run aborted having done nothing).
    printf '%s\n' "$OPENCODE_SESSION_ID" > "$ORCHESTRATE_CACHE_DIR/root_session_hint" 2>/dev/null || :
  fi
else
  printf '%s\n' "root_session_hint=none (orchestrator is external; create a root session or record TUI session)"
fi

# 7b) TUI/tabs gate (recipe-tui-tabs.md §3/§6). The gate becomes DATA, not an
# orchestrator judgment: init-run decides on its own and its reason stays in the output.
TUI_DETECT="$SELF_DIR/os/tui-detect.sh"
if [ -f "$TUI_DETECT" ]; then
  # The pin belongs to the detector (branch major) and only to it: passing a
  # version with minor/patch here made it fail with exit 2, and the
  # 2>/dev/null turned that error into an empty gate. One single pin owner (DRY).
  TUI_OUT=$(sh "$TUI_DETECT" "$CANON" 2>/dev/null)
  if [ -z "$TUI_OUT" ]; then
    printf '%s\n' 'gate=blocked' 'gate_reason=tui-detect.sh returned no output; run sh os/tui-detect.sh to see the error'
  else
    printf '%s\n' "$TUI_OUT" | grep -E '^(tui_pids|tui_cwd|tui_cwd_match|tui_channel|tabs_json|tui_version|version_ok|gate|gate_reason)='
  fi
else
  printf '%s\n' 'gate=blocked' 'gate_reason=tui-detect.sh missing from the package'
fi

# 8) optional cache for orchestrate.sh (secret only to a chmod 600 file; never to stdout)
if [ -n "${ORCHESTRATE_CACHE_DIR:-}" ]; then
  mkdir -p "$ORCHESTRATE_CACHE_DIR" 2>/dev/null || { printf '%s\n' "ERROR: cannot create cache dir" >&2; exit 1; }
  printf '%s\n' "$URL"      > "$ORCHESTRATE_CACHE_DIR/endpoint"
  printf '%s\n' "$VERSION"  > "$ORCHESTRATE_CACHE_DIR/version"
  printf '%s\n' "${PID:-}"  > "$ORCHESTRATE_CACHE_DIR/server_pid"
  printf '%s\n' "$CANON"    > "$ORCHESTRATE_CACHE_DIR/canonical_directory"
  printf '%s\n' "${PROJ:-}" > "$ORCHESTRATE_CACHE_DIR/projectID"
  printf '%s\n' "${MID:-}@${PROV:-}" > "$ORCHESTRATE_CACHE_DIR/model_default"
  case "$P" in ""|none) : ;; *) printf '%s\n' "${P%%,*}" > "$ORCHESTRATE_CACHE_DIR/default_agent" ;; esac
  if [ -n "$PW" ]; then
    printf '%s\n' "$PW" > "$ORCHESTRATE_CACHE_DIR/auth_password"
    chmod 600 "$ORCHESTRATE_CACHE_DIR/auth_password" 2>/dev/null || :
  fi
  # Caches the tabs gate: init-run reads it and decides without asking for --tui-cwd.
  if [ -f "$TUI_DETECT" ]; then
    printf '%s\n' "$TUI_OUT" | grep -E '^gate='          > "$ORCHESTRATE_CACHE_DIR/tabs_gate" 2>/dev/null || :
    printf '%s\n' "$TUI_OUT" | grep -E '^tui_cwd='        > "$ORCHESTRATE_CACHE_DIR/tabs_cwd" 2>/dev/null || :
    printf '%s\n' "$TUI_OUT" | grep -E '^tui_channel='    > "$ORCHESTRATE_CACHE_DIR/tabs_channel" 2>/dev/null || :
    printf '%s\n' "$TUI_OUT" | grep -E '^gate_reason='    > "$ORCHESTRATE_CACHE_DIR/tabs_reason" 2>/dev/null || :
    printf '%s\n' "$TUI_OUT" | grep -E '^tui_version_norm=' > "$ORCHESTRATE_CACHE_DIR/tui_version" 2>/dev/null || :
  fi
fi
exit 0
