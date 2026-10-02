#!/bin/sh
# orchestrate.sh - navaja suiza de orquestación para OpenCode V2 (multi-OS).
# Detecta el OS (o acepta --os); carga helpers por OS; expone subcomandos.
# Uso: orchestrate.sh [--os <darwin|linux|wsl|windows-gbash>] <subcmd> [args]
# Contrato: nada quemado; endpoint/modelo/agentes/proyecto se resuelven del estado activo.
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
OS_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --os) OS_OVERRIDE="$2"; shift 2 ;;
    --os=*) OS_OVERRIDE="${1#--os=}"; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
SUBCMD="${1:-}"; [ $# -gt 0 ] && shift

detect_os() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin) echo darwin ;;
    Linux)
      if [ -r /proc/version ] && grep -qi 'microsoft' /proc/version 2>/dev/null; then
        echo wsl
      else
        echo linux
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*) echo windows-gbash ;;
    *) echo linux ;;
  esac
}
OS="${OS_OVERRIDE:-$(detect_os)}"

# OS primero (define os_project_dir / os_tabs_merge); _common después (los usa).
[ -f "$SELF_DIR/os/$OS.sh" ] || { printf 'ERROR: OS no soportado: %s\n' "$OS" >&2; exit 2; }
. "$SELF_DIR/os/$OS.sh"
. "$SELF_DIR/os/_common.sh"

# auth_flag vive en os/_common.sh (capa baja que la usa), no aqui.

# --- subcomandos ----------------------------------------------------------------
sub_preflight() {
  ORCHESTRATE_CACHE_DIR="$CACHE_DIR" exec sh "$SELF_DIR/preflight.sh" "$@"
}

sub_ensure_root() {
  TITLE=""; AGENT=""; MODEL=""
  parse_kv "$@"
  # Sin --title, la raiz se llama Orquestador: es el nombre canonico de la
  # sesion [00] y evita inventar un titulo distinto en cada run.
  [ -n "$TITLE" ] || TITLE="Orquestador"
  require_state
  # [00] es la ranura del orquestador, SIEMPRE. El nombre por defecto es
  # "Orquestador"; un --title propio se normaliza al mismo ordinal, de modo que
  # el prefijo 00 no depende de que el operador se acuerde (DRY: title_normalize
  # es la unica implementacion del patron).
  TITLE=$(title_normalize 0 "$TITLE")
  : "${AGENT:=$(cache_get default_agent)}"; : "${AGENT:=build}"
  # Mismo dedup que create-worker (anti-pisoton): un titulo = una sesion.
  GUARD_OUT=$(dedup_guard "$TITLE"); GRC=$?
  if [ "$GRC" -eq 3 ]; then
    die "no se pudo consultar el catalogo de sesiones para el dedup; fail-closed (no se crea la sesion)"
  fi
  if [ "$GRC" -eq 2 ]; then
    EX_OUT=$(printf '%s\n' "$GUARD_OUT" | sed 's/^COLLISION out=//')
    die "colision: '$TITLE' ya existe con trabajo previo (out=$EX_OUT); usa otro titulo o --force-new"
  fi
  if [ "$GRC" -eq 0 ]; then
    RID=$(printf '%s\n' "$GUARD_OUT" | awk -F= '/^worker_id/{print $2}')
    cache_put root_session "$RID"
    printf '%s\n' "$GUARD_OUT" | sed 's/^worker_id=/root_id=/'
    return 0
  fi
  OUT=$(post_new_session "$(session_body "$TITLE" "$AGENT" "$MODEL")"); PRC=$?
  [ "$PRC" -eq 0 ] || exit "$PRC"   # die ya imprimio el motivo
  RID=$(printf '%s\n' "$OUT" | awk -F= '/^worker_id/{print $2}')
  cache_put root_session "$RID"
  printf '%s\n' "$OUT" | sed 's/^worker_id=/root_id=/'
}

