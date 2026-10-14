#!/bin/sh
# Linux: flock(1) from util-linux; merge via python3 under the CLI lock.
os_project_dir() { pwd -P; }
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  command -v flock >/dev/null 2>&1 || { printf 'flock(1) required for tabs on linux\n' >&2; return 2; }
  command -v python3 >/dev/null 2>&1 || { printf 'python3 required for tabs on linux\n' >&2; return 2; }
  # Path resolved by tabs_json_path (SINGLE SOURCE); only flock(1) here.
  # ORCHESTRATE_TABS_JSON is exported so the python writes EXACTLY the file
  # flocked below (same contract as darwin.sh/windows-gbash.sh). Before, the
  # lock was held on the shell-resolved tabs.json while the python re-resolved
  # the path on its own (default channel "latest"): with more than one
  # channel directory the merge could write a DIFFERENT tabs.json with no lock
  # held on it.
  if [ -n "${ORCHESTRATE_TABS_JSON:-}" ]; then
    _tabs="$ORCHESTRATE_TABS_JSON"
  else
    _tabs=$(tabs_json_path) || { printf 'tabs_status=no-tui\n'; return 4; }
    export ORCHESTRATE_TABS_JSON="$_tabs"
  fi
  _pyf=$(tabs_merge_py_file)
  flock -x "$_tabs" python3 "$_pyf" "$1" "$2" "$3" "$4" none
  _rc=$?
  rm -f "$_pyf"
  return $_rc
}
