#!/bin/sh
# orchestrate.sh - swiss-army orchestration knife for OpenCode V2 (multi-OS).
# Detects the OS (or accepts --os); loads per-OS helpers; exposes subcommands.
# Usage: orchestrate.sh [--os <darwin|linux|wsl|windows-gbash>] <subcmd> [args]
# Contract: nothing hardcoded; endpoint/model/agents/project are resolved from the active state.
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

# OS first (defines os_project_dir / os_tabs_merge); _common after (uses them).
[ -f "$SELF_DIR/os/$OS.sh" ] || { printf 'ERROR: unsupported OS: %s\n' "$OS" >&2; exit 2; }
. "$SELF_DIR/os/$OS.sh"
. "$SELF_DIR/os/_common.sh"

# auth_flag lives in os/_common.sh (the low layer that uses it), not here.

# --- subcommands ----------------------------------------------------------------
sub_preflight() {
  ORCHESTRATE_CACHE_DIR="$CACHE_DIR" exec sh "$SELF_DIR/preflight.sh" "$@"
}

sub_ensure_root() {
  TITLE=""; AGENT=""; MODEL=""
  parse_kv "$@"
  # Without --title, the root is called Orchestrator: it is the canonical name
  # of the [00] session and avoids inventing a different title on each run.
  [ -n "$TITLE" ] || TITLE="Orchestrator"
  require_state
  # [00] is the orchestrator slot, ALWAYS. The default name is "Orchestrator";
  # a custom --title is normalized to the same ordinal, so the 00 prefix does
  # not depend on the operator remembering it (DRY: title_normalize is the
  # only implementation of the pattern).
  TITLE=$(title_normalize 0 "$TITLE")
  : "${AGENT:=$(cache_get default_agent)}"; : "${AGENT:=build}"
  # Same dedup as create-worker (anti-overwrite): one title = one session.
  GUARD_OUT=$(dedup_guard "$TITLE"); GRC=$?
  if [ "$GRC" -eq 3 ]; then
    die "could not query the session catalog for dedup; fail-closed (session not created)"
  fi
  if [ "$GRC" -eq 2 ]; then
    EX_OUT=$(printf '%s\n' "$GUARD_OUT" | sed 's/^COLLISION out=//')
    die "collision: '$TITLE' already exists with prior work (out=$EX_OUT); use another title or --force-new"
  fi
  if [ "$GRC" -eq 0 ]; then
    RID=$(printf '%s\n' "$GUARD_OUT" | awk -F= '/^worker_id/{print $2}')
    cache_put root_session "$RID"
    printf '%s\n' "$GUARD_OUT" | sed 's/^worker_id=/root_id=/'
    return 0
  fi
  OUT=$(post_new_session "$(session_body "$TITLE" "$AGENT" "$MODEL")"); PRC=$?
  [ "$PRC" -eq 0 ] || exit "$PRC"   # die already printed the reason
  RID=$(printf '%s\n' "$OUT" | awk -F= '/^worker_id/{print $2}')
  cache_put root_session "$RID"
  printf '%s\n' "$OUT" | sed 's/^worker_id=/root_id=/'
}

sub_create_worker() {
  TITLE=""; AGENT=""; MODEL=""
  parse_kv "$@"
  [ -n "$TITLE" ] || { printf '%s\n' '--title required' >&2; exit 2; }
  require_state
  # Idempotent dedup: same title (slug: no spaces) in the same project.
  # Only reuses inert sessions (out=0); if it has prior work, fail-closed.
  GUARD_OUT=$(dedup_guard "$TITLE"); GRC=$?
  if [ "$GRC" -eq 3 ]; then
    die "could not query the session catalog for dedup; fail-closed (session not created)"
  fi
  if [ "$GRC" -eq 2 ]; then
    EX_OUT=$(printf '%s\n' "$GUARD_OUT" | sed 's/^COLLISION out=//')
    die "collision: '$TITLE' already exists with prior work (out=$EX_OUT); use another title or --force-new"
  fi
  [ "$GRC" -eq 0 ] && { printf '%s\n' "$GUARD_OUT"; return 0; }
  : "${AGENT:=build}"
  post_new_session "$(session_body "$TITLE" "$AGENT" "$MODEL")"
}