sub_create_worker() {
  TITLE=""; AGENT=""; MODEL=""
  parse_kv "$@"
  [ -n "$TITLE" ] || { printf '%s\n' '--title requerido' >&2; exit 2; }
  require_state
  # dedup idempotente: mismo titulo (slug: sin espacios) en el mismo proyecto.
  # Solo reusa sesiones inertes (out=0); si tiene trabajo previo, fail-closed.
  GUARD_OUT=$(dedup_guard "$TITLE"); GRC=$?
  if [ "$GRC" -eq 3 ]; then
    die "no se pudo consultar el catalogo de sesiones para el dedup; fail-closed (no se crea la sesion)"
  fi
  if [ "$GRC" -eq 2 ]; then
    EX_OUT=$(printf '%s\n' "$GUARD_OUT" | sed 's/^COLLISION out=//')
    die "colision: '$TITLE' ya existe con trabajo previo (out=$EX_OUT); usa otro titulo o --force-new"
  fi
  [ "$GRC" -eq 0 ] && { printf '%s\n' "$GUARD_OUT"; return 0; }
  : "${AGENT:=build}"
  post_new_session "$(session_body "$TITLE" "$AGENT" "$MODEL")"
}

sub_sessions() {
  require_state
  AUTH=$(auth_flag)
  # Solo se quitan los newlines: los ESPACIOS se conservan. `tr -d ' '` hacia
  # doble trabajo de compactar y ademas destruia el titulo ("[01] Vermithrax"
  # -> "[01]Vermithrax"), que es justo lo que esta vista debe mostrar.
  # El fetch fuera del pipeline: con curl caido el rc del pipe era el de awk y
  # un inventario vacio se leia como "no hay sesiones".
  RESP=$(http_get "$(cache_get endpoint)/api/session" 2>/dev/null) || die "GET /api/session fallo; no se puede listar el inventario"
  [ -n "$RESP" ] || die "GET /api/session devolvio una respuesta vacia"
  printf '%s' "$RESP" | tr -d '\n' | sed 's/},{"id":"/\n{"id":"/g' | \
    awk -v d="$PROJ_DIR" \
      'match($0,/"directory":"[^"]+"/){dd=substr($0,RSTART+13,RLENGTH-14)}
       {if(dd!=d)next}
       match($0,/"id":"ses_[^"]+"/){id=substr($0,RSTART+6,RLENGTH-7)}
       match($0,/"title":"[^"]+"/){tt=substr($0,RSTART+9,RLENGTH-10)}
       match($0,/"output":[0-9]+/){o=substr($0,RSTART+9,RLENGTH-9)}
       {printf "%s out=%-6s %s\n", id, (o==""?0:o), tt}'
}

