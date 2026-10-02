#!/bin/sh
# Detecta TUI local activa de OpenCode y su cwd real (recipe-tui-tabs.md §3/§6).
# POSIX sh + awk. No modifica nada: solo lectura. Sin estado quemado.
#
# Salida (stdout, una por línea, key=value; cwd sin espacios ni comillasrare):
#   tui_pids=<p1,p2,...>        procesos TUI vivos (excluye `opencode serve`)
#   tui_cwd=<ruta>              cwd del proceso TUI cuyo cwd == PROJ_DIR, si existe
#   tui_cwd_any=<ruta>          cwd del primer TUI vivo ( aunque no coincida)
#   tui_cwd_match=yes|no        tui_cwd coincide literalmente con PROJ_DIR
#   tui_channel=<canal>         canal de storage de la TUI (del path de tabs.json)
#   tabs_json=<ruta>            tabs.json resuelto del state root activo
#   tui_version=<ver>           versión del binario TUI
#   version_ok=yes|no           tui_version == PINNED_VERSION
#   gate=<ready|blocked>        decisión de la gate de tabs de §6
#   gate_reason=<texto>         por qué blocked (o la precondición quefulfilled)
#
# Uso: sh tui-detect.sh [project_dir] [pinned_version]
# Exit: 0 siempre que pueda responder (incluido blocked); 2 solo por mal uso.
set -u

PROJ="${1:-$(pwd -P)}"
# Pin = SOLO la rama mayor (2 = cualquier 2.x.y). El esquema de tabs.json es estable
# dentro de 2.x, y un 3.x (major nuevo) SI bloquea: alli el esquema pudo cambiar.
# Override por OPENCODE_TUI_PINNED_VERSION (compat nombre-conservado, pero su valor
# se interpreta solo como su primer componente numerico; se rechaza un pin con
# minor explicito para evitar la confusion de "2.0.21 vs 2.0.22").
PINNED="${2:-${OPENCODE_TUI_PINNED_VERSION:-2}}"
case "$PINNED" in
  *.*) printf 'ERROR: pin con minor/patch no soportado (recibido: %s; usa solo el major, p.ej. 2)\n' "$PINNED" >&2; exit 2 ;;
esac
CLI="${OPENCODE_CLI:-opencode}"

# 1) state root + canal. `opencode debug paths state` es la fuente canónica;
#    nunca se adivina el canal: se deduce del subdirectorio que contiene tui/tabs.json.
STATE_ROOT="${OPENCODE_STATE_ROOT:-}"
if [ -z "$STATE_ROOT" ] && command -v "$CLI" >/dev/null 2>&1; then
  STATE_ROOT=$("$CLI" debug paths state 2>/dev/null | head -1)
fi
[ -n "$STATE_ROOT" ] || STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"

