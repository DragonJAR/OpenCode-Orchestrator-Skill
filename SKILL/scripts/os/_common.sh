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
# AUTH is intentionally unquoted. The basic-auth password used by
# OpenCode contains characters that, when wrapped in one argument via
# shell word splitting, change how curl parses the colon-separated user:pass
# pair (some curl versions split on the colon and treat the right-hand side
# as a URL, yielding HTTP 401). With AUTH as separate words (no surrounding
# quotes), curl sees -u followed by user:pass as two separate arguments
# and authenticates correctly. Quoting re-breaks this path; the
# corresponding SC2086 warning is a known false positive here.
http_get() { curl -fsS -m 30 ${AUTH:-} "$1"; }
http_post_json() { curl -fsS -m 30 ${AUTH:-} -H 'Content-Type: application/json' -d "$2" "$1"; }

# --- json (jq-less; awk) --------------------------------------------------------
json_escape() {  # stdin -> JSON string body (no quotes) with \n between lines
  awk 'BEGIN{ORS=""}{gsub(/\\/,"\\\\");gsub(/"/,"\\\"");gsub(/\t/,"\\t");gsub(/\r/,"\\r");if(NR>1)printf "\\n";printf "%s",$0}'
}
json_get_field() {  # stdin=JSON, $1=KEY -> emits the value
  awk -v k="\"$1\"" 'index($0,k){p=index($0,k)+length(k);
    while(p<=length($0)&&substr($0,p,1)~/[ \t:]/)p++; s=p; c=substr($0,s,1);
    if(c=="{"||c=="["){d=0;for(i=s;i<=length($0);i++){x=substr($0,i,1);if(x==c)d++;else if(x==(c=="{"?"}":"]")){d--;if(d==0){print substr($0,s,i-s+1);exit}}}}
    else{e=p;while(e<=length($0)&&substr($0,e,1)!~/[,\}]/)e++;v=substr($0,s,e-s);gsub(/^"|"$/,"",v);print v;exit}}'
}

# --- kv cache -------------------------------------------------------------------
cache_put() { printf '%s\n' "$2" > "$CACHE_DIR/$1"; }
cache_get() { if [ -f "$CACHE_DIR/$1" ]; then cat "$CACHE_DIR/$1"; else printf ''; fi; }
cache_has() { [ -f "$CACHE_DIR/$1" ] && [ -s "$CACHE_DIR/$1" ]; }
# auth_flag: Basic-auth flag for curl. It lives HERE, not in orchestrate.sh,
# because find_dedup and http_* use it and _common.sh is the low layer.
# Defining it in the caller would create a dependency on sourcing order:
# correct at runtime, fragile against any test or direct inclusion of _common.sh.
auth_flag() { if cache_has auth_password; then printf '%s' "-u opencode:$(cat "$CACHE_DIR/auth_password")"; fi; }
require_state() {
  for k in endpoint version projectID model_default; do
    cache_has "$k" || { printf 'ERROR: state not initialized; run: orchestrate.sh preflight %s\n' "$PROJ_DIR" >&2; exit 1; }
  done
}