sub_sessions() {
  require_state
  AUTH=$(auth_flag)
  # Only newlines are stripped: SPACES are preserved. `tr -d ' '` did double
  # duty compacting and also destroyed the title ("[01] Vermithrax"
  # -> "[01]Vermithrax"), which is exactly what this view must show.
  # The fetch stays outside the pipeline: with curl down, the pipe's rc was
  # awk's and an empty inventory read as "no sessions".
  RESP=$(http_get "$(cache_get endpoint)/api/session" 2>/dev/null) || die "GET /api/session failed; cannot list the inventory"
  [ -n "$RESP" ] || die "GET /api/session returned an empty response"
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
  [ -n "$SID" ] || { printf '%s\n' '--session required' >&2; exit 2; }
  # Same resolution as init-run (DRY): preflight cache, re-probing if the
  # requested pin is not the cached one. Before, attach-tabs reimplemented the
  # version comparison, drifted out of sync with init-run and wrote tabs.json
  # with the gate blocked.
  resolve_gate
  if [ "$GATE" != "ready" ] && [ "${FORCE_TABS:-0}" -ne 1 ]; then
    printf 'ERROR: tabs gate=%s; fail-closed (tabs.json untouched).\n' "${GATE:-no-preflight}" >&2
    printf 'Reason: %s\n' "${GATE_REASON:-run orchestrate.sh preflight}" >&2
    printf 'Next: if you confirmed the tabs.json schema, retry with --force-tabs, or mark the tab as not verified.\n' >&2
    exit 2
  fi
  [ "${FORCE_TABS:-0}" -eq 1 ] && [ "$GATE" != "ready" ] && \
    printf 'tabs_force=1 gate=%s (authorized by the operator)\n' "${GATE:-no-preflight}" >&2
  # --tui-cwd remains optional: if missing, it is resolved from the gate cached
  # by preflight (same data, not a guess).
  GATE_CWD=$(cache_get tabs_cwd | sed 's/^tui_cwd=//')
  [ -n "$TUI_CWD" ] || TUI_CWD="$GATE_CWD"
  [ -n "$TUI_CWD" ] || { printf '%s\n' 'ERROR: no --tui-cwd and no cached gate (run orchestrate.sh preflight to resolve the active TUI)' >&2; exit 2; }
  # Propagates the channel DETECTED by tui-detect to the OS adapters. Before,
  # it was written to the cache and nobody read it: each OS re-resolved the
  # channel on its own (darwin with glob, linux/wsl/windows with env or
  # "latest"), so a tab could end up "ok-verified" on a channel the TUI never
  # reads.
  DETECTED_CHANNEL=$(cache_get tabs_channel | sed 's/^tui_channel=//')
  if [ -n "$DETECTED_CHANNEL" ] && [ "$DETECTED_CHANNEL" != "none" ]; then
    export OPENCODE_TUI_CHANNEL="$DETECTED_CHANNEL"
    printf 'tabs_channel=%s (detected, propagated to the merge)\n' "$DETECTED_CHANNEL" >&2
  fi
  # Fail-closed: an explicit --tui-cwd that contradicts the real TUI is not accepted.
  if [ -n "$GATE_CWD" ] && [ "$TUI_CWD" != "$GATE_CWD" ]; then
    printf 'ERROR: --tui-cwd %s does not match the real TUI cwd %s; fail-closed (tabs.json untouched)\n' \
      "$TUI_CWD" "$GATE_CWD" >&2
    exit 2
  fi
  [ -d "$TUI_CWD" ] || { printf 'ERROR: --tui-cwd does not exist: %s (fail-closed; tabs.json left untouched)\n' "$TUI_CWD" >&2; exit 2; }
  [ -n "$TITLE" ] || TITLE="$SID"
  os_tabs_merge "$SID" "$TITLE" "$TUI_CWD" "$CACHE_DIR"
}

sub_watch() {
  SID=""; ARTIFACT=""; DEADLINE=""; INTERVAL=""
  parse_kv "$@"
  [ -n "$SID" ] && [ -n "$ARTIFACT" ] || { printf '%s\n' '--session and --artifact required' >&2; exit 2; }
  if cache_has endpoint; then OPENCODE_URL=$(cache_get endpoint); export OPENCODE_URL; fi
  if cache_has auth_password; then OPENCODE_PW=$(cat "$CACHE_DIR/auth_password"); export OPENCODE_PW; fi
  # Quoted positional args: they support paths with spaces (no arrays, pure POSIX).
  set -- "$SELF_DIR/watch_run.sh" -s "$SID" -a "$ARTIFACT"
  [ -n "$DEADLINE" ] && set -- "$@" -d "$DEADLINE"
  [ -n "$INTERVAL" ] && set -- "$@" -i "$INTERVAL"
  exec sh "$@"
}