sub_attach_tabs() {
  SID=""; TUI_CWD=""; TITLE=""
  parse_kv "$@"
  [ -n "$SID" ] || { printf '%s\n' '--session requerido' >&2; exit 2; }
  # Misma resolucion que init-run (DRY): cache del preflight, re-probando si el
  # pin solicitado no es el cacheado. Antes attach-tabs reimplementaba la
  # comparacion de version, se desincronizo de init-run y escribio tabs.json
  # con la gate bloqueada.
  resolve_gate
  if [ "$GATE" != "ready" ] && [ "${FORCE_TABS:-0}" -ne 1 ]; then
    printf 'ERROR: gate de tabs=%s; fail-closed (tabs.json intacto).\n' "${GATE:-sin-preflight}" >&2
    printf 'Motivo: %s\n' "${GATE_REASON:-corre orchestrate.sh preflight}" >&2
    printf 'Siguiente: si confirmaste el esquema de tabs.json, reintenta con --force-tabs, o marca la tab como no verificada.\n' >&2
    exit 2
  fi
  [ "${FORCE_TABS:-0}" -eq 1 ] && [ "$GATE" != "ready" ] && \
    printf 'tabs_force=1 gate=%s (autorizado por el operador)\n' "${GATE:-sin-preflight}" >&2
  # --tui-cwd sigue siendo opcional: si falta, se resuelve desde la gate cacheada
  # por preflight (mismo dato, no una suposicion).
  GATE_CWD=$(cache_get tabs_cwd | sed 's/^tui_cwd=//')
  [ -n "$TUI_CWD" ] || TUI_CWD="$GATE_CWD"
  [ -n "$TUI_CWD" ] || { printf '%s\n' 'ERROR: sin --tui-cwd y sin gate cacheada (corre orchestrate.sh preflight para resolver la TUI activa)' >&2; exit 2; }
  # Propaga el canal DETECTADO por tui-detect a los adaptadores de OS. Antes se
  # escribia en el cache y nadie lo leia: cada OS re-resolvia el canal por su
  # cuenta (darwin con glob, linux/wsl/windows con env o "latest"), de modo que
  # una tab podia quedar "ok-verificada" en un canal que la TUI jamas lee.
  DETECTED_CHANNEL=$(cache_get tabs_channel | sed 's/^tui_channel=//')
  if [ -n "$DETECTED_CHANNEL" ] && [ "$DETECTED_CHANNEL" != "none" ]; then
    export OPENCODE_TUI_CHANNEL="$DETECTED_CHANNEL"
    printf 'tabs_channel=%s (detectado, propagado al merge)\n' "$DETECTED_CHANNEL" >&2
  fi
  # Fail-closed: un --tui-cwd explicito que contradiga la TUI real no se acepta.
  if [ -n "$GATE_CWD" ] && [ "$TUI_CWD" != "$GATE_CWD" ]; then
    printf 'ERROR: --tui-cwd %s no coincide con el cwd real de la TUI %s; fail-closed (tabs.json intacto)\n' \
      "$TUI_CWD" "$GATE_CWD" >&2
    exit 2
  fi
  [ -d "$TUI_CWD" ] || { printf 'ERROR: --tui-cwd no existe: %s (fail-closed; tabs.json queda intacto)\n' "$TUI_CWD" >&2; exit 2; }
  [ -n "$TITLE" ] || TITLE="$SID"
  os_tabs_merge "$SID" "$TITLE" "$TUI_CWD" "$CACHE_DIR"
}

sub_watch() {
  SID=""; ARTIFACT=""; DEADLINE=""; INTERVAL=""
  parse_kv "$@"
  [ -n "$SID" ] && [ -n "$ARTIFACT" ] || { printf '%s\n' '--session y --artifact requeridos' >&2; exit 2; }
  if cache_has endpoint; then OPENCODE_URL=$(cache_get endpoint); export OPENCODE_URL; fi
  if cache_has auth_password; then OPENCODE_PW=$(cat "$CACHE_DIR/auth_password"); export OPENCODE_PW; fi
  # Args posicionales citados: soportan rutas con espacios (sin arrays, POSIX puro).
  set -- "$SELF_DIR/watch_run.sh" -s "$SID" -a "$ARTIFACT"
  [ -n "$DEADLINE" ] && set -- "$@" -d "$DEADLINE"
  [ -n "$INTERVAL" ] && set -- "$@" -i "$INTERVAL"
  exec sh "$@"
}

sub_wait_idle() {
  SID=""; DEADLINE=600; INTERVAL=15
  parse_kv "$@"
  [ -n "$SID" ] || { printf '%s\n' '--session requerido' >&2; exit 2; }
  require_state
  AUTH=$(auth_flag)
  START=$(date +%s)
  while : ; do
    now=$(date +%s); [ $((now - START)) -ge "$DEADLINE" ] && { printf 'wait-idle=timeout session=%s\n' "$SID"; exit 3; }
    R=$(curl -fsS -m 10 $AUTH "$(cache_get endpoint)/api/session/$SID" 2>/dev/null) || { sleep "$INTERVAL"; continue; }
    IDLE=$(printf '%s' "$R" | awk 'match($0,/"idle":[0-9]+/){print substr($0,RSTART+7,RLENGTH-7); exit}')
    [ -n "$IDLE" ] && break
    sleep "$INTERVAL"
  done
  OUTCOME=$(printf '%s' "$R" | awk -F'"outcome":"' 'NF>1{split($2,a,"\"");print a[1]; exit}')
  printf 'wait-idle=ok session=%s idle=%s outcome=%s\n' "$SID" "${IDLE:-none}" "${OUTCOME:-none}"
}

