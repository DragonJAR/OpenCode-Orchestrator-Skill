#!/bin/sh
# Shared helpers for the orchestration swissknife. POSIX sh, sourced by orchestrate.sh.
# Contract: per-OS files (sourced BEFORE this one) define os_project_dir and os_tabs_merge.
set -u
# Newline as a data separator for accumulating repeated flag values in POSIX sh.
NL='
'

# --- project dir (OS-normalized; windows-gbash converts to Windows literal) ----
PROJ_DIR="${ORCHESTRATE_DIR:-$(os_project_dir 2>/dev/null || pwd -P)}"
if command -v shasum >/dev/null 2>&1; then
  PROJ_HASH=$(printf '%s' "$PROJ_DIR" | shasum -a 256 | cut -c1-12)
elif command -v sha256sum >/dev/null 2>&1; then
  PROJ_HASH=$(printf '%s' "$PROJ_DIR" | sha256sum | cut -c1-12)
else
  PROJ_HASH=$(printf '%s' "$PROJ_DIR" | cksum | cut -d' ' -f1)
fi
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/orchestrate/$PROJ_HASH"
mkdir -p "$CACHE_DIR" 2>/dev/null || CACHE_DIR="/tmp/orchestrate-$PROJ_HASH"
mkdir -p "$CACHE_DIR" 2>/dev/null

# --- http ---------------------------------------------------------------------
http_get() { curl -fsS -m 30 ${AUTH:-} "$1"; }
http_post_json() { curl -fsS -m 30 ${AUTH:-} -H 'Content-Type: application/json' -d "$2" "$1"; }

# --- json (jq-less; awk) --------------------------------------------------------
json_escape() {  # stdin -> JSON string body (no quotes) with \n between lines
  awk 'BEGIN{ORS=""}{gsub(/\\/,"\\\\");gsub(/"/,"\\\"");gsub(/\t/,"\\t");gsub(/\r/,"\\r");if(NR>1)printf "\\n";printf "%s",$0}'
}
json_get_field() {  # stdin=JSON, $1=KEY -> emite valor
  awk -v k="\"$1\"" 'index($0,k){p=index($0,k)+length(k);
    while(p<=length($0)&&substr($0,p,1)~/[ \t:]/)p++; s=p; c=substr($0,s,1);
    if(c=="{"||c=="["){d=0;for(i=s;i<=length($0);i++){x=substr($0,i,1);if(x==c)d++;else if(x==(c=="{"?"}":"]")){d--;if(d==0){print substr($0,s,i-s+1);exit}}}}
    else{e=p;while(e<=length($0)&&substr($0,e,1)!~/[,\}]/)e++;v=substr($0,s,e-s);gsub(/^"|"$/,"",v);print v;exit}}'
}

# --- kv cache -------------------------------------------------------------------
cache_put() { printf '%s\n' "$2" > "$CACHE_DIR/$1"; }
cache_get() { if [ -f "$CACHE_DIR/$1" ]; then cat "$CACHE_DIR/$1"; else printf ''; fi; }
cache_has() { [ -f "$CACHE_DIR/$1" ] && [ -s "$CACHE_DIR/$1" ]; }
# auth_flag: flag de Basic auth para curl. Vive AQUI, no en orchestrate.sh, porque
# find_dedup y http_* la usan y _common.sh es la capa baja. Definirla en el
# llamador hacia depender del orden de sourcing: correcto en runtime, fragil ante
# cualquier test o inclusion directa de _common.sh.
auth_flag() { if cache_has auth_password; then printf '%s' "-u opencode:$(cat "$CACHE_DIR/auth_password")"; fi; }
require_state() {
  for k in endpoint version projectID model_default; do
    cache_has "$k" || { printf 'ERROR: state not initialized; run: orchestrate.sh preflight %s\n' "$PROJ_DIR" >&2; exit 1; }
  done
}