sub_wait_idle() {
  SID=""; DEADLINE=600; INTERVAL=15
  parse_kv "$@"
  [ -n "$SID" ] || { printf '%s\n' '--session required' >&2; exit 2; }
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
  [ -n "$SID" ] && [ -n "$PROMPT_FILE" ] || { printf '%s\n' '--session and --prompt-file required' >&2; exit 2; }
  require_state
  [ -f "$PROMPT_FILE" ] || die "prompt file does not exist: $PROMPT_FILE"
  AUTH=$(auth_flag)
  # Guard against the silent failure: a session created without a resolved
  # model accepts the prompt, infers nothing (0 tokens) and ends in
  # outcome=failed with no visible error. Verified BEFORE sending, with the
  # reason stated.
  SINFO=$(curl -fsS -m 15 $AUTH "$(cache_get endpoint)/api/session/$SID" 2>/dev/null)
  SESS_M=$(printf '%s' "$SINFO" | tr -d '\n' | sed 's/.*"model":{"id":"\([^"]*\)".*/\1/')
  if [ -z "$SESS_M" ] || [ "$SESS_M" = "$SINFO" ]; then
    printf 'ERROR: session %s has no resolved model (empty model.id).\n' "$SID" >&2
    printf 'Cause: it was created without the model_default cache key, or its agent does not resolve a model.\n' >&2
    printf 'Next: recreate it with an explicit model: create-worker --title "<T>" --model <id>@<prov> --force-new\n' >&2
    exit 2
  fi
  TEXT=$(json_escape < "$PROMPT_FILE")
  # An empty prompt used to be dispatched with prompt=ok: workers running with
  # no instructions and no error signal. Fail-closed.
  [ -n "$TEXT" ] || die "prompt file empty or unreadable: $PROMPT_FILE"
  R=$(curl -fsS -m 60 $AUTH -H 'Content-Type: application/json' \
    -d '{"text":"'"$TEXT"'"}' "$(cache_get endpoint)/api/session/$SID/prompt") \
    || die 'POST /api/session/{id}/prompt failed'
  MID=$(printf '%s' "$R" | awk 'match($0,/"infoID":"[^"]+/){print substr($0,RSTART+10,RLENGTH-10); exit}')
  printf 'prompt=ok session=%s infoID=%s\n' "$SID" "${MID:-none}"
}