sub_send_prompt() {
  SID=""; PROMPT_FILE=""
  parse_kv "$@"
  [ -n "$SID" ] && [ -n "$PROMPT_FILE" ] || { printf '%s\n' '--session y --prompt-file requeridos' >&2; exit 2; }
  require_state
  [ -f "$PROMPT_FILE" ] || die "prompt file no existe: $PROMPT_FILE"
  AUTH=$(auth_flag)
  # Guarda contra el fallo mudo: una sesion creada sin modelo resuelto acepta el
  # prompt, no infiere nada (0 tokens) y acaba en outcome=failed sin error
  # visible. Se verifica ANTES de enviar y se dice por que.
  SINFO=$(curl -fsS -m 15 $AUTH "$(cache_get endpoint)/api/session/$SID" 2>/dev/null)
  SESS_M=$(printf '%s' "$SINFO" | tr -d '\n' | sed 's/.*"model":{"id":"\([^"]*\)".*/\1/')
  if [ -z "$SESS_M" ] || [ "$SESS_M" = "$SINFO" ]; then
    printf 'ERROR: la sesion %s no tiene modelo resuelto (model.id vacio).\n' "$SID" >&2
    printf 'Causa: se creo sin la clave de cache model_default, o su agente no resuelve modelo.\n' >&2
    printf 'Siguiente: recreala con el modelo explicito: create-worker --title "<T>" --model <id>@<prov> --force-new\n' >&2
    exit 2
  fi
  TEXT=$(json_escape < "$PROMPT_FILE")
  # Un prompt vacio se despachaba con prompt=ok: workers corriendo sin
  # instrucciones y sin senal de error. Fail-closed.
  [ -n "$TEXT" ] || die "prompt file vacio o ilegible: $PROMPT_FILE"
  R=$(curl -fsS -m 60 $AUTH -H 'Content-Type: application/json' \
    -d '{"text":"'"$TEXT"'"}' "$(cache_get endpoint)/api/session/$SID/prompt") \
    || die 'POST /api/session/{id}/prompt fallo'
  MID=$(printf '%s' "$R" | awk 'match($0,/"infoID":"[^"]+/){print substr($0,RSTART+10,RLENGTH-10); exit}')
  printf 'prompt=ok session=%s infoID=%s\n' "$SID" "${MID:-none}"
}

# resolve_gate: deja en GATE / GATE_REASON / GATE_CWD la decision de la gate de
# tabs. Consume el cache del preflight (fuente única), pero RE-PROBEA cuando el
# cache no corresponde al pin solicitado: si el operador cambia
# OPENCODE_TUI_PINNED_VERSION sin re-correr preflight, un cache viejo decidia
# "ready" con una version que la gate rechazaria. Fallar por cache obsoleto es
# la misma clase de fallo mudo que ya corregimos dos veces.
resolve_gate() {
  # El pin (major de la rama) es del detector; aqui no se re-declara, se le
  # deja su default para que no haya dos verdades (DRY). Antes se pasaba
  # "2.0.22" y el detector lo rechazaba con exit 2; el 2>/dev/null lo
  # convertia en una gate vacia que se leia como "sin-preflight".
  WANT_PIN="${OPENCODE_TUI_PINNED_VERSION:-2}"
  PROBE=$(sh "$SELF_DIR/os/tui-detect.sh" "$PROJ_DIR" "$WANT_PIN" 2>/dev/null)
  if [ -n "$PROBE" ]; then
    GATE=$(printf '%s\n' "$PROBE" | sed -n 's/^gate=//p')
    GATE_REASON=$(printf '%s\n' "$PROBE" | sed -n 's/^gate_reason=//p')
    GATE_CWD=$(printf '%s\n' "$PROBE" | sed -n 's/^tui_cwd=//p')
    # Refresca el cache para que attach-tabs vea la misma decision (DRY).
    printf '%s\n' "$GATE"        > "$CACHE_DIR/tabs_gate"
    printf '%s\n' "$GATE_CWD"    > "$CACHE_DIR/tabs_cwd"
    printf '%s\n' "$GATE_REASON" > "$CACHE_DIR/tabs_reason"
    printf '%s\n' "$WANT_PIN"    > "$CACHE_DIR/tui_version_pin"
    return 0
  fi
  GATE=$(cache_get tabs_gate | sed 's/^gate=//')
  GATE_REASON=$(cache_get tabs_reason | sed 's/^gate_reason=//')
  GATE_CWD=$(cache_get tabs_cwd | sed 's/^tui_cwd=//')
}

