#!/bin/sh
# _paths.sh - project/cache path derivation. POSIX sh; sourced, never executed.
# F5 (DRY): this derivation lived ONLY in os/_common.sh, which cannot be
# sourced standalone (it calls os_project_dir, defined by the per-OS
# adapters). A user running `sh scripts/preflight.sh .` - the natural first
# command - therefore got a successful discovery but NO populated cache, and
# the next command failed with "state not initialized". The rule is now
# extracted ONCE here so BOTH callers share it:
#   * os/_common.sh (sourced by orchestrate.sh; ORCHESTRATE_PATHS_FILE is
#     exported by orchestrate.sh, with a $0-relative fallback for direct
#     test-fixture sourcing),
#   * preflight.sh (standalone, via its own SELF_DIR).
# Sets (idempotent on re-source): PROJ_DIR, PROJ_HASH, CACHE_DIR.
#
# PROJ_DIR: ORCHESTRATE_DIR > os_project_dir() (when a per-OS adapter was
# sourced first; windows-gbash normalizes to the Windows literal) > pwd -P.
# On Windows Git Bash the cache key MUST be the Windows literal (that is what
# os/windows-gbash.sh's os_project_dir returns), or a standalone preflight
# would populate a DIFFERENT cache than orchestrate.sh. When no adapter was
# sourced yet (standalone preflight.sh, which knows its SELF_DIR), load the
# only adapter whose normalization is not `pwd -P` (darwin/linux/wsl need
# none). Sourcing is side-effect free (it only defines functions).
if ! command -v os_project_dir >/dev/null 2>&1 && [ -n "${SELF_DIR:-}" ]; then
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) [ -f "$SELF_DIR/os/windows-gbash.sh" ] && . "$SELF_DIR/os/windows-gbash.sh" ;;
  esac
fi
if [ -n "${ORCHESTRATE_DIR:-}" ]; then
  PROJ_DIR="$ORCHESTRATE_DIR"
elif command -v os_project_dir >/dev/null 2>&1; then
  PROJ_DIR=$(os_project_dir 2>/dev/null || pwd -P)
else
  PROJ_DIR=$(pwd -P)
fi
if command -v shasum >/dev/null 2>&1; then
  PROJ_HASH=$(printf '%s' "$PROJ_DIR" | shasum -a 256 | cut -c1-12)
elif command -v sha256sum >/dev/null 2>&1; then
  PROJ_HASH=$(printf '%s' "$PROJ_DIR" | sha256sum | cut -c1-12)
else
  PROJ_HASH=$(printf '%s' "$PROJ_DIR" | cksum | cut -d' ' -f1)
fi
# shellcheck disable=SC2034  # CACHE_DIR is read by the files that source this one
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/orchestrate/$PROJ_HASH"
# The cache DIR is PREPARED by os/_common.sh (the only writer of the cache
# keys), not here: this file is sourced by read-only scripts (the TUI
# detector) and must not create anything. The guard (an empty or "/"
# CACHE_DIR would turn every key into "/<key>") lives with the creation, in
# os/_common.sh.
#
# state_root -> prints the OpenCode state root. ONE resolver (DRY).
#
# Order: OPENCODE_STATE_ROOT > ORCHESTRATE_STATE_ROOT > the CLI's own
# registry (`opencode debug paths state`) > the XDG default.
#
# WHY ONE: the preflight, the TUI detector and the tabs merge each had their
# own resolution, with a DIFFERENT order and a DIFFERENT variable set. With
# ORCHESTRATE_STATE_ROOT set, the detector resolved one root (the gate said
# "no tabs.json found") while the merge resolved another (the tab was written
# somewhere else): the tabs feature broke silently. The gate and the merge
# must name the same root, so the resolution is named once.
state_root() {
  _srt=${OPENCODE_STATE_ROOT:-${ORCHESTRATE_STATE_ROOT:-}}
  if [ -z "$_srt" ] && command -v "${OPENCODE_CLI:-opencode}" >/dev/null 2>&1; then
    _srt=$("${OPENCODE_CLI:-opencode}" debug paths state 2>/dev/null | head -1)
  fi
  [ -n "$_srt" ] || _srt="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"
  printf '%s' "$_srt"
}
