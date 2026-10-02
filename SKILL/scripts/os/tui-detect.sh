#!/bin/sh
# Detects the active local OpenCode TUI and its real cwd (recipe-tui-tabs.md §3/§6).
# POSIX sh + awk. Modifies nothing: read-only. No hardcoded state.
#
# Output (stdout, one per line, key=value; cwd without spaces or backticks):
#   tui_pids=<p1,p2,...>        live TUI processes (excludes `opencode serve`)
#   tui_cwd=<path>              cwd of the TUI process whose cwd == PROJ_DIR, if any
#   tui_cwd_any=<path>          cwd of the first live TUI (even without a match)
#   tui_cwd_match=yes|no        tui_cwd literally matches PROJ_DIR
#   tui_channel=<channel>       storage channel of the TUI (from the tabs.json path)
#   tabs_json=<path>            tabs.json resolved from the active state root
#   tui_version=<ver>           version of the TUI binary
#   version_ok=yes|no           tui_version == PINNED_VERSION
#   gate=<ready|blocked>        decision of the §6 tabs gate
#   gate_reason=<text>          why blocked (or the precondition fulfilled)
#
# Usage: sh tui-detect.sh [project_dir] [pinned_version]
# Exit: 0 whenever it can answer (blocked included); 2 only for misuse.
set -u

PROJ="${1:-$(pwd -P)}"
# Pin = ONLY the major branch (2 = any 2.x.y). The tabs.json schema is stable
# within 2.x, and a 3.x (new major) DOES block: there the schema may have
# changed. Override via OPENCODE_TUI_PINNED_VERSION (name kept for compat, but
# its value is interpreted only as its first numeric component; a pin with an
# explicit minor is rejected to avoid the "2.0.21 vs 2.0.22" confusion).
PINNED="${2:-${OPENCODE_TUI_PINNED_VERSION:-2}}"
case "$PINNED" in
  *.*) printf 'ERROR: pin with minor/patch not supported (received: %s; use only the major, e.g. 2)\n' "$PINNED" >&2; exit 2 ;;
esac
CLI="${OPENCODE_CLI:-opencode}"

# 1) state root + channel. `opencode debug paths state` is the canonical
#    source; the channel is never guessed: it is deduced from the
#    subdirectory that contains tui/tabs.json.
STATE_ROOT="${OPENCODE_STATE_ROOT:-}"
if [ -z "$STATE_ROOT" ] && command -v "$CLI" >/dev/null 2>&1; then
  STATE_ROOT=$("$CLI" debug paths state 2>/dev/null | head -1)
fi
[ -n "$STATE_ROOT" ] || STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"