sub_init_run() {
  WORKERS=""; NO_ATTACH=0; TUI_CWD=""; TITLE=""
  parse_kv "$@"
  # --worker es la vía inequívoca (una sesión por flag, título con espacios
  # permitido). --workers sigue aceptando una lista separada por comas/nuevas
  # líneas; NUNCA por espacios, porque el espacio es parte del título "[01] Foo".
  [ -n "$POSITIONAL" ] && WORKER_TITLES="${WORKER_TITLES:+$WORKER_TITLES$NL}$POSITIONAL"
  [ -n "$WORKER_TITLES" ] && WORKERS="$WORKER_TITLES"
  [ -n "$WORKERS" ] || { printf '%s\n' '--worker "Title" (repetible) o --workers "T1, T2" requerido' >&2; exit 2; }
  require_state
  printf 'init-run: dir=%s os=%s workers="%s"\n' "$PROJ_DIR" "$OS" "$WORKERS"

  # Gate de tabs resuelta UNA vez (resolve_gate). Antes era un paso opcional que
  # se saltaba en silencio si faltaba --tui-cwd; ahora la decision es dato y el
  # motivo se imprime pase lo que pase.
  resolve_gate
  TUI_CWD="${TUI_CWD:-$GATE_CWD}"
  if [ "$NO_ATTACH" -eq 0 ]; then
    # Un --tui-cwd explicito NO bypasea la gate: se contrasta con el cwd real
    # detectado. Pedir una clave que la TUI no usa crearia tabs huerfanas (§3).
    if [ -n "$TUI_CWD" ] && [ -n "$GATE_CWD" ] && [ "$TUI_CWD" != "$GATE_CWD" ]; then
      printf 'tabs_gate=blocked reason=--tui-cwd %s != cwd real de la TUI %s (fail-closed; no se crea clave cwd por suposicion)\n' \
        "$TUI_CWD" "$GATE_CWD"
      NO_ATTACH=1
      TUI_CWD=""
    elif [ "$GATE" = "ready" ] && [ -n "$TUI_CWD" ]; then
      printf 'tabs_gate=ready cwd=%s (%s)\n' "$TUI_CWD" "${GATE_REASON:-preflight}"
    else
      printf 'tabs_gate=blocked reason=%s (tabs no escritas; el run continua sin tabs)\n' \
        "${GATE_REASON:-preflight no cacheado: corre preflight}"
      NO_ATTACH=1
    fi
  fi

  # La raiz del orquestador se REUSA si el entorno la declara (OPENCODE_SESSION_ID,
  # cacheada por preflight): en un proyecto donde el orquestador YA es la sesion
  # [00] con trabajo, intentar crear otra raiz colisiona y abortaba el run.
  # Solo se crea una raiz nueva cuando no hay ninguna declarada.
  ROOT_TITLE="${TITLE:-Orquestador}"
  if cache_has root_session_hint; then
    RID=$(cache_get root_session_hint)
    printf 'root=[00] %s -> %s (reusada: es la sesion del orquestador)\n' "$ROOT_TITLE" "$RID"
  else
    ROOT_OUT=$(sub_ensure_root --title "$ROOT_TITLE"); ROOT_RC=$?
    [ "$ROOT_RC" -eq 0 ] || die "ensure_root fallo (rc=$ROOT_RC); aborta el run sin raiz"
    RID=$(printf '%s\n' "$ROOT_OUT" | awk -F= '/^root_id/{print $2}')
    [ -n "$RID" ] || die "ensure_root no devolvio root_id; aborta el run sin raiz"
    printf 'root=[00] %s -> %s\n' "$ROOT_TITLE" "$RID"
  fi
  ATTACHED=0; TABS_FAILED=0; FAILED=0
  # Line-driven, not word-split: a title is "[NN] Name" and the space is part
  # of it. `for t in $WORKERS` shredded these into two sessions each.
  WORKER_LIST=$(worker_list "$WORKERS")
  [ -n "$WORKER_LIST" ] || { printf 'ERROR: --workers/--worker no produjo titulos validos\n' >&2; exit 2; }
  # Un fallo tiene que detener el run. Con `| while` el bucle corre en un
  # SUBSHELL: `die`/`exit` solo mataban el subshell, el padre seguia y
  # culminaba imprimiendo "done". El heredoc mantiene el bucle en el shell
  # actual, asi que exit propaga de verdad.
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    ID=$(sub_create_worker --title "$t" | awk -F= '/^worker_id/{print $2}')
    if [ -z "$ID" ]; then
      printf 'ERROR: create-worker fallo para %s\n' "$t" >&2
      FAILED=$((FAILED + 1)); continue
    fi
    cache_put "worker_$t" "$ID"
    printf 'created %s -> %s\n' "$t" "$ID"
    if [ "$NO_ATTACH" -eq 0 ]; then
      # Ya no se traga el fallo: el estado de cada tab se reporta.
      if sub_attach_tabs --session "$ID" --tui-cwd "$TUI_CWD" --title "$t" >/dev/null 2>&1; then
        printf 'tabs=ok %s\n' "$t"
      else
        printf 'tabs=%s FAILED (sesion existe; ver attach-tabs --session %s --tui-cwd %s)\n' "$t" "$ID" "$TUI_CWD"
      fi
    fi
  # Deliberadamente SIN citar el delimitador: hay que expandir $WORKER_LIST para
  # que el bucle lea los titulos. W1 reporto que el heredoc sin citar
  # re-expandia $ y backticks de los titulos (S1a-07); es un hallazgo FALSO: la
  # expansion de una variable no re-escanea su contenido. Probado con
  # "[01] Ver\$mite {\`id\`} y \\bar": el while lee el valor literal.
  done <<EOF
$WORKER_LIST
EOF
  if [ "$FAILED" -gt 0 ]; then
    printf 'init-run: INCOMPLETO (%d worker(s) fallaron; ninguna tab expuesta para esos)\n' "$FAILED" >&2
    exit 1
  fi
  [ "$NO_ATTACH" -eq 0 ] && printf 'tabs: expuestas (no verificadas por sessionID; ver lineas tabs=)\n'
  printf 'init-run: done | siguiente: orchestrate.sh send-prompt --session <ID> --prompt-file <ruta>\n'
}