# resolve_gate: leaves in GATE / GATE_REASON / GATE_CWD the tabs-gate
# decision. It consumes the preflight cache (single source), but RE-PROBES
# when the cache does not match the requested pin: if the operator changes
# OPENCODE_TUI_PINNED_VERSION without re-running preflight, a stale cache would
# decide "ready" with a version the gate would reject. Failing on a stale
# cache is the same class of silent failure we already fixed twice.
resolve_gate() {
  # The pin (branch major) belongs to the detector; it is not re-declared
  # here, its default is left alone so there are not two truths (DRY). Before,
  # "2.0.22" was passed and the detector rejected it with exit 2; the
  # 2>/dev/null turned that into an empty gate that read as "no-preflight".
  WANT_PIN="${OPENCODE_TUI_PINNED_VERSION:-2}"
  PROBE=$(sh "$SELF_DIR/os/tui-detect.sh" "$PROJ_DIR" "$WANT_PIN" 2>/dev/null)
  if [ -n "$PROBE" ]; then
    GATE=$(printf '%s\n' "$PROBE" | sed -n 's/^gate=//p')
    GATE_REASON=$(printf '%s\n' "$PROBE" | sed -n 's/^gate_reason=//p')
    GATE_CWD=$(printf '%s\n' "$PROBE" | sed -n 's/^tui_cwd=//p')
    # Refresh the cache so attach-tabs sees the same decision (DRY).
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
  WORKERS=""; NO_ATTACH=0; TUI_CWD=""; TITLE=""; COUNT=""
  parse_kv "$@"
  require_state
  # INCREMENTAL POOL SCALING: the deployed [NN] sessions are a pool that
  # survives runs. init-run REUSES the idle ones and creates ONLY the delta;
  # ordinals come from the pool (max deployed + 1), never from the invocation
  # counter, so [01] is never repeated between calls.
  #   --count N             -> N workers, names from the dragon catalog
  #   --worker "Name"       -> explicit names (repeatable / commas)
  # A RUNNING worker (no time.idle) is a collision: it is not overwritten (fail-closed).
  MAXORD=$(pool_max_ordinal)
  if [ -n "$COUNT" ]; then
    case "$COUNT" in ''|*[!0-9]*) die "--count requires an integer" ;; esac
    [ "$COUNT" -ge 1 ] || die "--count must be >= 1"
    i=0
    while [ "$i" -lt "$COUNT" ]; do
      i=$((i + 1))
      DN=$(sh "$SELF_DIR/dragon_name.sh" "$i" 2>/dev/null) || DN="Worker$i"
      WORKER_TITLES="${WORKER_TITLES:+$WORKER_TITLES$NL}$DN"
    done
  fi
  [ -n "$POSITIONAL" ] && WORKER_TITLES="${WORKER_TITLES:+$WORKER_TITLES$NL}$POSITIONAL"
  [ -n "$WORKER_TITLES" ] && WORKERS="$WORKER_TITLES"
  [ -n "$WORKERS" ] || { printf '%s\n' '--count N or --worker "Title" (repeatable) required' >&2; exit 2; }
  printf 'init-run: dir=%s os=%s pool_up_to=[%02d] requested=%s\n' "$PROJ_DIR" "$OS" "$MAXORD" "$(printf '%s' "$WORKERS" | tr '\n' ',')"

  # Tabs gate resolved ONCE (resolve_gate). Before, it was an optional step
  # silently skipped when --tui-cwd was missing; now the decision is data and
  # the reason is printed no matter what.
  resolve_gate
  TUI_CWD="${TUI_CWD:-$GATE_CWD}"
  if [ "$NO_ATTACH" -eq 0 ]; then
    # An explicit --tui-cwd does NOT bypass the gate: it is checked against the
    # real detected cwd. Asking for a key the TUI does not use would create
    # orphan tabs (§3).
    if [ -n "$TUI_CWD" ] && [ -n "$GATE_CWD" ] && [ "$TUI_CWD" != "$GATE_CWD" ]; then
      printf 'tabs_gate=blocked reason=--tui-cwd %s != real TUI cwd %s (fail-closed; no cwd key created by guesswork)\n' \
        "$TUI_CWD" "$GATE_CWD"
      NO_ATTACH=1
      TUI_CWD=""
    elif [ "$GATE" = "ready" ] && [ -n "$TUI_CWD" ]; then
      printf 'tabs_gate=ready cwd=%s (%s)\n' "$TUI_CWD" "${GATE_REASON:-preflight}"
    else
      printf 'tabs_gate=blocked reason=%s (tabs not written; the run continues without tabs)\n' \
        "${GATE_REASON:-preflight not cached: run preflight}"
      NO_ATTACH=1
    fi
  fi

  # The orchestrator root is REUSED if the environment declares it
  # (OPENCODE_SESSION_ID, cached by preflight): in a project where the
  # orchestrator ALREADY is the [00] session with work, trying to create
  # another root collides and used to abort the run.
  # A new root is only created when none is declared.
  ROOT_TITLE="${TITLE:-Orchestrator}"
  if cache_has root_session_hint; then
    RID=$(cache_get root_session_hint)
    printf 'root=[00] %s -> %s (reused: it is the orchestrator session)\n' "$ROOT_TITLE" "$RID"
  else
    ROOT_OUT=$(sub_ensure_root --title "$ROOT_TITLE"); ROOT_RC=$?
    [ "$ROOT_RC" -eq 0 ] || die "ensure_root failed (rc=$ROOT_RC); aborting the run without a root"
    RID=$(printf '%s\n' "$ROOT_OUT" | awk -F= '/^root_id/{print $2}')
    [ -n "$RID" ] || die "ensure_root returned no root_id; aborting the run without a root"
    printf 'root=[00] %s -> %s\n' "$ROOT_TITLE" "$RID"
  fi
  ATTACHED=0; TABS_FAILED=0; FAILED=0; REUSED=0; CREATED=0
  # Line-driven, not word-split: a title is "[NN] Name" and the space is part
  # of it. `for t in $WORKERS` shredded these into two sessions each.
  WORKER_LIST=$(worker_list "$WORKERS")
  [ -n "$WORKER_LIST" ] || { printf 'ERROR: --workers/--worker produced no valid titles\n' >&2; exit 2; }
  # A failure must stop the run. With `| while` the loop runs in a SUBSHELL:
  # `die`/`exit` only killed the subshell, the parent carried on and ended up
  # printing "done". The heredoc keeps the loop in the current shell, so exit
  # truly propagates.
  POOL=$(pool_list) || die "could not query the worker pool; fail-closed"
  # INCREMENTAL SCALING: if the pool already has that NAME it is REUSED (idle)
  # or the run aborts (running, no idle = in progress, not overwritten); only
  # if it does not exist is it created, with the pool's next free ordinal.
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    SLUG=$(printf '%s' "$t" | awk '{sub(/^\[[0-9]+\][ \t]*/,"");gsub(/[ \t]/,"");print}')
    # EVERYTHING comes from the pool row (ordinal, state and sessionID): no
    # second API call and no unchecked rc. Before, the reuse path repeated the
    # fetch with find_dedup and did not verify its rc: on failure it cached an
    # empty worker_id and attached a tab to a nonexistent session.
    HIT=$(printf '%s\n' "$POOL" | awk -F'\t' -v s="$SLUG" '$4==s{print $1"\t"$3"\t"$5; exit}')
    if [ -n "$HIT" ]; then
      P_ORD=$(printf '%s' "$HIT" | cut -f1)
      P_ST=$(printf '%s' "$HIT" | cut -f2)
      ID=$(printf '%s' "$HIT" | cut -f3)
      if [ -z "$ID" ]; then
        printf 'ERROR: [%02d] %s exists in the pool without a usable sessionID\n' "$P_ORD" "$t" >&2
        FAILED=$((FAILED + 1)); continue
      fi
      if [ "$P_ST" != "idle" ]; then
        printf 'ERROR: [%02d] %s is RUNNING (no idle); it is not overwritten. Wait for wait-idle before reassigning work to it.\n' "$P_ORD" "$t" >&2
        FAILED=$((FAILED + 1)); continue
      fi
      printf 'reused  %s -> %s\n' "$t" "$ID"
      REUSED=$((REUSED + 1))
    else
      MAXORD=$((MAXORD + 1))
      t=$(title_normalize "$MAXORD" "$t")
      ID=$(sub_create_worker --title "$t" | awk -F= '/^worker_id/{print $2}')
      if [ -z "$ID" ]; then
        printf 'ERROR: create-worker failed for %s\n' "$t" >&2
        FAILED=$((FAILED + 1)); continue
      fi
      printf 'created %s -> %s\n' "$t" "$ID"
      CREATED=$((CREATED + 1))
    fi
    cache_put "worker_$t" "$ID"
    if [ "$NO_ATTACH" -eq 0 ]; then
      # Failure is no longer swallowed: each tab's state is reported.
      if sub_attach_tabs --session "$ID" --tui-cwd "$TUI_CWD" --title "$t" >/dev/null 2>&1; then
        printf 'tabs=ok %s\n' "$t"
      else
        printf 'tabs=%s FAILED (session exists; see attach-tabs --session %s --tui-cwd %s)\n' "$t" "$ID" "$TUI_CWD"
      fi
    fi
  # Deliberately WITHOUT quoting the delimiter: $WORKER_LIST must expand so
  # the loop reads the titles. W1 reported that the unquoted heredoc
  # re-expanded $ and backticks in the titles (S1a-07); that finding is FALSE:
  # expanding a variable does not re-scan its content. Tested with
  # "[01] Ver\$mite {\`id\`} and \\bar": the while loop reads the literal value.
  done <<EOF
