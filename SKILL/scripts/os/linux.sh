#!/bin/sh
# Linux: no flock(1) either; the lock is the shared one (lock_exec -> python
# fcntl). No OS-specific extra: the merge is the ONE shared implementation
# (os_tabs_merge_shared in os/_common.sh).
os_project_dir() { pwd -P; }
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  os_tabs_merge_shared "$@"
}