# --- arg parsing ------------------------------------------------------------------
parse_kv() {
  # POSITIONAL recoge tokens sueltos. Antes `*) shift` los descartaba en
  # silencio, de modo que `init-run --workers "T1" "T2" "T3"` creaba solo T1
  # sin avisar. Ahora se suman a WORKERS (ver sub_init_run).
  POSITIONAL=""; WORKER_TITLES=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) TITLE="${2:-}"; shift 2 ;; --title=*) TITLE="${1#--title=}"; shift ;;
      --agent) AGENT="${2:-}"; shift 2 ;; --agent=*) AGENT="${1#--agent=}"; shift ;;
      --model) MODEL="${2:-}"; shift 2 ;; --model=*) MODEL="${1#--model=}"; shift ;;
      --session) SID="${2:-}"; shift 2 ;; --session=*) SID="${1#--session=}"; shift ;;
      --worker-id) WORKER_ID="${2:-}"; shift 2 ;; --worker-id=*) WORKER_ID="${1#--worker-id=}"; shift ;;
      --expected-parent) EXPECTED_PARENT="${2:-}"; shift 2 ;; --expected-parent=*) EXPECTED_PARENT="${1#--expected-parent=}"; shift ;;
      --artifact) ARTIFACT="${2:-}"; shift 2 ;; --artifact=*) ARTIFACT="${1#--artifact=}"; shift ;;
      --tui-cwd) TUI_CWD="${2:-}"; shift 2 ;; --tui-cwd=*) TUI_CWD="${1#--tui-cwd=}"; shift ;;
      -d|--deadline) DEADLINE="${2:-}"; shift 2 ;; -i|--interval) INTERVAL="${2:-}"; shift 2 ;;
      -s|--session) SID="${2:-}"; shift 2 ;; -a|--artifact) ARTIFACT="${2:-}"; shift 2 ;;
      --workers) WORKERS="${2:-}"; shift 2 ;;
      --worker) WORKER_TITLES="${WORKER_TITLES:+$WORKER_TITLES$NL}${2:-}"; shift 2 ;;
      --worker=*) WORKER_TITLES="${WORKER_TITLES:+$WORKER_TITLES$NL}${1#--worker=}"; shift ;;
      --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
      --no-attach-tabs) NO_ATTACH=1; shift ;;
      --force-tabs) FORCE_TABS=1; shift ;;
      --force-new) FORCE_NEW=1; shift ;;
      --yes) YES=1; shift ;;
      --force) FORCE=1; shift ;;
      --) shift; break ;;
      -*) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
      *) POSITIONAL="${POSITIONAL:+$POSITIONAL }$1"; shift ;;
    esac
  done
}

# --- tabs merge engine (python3; lock strategy chosen per OS) ---------------------
TABS_MERGE_PY='import json, os, shutil, sys
sid, title, tui_cwd, bk, lockmode = sys.argv[1:6]
chan = os.environ.get("OPENCODE_TUI_CHANNEL","latest")
p = os.environ.get("ORCHESTRATE_TABS_JSON")
if not p:
    sroot = os.environ.get("ORCHESTRATE_STATE_ROOT","")
    p = (os.path.join(sroot, chan, "tui", "tabs.json") if sroot
         else os.path.expanduser(f"~/.local/state/opencode/{chan}/tui/tabs.json"))
if not os.path.exists(p):
    print("tabs_status=no-tui"); sys.exit(4)
f = open(p, "r+")
if lockmode == "fcntl":
    import time
    got = False
    for _ in range(5):
        try:
            import fcntl; fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB); got = True; break
        except OSError:
            time.sleep(1)
    if not got:
        print("tabs_status=lock-fail-closed"); sys.exit(3)