$WORKER_LIST
EOF
  if [ "$FAILED" -gt 0 ]; then
    printf 'init-run: INCOMPLETE (%d worker(s) failed; no tab exposed for those)\n' "$FAILED" >&2
    exit 1
  fi
  printf 'pool: %d reused, %d created, %d failed\n' "$REUSED" "$CREATED" "$FAILED"
  [ "$NO_ATTACH" -eq 0 ] && printf 'tabs: exposed (not verified by sessionID; see tabs= lines)\n'
  printf 'init-run: done | next: orchestrate.sh send-prompt --session <ID> --prompt-file <path>\n'
}

sub_pool() {
  # Pool visibility BEFORE launching: what is deployed, its state and the next
  # free ordinal. This is the data that prevents recreating agents per task.
  require_state
  POOL=$(pool_list) || die "could not query the worker pool"
  if [ -z "$POOL" ]; then
    printf '%s\n' 'empty pool (no [NN] Name session in this project)'
    return 0
  fi
  printf '%-8s %-30s %-9s\n' ORDINAL NAME STATE
  printf '%s\n' "$POOL" | awk -F'\t' '{ printf "%-8s %-30s %-9s\n", "["$1"]", $2, $3 }'
  printf 'next free ordinal: [%02d]\n' $(( $(pool_max_ordinal) + 1 ))
}

