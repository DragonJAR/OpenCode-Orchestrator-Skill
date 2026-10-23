#!/bin/sh
# package.sh — versioned, executable packaging recipe (closed-list ZIP builder).
# Extracted from the in-prose recipe that lived in .agents/maintenance/testing-and-iteration.md
# (unversioned: .agents/ is gitignored), so the packaging logic is now tracked and self-hosting:
# this script appears in PACKAGE_FILES and the distributed ZIP carries its own recipe.
#
# Single source of truth: the closed list below drives check_source_file, cp and the
# expected-inventory comparison. To add or remove a package entry, edit PACKAGE_FILES only;
# every downstream step is generated from it in one pass (DRY: the list is never duplicated).
#
# Dependencies: POSIX sh, zip, zipinfo, unzip, sort, cmp.
# Usage: sh SKILL/scripts/package.sh   (run from the workspace root; uses cwd-relative SKILL/)
# Exit codes: 0 = success, 1 = invalid source or inventory mismatch, 2 = usage/environment.
set -eu

PACKAGE_NAME="opencode-orchestrator-skill" # must match the frontmatter `name`
SOURCE_ROOT="$(pwd -P)/SKILL"
test -d "$SOURCE_ROOT" || { printf 'ERROR: SKILL/ not found in %s; run this from the workspace root.\n' "$SOURCE_ROOT" >&2; exit 2; }

# --- Closed list (single source of truth; last entry = self-inclusion) --------
# The closed list covers EVERY file that ships. It used to list only 2 of the
# 22 eval fixtures, so the packaged smoke harness referenced files that were
# not in the ZIP: every user of the package got a broken eval suite. The
# guard below makes that drift impossible to reintroduce.
PACKAGE_FILES='
SKILL.md
LICENSE
references/agent-patterns.md
references/agents-and-safety.md
references/api-and-sessions.md
references/decision-trees.md
references/failure-matrix.md
references/ledger-template.md
references/naming-convention.md
references/opencode-patterns.md
references/playbook.md
references/prompt-templates.md
references/recipe-tui-tabs.md
references/research-evidence.md
references/subagent-contract.md
references/trigger-tests.md
references/triggers-es.md
scripts/_validators.awk
scripts/dragon_name.sh
scripts/orchestrate-darwin.sh
scripts/orchestrate-linux.sh
scripts/orchestrate-wsl.sh
scripts/orchestrate-windows.sh
scripts/orchestrate.sh
scripts/os/_common.sh
scripts/os/_paths.sh
scripts/os/darwin.sh
scripts/os/linux.sh
scripts/os/tui-detect.sh
scripts/os/windows-gbash.sh
scripts/os/wsl.sh
scripts/package.sh
scripts/preflight.sh
scripts/prompt-templates/router-orchestrator.md
scripts/validate_dag.sh
scripts/validate_ledger_closed.sh
scripts/watch_run.sh
'

check_source_dir() {
  if [ -L "$1" ] || [ ! -d "$1" ] || [ ! -r "$1" ] || [ ! -x "$1" ]; then
    printf 'ERROR: invalid source (directory reachable, not a symlink): %s\n' "$1" >&2
    exit 1
  fi
}
check_source_file() {
  if [ -L "$1" ] || [ ! -f "$1" ] || [ ! -r "$1" ]; then
    printf 'ERROR: invalid source (regular readable file, not a symlink): %s\n' "$1" >&2
    exit 1
  fi
}

for c in python3 sort; do
  command -v "$c" >/dev/null 2>&1 || { printf 'ERROR: required dependency not available: %s\n' "$c" >&2; exit 2; }
done

# Guard: the regression suite is MAINTAINER-INTERNAL and must NOT ship. The
# closed list used to carry only 2 of its fixtures, so the published package
# referenced files it did not contain; excluding the suite entirely removes
# the class of problem instead of tracking it.
if printf '%s\n' "$PACKAGE_FILES" | grep -q '^scripts/evals/'; then
  printf 'ERROR: the closed list contains the internal regression suite; it must not be published\n' >&2
  exit 1
fi

check_source_dir "$SOURCE_ROOT/references"
check_source_dir "$SOURCE_ROOT/scripts"

PACKAGE_WORK="$(mktemp -d)"
PACKAGE_STAGE="$PACKAGE_WORK/stage"
PACKAGE_ROOT="$PACKAGE_STAGE/$PACKAGE_NAME"
mkdir -p "$PACKAGE_ROOT/references" "$PACKAGE_ROOT/scripts"
# Guarantee cleanup on any exit (failure sites below would otherwise leave the staged tree on /var).
trap 'rm -rf "$PACKAGE_WORK"' EXIT INT TERM

