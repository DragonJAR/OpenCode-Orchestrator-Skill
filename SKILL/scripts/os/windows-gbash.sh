#!/bin/sh
# Windows Git Bash (MINGW/MSYS/CYGWIN): no flock(1); lock via python fcntl if the
# python is MSYS2 (modern MSYS2 supports it; if it fails, fail-closed -> manual TUI).
# PROJ_DIR is normalized to a literal Windows path with cygpath -w (JSON-escaped when the body is built).
os_project_dir() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$(pwd -P)"; else pwd -P; fi
}
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  [ $# -eq 4 ] || { printf 'os_tabs_merge: internal usage: SID TITLE TUI_CWD BACKUP_DIR\n' >&2; return 2; }
  command -v python3 >/dev/null 2>&1 || {
    printf 'python3 not found; tabs on Git Bash requires it (fail-closed; nothing was written).\n' >&2
    printf 'Next: install MSYS2 python3 (pacman -S mingw-w64-ucrt-x86_64-python3) and retry "orchestrate-windows.sh attach-tabs --session <ID> --tui-cwd <PATH>", or open the session in the TUI (/sessions or Ctrl+X L) and mark the tab as not verified.\n' >&2
    return 2
  }
  # A6: a native Windows python3 (python.org) on PATH has no fcntl. Its
  # traceback would exit with rc=1 and the friendly message would never be
  # emitted because the python script only exits 0/3/4/5. Probe before launching
  # the merge.
  python3 -c 'import fcntl' >/dev/null 2>&1 || {
    printf 'tabs_status=fail-closed (this python3 has no fcntl; e.g. native Windows python on PATH; nothing was written)\n' >&2
    printf 'Next: put an MSYS2 python3 on PATH, or open the session in the TUI (/sessions or Ctrl+X L) and mark the tab as not verified.\n' >&2
    return 2
  }
  _pyf=$(tabs_merge_py_file)
  [ -n "$_pyf" ] || { printf 'os_tabs_merge: could not create the temporary python helper\n' >&2; return 2; }
  if command -v opencode >/dev/null 2>&1; then
    _sr=$(opencode debug paths state 2>/dev/null | head -1)
    [ -n "$_sr" ] && export OPENCODE_STATE_ROOT="$_sr"
  fi
  # 1) Resolves the tabs.json path (tabs_json_path, SINGLE SOURCE).
  _tj=$(tabs_json_path) || { printf 'tabs_status=no-tui\n'; return 4; }
  export ORCHESTRATE_TABS_JSON="$_tj"
  # 2) THEN convert to drive format: a native Win32 python cannot open MSYS
  #    paths (/tmp/..., /c/...). cygpath -m produces C:/a/b (slashes, no
  #    escapes). Without cygpath it is left as is (MSYS2 python understands them).
  if command -v cygpath >/dev/null 2>&1; then
    _pyf=$(cygpath -m "$_pyf")
    ORCHESTRATE_TABS_JSON=$(cygpath -m "$ORCHESTRATE_TABS_JSON")
    export ORCHESTRATE_TABS_JSON
  fi
  python3 "$_pyf" "$1" "$2" "$3" "$4" fcntl
  _rc=$?
  rm -f "$_pyf"
  return $_rc
}