# --- arg parsing ------------------------------------------------------------------
parse_kv() {
  # POSITIONAL collects loose tokens. Before, `*) shift` discarded them
  # silently, so `init-run --workers "T1" "T2" "T3"` created only T1 with no
  # warning. They are now added to WORKERS (see sub_init_run).
  POSITIONAL=""; WORKER_TITLES=""
  # shellcheck disable=SC2034  # TITLE/AGENT/MODEL/WORKER_ID are populated by parse_kv and read by callers (sub_create_worker, sub_send_prompt, etc.); shellcheck can't see across function boundaries
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
      --count) COUNT="${2:-}"; shift 2 ;;
      --worker) WORKER_TITLES="${WORKER_TITLES:+$WORKER_TITLES$NL}${2:-}"; shift 2 ;;
      --worker=*) WORKER_TITLES="${WORKER_TITLES:+$WORKER_TITLES$NL}${1#--worker=}"; shift ;;
      --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
      --router-prompt) ROUTER_PROMPT="${2:-}"; shift 2 ;;
      --no-router) NO_ROUTER=1; shift ;;
      --target) WORKER="${2:-}"; shift 2 ;;
      --auto-count) AUTO_COUNT=1; shift ;;
      --wait) WAIT=1; shift ;;
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
    sroot = os.environ.get("OPENCODE_STATE_ROOT") or os.environ.get("ORCHESTRATE_STATE_ROOT","")
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
    # --- schema guard (the real guarantee, not the version number) --------------
    # Before writing, confirm the EXACT shape the merge depends on. If the TUI
    # changed the schema in a new version, we fail closed instead of deforming
    # its file. This is what justifies accepting any 2.x.
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
    # Write through the SAME descriptor that holds the lock. temp + os.replace
    # was used before, which destroys the inode: the lock ended up on a file
    # that no longer existed, and two concurrent merges could lose one tab
    # while BOTH reported ok-verified (S1b-10). We lose rename atomicity but
    # keep real mutual exclusion, which is what prevents silent loss; the
    # backup above covers the crash-mid-write case.
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

# parse_short_id REF -> "PARENT SUB"  (SUB empty for root/worker)
# Accepts: "01", "1", "01s02", "[01]s[02]", "[01]s02", "01s2"
# The encoding is the worker's `[NN]` prefix optionally followed by `s[MM]`
# (sub-agent of that worker; R3c forbids a third level, so the grammar stops at `s`).
parse_short_id() {
  r=${1:-}
  case "$r" in
    *[!0-9s\[\]]*) printf '' ;;  # any disallowed char -> invalid
    *)
      r=$(printf '%s' "$r" | tr -d '[]')  # strip optional brackets (POSIX-portable)
      case "$r" in
        *s*) N=${r%%s*}; M=${r#*s}
              case "$N$M" in *[!0-9]*) printf '' ;;
                *) [ -n "$N" ] && [ -n "$M" ] && printf '%s %s\n' "$N" "$M" || printf '' ;; esac ;;
        *) case "$r" in *[!0-9]*) printf '' ;; *) [ -n "$r" ] && printf '%s\n' "$r" || printf '' ;; esac ;;
      esac
      ;;
  esac
}