EXPECTED_ENTRIES="$PACKAGE_WORK/expected-entries.txt"
# Directory entries the recursive zip stores, DERIVED from the closed list itself
# (single source of truth: a new subdir in PACKAGE_FILES updates this for free).
{ printf '%s\n' "$PACKAGE_NAME/"
  printf '%s\n' "$PACKAGE_FILES" | awk -F/ 'NF>1{d="";for(i=1;i<NF;i++){d=d (i>1?"/":"") $i; print d}}' | LC_ALL=C sort -u |
    while IFS= read -r d; do printf '%s\n' "$PACKAGE_NAME/$d/"; done
} > "$EXPECTED_ENTRIES"

# Single pass over the closed list: check + copy + record the expected entry.
printf '%s\n' "$PACKAGE_FILES" | awk 'NF{print}' | while IFS= read -r rel; do
  src="$SOURCE_ROOT/$rel"
  check_source_file "$src"
  mkdir -p "$(dirname "$PACKAGE_ROOT/$rel")"
  cp -p "$src" "$PACKAGE_ROOT/$rel"
  printf '%s\n' "$PACKAGE_NAME/$rel" >> "$EXPECTED_ENTRIES"
done

PACKAGE_ZIP="$(pwd -P)/dist/$PACKAGE_NAME.zip"
# The ZIP is written OUTSIDE the staging dir: the EXIT trap removes
# PACKAGE_WORK, so a ZIP inside it was deleted the moment the script printed
# its path (the recipe produced no durable artifact at all).
# It lands in dist/ and is rebuilt fresh every run: zip MERGES into an
# existing archive, so a stale entry would survive a rebuild.
mkdir -p "$(dirname "$PACKAGE_ZIP")" 2>/dev/null || true
rm -f "$PACKAGE_ZIP"
# The archive is built and inspected with the python standard library:
# `zip`, `zipinfo` and `unzip` are NOT part of Git for Windows, so the
# packaging step only worked on macOS and Linux. python3 is already a
# documented requirement of the skill, and ONE implementation behaves the
# same on the three platforms.
python3 - "$PACKAGE_STAGE" "$PACKAGE_NAME" "$PACKAGE_ZIP" <<'PYZIP' || exit 1
import os, sys, zipfile
stage, name, out = sys.argv[1], sys.argv[2], sys.argv[3]
root = os.path.join(stage, name)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel = os.path.relpath(dirpath, stage)
        if rel != ".":
            z.writestr(rel.replace(os.sep, "/") + "/", "")
        for f in sorted(filenames):
            z.write(os.path.join(dirpath, f), os.path.join(rel, f).replace(os.sep, "/"))
PYZIP

ACTUAL_ENTRIES="$PACKAGE_WORK/actual-entries.txt"
EXPECTED_SORTED="$PACKAGE_WORK/expected-sorted.txt"
ACTUAL_SORTED="$PACKAGE_WORK/actual-sorted.txt"
python3 - "$PACKAGE_ZIP" > "$ACTUAL_ENTRIES" <<'PYLIST' || exit 1
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    names = z.namelist()
# BINARY write: on Windows a text-mode print() ends the line with CRLF, and
# the comparison against the LF-only expected list then reports a mismatch
# that does not exist (and the runner log hides the CR, so both lists look
# identical).
sys.stdout.buffer.write(("\n".join(names) + "\n").encode("utf-8"))
PYLIST
LC_ALL=C sort "$EXPECTED_ENTRIES" > "$EXPECTED_SORTED"
LC_ALL=C sort "$ACTUAL_ENTRIES" > "$ACTUAL_SORTED"
# The comparison uses the SHELL, not cmp(1): Git for Windows does not ship
# cmp, so `cmp -s` failed with "command not found" and the check reported a
# content mismatch that did not exist.
if [ "$(cat "$EXPECTED_SORTED")" != "$(cat "$ACTUAL_SORTED")" ]; then
  printf '%s\n' 'ERROR: the ZIP contents do not match the closed list.' >&2
  printf '%s\n' 'Expected:' >&2
  cat "$EXPECTED_SORTED" >&2
  printf '%s\n' 'Found:' >&2
  cat "$ACTUAL_SORTED" >&2
  exit 1
fi

printf 'ZIP created at %s\n' "$PACKAGE_ZIP"