TABS_JSON=""; CHANNEL=""
if [ -d "$STATE_ROOT" ]; then
  # Walk the present channels and pick the one holding tui/tabs.json.
  # OPENCODE_TUI_CHANNEL takes priority if set; otherwise the first real channel.
  if [ -n "${OPENCODE_TUI_CHANNEL:-}" ] && [ -f "$STATE_ROOT/$OPENCODE_TUI_CHANNEL/tui/tabs.json" ]; then
    TABS_JSON="$STATE_ROOT/$OPENCODE_TUI_CHANNEL/tui/tabs.json"
    CHANNEL="$OPENCODE_TUI_CHANNEL"
  else
    for c in "$STATE_ROOT"/*; do
      [ -d "$c" ] || continue
      if [ -f "$c/tui/tabs.json" ]; then
        TABS_JSON="$c/tui/tabs.json"; CHANNEL=$(basename "$c"); break
      fi
    done
  fi
fi

# 2) live TUI processes. `opencode serve` is the server, not the TUI: excluded.
PIDS=""
if command -v pgrep >/dev/null 2>&1; then
  for p in $(pgrep -x opencode 2>/dev/null); do
    CMD=$(ps -p "$p" -o command= 2>/dev/null)
    case "$CMD" in
      *serve*|*api*) continue ;;
    esac
    PIDS="${PIDS:+$PIDS,}$p"
  done
fi

# 3) real cwd of each TUI. lsof on darwin/linux; /proc on linux/wsl.
cwd_of() {  # $1=pid -> prints the cwd
  p=$1
  if [ -r "/proc/$p/cwd" ]; then
    readlink "/proc/$p/cwd" 2>/dev/null && return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
    return 0
  fi
  return 1
}

TUI_CWD=""; TUI_CWD_ANY=""
if [ -n "$PIDS" ]; then
  OLDIFS=$IFS; IFS=,
  for p in $PIDS; do
    d=$(cwd_of "$p" 2>/dev/null)
    [ -n "$d" ] || continue
    [ -n "$TUI_CWD_ANY" ] || TUI_CWD_ANY="$d"
    # Only a cwd equal to the project works as the tabs `cwd` key (§3).
    if [ "$d" = "$PROJ" ] && [ -z "$TUI_CWD" ]; then TUI_CWD="$d"; fi
  done
  IFS=$OLDIFS
fi

# 4) version of the TUI binary (not the server's). Unreadable binary -> unknown.
TUI_VERSION=""
# POSIX: `${PIDS//,/ }` is a bashism and aborts in dash (Ubuntu WSL default).
PIDS_SPACE=$(printf '%s' "$PIDS" | tr ',' ' ')
for p in $PIDS_SPACE; do
  exe=$(command -v ps >/dev/null 2>&1 && ps -p "$p" -o command= 2>/dev/null | awk '{print $1}')
  [ -n "$exe" ] || continue
  v=$("$exe" --version 2>/dev/null | head -1 | awk '{print $NF}')
  [ -n "$v" ] && { TUI_VERSION="$v"; break; }
done
[ -n "$TUI_VERSION" ] || TUI_VERSION=$(command -v "$CLI" >/dev/null 2>&1 && "$CLI" --version 2>/dev/null | head -1 | awk '{print $NF}')
[ -n "$TUI_VERSION" ] || TUI_VERSION="unknown"

MATCH=no; [ -n "$TUI_CWD" ] && [ "$TUI_CWD" = "$PROJ" ] && MATCH=yes
# `opencode --version` prints "opencode v2.0.21": normalizes the v prefix.
TUI_VERSION_NORM=$(printf '%s' "$TUI_VERSION" | sed 's/^v//')
PINNED_NORM=$(printf '%s' "$PINNED" | sed 's/^v//')
VMaj=$(printf '%s' "$TUI_VERSION_NORM" | cut -d. -f1 | tr -dc '0-9')
PMaj=$(printf '%s' "$PINNED_NORM" | cut -d. -f1 | tr -dc '0-9')
# Version gate = same major only. Any 2.x.y is acceptable; tabs storage is
# stable within the branch and the merge is additive + fail-closed.
VERSION_OK=no
if [ -n "$VMaj" ] && [ "$VMaj" = "$PMaj" ]; then
  VERSION_OK=yes
fi

# 5) §6 gate. Each failed precondition names its cause; nothing is written.
GATE=blocked; REASON=""
if [ -z "$PIDS" ]; then
  REASON="no active local TUI (no live opencode process; tabs not applicable)"
elif [ "$VERSION_OK" != yes ]; then
  REASON="TUI version $TUI_VERSION is not 2.x$ (the gate requires major 2; fail-closed)"
elif [ -z "$TABS_JSON" ]; then
  REASON="no tui/tabs.json found under $STATE_ROOT (TUI without initialized storage)"
elif [ "$MATCH" != yes ]; then
  REASON="tui_cwd ($TUI_CWD_ANY) != project dir ($PROJ); no cwd key created by guesswork"
else
  GATE=ready; REASON="TUI $TUI_VERSION at $TUI_CWD; channel $CHANNEL; lock per OS"
fi

printf 'tui_pids=%s\n' "$PIDS"
printf 'tui_cwd=%s\n' "${TUI_CWD:-$TUI_CWD_ANY}"
printf 'tui_cwd_any=%s\n' "$TUI_CWD_ANY"
printf 'tui_cwd_match=%s\n' "$MATCH"
printf 'tui_channel=%s\n' "${CHANNEL:-none}"
printf 'tabs_json=%s\n' "${TABS_JSON:-none}"
printf 'tui_version=%s\n' "$TUI_VERSION"
printf 'tui_version_norm=%s\n' "$TUI_VERSION_NORM"
printf 'version_ok=%s\n' "$VERSION_OK"
printf 'gate=%s\n' "$GATE"
printf 'gate_reason=%s\n' "$REASON"
exit 0
