#!/bin/sh
# Linux: flock(1) de util-linux; merge via python3 bajo el lock del CLI.
os_project_dir() { pwd -P; }
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  command -v flock >/dev/null 2>&1 || { printf 'flock(1) requerido para tabs en linux\n' >&2; return 2; }
  command -v python3 >/dev/null 2>&1 || { printf 'python3 requerido para tabs en linux\n' >&2; return 2; }
  _tabs="$HOME/.local/state/opencode/${OPENCODE_TUI_CHANNEL:-latest}/tui/tabs.json"
  if command -v opencode >/dev/null 2>&1; then
    _sr=$(opencode debug paths state 2>/dev/null | head -1)
    [ -n "$_sr" ] && [ -f "$_sr/${OPENCODE_TUI_CHANNEL:-latest}/tui/tabs.json" ] && _tabs="$_sr/${OPENCODE_TUI_CHANNEL:-latest}/tui/tabs.json"
  fi
  [ -f "$_tabs" ] || { printf 'tabs_status=no-tui\n'; return 4; }
  _pyf=$(tabs_merge_py_file)
  OPENCODE_TUI_CHANNEL="${OPENCODE_TUI_CHANNEL:-latest}" flock -x "$_tabs" python3 "$_pyf" "$1" "$2" "$3" "$4" none
  _rc=$?
  rm -f "$_pyf"
  return $_rc
}
