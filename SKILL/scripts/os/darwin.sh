#!/bin/sh
# macOS (Darwin): BSD userland, sin flock(1); lock via python fcntl (probado).
os_project_dir() { pwd -P; }
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  command -v python3 >/dev/null 2>&1 || { printf 'python3 requerido para tabs en darwin\n' >&2; return 2; }
  # El canal NO se quema: si OPENCODE_TUI_CHANNEL no esta definido, se busca el
  # canal real bajo el state root activo (mismo criterio que los demas OS).
  if [ -z "${ORCHESTRATE_TABS_JSON:-}" ] && command -v opencode >/dev/null 2>&1; then
    _sr=$(opencode debug paths state 2>/dev/null | head -1)
    if [ -n "$_sr" ]; then
      if [ -n "${OPENCODE_TUI_CHANNEL:-}" ] && [ -f "$_sr/$OPENCODE_TUI_CHANNEL/tui/tabs.json" ]; then
        export ORCHESTRATE_TABS_JSON="$_sr/$OPENCODE_TUI_CHANNEL/tui/tabs.json"
      else
        for _c in "$_sr"/*; do
          [ -d "$_c" ] || continue
          if [ -f "$_c/tui/tabs.json" ]; then export ORCHESTRATE_TABS_JSON="$_c/tui/tabs.json"; break; fi
        done
      fi
    fi
  fi
  _pyf=$(tabs_merge_py_file)
  python3 "$_pyf" "$1" "$2" "$3" "$4" fcntl
  _rc=$?
  rm -f "$_pyf"
  return $_rc
}
