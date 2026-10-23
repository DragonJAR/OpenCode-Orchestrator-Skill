#!/bin/sh
# sweep-classes.sh — one detector per defect class in this project's history.
#
# WHAT THIS IS: the classes that actually bit this codebase, turned into
# checks that run on every push. Each rule below exists because the class was
# found the hard way: a hang, a wrong exit code, a CI failure, or a silent
# wrong answer.
#
# WHY IT IS NOT IN THE ZIP: it is a maintainer tool, not runtime. The
# distributable is the closed list in SKILL/scripts/package.sh, and this file
# is not in it.
#
# WHY IT IS NOT A GREP: a detector that cries is worse than no detector (it
# gets ignored and then disabled). Every rule below resolves the CLASS of the
# thing it looks at -- it knows a comment from code, a definition from a call,
# a sourced file from an executed one -- and skips what cannot exhibit the
# defect.
#
# Exit: 0 = every class closed, 1 = at least one class is open (the hits are
# printed), 2 = the tool itself could not run.
#
# Usage:
#   sh tools/sweep-classes.sh            # sweep the repo
#   sh tools/sweep-classes.sh --list     # list the rules
#   sh tools/sweep-classes.sh --selftest # prove every rule (introduce its defect)
#   sh tools/sweep-classes.sh --root DIR # sweep another tree (for validation)
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT="${SCRIPT_DIR}/.."

while [ $# -gt 0 ]; do
  case "$1" in
    --list) exec python3 "$SCRIPT_DIR/sweep_classes.py" --list ;;
    --selftest) exec python3 "$SCRIPT_DIR/sweep_classes.py" --selftest --root "$ROOT" ;;
    --root) ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'sweep-classes: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || {
  printf 'sweep-classes: python3 is required (standard library only)\n' >&2
  exit 2
}

exec python3 "$SCRIPT_DIR/sweep_classes.py" --root "$ROOT"