TABS_JSON=""; CHANNEL=""
if [ -d "$STATE_ROOT" ]; then
  # Recorre los canales presentes y elige el que tenga tui/tabs.json.
  # OPENCODE_TUI_CHANNEL tiene prioridad si existe; si no, el primer canal real.
  if [ -n "${OPENCODE_TUI_CHANNEL:-}" ] && [ -f "$STATE_ROOT/$OPENCODE_TUI_CHANNEL/tui/tabs.json" ]; then
    TABS_JSON="$STATE_ROOT/$OPENCODE_TUI_CHANNEL/tui/tabs.json"
    CHANNEL="$OPENCODE_TUI_CHANNEL"
  else
    for c in "$STATE_ROOT"/*; do
      [ -d "$c" ] || continue
      if [ -f "$c/tui/tabs.json" ]; then
        TABS_JSON="$c/tui/tabs.json"; CHANNEL=$(basename "$c"); break
      fi
    done
  fi
fi

# 2) procesos TUI vivos. `opencode serve` es el servidor, no la TUI: se excluye.
PIDS=""
if command -v pgrep >/dev/null 2>&1; then
  for p in $(pgrep -x opencode 2>/dev/null); do
    CMD=$(ps -p "$p" -o command= 2>/dev/null)
    case "$CMD" in
      *serve*|*api*) continue ;;
    esac
    PIDS="${PIDS:+$PIDS,}$p"
  done
fi

# 3) cwd real de cada TUI. lsof en darwin/linux; /proc en linux/wsl.
cwd_of() {  # $1=pid -> imprime cwd
  p=$1
  if [ -r "/proc/$p/cwd" ]; then
    readlink "/proc/$p/cwd" 2>/dev/null && return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
    return 0
  fi
  return 1
}

TUI_CWD=""; TUI_CWD_ANY=""
if [ -n "$PIDS" ]; then
  OLDIFS=$IFS; IFS=,
  for p in $PIDS; do
    d=$(cwd_of "$p" 2>/dev/null)
    [ -n "$d" ] || continue
    [ -n "$TUI_CWD_ANY" ] || TUI_CWD_ANY="$d"
    # Solo un cwd igual al proyecto sirve como clave `cwd` de tabs (§3).
    if [ "$d" = "$PROJ" ] && [ -z "$TUI_CWD" ]; then TUI_CWD="$d"; fi
  done
  IFS=$OLDIFS
fi

# 4) versión del binario TUI (no la del server). Sin binario legible -> unknown.
TUI_VERSION=""
for p in ${PIDS//,/ }; do
  exe=$(command -v ps >/dev/null 2>&1 && ps -p "$p" -o command= 2>/dev/null | awk '{print $1}')
  [ -n "$exe" ] || continue
  v=$("$exe" --version 2>/dev/null | head -1 | awk '{print $NF}')
  [ -n "$v" ] && { TUI_VERSION="$v"; break; }
done
[ -n "$TUI_VERSION" ] || TUI_VERSION=$(command -v "$CLI" >/dev/null 2>&1 && "$CLI" --version 2>/dev/null | head -1 | awk '{print $NF}')
[ -n "$TUI_VERSION" ] || TUI_VERSION="unknown"

MATCH=no; [ -n "$TUI_CWD" ] && [ "$TUI_CWD" = "$PROJ" ] && MATCH=yes
# `opencode --version` imprime "opencode v2.0.21": normaliza el prefijo v.
TUI_VERSION_NORM=$(printf '%s' "$TUI_VERSION" | sed 's/^v//')
PINNED_NORM=$(printf '%s' "$PINNED" | sed 's/^v//')
VMaj=$(printf '%s' "$TUI_VERSION_NORM" | cut -d. -f1 | tr -dc '0-9')
PMaj=$(printf '%s' "$PINNED_NORM" | cut -d. -f1 | tr -dc '0-9')
# Gate de version = solo mismo major. Cualquier 2.x.y es aceptable; el storage
# de tabs es estable dentro de la rama y el merge es aditivo + fail-closed.
VERSION_OK=no
if [ -n "$VMaj" ] && [ "$VMaj" = "$PMaj" ]; then
  VERSION_OK=yes
fi

# 5) gate de §6. Cada precondición fallida nombra su causa; no se escribe nada.
GATE=blocked; REASON=""
if [ -z "$PIDS" ]; then
  REASON="sin TUI local activa (no hay proceso opencode vivo; tabs no aplicables)"
elif [ "$VERSION_OK" != yes ]; then
  REASON="version TUI $TUI_VERSION no es 2.x$ (la gate exige que el major sea 2; fail-closed)"
elif [ -z "$TABS_JSON" ]; then
  REASON="no se encontro tui/tabs.json bajo $STATE_ROOT (TUI sin storage init)"
elif [ "$MATCH" != yes ]; then
  REASON="tui_cwd ($TUI_CWD_ANY) != project dir ($PROJ); no se crea clave cwd por suposicion"
else
  GATE=ready; REASON="TUI $TUI_VERSION en $TUI_CWD; canal $CHANNEL; lock segun OS"
fi

printf 'tui_pids=%s\n' "$PIDS"
printf 'tui_cwd=%s\n' "${TUI_CWD:-$TUI_CWD_ANY}"
printf 'tui_cwd_any=%s\n' "$TUI_CWD_ANY"
printf 'tui_cwd_match=%s\n' "$MATCH"
printf 'tui_channel=%s\n' "${CHANNEL:-none}"
printf 'tabs_json=%s\n' "${TABS_JSON:-none}"
printf 'tui_version=%s\n' "$TUI_VERSION"
printf 'tui_version_norm=%s\n' "$TUI_VERSION_NORM"
printf 'version_ok=%s\n' "$VERSION_OK"
printf 'gate=%s\n' "$GATE"
printf 'gate_reason=%s\n' "$REASON"
exit 0