sub_tabs() {
  # Gate de tabs sin efectos: responde "¿hay TUI y puedo exponer tabs?" antes de
  # crear nada. Si hay --tui-cwd explicito, lo contrasta con el cwd real detectado.
  TUI_CWD=""; parse_kv "$@"
  _probe=$(sh "$SELF_DIR/os/tui-detect.sh" "$PROJ_DIR" "${OPENCODE_TUI_PINNED_VERSION:-2}" 2>/dev/null)
  printf '%s\n' "$_probe"
  if [ -n "$TUI_CWD" ]; then
    _real=$(printf '%s\n' "$_probe" | sed -n 's/^tui_cwd_any=//p')
    if [ "$TUI_CWD" = "$_real" ]; then
      printf 'tui_cwd_request=match\n'
    else
      printf 'tui_cwd_request=MISMATCH pedido=%s detectado=%s (no se creara clave cwd por suposicion)\n' "$TUI_CWD" "${_real:-none}"
    fi
  fi
}

sub_self_check() {
  printf 'os=%s\nproj_dir=%s\ncache_dir=%s\n' "$OS" "$PROJ_DIR" "$CACHE_DIR"
  for c in awk sed curl tr python3 flock shasum sha256sum cygpath; do
    if command -v "$c" >/dev/null 2>&1; then printf 'have: %s -> %s\n' "$c" "$(command -v "$c")"; fi
  done
  command -v opencode >/dev/null 2>&1 && printf 'opencode_cli=%s\n' "$(command -v opencode)"
  cache_has endpoint && printf 'state=initialized (endpoint=%s)\n' "$(cache_get endpoint)"
  exit 0
}