try:
    d = json.load(f)
    # --- schema guard (la garantia real, no el numero de version) --------------
    # Antes de escribir, confirma la forma EXACTA de la que depende el merge. Si
    # la TUI cambio el esquema en una version nueva, fallamos cerrado en vez de
    # deformar su archivo. Esto es lo que justifica aceptar cualquier 2.x.
    def bad_shape(v):
        return (not isinstance(v, dict) or not isinstance(v.get("tabs"), list)
                or not isinstance(v.get("unread"), dict))
    shape_ok = isinstance(d, dict) and "global" in d and isinstance(d.get("cwd"), dict)
    if shape_ok and bad_shape(d["global"]): shape_ok = False
    if shape_ok:
        for k, v in d["cwd"].items():
            if bad_shape(v): shape_ok = False; break
    if shape_ok:
        for scope in [d["global"]] + list(d["cwd"].values()):
            for t in scope["tabs"]:
                if not isinstance(t, dict) or not isinstance(t.get("sessionID"), str):
                    shape_ok = False; break
            if not shape_ok: break
    if not shape_ok:
        print("tabs_status=fail-closed-esquema-distinto"); sys.exit(6)
    os.makedirs(bk, exist_ok=True)
    shutil.copyfile(p, os.path.join(bk, "tabs.json.orchbak"))
    tabs = d.setdefault("cwd", {}).setdefault(tui_cwd, {}).setdefault("tabs", [])
    renamed = False
    for t in tabs:
        if t.get("sessionID") == sid:
            if title and t.get("title") != title:
                t["title"] = title
                renamed = True
            break
    else:
        tabs.append({"sessionID": sid, "title": title})
    # Escritura EN EL MISMO descriptor que esta bloqueado. Antes se usaba
    # temp + os.replace, que destruye el inodo: el lock quedaba sobre un archivo
    # que ya no existia, y dos merges concurrentes podian perder una tab
    # mientras AMBOS reportaban ok-verificada (S1b-10). Perdemos atomicidad de
    # rename, pero conservamos exclusion mutua real, que es lo que evita la
    # perdida silenciosa; el backup de arriba cubre el caso de crash a mitad.
    f.seek(0); f.truncate()
    json.dump(d, f, indent=2)
    f.flush()
    os.fsync(f.fileno())
    with open(p) as rb:
        rt = next((t for t in json.load(rb).get("cwd", {}).get(tui_cwd, {}).get("tabs", [])
                   if t.get("sessionID") == sid), None)
        ok = rt is not None
        title_ok = ok and (not title or rt.get("title") == title)
    print("tabs_status=%s" % ("ok-verificada-title" if title_ok else "readback-fail"))
    sys.exit(0 if ok and title_ok else 5)
finally:
    if lockmode == "fcntl":
        try:
            import fcntl; fcntl.flock(f, fcntl.LOCK_UN)
        except Exception:
            pass
    f.close()'

tabs_merge_py_file() {  # emits path to a temp .py with TABS_MERGE_PY
  _tmf=$(mktemp "${TMPDIR:-/tmp}/tabsmerge.XXXXXX")
  printf '%s\n' "$TABS_MERGE_PY" > "$_tmf"
  printf '%s' "$_tmf"
}

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

# --- version comparison (POSIX, no sort -V: BSD sort lacks it) -------------------
# version_ge A B -> 0 si A >= B. Compara componente a componente en numerico.
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    na = split(a, A, "."); nb = split(b, B, ".")
    n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) {
      x = A[i] + 0; y = B[i] + 0
      if (x > y) { exit 0 }
      if (x < y) { exit 1 }
    }
    exit 0
  }'
}
version_major() { printf '%s' "${1#v}" | cut -d. -f1 | tr -dc '0-9'; }

