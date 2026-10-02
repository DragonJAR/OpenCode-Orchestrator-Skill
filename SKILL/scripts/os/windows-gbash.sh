#!/bin/sh
# Windows Git Bash (MINGW/MSYS/CYGWIN): sin flock(1); lock via python fcntl si el
# python es MSYS2 (MSYS2 moderno lo soporta; si falla, fail-closed -> TUI manual).
# PROJ_DIR se normaliza a ruta Windows literal con cygpath -w (JSON-escapada al construir el body).
os_project_dir() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$(pwd -P)"; else pwd -P; fi
}
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  [ $# -eq 4 ] || { printf 'os_tabs_merge: uso interno: SID TITLE TUI_CWD BACKUP_DIR\n' >&2; return 2; }
  command -v python3 >/dev/null 2>&1 || {
    printf 'python3 no encontrado; tabs en Git Bash lo requiere (fail-closed; no se escribio nada).\n' >&2
    printf 'Siguiente: instala python3 MSYS2 (pacman -S mingw-w64-ucrt-x86_64-python3) y reintenta "orchestrate-windows.sh attach-tabs --session <ID> --tui-cwd <PATH>", o abre la sesion en la TUI (/sessions o Ctrl+X L) y marca la tab como no verificada.\n' >&2
    return 2
  }
  # A6: un python3 nativo de Windows (python.org) en PATH no tiene fcntl. Su
  # traceback saldria con rc=1 y el mensaje amistoso nunca se emitiria porque el
  # script python solo termina con 0/3/4/5. Sondear antes de lanzar el merge.
  python3 -c 'import fcntl' >/dev/null 2>&1 || {
    printf 'tabs_status=fail-closed (este python3 no tiene fcntl; p. ej. python nativo de Windows en PATH; no se escribio nada)\n' >&2
    printf 'Siguiente: pon un python3 MSYS2 en PATH, o abre la sesion en la TUI (/sessions o Ctrl+X L) y marca la tab como no verificada.\n' >&2
    return 2
  }
  _pyf=$(tabs_merge_py_file)
  [ -n "$_pyf" ] || { printf 'os_tabs_merge: no pude crear el helper temporal python\n' >&2; return 2; }
  if command -v opencode >/dev/null 2>&1; then
    _sr=$(opencode debug paths state 2>/dev/null | head -1)
    [ -n "$_sr" ] && export ORCHESTRATE_STATE_ROOT="$_sr"
  fi
  export OPENCODE_TUI_CHANNEL="${OPENCODE_TUI_CHANNEL:-latest}"
  python3 "$_pyf" "$1" "$2" "$3" "$4" fcntl
  _rc=$?
  rm -f "$_pyf"
  return $_rc
}