# tabs_json_path -> prints the ABSOLUTE path of the active TUI's tabs.json.
# SINGLE SOURCE of the resolution (DRY): before, darwin/tui-detect discovered
# the channel by glob and honored XDG_STATE_HOME, while linux/wsl/windows
# guessed "latest" and hardcoded ~/.local/state — 8 sites that could write a
# tab into a channel the TUI never reads. The adapters only decide the lock
# mechanism.
# Exit 4 = no TUI with storage (the caller reports no-tui).
tabs_json_path() {
  SR=${OPENCODE_STATE_ROOT:-}
  if [ -z "$SR" ] && command -v opencode >/dev/null 2>&1; then
    SR=$(opencode debug paths state 2>/dev/null | head -1)
  fi
  [ -n "$SR" ] || SR="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"
  if [ -n "${OPENCODE_TUI_CHANNEL:-}" ] && [ -f "$SR/$OPENCODE_TUI_CHANNEL/tui/tabs.json" ]; then
    printf '%s\n' "$SR/$OPENCODE_TUI_CHANNEL/tui/tabs.json"; return 0
  fi
  for c in "$SR"/*; do
    [ -d "$c" ] || continue
    if [ -f "$c/tui/tabs.json" ]; then printf '%s\n' "$c/tui/tabs.json"; return 0; fi
  done
  return 4
}

# pool_list -> "ordinal<TAB>name<TAB>state<TAB>slug<TAB>sid<TAB>out<TAB>parent" lines.
# parent is the worker's [NN] for sub-agents (empty for root/worker). The pool is
# the set of project sessions titled "[NN] Name" (workers) or "[NN]s[MM] Name"
# (sub-agents). The ordinal/sub-ordinal pair is the stable identity: it survives
# runs and allows INCREMENTAL scaling (reuse the deployed ones, create only the
# missing delta).
pool_list() {
  # SINGLE SOURCE of the pool: one /api/session fetch for whoever needs
  # workers (pool, dedup, init-run). Parses with python3 (already a
  # dependency for sub_dispatch's wait-idle prompt and verify-daughters);
  # portable, robust to bracket mismatches and the closure-quirks of nawk.
  AUTH=$(auth_flag 2>/dev/null || printf '')
  RESP=$(http_get "$(cache_get endpoint)/api/session" 2>/dev/null) || return 3
  [ -n "$RESP" ] || return 3
  # Columns: ordinal<TAB>name<TAB>state<TAB>slug<TAB>sid<TAB>out<TAB>parent
  # 7 columns; `d == d` filter for the project directory.
  printf '%s' "$RESP" | python3 -c "
import json, sys, re
d = sys.argv[1]
data = json.loads(sys.stdin.read()).get('data', [])
for s in data:
    loc = s.get('location', {}).get('directory', '')
    if loc != d:
        continue
    title = s.get('title', '')
    m = re.match(r'^\[(\d+)\](?:s\[(\d+)\])?\s+(.*)$', title)
    if not m:
        continue
    ord = int(m.group(1))
    parent = m.group(2) if m.group(2) is not None else ''
    sid = s.get('id', '')
    out = s.get('output', 0)
    nm = m.group(3)  # capture properly
    idle = s.get('time', {}).get('idle', 0)
    updated = s.get('time', {}).get('updated', 0)
    st = 'idle' if idle and updated and idle >= updated else 'running'
    print('\t'.join([str(ord), nm, st, '', sid, str(out), str(parent)]))
" "$PROJ_DIR" | sort -t'	' -k7,7 -k1,1n
}


# pool_max_ordinal -> highest deployed ordinal (0 if the pool is empty).
pool_max_ordinal() {
  pool_list | awk -F'\t' 'BEGIN{m=0}{if($1+0>m)m=$1+0}END{print m}'
}

# --- version comparison (POSIX, no sort -V: BSD sort lacks it) -------------------
# --- naming convention (single source of truth; DRY) -------------------------------
# Pattern: "[NN] Name" — two-digit ordinal, space, human name. Examples:
#   [00] Orchestrator       root / orchestrator
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
    { sub(/^\[[0-9]+\][ \t]*/, "") }        # strips the previous ordinal
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
      # The 00 ordinal is reserved for the orchestrator root. A worker cannot
      # take it, not even explicitly: init-run always creates the root, and two
      # [00] slots would make the run identity ambiguous.
      if (ordtxt + 0 == 0) { n = (n > 0 ? n : 1); ord = n; ordtxt = sprintf("%02d", n) }
      key = "[" ordtxt "] " line
      # Same criterion as find_dedup: the slug ignores the ordinal, so
      # "Vermithrax" and "[01] Vermithrax" are recognized as the same worker.
      if (seen[slug(key)]++) next
      print key
    }'
}

# --- session creation (shared by ensure-root and create-worker; DRY) -----------
# session_body TITLE AGENT MODEL -> JSON for POST /api/session (nothing hardcoded)
session_body() {  # $1=title $2=agent $3=model(id@prov|empty)
  _t=$(printf '%s' "$1" | json_escape); _d=$(printf '%s' "$PROJ_DIR" | json_escape)
  _a="${2:-build}"; _m="$3"
  MID="${_m%@*}"; MPROV="${_m#*@}"
  if [ -z "$_m" ] || [ "$MID" = "$MPROV" ]; then
    # The cache key is `model_default` (the one preflight.sh writes). Before,
    # `default_model` was read — a name that existed nowhere: every session
    # created by the script ended up with model {id:"",providerID:""} and,
    # when the prompt was sent, there was no model to infer with -> 0 tokens
    # and outcome=failed. The old name is accepted as a fallback for old caches.
    D=$(cache_get model_default)
    [ -n "$D" ] || D=$(cache_get default_model)
    MID="${D%@*}"; MPROV="${D#*@}"
  fi
  printf '{"title":"%s","agent":"%s","model":{"id":"%s","providerID":"%s"},"location":{"directory":"%s"}}' \
    "$_t" "$_a" "$MID" "$MPROV" "$_d"
}