# --- naming convention (single source of truth; DRY) -------------------------------
# Pattern: "[NN] Name" — two-digit ordinal, space, human name. Examples:
#   [00] Orquestador        root / orchestrator
#   [10] Vermithrax         worker 1
#   [20] Glacielle          worker 2
#   [11] Saphira            sub-agent of worker 1
# Zero-padded so lexical order == numeric order, and one space (not a dot) because
# the TUI renders the title and a space is the most legible separator there.
#
# title_normalize ORDINAL NAME -> "[NN] Name"
#   Strips any existing [NN] and applies ORDINAL, so the caller always wins.
#   ORDINAL 0 therefore FORCES "[00]", which is how the root/orchestrator slot
#   is guaranteed regardless of what --title carried. Above 99 the width grows
#   to 3 digits and lexical sort stops matching numeric order.
title_normalize() {
  printf '%s' "$2" | awk -v ord="$1" '
    BEGIN { n = ord + 0; if (n < 0) n = 0; s = sprintf("%02d", n) }
    { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
    { sub(/^\[[0-9]+\][ \t]*/, "") }        # quita el ordinal previo
    { print "[" s "] " $0 }
  '
}

# worker_list LIST -> one normalized title per line, comma/newline delimited.
# NEVER splits on whitespace: a title may legitimately contain spaces
# ("[01] Vermithrax"), so whitespace is data, not a delimiter. Comma and
# newline are the only delimiters. Ordinals auto-increment 01, 02, 03... for
# entries without a leading [NN]; an explicit [NN] is always respected and
# advances the counter so a later auto entry never collides with it.
# [00] is left free for the root/orchestrator session, hence the counter
# starts at 1. Sequential (not stepped) numbering: dense and readable, at the
# cost that inserting a worker in the middle renumbers the later ones.
# Pure awk so it stays POSIX and needs no subshell round-trip (DRY: the only
# place that knows the pattern is title_normalize's contract, restated once).
worker_list() {
  printf '%s' "$1" | tr ',' '\n' | awk '
    function slug(s,   t) { t = s; sub(/^\[[0-9]+\][ \t]*/, "", t); gsub(/[ \t]/, "", t); return t }
    { line = $0
      sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
      if (line == "") next
      has = 0; ord = 0; ordtxt = ""
      if (match(line, /^\[[0-9]+\]/)) {
        has = 1
        # Keep the digits AS TEXT so "[00]" does not collapse to "[0]".
        ordtxt = substr(line, 2, RLENGTH - 2)
        ord = ordtxt + 0
        line = substr(line, RLENGTH + 1)
        sub(/^[ \t]+/, "", line)
        sub(/[ \t]+$/, "", line)
      }
      if (!has) { n += 1; ord = n; ordtxt = sprintf("%02d", n) }
      else if (ord > n) n = ord
      if (line == "") next
      # El ordinal 00 esta reservado a la raiz del orquestador. Un worker no
      # puede ocuparlo, ni siquiera explicitamente: init-run crea la raiz
      # siempre, y dos ranuras [00] harian ambigua la identidad del run.
      if (ordtxt + 0 == 0) { n = (n > 0 ? n : 1); ord = n; ordtxt = sprintf("%02d", n) }
      key = "[" ordtxt "] " line
      # Mismo criterio que find_dedup: el slug ignora el ordinal, asi que
      # "Vermithrax" y "[01] Vermithrax" se reconocen como el mismo worker.
      if (seen[slug(key)]++) next
      print key
    }'
}

# --- creacion de sesiones (compartido por ensure-root y create-worker; DRY) ----
# session_body TITLE AGENT MODEL -> JSON para POST /api/session (nada quemado)
session_body() {  # $1=title $2=agent $3=model(id@prov|vacio)
  _t=$(printf '%s' "$1" | json_escape); _d=$(printf '%s' "$PROJ_DIR" | json_escape)
  _a="${2:-build}"; _m="$3"
  MID="${_m%@*}"; MPROV="${_m#*@}"
  if [ -z "$_m" ] || [ "$MID" = "$MPROV" ]; then
    # La clave del cache es `model_default` (la que escribe preflight.sh).
    # Antes se leia `default_model`, un nombre que no existia en ningun sitio:
    # toda sesion creada por el script quedaba con model {id:"",providerID:""}
    # y al enviarle el prompt no habia modelo con el que inferir -> 0 tokens y
    # outcome=failed. Se acepta el nombre viejo como fallback por caches viejos.
    D=$(cache_get model_default)
    [ -n "$D" ] || D=$(cache_get default_model)
    MID="${D%@*}"; MPROV="${D#*@}"
  fi
  printf '{"title":"%s","agent":"%s","model":{"id":"%s","providerID":"%s"},"location":{"directory":"%s"}}' \
    "$_t" "$_a" "$MID" "$MPROV" "$_d"
}

# find_dedup TITLE -> "id out" si existe sesion con ese titulo (comparado por
# slug) en el proyecto; vacio si no hay match.
#
# El slug ignora el ordinal [NN] a proposito. "Vermithrax" y "[01] Vermithrax"
# son el MISMO worker: si el slug incluyera los corchetes, buscar por nombre
# nunca encontraria la sesion numerada y init-run creaba duplicados. El ordinal
# es decoracion de orden, la identidad es el nombre.
find_dedup() {
  AUTH=$(auth_flag 2>/dev/null || printf '')
  # El fetch va FUERA del pipeline: el rc de un pipe es el del ultimo comando
  # (awk), de modo que un fallo HTTP producia salida vacia + rc=0,
  # indistinguible de "no hay sesion" -> dedup_guard creaba duplicados en
  # silencio. Sin respuesta no hay match: se devuelve 3 para que el llamador
  # falle cerrado en lugar de inventar.
  RESP=$(http_get "$(cache_get endpoint)/api/session" 2>/dev/null) || return 3
  [ -n "$RESP" ] || return 3
  printf '%s' "$RESP" | tr -d '\n' | sed 's/},{"id":"/\n{"id":"/g' | \
    awk -v d="$PROJ_DIR" -v t="$1" \
      'function slug(s, x) { x = s; sub(/^\[[0-9]+\][ \t]*/, "", x); gsub(/[ \t]/, "", x); return x }
       BEGIN{t = slug(t)}
       match($0,/"directory":"[^"]+"/){dd=substr($0,RSTART+13,RLENGTH-14)}
       match($0,/"title":"[^"]+"/){tt=slug(substr($0,RSTART+9,RLENGTH-10))}
       {if(dd==d&&tt==t){match($0,/"id":"ses_[^"]+"/);id=substr($0,RSTART+6,RLENGTH-7);
        match($0,/"output":[0-9]+/);o=(RSTART?substr($0,RSTART+9,RLENGTH-9):0);
        print id, o; exit}}'
}

# dedup_guard TITLE: anti-pisoton unico para ensure-root y create-worker.
# Se invoca DENTRO de $( ) en los llamadores: nunca usa die aqui (moriria solo
# la subshell y el llamador crearia igual). Contrato de salida:
#   0 + stdout "worker_id=..." -> sesion inerte reusada (llamador la usa).
#   1 -> no hay match (ni --force-new): crear nueva.
#   2 + stdout "COLLISION out=N" -> titulo con trabajo previo: el LLAMADOR die.
dedup_guard() {
  [ "${FORCE_NEW:-0}" -eq 1 ] && return 1
  HIT=$(find_dedup "$1"); DRC=$?
  # rc 3 = no se pudo consultar el catalogo de sesiones. Tratarlo como
  # "no hay match" era exactamente la puerta de los duplicados: si la API
  # falla, NO se crea la sesion y se para el run.
  [ "$DRC" -eq 3 ] && return 3
  [ -n "$HIT" ] || return 1
  EX_ID=${HIT%% *}; EX_OUT=${HIT#* }
  if [ "${EX_OUT:-0}" = "0" ]; then
    printf 'worker_id=%s\ndedup=1 sesion-inerte-reusada\n' "$EX_ID"
    return 0
  fi
  printf 'COLLISION out=%s\n' "$EX_OUT"
  return 2
}

# post_new_session BODY -> emite worker_id=/location=/parentID=null (validado)
post_new_session() {
  AUTH=$(auth_flag 2>/dev/null || printf '')
  RESP=$(http_post_json "$(cache_get endpoint)/api/session" "$1") || die 'POST /api/session fallo'
  ID=$(printf '%s' "$RESP" | json_get_field id)
  # Validar el id era lo que faltaba: sin este check un POST "ok" con respuesta
  # sin id imprimia worker_id= vacio como hecho validado, y el llamador cacheaba
  # una raiz vacia retornando 0 (sesion inexistente creida creada).
  [ -n "$ID" ] && [ "${ID#ses_}" != "$ID" ] || die 'POST /api/session no devolvio un sessionID ses_*; no se creo sesion utilizable'
  PARENT=$(printf '%s' "$RESP" | json_get_field parentID)
  LOC=$(printf '%s' "$RESP" | json_get_field directory)
  [ -z "$PARENT" ] || [ "$PARENT" = "null" ] || die "parentID esperado null; obtuve $PARENT"
  [ "$LOC" = "$PROJ_DIR" ] || die "location mismatch: $LOC != $PROJ_DIR"
  printf 'worker_id=%s\nlocation=%s\nparentID=null\n' "$ID" "$LOC"
}