# verify-daughters: R14 — confirma que cada hija real de un worker tiene
# parentID == worker y location.directory == run.location.directory. Usa la query
# ?parentID= en la URL (no --param, que la CLI ignora en este runtime).
sub_verify_daughters() {
  WORKER_ID=""; EXPECTED_PARENT=""
  parse_kv "$@"
  [ -n "$WORKER_ID" ] || { printf '%s\n' '--worker-id requerido' >&2; exit 2; }
  : "${EXPECTED_PARENT:=$WORKER_ID}"
  require_state
  # opencode api resuelve servidor+auth y quiere PATH (con query), no URL completa.
  command -v opencode >/dev/null 2>&1 || die 'opencode CLI requerido para verify-daughters (no esta en PATH); corre preflight y usa el fallback de curl con la receta de auth si aplica'
  command -v python3 >/dev/null 2>&1 || die 'python3 requerido para verify-daughters (parser de la respuesta JSON)'
  RESP=$(opencode api GET "/api/session?parentID=$WORKER_ID" 2>/dev/null) \
    || die "GET /api/session?parentID=$WORKER_ID fallo"
  printf '%s\n' "$RESP" | EXPECTED_PARENT="$EXPECTED_PARENT" PROJ_DIR="$PROJ_DIR" python3 -c '
import json, sys, os
d = json.load(sys.stdin).get("data", [])
wp = os.environ["EXPECTED_PARENT"]; locx = os.environ["PROJ_DIR"]
ok = fail = 0
for s in d:
    pid = s.get("parentID"); loc = (s.get("location") or {}).get("directory", "")
    good = (pid == wp and loc == locx)
    ok += 1 if good else 0; fail += 0 if good else 1
    print("  %s %-32s | %s | parentID=%s | loc_ok=%s" % (
        "OK" if good else "FAIL", (s.get("title") or "?")[:32],
        (s.get("id") or "")[:18], pid, loc == locx))
print("verificadas_ok=%d fallos=%d" % (ok, fail))
if not d:
    print("ERROR: la consulta no devolvio hijas; un worker-id mal escrito se leeria como exito. Fail-closed.")
    sys.exit(2)
sys.exit(0 if fail == 0 else 2)'
}

# delete-session: R7. /openapi.json activo (v2.0.22 verificado; la tampa
# `2.0.21 vs 2.0.22` aqui es irrelevante porque la gate es por major) publica
# DELETE /api/session/{id}. Gate: enumera hijas con GET ?parentID=; aborta si
# las hay a menos que se use --force; sin --yes exige escribir "yes"
# (fail-closed para uso no interactivo).
sub_delete_session() {
  SID=""; YES=0; FORCE=0
  parse_kv "$@"
  [ -n "$SID" ] || { printf '%s\n' '--session requerido' >&2; exit 2; }
  case "$SID" in ses_*) : ;; *) printf '%s\n' 'ERROR: --session debe tener prefijo ses_' >&2; exit 2 ;; esac
  require_state
  command -v opencode >/dev/null 2>&1 || die 'opencode CLI requerido (enumerar hijas con R7)'
  CHILDREN=$(opencode api GET "/api/session?parentID=$SID" 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("data",[])))' 2>/dev/null \
    || printf '?')
  printf 'delete-session: target=%s children=%s\n' "$SID" "$CHILDREN" >&2
  if [ "$FORCE" -ne 1 ]; then
    if [ "$CHILDREN" != "0" ] && [ "$CHILDREN" != "?" ]; then
      printf 'ERROR: %s tiene %s hijas; R7 -> usa --force para omitir el chequeo (asumes borrado en cascada)\n' "$SID" "$CHILDREN" >&2
      exit 2
    fi
    if [ "$YES" -ne 1 ]; then
      printf 'BORRAR %s (children=%s)? Escribe "yes" para continuar: ' "$SID" "$CHILDREN" >&2
      if ! IFS= read -r ans; then printf '\nabortado (sin input)\n' >&2; exit 2; fi
      [ "$ans" = "yes" ] || { printf 'abortado\n' >&2; exit 2; }
    fi
  fi
  AUTH=$(auth_flag)
  curl -fsS -m 30 $AUTH -X DELETE "$(cache_get endpoint)/api/session/$SID" \
    || die "DELETE /api/session/$SID fallo"
  printf 'deleted=%s children_was=%s\n' "$SID" "$CHILDREN"
}

