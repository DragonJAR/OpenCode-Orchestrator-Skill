#!/bin/sh
# Linux: flock(1) from util-linux; merge via python3 under the CLI lock.
os_project_dir() { pwd -P; }
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  command -v flock >/dev/null 2>&1 || { printf 'flock(1) required for tabs on linux\n' >&2; return 2; }
  command -v python3 >/dev/null 2>&1 || { printf 'python3 required for tabs on linux\n' >&2; return 2; }
  # Path resolved by tabs_json_path (SINGLE SOURCE); only flock(1) here.
  _tabs=$(tabs_json_path) || { printf 'tabs_status=no-tui\n'; return 4; }
  _pyf=$(tabs_merge_py_file)
  flock -x "$_tabs" python3 "$_pyf" "$1" "$2" "$3" "$4" none
  _rc=$?
  rm -f "$_pyf"
  return $_rc
}
