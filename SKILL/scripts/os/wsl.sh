#!/bin/sh
# WSL: same as Linux (the shared lock_exec -> python fcntl). Caveat: if the
# state root lives on /mnt/c (drvfs), POSIX locks are not reliable across
# Windows/Linux processes; in doubt, attach-tabs fails closed and the tab is
# marked not verified (use the CLI plugin).
#
# The merge is the ONE shared implementation (os_tabs_merge_shared in
# os/_common.sh). WSL declares only what is genuinely OS-specific: the drvfs
# fail-closed check.
os_project_dir() { pwd -P; }
# os_tabs_extra_check PATH -> extra fail-closed check (drvfs: unreliable lock).
os_tabs_extra_check() {
  case "$1" in
    /mnt/[a-zA-Z]/*) printf 'tabs_status=fail-closed (state on drvfs: unreliable lock)\n' >&2; return 3 ;;
  esac
  return 0
}
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  os_tabs_merge_shared "$@"
}