sub_tabs() {
  # Tabs gate with no side effects: answers "is there a TUI and can I expose
  # tabs?" before creating anything. If an explicit --tui-cwd is given, it is
  # checked against the real detected cwd.
  TUI_CWD=""; parse_kv "$@"
  _probe=$(sh "$SELF_DIR/os/tui-detect.sh" "$PROJ_DIR" "${OPENCODE_TUI_PINNED_VERSION:-2}" 2>/dev/null)
  printf '%s\n' "$_probe"
  if [ -n "$TUI_CWD" ]; then
    _real=$(printf '%s\n' "$_probe" | sed -n 's/^tui_cwd_any=//p')
    if [ "$TUI_CWD" = "$_real" ]; then
      printf 'tui_cwd_request=match\n'
    else
      printf 'tui_cwd_request=MISMATCH requested=%s detected=%s (no cwd key will be created by guesswork)\n' "$TUI_CWD" "${_real:-none}"
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

# verify-daughters: R14 — confirms that each real child of a worker has
# parentID == worker and location.directory == run.location.directory. Uses the
# ?parentID= query in the URL (not --param, which the CLI ignores in this runtime).
sub_verify_daughters() {
  WORKER_ID=""; EXPECTED_PARENT=""
  parse_kv "$@"
  [ -n "$WORKER_ID" ] || { printf '%s\n' '--worker-id required' >&2; exit 2; }
  : "${EXPECTED_PARENT:=$WORKER_ID}"
  require_state
  # opencode api resolves server+auth and wants a PATH (with query), not a full URL.
  command -v opencode >/dev/null 2>&1 || die 'opencode CLI required for verify-daughters (not in PATH); run preflight and use the curl fallback with the auth recipe if applicable'
  command -v python3 >/dev/null 2>&1 || die 'python3 required for verify-daughters (JSON response parser)'
  RESP=$(opencode api GET "/api/session?parentID=$WORKER_ID" 2>/dev/null) \
    || die "GET /api/session?parentID=$WORKER_ID failed"
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
print("verified_ok=%d failures=%d" % (ok, fail))
if not d:
    print("ERROR: the query returned no children; a mistyped worker-id would read as success. Fail-closed.")
    sys.exit(2)
sys.exit(0 if fail == 0 else 2)'
}

# delete-session: R7. The active /openapi.json (v2.0.22 verified; the
# `2.0.21 vs 2.0.22` flap is irrelevant here because the gate is by major)
# publishes DELETE /api/session/{id}. Gate: enumerates children with GET
# ?parentID=; aborts if there are any unless --force is used; without --yes it
# requires typing "yes" (fail-closed for non-interactive use).
#
# FAIL-CLOSED ON ENUMERATION: if child enumeration fails (no python3, no
# network, auth), the "?" result is NOT treated as "no children". Deleting
# without knowing the cascade is unacceptable (R7), and with `--yes` that
# would have been a blind delete reporting success. Before, that was exactly
# the path it took.
sub_delete_session() {
  SID=""; YES=0; FORCE=0
  parse_kv "$@"
  [ -n "$SID" ] || { printf '%s\n' '--session required' >&2; exit 2; }
  case "$SID" in ses_*) : ;; *) printf '%s\n' 'ERROR: --session must have the ses_ prefix' >&2; exit 2 ;; esac
  require_state
  command -v opencode >/dev/null 2>&1 || die 'opencode CLI required (enumerate children per R7)'
  command -v python3 >/dev/null 2>&1 || die 'python3 required to enumerate children (R7): install python3 and retry'
  CHILDREN=$(opencode api GET "/api/session?parentID=$SID" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    print(len(json.load(sys.stdin).get("data",[])))
except Exception:
    print("?")' 2>/dev/null)
  if [ -z "$CHILDREN" ] || [ "$CHILDREN" = "?" ]; then
    printf 'ERROR: could not enumerate the children of %s; fail-closed (R7 requires knowing the cascade before deleting).\n' "$SID" >&2
    printf 'Check endpoint/auth and retry. --force does NOT override this gate.\n' >&2
    exit 2
  fi
  printf 'delete-session: target=%s children=%s\n' "$SID" "$CHILDREN" >&2
  if [ "$FORCE" -ne 1 ]; then
    if [ "$CHILDREN" != "0" ]; then
      printf 'ERROR: %s has %s children; R7 -> use --force to skip the check (you assume cascade delete)\n' "$SID" "$CHILDREN" >&2
      exit 2
    fi
    if [ "$YES" -ne 1 ]; then
      printf 'DELETE %s (children=%s)? Type "yes" to continue: ' "$SID" "$CHILDREN" >&2
      if ! IFS= read -r ans; then printf '\naborted (no input)\n' >&2; exit 2; fi
      [ "$ans" = "yes" ] || { printf 'aborted\n' >&2; exit 2; }
    fi
  fi
  AUTH=$(auth_flag)
  curl -fsS -m 30 $AUTH -X DELETE "$(cache_get endpoint)/api/session/$SID" \
    || die "DELETE /api/session/$SID failed"
  printf 'deleted=%s children_was=%s\n' "$SID" "$CHILDREN"
}

