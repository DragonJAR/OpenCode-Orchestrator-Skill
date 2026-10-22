#!/bin/sh
# macOS (Darwin): BSD userland, no flock(1); the lock is the shared one
# (lock_exec -> python fcntl, extracted from the old tabs.json merge lock).
#
# The tabs merge itself is the ONE shared implementation
# (os_tabs_merge_shared in os/_common.sh): darwin has no OS-specific extra.
# A guard that existed in ONE adapter and not the others was a defect
# (class), so the skeleton is shared and only the truly OS-specific
# bits are declared here.
os_project_dir() { pwd -P; }
os_tabs_merge() {  # SID TITLE TUI_CWD BACKUP_DIR
  os_tabs_merge_shared "$@"
}
