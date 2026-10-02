#!/bin/sh
# WSL: igual que Linux (flock(1) + python3). Caveat: si el state root vive en /mnt/c
# (drvfs), los locks POSIX no son confiables entre procesos Windows/Linux; ante duda,
# attach-tabs falla cerrado y la tab se marca no verificada (usar CLI plugin).
os_project_dir() { pwd -P; }
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  _tabs="$HOME/.local/state/opencode/${OPENCODE_TUI_CHANNEL:-latest}/tui/tabs.json"
  if command -v opencode >/dev/null 2>&1; then
    _sr=$(opencode debug paths state 2>/dev/null | head -1)
    [ -n "$_sr" ] && [ -f "$_sr/${OPENCODE_TUI_CHANNEL:-latest}/tui/tabs.json" ] && _tabs="$_sr/${OPENCODE_TUI_CHANNEL:-latest}/tui/tabs.json"
  fi
  case "$_tabs" in
    /mnt/[a-zA-Z]/*) printf 'tabs_status=fail-closed (state en drvfs: lock no confiable)\n' >&2; return 3 ;;
  esac
  command -v flock >/dev/null 2>&1 || { printf 'flock(1) requerido para tabs en wsl\n' >&2; return 2; }
  command -v python3 >/dev/null 2>&1 || { printf 'python3 requerido para tabs en wsl\n' >&2; return 2; }
  [ -f "$_tabs" ] || { printf 'tabs_status=no-tui\n'; return 4; }
  _pyf=$(tabs_merge_py_file)
  OPENCODE_TUI_CHANNEL="${OPENCODE_TUI_CHANNEL:-latest}" flock -x "$_tabs" python3 "$_pyf" "$1" "$2" "$3" "$4" none
  _rc=$?
  rm -f "$_pyf"
  return $_rc
}
