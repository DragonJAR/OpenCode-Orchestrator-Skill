#!/bin/sh
# Windows Git Bash (MINGW/MSYS/CYGWIN): no flock(1); the lock is the shared one
# (lock_exec -> python fcntl, with a fail-closed guard when the interpreter has
# no fcntl -- e.g. a native python.org python on PATH -> manual TUI).
# PROJ_DIR is normalized to a literal Windows path with cygpath -w (JSON-escaped when the body is built).
#
# The merge is the ONE shared implementation (os_tabs_merge_shared in
# os/_common.sh). Git Bash declares only what is genuinely OS-specific: the
# fcntl probe, the operator guidance and the cygpath adaptation.
os_project_dir() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$(pwd -P)"; else pwd -P; fi
}
# The fcntl probe lives in the shared skeleton (os_tabs_merge_shared): the same
# condition must fail closed with the same rc and message on every OS, and a
# guard that existed in ONE adapter was a defect (the class).
os_tabs_python_hint() {
  printf 'Next: install MSYS2 python3 (pacman -S mingw-w64-ucrt-x86_64-python3) and retry "orchestrate-windows.sh attach-tabs --session <ID> --tui-cwd <PATH>", or open the session in the TUI (/sessions or Ctrl+X L) and mark the tab as not verified.\n' >&2
}
# os_tabs_adapt_paths TABS HELPER -> converts BOTH paths to the drive format:
# a native Win32 python cannot open MSYS paths (/tmp/..., /c/...). cygpath -m
# produces C:/a/b (slashes, no escapes). Without cygpath they are left as is
# (MSYS2 python understands them).
os_tabs_adapt_paths() {
  TABS_PATH="$1"; TABS_HELPER="$2"
  if command -v cygpath >/dev/null 2>&1; then
    TABS_PATH=$(cygpath -m "$TABS_PATH")
    [ -n "$TABS_HELPER" ] && TABS_HELPER=$(cygpath -m "$TABS_HELPER")
  fi
}
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  os_tabs_merge_shared "$@"
}
