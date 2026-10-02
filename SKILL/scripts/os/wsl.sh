#!/bin/sh
# WSL: same as Linux (flock(1) + python3). Caveat: if the state root lives on
# /mnt/c (drvfs), POSIX locks are not reliable across Windows/Linux processes;
# in doubt, attach-tabs fails closed and the tab is marked not verified (use the CLI plugin).
os_project_dir() { pwd -P; }
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  # Path resolved by tabs_json_path (SINGLE SOURCE); only flock(1) + drvfs here.
  _tabs=$(tabs_json_path) || { printf 'tabs_status=no-tui\n'; return 4; }
  case "$_tabs" in
    /mnt/[a-zA-Z]/*) printf 'tabs_status=fail-closed (state on drvfs: unreliable lock)\n' >&2; return 3 ;;
  esac
  command -v flock >/dev/null 2>&1 || { printf 'flock(1) required for tabs on wsl\n' >&2; return 2; }
  command -v python3 >/dev/null 2>&1 || { printf 'python3 required for tabs on wsl\n' >&2; return 2; }
  [ -f "$_tabs" ] || { printf 'tabs_status=no-tui\n'; return 4; }
  _pyf=$(tabs_merge_py_file)
  OPENCODE_TUI_CHANNEL="${OPENCODE_TUI_CHANNEL:-latest}" flock -x "$_tabs" python3 "$_pyf" "$1" "$2" "$3" "$4" none
  _rc=$?
  rm -f "$_pyf"
  return $_rc
}
