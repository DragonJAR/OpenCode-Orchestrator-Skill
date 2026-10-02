#!/bin/sh
# macOS (Darwin): BSD userland, no flock(1); lock via python fcntl (tested).
os_project_dir() { pwd -P; }
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  command -v python3 >/dev/null 2>&1 || { printf 'python3 required for tabs on darwin\n' >&2; return 2; }
  # Same probe as windows-gbash: a minimal python3 (e.g. a CLT stub) may lack
  # fcntl and the rc=1 traceback says nothing useful to the operator.
  python3 -c 'import fcntl' >/dev/null 2>&1 || {
    printf 'tabs_status=fail-closed (this python3 has no fcntl; nothing was written)\n' >&2
    return 2
  }
  # The tabs.json path is resolved by tabs_json_path (SINGLE SOURCE in _common.sh):
  # only the lock mechanism is decided here (fcntl, no flock on BSD).
  if [ -z "${ORCHESTRATE_TABS_JSON:-}" ]; then
    _tj=$(tabs_json_path) || { printf 'tabs_status=no-tui\n'; return 4; }
    export ORCHESTRATE_TABS_JSON="$_tj"
  fi
  _pyf=$(tabs_merge_py_file)
  python3 "$_pyf" "$1" "$2" "$3" "$4" fcntl
  _rc=$?
  rm -f "$_pyf"
  return $_rc
}