sub_help() {
  cat <<'USAGE'
orchestrate.sh [--os <darwin|linux|wsl|windows-gbash>] <subcmd> [args]
Wrappers equivalentes: orchestrate-darwin.sh | orchestrate-linux.sh | orchestrate-wsl.sh | orchestrate-windows.sh

Subcomandos:
  preflight [dir]                    delega en scripts/preflight.sh y pobla cache de estado
  ensure-root --title T              POST /api/session raiz; verifica parentID=null; cachea root_session
  create-worker --title T [--agent A] [--model id@prov] [--force-new]
                                     POST /api/session; verifica parentID=null y location literal;
                                     dedup: si ya existe sesion inerte (out=0) con ese titulo en el
                                     proyecto, la reusa; --force-new salta el dedup y crea una nueva
  sessions                            inventario de sesiones del proyecto (id, out, titulo)
  send-prompt --session SID --prompt-file F
                                     POST prompt con JSON-escape awk (sin python)
  attach-tabs --session SID [--tui-cwd PATH] [--title T]
                                     merge aditivo de tabs.json con lock segun OS; readback; no verificada.
                                     --tui-cwd es opcional: sin el, usa la gate cacheada por preflight.
  tabs [--tui-cwd PATH]              gate de TUI/tabs sin efectos: pids, cwd real, canal, version,
                                     ready|blocked + motivo (recipe-tui-tabs.md §3/§6)
  watch --session SID --artifact A[,A...] [--deadline D] [--interval I]
                                     delega en scripts/watch_run.sh
  wait-idle --session SID [--deadline D] [--interval I]
                                     poll hasta time.idle; imprime outcome
  init-run --workers "T1 T2 T3" [--title ROOT] [--tui-cwd PATH] [--no-attach-tabs]
                                     crea root (opcional) + workers + tabs en un comando.
                                     Las tabs se adjuntan por defecto si la gate cacheada dice ready;
                                     --tui-cwd es opcional (la gate ya conoce el cwd real de la TUI)
  self-check                         reporta OS, herramientas y estado cacheado
  verify-daughters --worker-id WID [--expected-parent WID]
                                     GET /api/session?parentID= lista hijas y valida que
                                     cada una tenga parentID=expected_parent y
                                     location.directory=run.location.directory (R14).
  delete-session --session SID [--yes] [--force]
                                     DELETE /api/session/{id} (verificado en /openapi.json
                                     activo; R7 -> chequea hija y exige confirmacion).
                                     --yes: previene prompt. --force: omite chequeo de hijas.
USAGE
}

case "$SUBCMD" in
  preflight) sub_preflight "$@" ;;
  ensure-root) sub_ensure_root "$@" ;;
  create-worker) sub_create_worker "$@" ;;
  send-prompt) sub_send_prompt "$@" ;;
  attach-tabs) sub_attach_tabs "$@" ;;
  watch) sub_watch "$@" ;;
  wait-idle) sub_wait_idle "$@" ;;
  init-run) sub_init_run "$@" ;;
  sessions) sub_sessions "$@" ;;
  self-check) sub_self_check "$@" ;;
  tabs) sub_tabs "$@" ;;
  verify-daughters) sub_verify_daughters "$@" ;;
  delete-session) sub_delete_session "$@" ;;
  ""|-h|--help|help) sub_help; exit 0 ;;
  *) printf 'subcomando desconocido: %s\n' "$SUBCMD" >&2; sub_help >&2; exit 2 ;;
esac