# find_dedup TITLE -> "id out" if a session with that title exists (compared
# by slug) in the project; empty if there is no match.
#
# The slug deliberately ignores the [NN] ordinal. "Vermithrax" and
# "[01] Vermithrax" are the SAME worker: if the slug included the brackets,
# searching by name would never find the numbered session and init-run
# created duplicates. The ordinal is ordering decoration; the identity is the
# name.
find_dedup() {
  # Thin filter over pool_list (SINGLE SOURCE of the fetch: DRY). Returns the
  # "id out" of the session whose title matches by slug ignoring the ordinal —
  # "Vermithrax" finds "[01] Vermithrax" — or nothing if there is no match.
  # rc 3 = the pool could not be queried: the caller must fail closed.
  POOL=$(pool_list) || return 3
  printf '%s\n' "$POOL" | awk -F'\t' -v t="$1" '
      function slug(s, x) { x = s; sub(/^\[[0-9]+\][ \t]*/, "", x); gsub(/[ \t]/, "", x); return x }
      BEGIN { t = slug(t) }
      $4 == t { print $5, $6; exit }'
}

# dedup_guard TITLE: single anti-overwrite guard for ensure-root and create-worker.
# It is invoked INSIDE $( ) by the callers: never uses die here (only the
# subshell would die and the caller would still create the session). Output
# contract:
#   0 + stdout "worker_id=..." -> inert session reused (the caller uses it).
#   1 -> no match (nor --force-new): create a new one.
#   2 + stdout "COLLISION out=N" -> title with prior work: the CALLER dies.
dedup_guard() {
  [ "${FORCE_NEW:-0}" -eq 1 ] && return 1
  HIT=$(find_dedup "$1"); DRC=$?
  # rc 3 = the session catalog could not be queried. Treating it as "no
  # match" was exactly the door to duplicates: if the API fails, the session
  # is NOT created and the run stops.
  [ "$DRC" -eq 3 ] && return 3
  [ -n "$HIT" ] || return 1
  EX_ID=${HIT%% *}; EX_OUT=${HIT#* }
  if [ "${EX_OUT:-0}" = "0" ]; then
    printf 'worker_id=%s\ndedup=1 inert-session-reused\n' "$EX_ID"
    return 0
  fi
  printf 'COLLISION out=%s\n' "$EX_OUT"
  return 2
}

# post_new_session BODY -> emits worker_id=/location=/parentID=null (validated)
post_new_session() {
  AUTH=$(auth_flag 2>/dev/null || printf '')
  RESP=$(http_post_json "$(cache_get endpoint)/api/session" "$1") || die 'POST /api/session failed'
  ID=$(printf '%s' "$RESP" | json_get_field id)
  # Validating the id was the missing piece: without this check a "ok" POST
  # whose response lacked an id printed an empty worker_id= as validated, and
  # the caller cached an empty root returning 0 (nonexistent session believed
  # created).
  [ -n "$ID" ] && [ "${ID#ses_}" != "$ID" ] || die 'POST /api/session returned no ses_* sessionID; no usable session was created'
  PARENT=$(printf '%s' "$RESP" | json_get_field parentID)
  LOC=$(printf '%s' "$RESP" | json_get_field directory)
  [ -z "$PARENT" ] || [ "$PARENT" = "null" ] || die "expected null parentID; got $PARENT"
  [ "$LOC" = "$PROJ_DIR" ] || die "location mismatch: $LOC != $PROJ_DIR"
  printf 'worker_id=%s\nlocation=%s\nparentID=null\n' "$ID" "$LOC"
}