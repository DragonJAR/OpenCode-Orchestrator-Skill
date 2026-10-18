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
test -d "$SOURCE_ROOT" || { printf 'ERROR: SKILL/ no encontrado en %s; ejecuta desde la raíz del workspace.\n' "$SOURCE_ROOT" >&2; exit 2; }

# --- Closed list (single source of truth; last entry = self-inclusion) --------
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
    printf 'Fuente no válida (directorio accesible sin enlace simbólico): %s\n' "$1" >&2
    exit 1
  fi
}
check_source_file() {
  if [ -L "$1" ] || [ ! -f "$1" ] || [ ! -r "$1" ]; then
    printf 'Fuente no válida (archivo regular legible y sin enlace simbólico): %s\n' "$1" >&2
    exit 1
  fi
}

for c in zip zipinfo unzip sort cmp; do
  command -v "$c" >/dev/null 2>&1 || { printf 'ERROR: dependencia no disponible: %s\n' "$c" >&2; exit 2; }
done

check_source_dir "$SOURCE_ROOT/references"
check_source_dir "$SOURCE_ROOT/scripts"

PACKAGE_WORK="$(mktemp -d)"
PACKAGE_STAGE="$PACKAGE_WORK/stage"
PACKAGE_ROOT="$PACKAGE_STAGE/$PACKAGE_NAME"
mkdir -p "$PACKAGE_ROOT/references" "$PACKAGE_ROOT/scripts"
# Guarantee cleanup on any exit (failure sites below would otherwise leave the staged tree on /var).
trap 'rm -rf "$PACKAGE_WORK"' EXIT INT TERM

EXPECTED_ENTRIES="$PACKAGE_WORK/expected-entries.txt"
# Directory entries the recursive zip stores (comparison is order-independent: both sides sorted).
printf '%s\n' "$PACKAGE_NAME/" "$PACKAGE_NAME/references/" "$PACKAGE_NAME/scripts/" > "$EXPECTED_ENTRIES"

# Single pass over the closed list: check + copy + record the expected entry.
printf '%s\n' "$PACKAGE_FILES" | awk 'NF{print}' | while IFS= read -r rel; do
  src="$SOURCE_ROOT/$rel"
  check_source_file "$src"
  case "$rel" in
    references/*) cp -p "$src" "$PACKAGE_ROOT/references/" ;;
    scripts/*)    cp -p "$src" "$PACKAGE_ROOT/scripts/" ;;
    *)            cp -p "$src" "$PACKAGE_ROOT/" ;;
  esac
  printf '%s\n' "$PACKAGE_NAME/$rel" >> "$EXPECTED_ENTRIES"
done

PACKAGE_ZIP="$PACKAGE_WORK/package.zip"
test ! -e "$PACKAGE_ZIP" || { printf '%s\n' "El destino ya existe: $PACKAGE_ZIP" >&2; exit 1; }
(cd "$PACKAGE_STAGE" && zip -q -X -r "$PACKAGE_ZIP" "$PACKAGE_NAME")

unzip -t "$PACKAGE_ZIP" >/dev/null
ACTUAL_ENTRIES="$PACKAGE_WORK/actual-entries.txt"
EXPECTED_SORTED="$PACKAGE_WORK/expected-sorted.txt"
ACTUAL_SORTED="$PACKAGE_WORK/actual-sorted.txt"
zipinfo -1 "$PACKAGE_ZIP" > "$ACTUAL_ENTRIES"
LC_ALL=C sort "$EXPECTED_ENTRIES" > "$EXPECTED_SORTED"
LC_ALL=C sort "$ACTUAL_ENTRIES" > "$ACTUAL_SORTED"
if ! cmp -s "$EXPECTED_SORTED" "$ACTUAL_SORTED"; then
  printf '%s\n' 'El contenido del ZIP no coincide con la lista cerrada.' >&2
  printf '%s\n' 'Esperado:' >&2
  cat "$EXPECTED_SORTED" >&2
  printf '%s\n' 'Encontrado:' >&2
  cat "$ACTUAL_SORTED" >&2
  exit 1
fi

printf 'ZIP creado en %s\n' "$PACKAGE_ZIP"