sub_help() {
  cat <<'USAGE'
orchestrate.sh [--os <darwin|linux|wsl|windows-gbash>] <subcmd> [args]
Equivalent wrappers: orchestrate-darwin.sh | orchestrate-linux.sh | orchestrate-wsl.sh | orchestrate-windows.sh

Subcommands:
  preflight [dir]                    delegates to scripts/preflight.sh and populates the state cache
  ensure-root --title T              POST /api/session root; verifies parentID=null; caches root_session
  create-worker --title T [--agent A] [--model id@prov] [--force-new]
                                     POST /api/session; verifies parentID=null and literal location;
                                     dedup: if an inert session (out=0) with that title already exists in
                                     the project, it is reused; --force-new skips dedup and creates a new one
  sessions                            project session inventory (id, out, title)
  send-prompt --session SID --prompt-file F
                                     POST prompt with awk JSON-escape (no python)
  attach-tabs --session SID [--tui-cwd PATH] [--title T]
                                     additive merge of tabs.json with OS-specific lock; readback; not verified.
                                     --tui-cwd is optional: without it, the gate cached by preflight is used.
  tabs [--tui-cwd PATH]              side-effect-free TUI/tabs gate: pids, real cwd, channel, version,
                                     ready|blocked + reason (recipe-tui-tabs.md §3/§6)
  watch --session SID --artifact A[,A...] [--deadline D] [--interval I]
                                     delegates to scripts/watch_run.sh
  wait-idle --session SID [--deadline D] [--interval I]
                                     polls until time.idle; prints outcome
  init-run --worker "T1" --worker "T2" [--title ROOT] [--no-attach-tabs]
                                     creates root (optional) + workers + tabs in one command.
                                     ONE single invocation per run: the [NN] sequence is assigned
                                     inside it; calling it twice resets the counter to [01].
                                     Tabs by default if the cached gate says ready; --tui-cwd optional
  self-check                         reports OS, tools and cached state
  pool                               deployed [NN] workers (ordinal, name, idle/running)
                                     and next free ordinal: look at this BEFORE launching
  verify-daughters --worker-id WID [--expected-parent WID]
                                     GET /api/session?parentID= lists children and validates that
                                     each one has parentID=expected_parent and
                                     location.directory=run.location.directory (R14).
  delete-session --session SID [--yes] [--force]
                                     DELETE /api/session/{id} (verified in the active
                                     /openapi.json; R7 -> checks children and requires confirmation).
                                     --yes: skips prompt. --force: skips the children check.
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
  pool) sub_pool "$@" ;;
  tabs) sub_tabs "$@" ;;
  verify-daughters) sub_verify_daughters "$@" ;;
  delete-session) sub_delete_session "$@" ;;
  ""|-h|--help|help) sub_help; exit 0 ;;
  *) printf 'unknown subcommand: %s\n' "$SUBCMD" >&2; sub_help >&2; exit 2 ;;
esac