#!/bin/sh
# orchestrate.sh - swiss-army orchestration knife for OpenCode V2 (multi-OS).
# Detects the OS (or accepts --os); loads per-OS helpers; exposes subcommands.
# Usage: orchestrate.sh [--os <darwin|linux|wsl|windows-gbash>] <subcmd> [args]
# Contract: nothing hardcoded; endpoint/model/agents/project are resolved from the active state.
# Exit codes (wait-idle): 0 idle (0 also for a never-used session), 2 usage, 3 timeout, 4 stuck, 5 session-not-found.
# shellcheck source-path=scripts source=scripts
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
export SELF_DIR #: sub_clean's tabs-prune helper sources _common.sh via $SELF_DIR
OS_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    # The shared guard (os/_common.sh assert_value) is not loaded yet: this
    # parse runs BEFORE the OS adapter is sourced, because --os decides WHICH
    # adapter to load. `shift 2` with no value left does not advance the
    # argument list (POSIX), so the loop would spin forever -- hence the
    # inline check here.
    --os) [ $# -ge 2 ] || { printf '%s\n' 'ERROR: --os requires a value' >&2; exit 2; }; OS_OVERRIDE="$2"; shift 2 ;;
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

# OS first (defines os_project_dir / os_tabs_merge); os/_paths.sh next (F5:
# shared PROJ_DIR/CACHE_DIR derivation, also used by standalone preflight.sh);
# _common after (requires CACHE_DIR and uses os_project_dir).
[ -f "$SELF_DIR/os/$OS.sh" ] || { printf 'ERROR: unsupported OS: %s\n' "$OS" >&2; exit 2; }
# shellcheck disable=SC1091  # runtime-determined source paths (OS-dependent, also fetched by IDLE_POOL later in the file).
. "$SELF_DIR/os/$OS.sh"
# shellcheck disable=SC1091
. "$SELF_DIR/os/_paths.sh"
# shellcheck disable=SC1091
. "$SELF_DIR/os/_common.sh"

# auth_flag lives in os/_common.sh (the low layer that uses it), not here.

# assert_uint LABEL VALUE -- refuse unless VALUE is a positive integer (>= 1).
# D1: `--deadline 120s` reached `[ ... -ge "$DEADLINE" ]`, which printed
# "integer expression expected" to stderr and CONTINUED: the deadline was never
# enforced and the command still exited 0. Validated at PARSE time instead,
# with a portable case (no regex(3)); exit 2 is the documented usage code.
assert_uint() {
  case "${2:-}" in
    ''|*[!0-9]*) printf 'ERROR: %s must be a positive integer, got: %s\n' "$1" "${2:-<empty>}" >&2; exit 2 ;;
  esac
  [ "${2:-0}" -ge 1 ] 2>/dev/null || { printf 'ERROR: %s must be >= 1, got: %s\n' "$1" "$2" >&2; exit 2; }
}

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
    # The [00] slot belongs to init-run and SURVIVES RUNS (the pool survives
    # runs). A root that already exists -- busy, or with prior work -- is
    # REUSED, not refused: the router prompt alone leaves the root "running",
    # so refusing it made a second init-run impossible. The collision guard
    # protects a WORKER's work from being overwritten; the root is never
    # overwritten either, it is reused.
    EX_ID=$(printf '%s\n' "$GUARD_OUT" | sed -n 's/.* id=\(ses_[A-Za-z0-9]*\).*/\1/p')
    if [ -n "$EX_ID" ]; then
      cache_put root_session "$EX_ID"
      printf 'root_id=%s\nroot_reused=1 note=the [00] session already exists (busy or with prior work); it is reused, never replaced\n' "$EX_ID"
      return 0
    fi
    EX_OUT=$(printf '%s\n' "$GUARD_OUT" | sed 's/^COLLISION out=//')
    die "collision: '$TITLE' is not reusable ($EX_OUT); use another title or --force-new"
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
    die "collision: '$TITLE' is not reusable ($EX_OUT); use another title or --force-new"
  fi
  [ "$GRC" -eq 0 ] && { printf '%s\n' "$GUARD_OUT"; return 0; }
  : "${AGENT:=build}"
  post_new_session "$(session_body "$TITLE" "$AGENT" "$MODEL")"
}

sub_sessions() {
  require_state
  # Only newlines are stripped: SPACES are preserved. `tr -d ' '` did double
  # duty compacting and also destroyed the title ("[01] Vermithrax"
  # -> "[01]Vermithrax"), which is exactly what this view must show.
  # The fetch stays outside the pipeline: with curl down, the pipe's rc was
  # awk's and an empty inventory read as "no sessions".
  RESP=$(project_sessions_json) || die "GET /api/session failed; cannot list the inventory"
  [ -n "$RESP" ] || die "GET /api/session returned an empty response"
  # ONE awk pass (a per-record scan; a subshell per field per record cost ~35ms
  # per session, which is a real regression on an inventory view).
  # The offset formula is the ONE of json_get_field (os/_common.sh): the value
  # starts at the key prefix and is read to its natural end. The offsets are
  # DERIVED from the key, never hardcoded -- a typo can no longer shift a
  # field by one character or one digit, which is exactly how the msgID and
  # the millisecond timestamps got truncated in wait-idle.
  printf '%s' "$RESP" | tr -d '\n' | sed 's/},{"id":"/\n{"id":"/g' | \
    awk -v d="$(printf '%s' "$PROJ_DIR" | sed 's/\\/\\\\/g')" '
    function field(s, key,   k, p, v, q, j, e, n) {
      k = "\"" key "\""
      p = index(s, k)
      if (!p) return ""
      p += length(k)
      while (p <= length(s) && substr(s, p, 1) ~ /[ \t]/) p++
      if (substr(s, p, 1) != ":") return ""
      p++
      while (p <= length(s) && substr(s, p, 1) ~ /[ \t]/) p++
      v = substr(s, p)
      if (substr(v, 1, 1) == "\"") {
        q = substr(v, 2); j = index(q, "\"")
        return (j > 0 ? substr(q, 1, j - 1) : q)
      }
      e = 1
      while (e <= length(v) && substr(v, e, 1) !~ /[,}\]]/) e++
      n = substr(v, 1, e - 1)
      gsub(/[^0-9].*$/, "", n)
      return n
    }
    { dd = field($0, "directory"); if (dd != d) next
      printf "%s out=%-6s %s\n", field($0, "id"), field($0, "output"), field($0, "title") }'
}

sub_attach_tabs() {
  SID=""; TUI_CWD=""; TITLE=""
  parse_kv "$@"
  [ -n "$SID" ] || { printf '%s\n' '--session required' >&2; exit 2; }
 #: verify the session exists BEFORE the merge. A typo'd SID used to
  # write a ghost tab and still report ok (the readback proves the JSON write,
  # not the session). Fail-closed: tabs.json untouched, no phantom entry.
  opencode api GET "/api/session/$SID" >/dev/null 2>&1 \
    || { printf 'ERROR: attach-tabs: session %s not found; no tab written\n' "$SID" >&2; exit 2; }
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
  [ -z "$DEADLINE" ] || assert_uint --deadline "$DEADLINE"
  [ -z "$INTERVAL" ] || assert_uint --interval "$INTERVAL"
  if cache_has endpoint; then OPENCODE_URL=$(cache_get endpoint); export OPENCODE_URL; fi
  if cache_has auth_password; then OPENCODE_PW=$(cache_get auth_password); export OPENCODE_PW; fi
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
  assert_uint --deadline "$DEADLINE"
  assert_uint --interval "$INTERVAL"
  require_state
 #: one existence probe BEFORE the loop. A typo'd SID used to be retried
  # as if it were a transient API error and only gave up at --deadline (600s
  # by default) as a misleading timeout. 404 / bad JSON / no ses_ id -> exit 5.
  R=$(opencode api GET "/api/session/$SID" 2>/dev/null) || R=""
  case "$R" in *'"id":"ses_'*) : ;; *) printf 'wait-idle=session-not-found session=%s\n' "$SID"; exit 5 ;; esac
  # Pool-safe: sessions are REUSED across tasks, so a time.idle inherited
  # from a previous run would cause this wait to return immediately with stale
  # values. send-prompt caches the dispatch timestamp per session; if it
  # exists, only an idle timestamp NEWER than that mark counts as done.
 # NOT silenced: cache_get reports a symlinked key (CWE-59) on stderr,
  # and hiding it made the dispatch mark silently empty -> wait-idle accepted
  # an inherited (stale) time.idle.
  SINCE=$(cache_get "dispatch_$SID")
  # F2: a session that NEVER received a task is trivially idle - do not poll
  # it to the deadline (600s) or downplay it as "stuck ... reassign". The
  # state comes from the SAME session_state helper as pool_list (F1, one
 # derivation); above already distinguished "does not exist" (exit 5)
  # from "never used" (exit 0 here). A dispatch mark (SINCE) disables the
  # shortcut: the prompt is in flight and the session must be waited on.
  # All five fields come from the ONE shared getter (json_get_field): the old
  # inline `match()/substr()` extractions used two different offset conventions
 # and time.updated/time.created lost a digit, which made a busy
  # session compare as "older than idle" and mis-classify it.
  W_OUT=$(printf '%s' "$R" | json_get_field output)
  W_OC=$(printf '%s' "$R" | json_get_field outcome)
  [ -n "$W_OC" ] && W_OC=1 || W_OC=0
  W_IDLE=$(printf '%s' "$R" | json_get_field idle)
  W_UPD=$(printf '%s' "$R" | json_get_field updated)
  W_CRE=$(printf '%s' "$R" | json_get_field created)
  if [ -z "$SINCE" ] && [ "$(session_state "${W_OUT:-0}" "${W_IDLE:-0}" "${W_UPD:-0}" "${W_CRE:-0}" "${W_OC:-0}")" = "empty" ]; then
    printf 'wait-idle=ok session=%s state=empty (never received a task; nothing to wait for)\n' "$SID"
    exit 0
  fi
  # Stuck detection: a worker that hangs (e.g. empty completion in the Glacielle
  # lineage) does NOT go idle and does NOT advance time.updated. Turning that
  # hang into a detectable state lets the orchestrator reassign (previously it
  # was an infinite silence indistinguishable from slow work).
  STUCK_SECS=900
  START=$(date +%s); LAST_UPD=""; STUCK_AT=0
  while : ; do
    now=$(date +%s)
    [ $((now - START)) -ge "$DEADLINE" ] && { printf 'wait-idle=timeout session=%s\n' "$SID"; exit 3; }
    R=$(opencode api GET "/api/session/$SID" 2>/dev/null) || { sleep "$INTERVAL"; continue; }
    IDLE=$(printf '%s' "$R" | json_get_field idle)
    UPD=$(printf '%s' "$R" | json_get_field updated)
    if [ -n "$SINCE" ]; then
      # pool-safe: el idle debe ser posterior al despacho de ESTA tarea
      # C-13: >= not > — both stamps are second-granular (date +%s + "000"), so a
      # worker idle in the SAME second as the dispatch would otherwise poll to a
      # spurious timeout (rc 3). Trade-off: a stale idle within that same second
      # is accepted; the window is 1s vs. a guaranteed spurious timeout.
      [ -n "$IDLE" ] && [ "$IDLE" -ge "$SINCE" ] && break
    else
      [ -n "$IDLE" ] && break
    fi
    if [ -n "$UPD" ]; then
      if [ "$UPD" = "$LAST_UPD" ]; then
        if [ $((now - STUCK_AT)) -ge "$STUCK_SECS" ]; then
          printf 'wait-idle=stuck session=%s updated=%s (no progress in %ss; reassign the task)\n' \
            "$SID" "$UPD" "$STUCK_SECS"
          exit 4
        fi
      else
        LAST_UPD="$UPD"; STUCK_AT=$now
      fi
    fi
    sleep "$INTERVAL"
  done
  OUTCOME=$(printf '%s' "$R" | json_get_field outcome)
  printf 'wait-idle=ok session=%s idle=%s outcome=%s\n' "$SID" "${IDLE:-none}" "${OUTCOME:-none}"
}

sub_send_prompt() {
  SID=""; PROMPT_FILE=""
  parse_kv "$@"
  [ -n "$SID" ] && [ -n "$PROMPT_FILE" ] || { printf '%s\n' '--session and --prompt-file required' >&2; exit 2; }
  require_state
  [ -f "$PROMPT_FILE" ] || die "prompt file does not exist: $PROMPT_FILE"
  # Guard against the silent failure: a session created without a resolved
  # model accepts the prompt, infers nothing (0 tokens) and ends in
  # outcome=failed with no visible error. Verified BEFORE sending, with the
  # reason stated.
  SINFO=$(opencode api GET "/api/session/$SID" 2>/dev/null) \
    || die "GET /api/session/$SID failed (transport); the session model could not be read"
  # Nested field through the ONE shared getter: model -> id. The old sed
  # pattern could not tell "no model" apart from "model present but empty",
  # and its sentinel comparison ($SESS_M = $SINFO) only held for one exact
  # JSON shape.
  SESS_M=$(printf '%s' "$SINFO" | json_get_field model)
  case "$SESS_M" in
    '{'*|'['*) SESS_M=$(printf '%s' "$SESS_M" | json_get_field id) ;;
  esac
  if [ -z "$SESS_M" ]; then
    printf 'ERROR: session %s has no resolved model (empty model.id).\n' "$SID" >&2
    printf 'Cause: it was created without the model_default cache key, or its agent does not resolve a model.\n' >&2
    printf 'Next: recreate it with an explicit model: create-worker --title "<T>" --model <id>@<prov> --force-new\n' >&2
    exit 2
  fi
  TEXT=$(json_escape < "$PROMPT_FILE")
  # An empty prompt used to be dispatched with prompt=ok: workers running with
  # no instructions and no error signal. Fail-closed.
  [ -n "$TEXT" ] || die "prompt file empty or unreadable: $PROMPT_FILE"
  R=$(opencode api POST "/api/session/$SID/prompt" -d '{"text":"'"$TEXT"'"}' 2>/dev/null) \
    || die 'POST /api/session/{sessionID}/prompt failed'
  # Session.Inbox.User returns `id` (a Session.Message.ID, ^msg_). The script
  # used to look for "infoID", which the v2 schema does not emit -- always
  # "none" -- so the extraction was dead. Renamed label and pattern.
  # The old inline extraction dropped the LAST character of the id (the regex
  # had no closing quote but the length subtracted one), so the printed
  # msgID was not a real id. The shared getter + the "msg_" prefix filter
  # return the id verbatim and never confuse it with the session id.
  MID=$(printf '%s' "$R" | json_get_field id msg_)
  # Cachea el timestamp de despacho: wait-idle de esta sesion solo acepta un
  # idle POSTERIOR (pool-safe; sin esto el idle heredado del run anterior
  # hacia regresar la espera de inmediato con valores viejos).
  cache_put "dispatch_$SID" "$(date +%s)000"
  printf 'prompt=ok session=%s msgID=%s\n' "$SID" "${MID:-none}"
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
  WANT_PIN=$(tui_pin)
  PROBE=$(sh "$SELF_DIR/os/tui-detect.sh" "$PROJ_DIR" "$WANT_PIN" 2>/dev/null)
  if [ -n "$PROBE" ]; then
    GATE=$(printf '%s\n' "$PROBE" | sed -n 's/^gate=//p')
    GATE_REASON=$(printf '%s\n' "$PROBE" | sed -n 's/^gate_reason=//p')
    GATE_CWD=$(printf '%s\n' "$PROBE" | sed -n 's/^tui_cwd=//p')
 # Refresh the cache so attach-tabs sees the same decision (DRY).:
    # via cache_put, never a raw `>` (a symlinked key must not be followed).
    cache_put tabs_gate "$GATE"
    cache_put tabs_cwd "$GATE_CWD"
    cache_put tabs_reason "$GATE_REASON"
    cache_put tui_version_pin "$WANT_PIN"
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
  # A RUNNING worker (no time.idle but with activity: out>0, an outcome, or
  # time.updated > time.created) is a collision: not overwritten (fail-closed).
  # A never-used worker (F1 state `empty`: no output, no idle) is reusable.
  # ONE fetch of the pool: it is BOTH the dedup source and the ordinal source.
  # Before, MAXORD came from a separate unguarded pool_max_ordinal call whose
  # failure read as "pool empty" (max=0), so the next worker took ordinal 01
  # even when [01] was already deployed -> two workers with the same [NN].
  # Fail-closed BEFORE anything is created.
  POOL=$(pool_list) || die "could not query the worker pool; fail-closed"
  MAXORD=$(pool_max_ordinal "$POOL")
  if [ -n "$COUNT" ]; then
    assert_uint --count "$COUNT"
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
    # Install the router prompt on the freshly-created orchestrator so the LLM
    # knows it must dispatch every task to a worker (never implement directly).
    # DRY: one canonical router prompt under scripts/prompt-templates/.
    # A REUSED root is left alone: it already has the instruction, and sending
    # it again would post a message into the operator's live session.
    case "$ROOT_OUT" in
      *root_reused=1*)
        printf 'router: skipped (the [00] root already exists; it is reused, not re-instructed)\n'
        ;;
      *)
        if [ "${NO_ROUTER:-0}" -ne 1 ]; then
          ROUTER_FILE="${ROUTER_PROMPT:-$SELF_DIR/prompt-templates/router-orchestrator.md}"
          if [ -f "$ROUTER_FILE" ]; then
            printf 'router: installing orchestrator instruction (%s, %s bytes)...\n' \
              "$ROUTER_FILE" "$(wc -c < "$ROUTER_FILE" | tr -d ' ')"
            # The router instruction IS what makes the orchestrator dispatch every
            # task instead of implementing it. `|| true` swallowed the failure and
            # the run continued with an orchestrator that never learned the rule,
            # so the failure is now fatal (fail-closed, same as ensure_root above).
            sub_send_prompt --session "$RID" --prompt-file "$ROUTER_FILE" \
              || die "could not install the router instruction on the orchestrator ($RID); aborting the run"
          else
            printf 'router: skipped (no router prompt at %s; use --router-prompt PATH or copy SKILL/scripts/prompt-templates/router-orchestrator.md)\n' "$ROUTER_FILE"
          fi
        fi
        ;;
    esac
  fi
  FAILED=0; REUSED=0; CREATED=0
  # Line-driven, not word-split: a title is "[NN] Name" and the space is part
  # of it. `for t in $WORKERS` shredded these into two sessions each.
  WORKER_LIST=$(worker_list "$WORKERS")
  [ -n "$WORKER_LIST" ] || { printf 'ERROR: --workers/--worker produced no valid titles\n' >&2; exit 2; }
  # A failure must stop the run. With `| while` the loop runs in a SUBSHELL:
  # `die`/`exit` only killed the subshell, the parent carried on and ended up
  # printing "done". The heredoc keeps the loop in the current shell, so exit
  # truly propagates.
  # (POOL is fetched once, above MAXORD: dedup and ordinals must come from the
  # SAME snapshot.)
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
      # $t already carries the "[NN] " prefix from worker_list, so
      # "[%02d] %s" printed the ordinal twice ("[01] [01] Vermithrax"). Show
      # the POOL's authoritative ordinal (P_ORD) with the name alone.
      # The canonical slug rule (os/_common.sh: worker_list / find_dedup):
      # strip a "[NN] " prefix with AT LEAST ONE digit, then drop the
      # whitespace. This copy used [0-9]*, so "[] Name" was stripped here and
      # not in the other two.
      P_NAME=$(printf '%s' "$t" | sed 's/^\[[0-9][0-9]*\][ \t]*//')
      if [ -z "$ID" ]; then
        printf 'ERROR: [%02d] %s exists in the pool without a usable sessionID\n' "$P_ORD" "$P_NAME" >&2
        FAILED=$((FAILED + 1)); continue
      fi
      if [ "$P_ST" != "idle" ] && [ "$P_ST" != "empty" ]; then
        printf 'ERROR: [%02d] %s is %s; it is not overwritten. Wait for wait-idle before reassigning work to it.\n' "$P_ORD" "$P_NAME" "$P_ST" >&2
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
  # `sprintf("%02d", $1)` keeps the 2-digit ordinal (cosmetic: `[00]` instead of `[0]`).
  printf '%s\n' "$POOL" | awk -F'\t' '{ o=sprintf("%02d", $1); printf "%-8s %-30s %-9s\n", "["o"]", $2, $3 }'
  printf 'next free ordinal: [%02d]\n' $(( $(pool_max_ordinal "$POOL") + 1 ))
}

sub_tabs() {
  # Tabs gate with no side effects: answers "is there a TUI and can I expose
  # tabs?" before creating anything. If an explicit --tui-cwd is given, it is
  # checked against the real detected cwd.
  TUI_CWD=""; parse_kv "$@"
  WANT_PIN=$(tui_pin)
  _probe=$(sh "$SELF_DIR/os/tui-detect.sh" "$PROJ_DIR" "$WANT_PIN" 2>/dev/null)
  printf '%s\n' "$_probe"
  if [ -n "$TUI_CWD" ]; then
    # The SAME field the gate uses (tui_cwd = the cwd of the TUI that matches
    # the project, with tui_cwd_any as fallback). It used to compare against
    # tui_cwd_any, so with more than one TUI running `tabs` reported MISMATCH
    # for a cwd that `attach-tabs` accepted: two gates for one decision.
    _real=$(printf '%s\n' "$_probe" | sed -n 's/^tui_cwd=//p')
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
  # F4: distinguish "worker id not found" from "worker has no children yet".
  # The empty-children baseline is legitimate for a worker that has not
  # spawned subagents yet, and the old message asserted a typo in that case.
  # Both cases stay exit 2 (fail-closed: a mistyped id NEVER reads as
  # success - round-2 evidence preserved; see references/failure-matrix.md).
  # The CONTENT decides, not the exit code: the CLI returns a non-zero rc for
  # BOTH a 404 and an unreachable API, so the rc alone cannot tell them apart.
  # The rc is still not ignored: it is folded into the message.
  WINFO=$(opencode api GET "/api/session/$WORKER_ID" 2>/dev/null) || WINFO=""
  case "$WINFO" in *'"id":"ses_'*) : ;;
    *) printf 'ERROR: verify-daughters: worker id not found (or the API is unreachable): %s; nothing was listed. Fail-closed.\n' "$WORKER_ID" >&2; exit 2 ;;
  esac
  # PAGINATED: a single page holds 50 sessions, so a worker with more
  # children than that was silently under-verified and R14 reported
  # "verified_ok=N failures=0" over an INCOMPLETE list.
  RESP=$(api_get_all_pages "/api/session?parentID=$WORKER_ID") \
    || die "GET /api/session?parentID=$WORKER_ID failed"
  printf '%s\n' "$RESP" | EXPECTED_PARENT="$EXPECTED_PARENT" PROJ_DIR="$PROJ_DIR" py -c '
import json, sys, os
d = json.load(sys.stdin, strict=False).get("data", [])
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
    print("NOTE: worker has no children yet (id verified above); nothing to verify. Fail-closed exit 2: it cannot be marked verified.")
    sys.exit(2)
sys.exit(0 if fail == 0 else 2)'
}

# delete-session: R7. The active /openapi.json (2.0.29 observed
# 2026-10-14; first verified at v2.0.22, gate is by major so the
# earlier 2.0.21 / 2.0.22 flap is irrelevant) publishes DELETE
# /api/session/{sessionID}. Gate: enumerates children with GET
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
  # PAGINATED: the R7 gate counts the children, so a truncated page would
  # under-report them (the gate itself still holds, but the number printed
  # to the operator would be wrong).
  _CHILD_JSON=$(api_get_all_pages "/api/session?parentID=$SID") \
    || die "GET /api/session?parentID=$SID failed; the R7 gate needs the real child count"
  CHILDREN=$(printf '%s' "$_CHILD_JSON" | py -c 'import json,sys
try:
    print(len(json.load(sys.stdin, strict=False).get("data",[])))
except Exception:
    print("?")' 2>/dev/null)
  if [ -z "$CHILDREN" ] || [ "$CHILDREN" = "?" ]; then
    printf 'ERROR: could not enumerate the children of %s; fail-closed (R7 requires knowing the cascade before deleting).\n' "$SID" >&2
    printf 'Check endpoint/auth and retry. --force does NOT override this gate.\n' >&2
    exit 2
  fi
  printf 'delete-session: target=%s children=%s\n' "$SID" "$CHILDREN" >&2
  # --force skips ONLY the children check, exactly as documented (SKILL.md row
  # 8.1). It must NOT skip the confirmation: a destructive R7 delete always
  # needs an explicit approval (--yes or the typed "yes"). Before, the whole
  # block was inside `if [ "$FORCE" -ne 1 ]`, so `--force` alone deleted the
  # session with no prompt at all.
  if [ "$FORCE" -ne 1 ] && [ "$CHILDREN" != "0" ]; then
    printf 'ERROR: %s has %s children; R7 -> use --force to skip the check (you assume cascade delete)\n' "$SID" "$CHILDREN" >&2
    exit 2
  fi
  if [ "$YES" -ne 1 ]; then
    printf 'DELETE %s (children=%s)? Type "yes" to continue: ' "$SID" "$CHILDREN" >&2
    if ! IFS= read -r ans; then printf '\naborted (no input)\n' >&2; exit 2; fi
    [ "$ans" = "yes" ] || { printf 'aborted\n' >&2; exit 2; }
  fi
  opencode api DELETE "/api/session/$SID" >/dev/null 2>&1 \
    || die "DELETE /api/session/$SID failed"
  # C-12: the cache keys pointing at this SID (worker_*, root_session,
  # dispatch_*) are purged WITH the session, so the skill cannot later reuse a
  # dead session id. Same helper as clean (DRY).
  cache_purge_sid "$SID"
  # tabs.json DRY: same helper as sub_clean (was missing — left orphan tabs).
  TABS_REMOVED=$(tabs_prune_ids "$SID")
  [ -n "$TABS_REMOVED" ] && [ "$TABS_REMOVED" -gt 0 ] 2>/dev/null \
    && printf 'delete-session: removed %s tab(s) from tabs.json\n' "$TABS_REMOVED" >&2
  printf 'deleted=%s children_was=%s\n' "$SID" "$CHILDREN"
}

# clean: identify + delete every session the orchestrator opened (R7).
# Usage: orchestrate.sh clean [--orchestrator SID] [--yes] [--dry-run]
#
# Identification algorithm (the "conversation history" part):
#   1. The orchestrator: auto-detected as the most recent [00]-titled
#      session in this project (the orchestrator's canonical name), or
#      pass --orchestrator SID explicitly.
#   2. Sessions to delete: the orchestrator's direct children (parentID
#      = orchestrator), all [NN] Name workers in this project (the
#      orchestrator's naming convention), and their transitive subagents.
#   3. Exclude: the orchestrator itself; any session in another project.
# After deletion, the corresponding tab entries in tabs.json are removed
# (under the shared tabs.json lock; portable across darwin/linux/WSL/git-bash).
# tabs_prune_ids SID_LIST -> prints N (count of tabs pruned from tabs.json).
# Single source of truth for tabs.json pruning (DRY; called by clean and
# delete-session). The tabs.json lock is the shared lock_exec (no second
# locking strategy anywhere in the skill): resolve the path in the shell via
# tabs_json_path (one source of truth, defined in os/_common.sh) and run the
# prune under lock_exec. Any reader of tabs.json sees either the previous
# shape or the complete new shape -- the prune is atomic w.r.t. concurrent
# merges (which themselves go through lock_exec on the same file).
tabs_prune_ids() {
  # Same file the merge writes (DRY): tabs_target_path is the ONE resolver
  # (ORCHESTRATE_TABS_JSON wins, else tabs_json_path) shared with the four
  # merge adapters, so a redirected tabs.json is pruned where it lives. This
  # was a 5th copy of the same 6-line block, and the merge python carried a
  # 6th resolver with different rules.
  _tj=$(tabs_target_path 2>/dev/null) || { printf '0\n'; return 0; }
  [ -f "$_tj" ] || { printf '0\n'; return 0; }
  DELETED_IDS="$*"
  export DELETED_IDS
  lock_exec "$_tj" "${ORCHESTRATE_TABS_LOCK_TIMEOUT:-5}" \
    py -c '
import json, os, sys
deleted = set(os.environ.get("DELETED_IDS","").split())
if not deleted or "" in deleted: print(0); raise SystemExit
p = sys.argv[1]
with open(p, "r+") as f:
    try: d = json.load(f, strict=False)
    except Exception: d = {"global":{"tabs":[]}, "cwd":{}}
    removed = 0
    for cwd_key in list(d.get("cwd", {}).keys()):
        tabs = d["cwd"][cwd_key].get("tabs", [])
        new = [t for t in tabs if t.get("sessionID") not in deleted]
        removed += len(tabs) - len(new)
        d["cwd"][cwd_key]["tabs"] = new
    if removed:
        f.seek(0); f.truncate()
        json.dump(d, f, indent=2)
    print(removed)
' "$_tj"
}

sub_clean() {
  ORCH_SID=""; YES=0; DRY=0
  # Local flag parsing (parse_kv in _common.sh doesn't know these flags;
  # adding them there would leak clean-specific args into a shared lib).
  while [ $# -gt 0 ]; do
    case "$1" in
      --orchestrator) assert_value --orchestrator "$#"; ORCH_SID="${2:-}"; shift 2 ;;
      --orchestrator=*) ORCH_SID="${1#--orchestrator=}"; shift ;;
      --yes) YES=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --) shift; break ;;
      *) printf 'clean: unknown flag: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  if [ -z "$ORCH_SID" ]; then
    # PAGINATED + checked: a single page holds 50 sessions, so the [00] root
    # could be off-page and clean died with "no [00] orchestrator"; and an
    # unchecked fetch reported a transport failure as the same message.
    _orch_all=$(project_sessions_json) \
      || die "GET /api/session failed; cannot find the [00] orchestrator"
    ORCH_SID=$(printf '%s' "$_orch_all" | py -c '
import json, sys, re
proj = "'"$PROJ_DIR"'"
ss = json.load(sys.stdin, strict=False).get("data", [])
cands = [s for s in ss if s.get("location",{}).get("directory","") == proj
         and re.match(r"^\[00\]", s.get("title",""))]
cands.sort(key=lambda s: s.get("time",{}).get("created", 0), reverse=True)
if cands: print(cands[0]["id"])
' 2>/dev/null)
  fi
  [ -n "$ORCH_SID" ] || die 'clean: no [00] orchestrator in this project; pass --orchestrator SID'
  case "$ORCH_SID" in ses_*) : ;; *) die 'clean: --orchestrator must have the ses_ prefix' ;; esac
 # (concurrency-probe HIGH): validate ORCH_SID belongs to this project
  # BEFORE any destructive enumeration. A bogus --orchestrator used to
  # pass through `seen = {orch}` (which excluded only the bogus SID) and
  # then sweep the real [00] + workers. Fail-closed with a clear message.
  if ! opencode api GET "/api/session/$ORCH_SID" 2>/dev/null | grep -q "\"directory\":\"$PROJ_DIR\""; then
 die "clean: --orchestrator $ORCH_SID is not in this project (location != $PROJ_DIR); refusing to sweep (data-loss class)"
  fi

  # Identify orchestrator-opened sessions in this project
 # (CWE-703): capture stderr separately so a python exception
  # cannot masquerade as "nothing to delete" (was: empty result + rc 0 +
  # operator believes cleanup succeeded). Fail-closed on python failure,
  # consistent with sub_delete_session's R7 contract.
  # No predictable /tmp fallback: a planted symlink at a known name would
  # redirect the python's stderr into the attacker's file. Fail closed.
  _clean_err=$(mktemp 2>/dev/null) || die "clean: cannot create a temporary file for the enumeration errors"
  TO_DELETE=$(PROJ_DIR="$PROJ_DIR" ORCH_SID="$ORCH_SID" py -c '
import json, os, re, subprocess
orch = os.environ["ORCH_SID"]; proj = os.environ["PROJ_DIR"]
seen = {orch}; stack = []
_pages = {}
def get_all(path):
    """Fetch all pages of a paginated endpoint (50/page, base64 cursor).

    Same contract as the shell helper api_get_all_pages (DRY): the separator is
    "?" or "&" depending on the path, limit=200, a stable-cursor guard, a
    30-iteration cap and ONE retry of the same url on a malformed page.

    Two defects fixed here:
    * the url was built as path + "?limit=200" ALWAYS, so a path that already
      had a query string ("/api/session?parentID=X") became
      "...?parentID=X?limit=200": the second "?" landed INSIDE the parentID
      value, the filter matched nothing and the child enumeration silently
      returned an empty list (no children, no topological order).
    * a malformed page did `break`, so a PARTIAL list was returned and the
      caller treated it as the complete one (B-pagination-silent class). It
 now raises, and the shell turns that into the fail-closed die.

    Results are memoised per path: the same list was fetched up to three
    times (children, children map, session info)."""
    if path in _pages: return _pages[path]
    out = []; cursor = None; prev = None; i = 0
    while i < 30:
        i += 1
        if cursor is not None and cursor == prev: break
        prev = cursor
        sep = "&" if "?" in path else "?"
        url = path + sep + "limit=200" + (("&cursor=%s" % cursor) if cursor else "")
        r = subprocess.run(["opencode","api","GET",url], capture_output=True, text=True)
        try:
            d = json.loads(r.stdout, strict=False)
        except Exception:
            # One retry of the SAME url (the serve occasionally emits a
            # malformed page); a second failure is fatal, not "end of list".
            r = subprocess.run(["opencode","api","GET",url], capture_output=True, text=True)
            try:
                d = json.loads(r.stdout, strict=False)
            except Exception as exc:
                raise SystemExit("clean: malformed page from %s (%s)" % (url, exc))
        out.extend(d.get("data", []) or [])
        cursor = (d.get("cursor") or {}).get("next") or None
        if not cursor: break
    _pages[path] = out
    return out
# 1. Direct children of the orchestrator
for c in get_all(f"/api/session?parentID={orch}"):
    sid = c.get("id")
    if sid and c.get("location",{}).get("directory","") == proj and sid not in seen:
        seen.add(sid); stack.append(sid)
# 2. All [NN] Name workers in this project (orchestrator convention)
pat = re.compile(r"^\[\d+\](?:s\[\d+\])?\s+")
for s in get_all("/api/session"):
    sid = s.get("id")
    if sid and s.get("location",{}).get("directory","") == proj and pat.match(s.get("title","")) and sid not in seen:
        seen.add(sid); stack.append(sid)
# 3. BFS for children (transitive subagents)
while stack:
    sid = stack.pop()
    for c in get_all(f"/api/session?parentID={sid}"):
        csid = c.get("id")
        if csid and c.get("location",{}).get("directory","") == proj and csid not in seen:
            seen.add(csid); stack.append(csid)
# 4. Build the children map (within our deletion set) for topological ordering.
#    Delete children BEFORE their parents so per-session R7 (which
#    aborts on a non-zero child count) passes without --force. This is the
#    key insight: keep R7 per-session safety AND cascade by default,
#    without changing the meaning of --yes or --force.
children_of = {sid: [] for sid in seen}
for sid in seen:
    for c in get_all(f"/api/session?parentID={sid}"):
        csid = c.get("id")
        if csid in seen:
            children_of[sid].append(csid)
# 5. DFS post-order: visit children first, then the node. Result is
#    the deletion order (leaves before parents, parents with no in-set
#    children first, deepest workers last). Cycles are impossible
#    (parentID is a tree from the API), so no cycle handling needed.
visited = set()
order = []
def visit(n):
    if n in visited: return
    visited.add(n)
    for c in children_of.get(n, []):
        visit(c)
    order.append(n)
for n in seen:
    visit(n)
# 6. Output: project, not the orchestrator, in topological deletion order
session_info = {s["id"]: s for s in get_all("/api/session")}
for sid in order:
    if sid == orch: continue
    info = session_info.get(sid, {})
    print(sid + "|" + (info.get("title") or ""))
' 2>"$_clean_err") || {
    cat "$_clean_err" >&2
    rm -f "$_clean_err"
 die 'clean: python enumeration failed; refusing to clean (fail-closed)'
  }
  rm -f "$_clean_err"

  N=$(printf '%s\n' "$TO_DELETE" | grep -c '^ses_')
  if [ "$N" -eq 0 ]; then
    printf 'clean: no orchestrator-opened sessions in this project\n' >&2
    return 0
  fi

  # Preview
  printf 'clean: %s session(s) to delete:\n' "$N" >&2
  printf '%s\n' "$TO_DELETE" | while IFS='|' read -r sid title; do
    [ -n "$sid" ] || continue
    printf '  %s  %s\n' "$sid" "${title# }" >&2
  done

  if [ "$DRY" -eq 1 ]; then
    printf 'clean: --dry-run; no changes applied\n' >&2
    return 0
  fi

  # R7 confirmation
  if [ "$YES" -ne 1 ]; then
    printf 'clean: type "yes" to delete these %s session(s) [no=abort]: ' "$N" >&2
    if ! IFS= read -r ans; then printf '\naborted (no input)\n' >&2; exit 2; fi
    [ "$ans" = "yes" ] || { printf 'aborted\n' >&2; exit 2; }
  fi

  # Delete each via opencode api (bypasses the preflight cache: the CLI
  # handles auth internally and is what the rest of the skill uses to
  # read/write; sub_delete_session's curl path depends on auth_flag which
  # is empty when preflight cannot populate the cache, e.g. on opencode
  # 2.0.29 where /openapi.json fails validation). R7 is preserved by the
  # topological order above: by the time we reach a session, all of its
  # children in the set are already gone, so the per-session child
  # enumeration is not needed for cascade safety.
  TMP=$(mktemp) || die "clean: cannot create the temporary deletion log"
  printf '%s\n' "$TO_DELETE" | while IFS='|' read -r sid title; do
    [ -n "$sid" ] || continue
    if opencode api DELETE "/api/session/$sid" >/dev/null 2>&1; then
      printf 'ok %s\n' "$sid" >> "$TMP"
      printf 'clean: deleted %s\n' "$sid" >&2
    else
      printf 'fail %s\n' "$sid" >> "$TMP"
      printf 'clean: FAILED to delete %s\n' "$sid" >&2
    fi
  done
  OK=$(grep -c '^ok ' "$TMP" 2>/dev/null; true)
  FAIL=$(grep -c '^fail ' "$TMP" 2>/dev/null; true)
  # FAIL-CLOSED: the counts must add up to the plan. Before, an unwritable or
  # missing $TMP made BOTH counts 0, so clean reported SUCCESS having deleted
  # nothing, and the ok-list was silently empty -> the cache purge and the
  # tabs prune were skipped while the command claimed it was done.
  if [ $((OK + FAIL)) -ne "$N" ]; then
    printf 'ERROR: clean: the deletion log is incomplete (%s ok + %s fail != %s planned); the tabs prune and the cache purge are SKIPPED. Fail-closed.\n' "$OK" "$FAIL" "$N" >&2
    die "clean: the deletion log does not match the plan; nothing else was touched"
  fi
  [ "$FAIL" -gt 0 ] && printf 'clean: %s delete(s) failed; check logs\n' "$FAIL" >&2

  # Clean tabs.json: remove entries whose sessionID was ACTUALLY deleted
  # (use the ok lines from TMP, not the full TO_DELETE plan). This keeps
  # tabs.json consistent with the live state: a session that failed to
  # delete keeps its tab entry until the user retries or cleans manually.
  DELETED_IDS=$(awk '$1 == "ok" {print $2}' "$TMP" 2>/dev/null; true | tr '\n' ' ')
  rm -f "$TMP"
  if [ -n "$DELETED_IDS" ]; then
    # C-12: purge the cache pointers of the ACTUALLY deleted sessions only
    # (same helper as delete-session; DRY).
    for _sid in $DELETED_IDS; do cache_purge_sid "$_sid"; done
    TABS_REMOVED=$(tabs_prune_ids "$DELETED_IDS")
    if [ -n "$TABS_REMOVED" ] && [ "$TABS_REMOVED" -gt 0 ] 2>/dev/null; then
      printf 'clean: removed %s tab(s) from tabs.json\n' "$TABS_REMOVED" >&2
    fi
  fi

  printf 'clean: done (%s/%s session(s) deleted)\n' "$OK" "$N" >&2
  [ "$FAIL" -gt 0 ] && return 1 || return 0
}

# dispatch: route a task to one or multiple workers based on complexity.
# NEVER touches the orchestrator's own context: the prompt is sent to workers
# and the orchestrator only sees the dispatch summary + (optionally) the wait-idle
# outcome. The orchestrator's job is routing + aggregation, not execution.
sub_dispatch() {
  PROMPT_FILE=""; WORKER=""; COUNT=""; AUTO_COUNT=0; WAIT=0; DEADLINE=600; INTERVAL=10
  parse_kv "$@"
  [ -n "$PROMPT_FILE" ] || die "dispatch: --prompt-file required"
  [ -f "$PROMPT_FILE" ] || die "dispatch: prompt file not found: $PROMPT_FILE"
  assert_uint --deadline "$DEADLINE"
  assert_uint --interval "$INTERVAL"
  [ -z "$COUNT" ] || assert_uint --count "$COUNT"
  require_state

  # Idle OR empty workers in the pool (column 7 = parent, empty for workers;
  # column 3 = state). F1: `empty` is a created-but-never-used session — it
  # must be dispatchable or the first prompt can never be delivered; a
  # genuinely `running` session (out>0 or updated>created, no time.idle) is
  # still refused (fail-closed collision guard, semantics unchanged).
  POOL=$(pool_list) || die "dispatch: could not query worker pool"
  IDLE=$(printf '%s\n' "$POOL" | awk -F'\t' '$7 == "" && ($3 == "idle" || $3 == "empty") { print $1, $5 }')
  N_IDLE=$(printf '%s\n' "$IDLE" | grep -c .)
 #: --target is resolved BEFORE the idle-count gate. With the gate first,
  # a --target naming a busy (or nonexistent) worker died with "no idle worker
  # ... or pass --target NN" -- a hint already satisfied (it HAD been passed)
  # that also conflated "no such ordinal" with "worker is busy". F1's truthful
  # state reporting is preserved; the two refusals are now separate messages.
  if [ -n "$WORKER" ]; then
    # --target NN    -> the worker with that ordinal.
    # --target NNsMM -> the sub-agent MM of the worker NN (the router prompt
    #                   documents both forms).
    # The selector compares the ordinal AND the sub-agent index. awk coerces
    # "01s02" to the NUMBER 1, so the old `w+0` match silently selected the
    # WORKER 01 instead of its sub-agent 02 and the prompt went to the WRONG
    # session. (The IDLE set only contains workers, so a sub-agent target was
    # unreachable as well.)
    case "$WORKER" in
      *s*) T_ORD="${WORKER%%s*}"; T_SUB="${WORKER#*s}" ;;
      *)   T_ORD="$WORKER"; T_SUB="" ;;
    esac
    [ -n "$T_ORD" ] || die "dispatch: --target must be NN or NNsMM (digits only)"
    case "$T_ORD$T_SUB" in
      *[!0-9]*) die "dispatch: --target must be NN or NNsMM (digits only)" ;;
    esac
    if [ -n "$T_SUB" ]; then
      [ "$T_SUB" -ge 1 ] 2>/dev/null || die "dispatch: --target sub-agent index must be >= 1"
    fi
    WST=$(printf '%s\n' "$POOL" | awk -F'\t' -v o="$T_ORD" -v sbi="$T_SUB" '$1 == (o+0) && ($7+0) == (sbi+0) { print $3; exit }')
    [ -n "$WST" ] || die "dispatch: no worker with ordinal $WORKER in this project (run 'pool' to list the deployed workers)"
    [ "$WST" = idle ] || [ "$WST" = empty ] || die "dispatch: worker $WORKER is $WST (only idle or empty workers can receive new prompts)"
  fi

  # Heuristic complexity -> N (only when --auto-count). Single tool (awk)
  # for both counts: `wc -w || printf 0` and `grep -cE || printf 0` both
  # race and emit "0\n0" when the count is zero, breaking the -ge tests.
  WORDS=$(awk 'BEGIN{n=0}{n+=NF}END{print n+0}' "$PROMPT_FILE")
  BULLETS=$(awk 'BEGIN{n=0}/^[[:space:]]*[0-9]+[.)][[:space:]]|^[[:space:]]*[-*][[:space:]]/{n++}END{print n+0}' "$PROMPT_FILE")

  # Decide the target list.
  if [ -n "$WORKER" ]; then
 # Validated above: it exists and is idle/empty. Selected from the
    # POOL (not from IDLE) so a sub-agent target NNsMM is reachable: IDLE
    # only holds the workers (column 7 empty).
    TARGET=$(printf '%s\n' "$POOL" | awk -F'\t' -v o="$T_ORD" -v sbi="$T_SUB" '$1 == (o+0) && ($7+0) == (sbi+0) { print $1, $5; exit }')
  elif [ "$N_IDLE" -eq 0 ]; then
    die "dispatch: no idle worker in the pool; free one with wait-idle or pass --target NN"
  elif [ -n "$COUNT" ]; then
    N="$COUNT"
    [ "$N" -ge 1 ] || die "--count must be >= 1"
    [ "$N" -gt "$N_IDLE" ] && N="$N_IDLE"
    TARGET=$(printf '%s\n' "$IDLE" | head -n "$N")
  elif [ "$AUTO_COUNT" -eq 1 ]; then
    N=1
    if   [ "$WORDS" -ge 500 ] 2>/dev/null; then N=3
    elif [ "$WORDS" -ge 200 ] 2>/dev/null; then N=2
    fi
    [ "$BULLETS" -ge 6 ] 2>/dev/null && N=3
    [ "$BULLETS" -ge 3 ] 2>/dev/null && [ "$N" -lt 2 ] && N=2
    [ "$N" -gt "$N_IDLE" ] && N="$N_IDLE"
    [ "$N" -lt 1 ] && N=1
    TARGET=$(printf '%s\n' "$IDLE" | head -n "$N")
  else
    # Default: single worker (first idle).
    TARGET=$(printf '%s\n' "$IDLE" | head -n 1)
  fi

  # Dispatch + (optionally) wait.
  printf 'dispatch: prompt=%s (words=%s bullets=%s) -> %d worker(s)\n' \
    "$PROMPT_FILE" "$WORDS" "$BULLETS" "$(printf '%s\n' "$TARGET" | grep -c .)"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    set -- $line
    ORD="$1"; SID="$2"
 #: a hostile worker could craft a title like "[05] ses_TARGETID"
    # which would set SID=ses_TARGETID and route this prompt to someone else's
    # session. Re-validate the sessionID prefix before sending.
    case "$SID" in ses_*) ;; *) die "dispatch: parsed SID '$SID' lacks ses_ prefix (worker title poisoning?)" ;; esac
    printf '  -> [%02d] %s sending prompt...\n' "$ORD" "$SID"
    sub_send_prompt --session "$SID" --prompt-file "$PROMPT_FILE" 2>&1 | sed 's/^/    /'
    if [ "$WAIT" -eq 1 ]; then
      printf '    waiting (deadline=%ds interval=%ds)...\n' "$DEADLINE" "$INTERVAL"
      sub_wait_idle --session "$SID" --deadline "$DEADLINE" -i "$INTERVAL" | sed 's/^/    /'
    fi
  done <<EOF
$TARGET
EOF
}

# session-id COMPACT_REF -> prints the raw sessionID (ses_XXX) for a project
# session whose title matches COMPACT_REF (a worker compact id, e.g. 00, 01,
# 01s02, [01], or [01s02]). Resolves the helper parse_short_id (which
# removes optional brackets and splits on 's' for sub-agents), queries the
# /api/session pool, and prints the first match's id. -1 if not found.
sub_session_id() {
  COMPACT="${1:-}"
  [ -n "$COMPACT" ] || die "session-id: COMPACT_REF required (e.g. 00, 01, 01s02, [01], or [01s02])"
  PARTS=$(parse_short_id "$COMPACT")
  [ -n "$PARTS" ] || die "session-id: invalid compact ref: $COMPACT (want NN, NNsMM, [NN], or [NN]s[MM])"
  set -- $PARTS
  PARENT="$1"; SUB="${2:-}"
  # require_state deliberately removed: api_get_all_pages bypasses
  # the preflight cache and works on its own. Keeping require_state would
  # make this subcommand fail in the same 2.0.29 case the rest of the
  # migration just fixed.
  RESP=$(project_sessions_json) || die "session-id: /api/session failed"
  # Re-run with output capture (python3 inline output not reliable across all sh -> python stdin handling)
  # D3: the pool convention is a LEADING '[NN] ' (pool_list and sub_clean both
  # anchor it). 'search' matched '[01]' ANYWHERE, so a session titled e.g.
  # '... crear worker [01] R5B1' resolved as worker 01. Exact-prefix match now,
  # and >1 match is fail-closed instead of silently taking the first.
  _sid_rc=0
  RESULT=$(printf '%s' "$RESP" | py -c "
import json, sys, re
d = sys.argv[1]
sub = sys.argv[2]
parent = sys.argv[3]
title_pat = re.compile(r'\\[' + parent + (r'\\]s\\[' + sub + r'\\]' if sub else r'\\]') + r'(?=\\s|\$)')
data = json.loads(sys.stdin.read(), strict=False).get('data', [])
hits = [s.get('id') or '' for s in data
        if s.get('location', {}).get('directory', '') == d
        and title_pat.match(s.get('title', ''))]
if len(hits) == 1:
    print(hits[0]); sys.exit(0)
if len(hits) > 1:
    print(','.join(hits)); sys.exit(2)
sys.exit(1)
" "$PROJ_DIR" "$SUB" "$PARENT") || _sid_rc=$?
  case "$_sid_rc" in
    0) : ;;
    2) printf 'session-id: %s is AMBIGUOUS in this project (%s); pass the explicit sessionID (ses_...)\n' "$COMPACT" "$RESULT" >&2; exit 1 ;;
    *) printf 'session-id: %s not found in this project\n' "$COMPACT" >&2; exit 1 ;;
  esac
  printf '%s\n' "$RESULT"
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
                                     CONCURRENCY: the dedup->POST->cache sequence runs under the per-project
                                     lock, so parallel invocations with the same title create ONE session
                                     (the loser reuses it); the lock wait is bounded and fails closed
                                     with "lock_status=fail-closed reason=busy" (rc 71)
  sessions                            project session inventory (id, out, title)
  send-prompt --session SID --prompt-file F
                                     POST prompt with awk JSON-escape (no python)
  attach-tabs --session SID [--tui-cwd PATH] [--title T] [--force-tabs]
                                     additive merge of tabs.json with OS-specific lock; readback; not verified.
                                     --tui-cwd is optional: without it, the gate cached by preflight is used.
                                     --force-tabs: the operator authorization that bypasses a blocked
                                     gate (the tab is written unverified).
  session-id COMPACT_REF              resolves a compact ref (00, 01, 01s02, [01], [01]s[02])
                                     to the raw sessionID (ses_...) of a session in this project
  tabs [--tui-cwd PATH]              side-effect-free TUI/tabs gate: pids, real cwd, channel, version,
                                     ready|blocked + reason (recipe-tui-tabs.md §3/§6)
  watch --session SID --artifact A[,A...] [--deadline D] [--interval I]
                                     delegates to scripts/watch_run.sh
  wait-idle --session SID [--deadline D] [--interval I]
                                     polls until time.idle; prints outcome
  init-run --worker "T1" --worker "T2" [--title ROOT] [--no-attach-tabs]
                                     creates root (optional) + workers + tabs in one command.
                                     ONE single invocation per run: the [NN] sequence is assigned
                                     inside it from the deployed pool (max + 1), and the whole
                                     read->decide->POST->cache sequence runs under the per-project
                                     lock, so a second (or concurrent) invocation REUSES the root and
                                     the idle workers instead of duplicating [00]/[01]; a worker with
                                     prior work (or still running) fails closed and is not overwritten.
                                     Tabs by default if the cached gate says ready; --tui-cwd optional
  self-check                         reports OS, tools and cached state
  pool                               deployed [NN] workers (ordinal, name, state: empty=never-used / idle / running)
                                     and next free ordinal: look at this BEFORE launching
  verify-daughters --worker-id WID [--expected-parent WID]
                                     GET /api/session?parentID= lists children and validates that
                                     each one has parentID=expected_parent and
                                     location.directory=run.location.directory (R14).
  delete-session --session SID [--yes] [--force]
                                     DELETE /api/session/{sessionID} (verified in the active
                                     /openapi.json; R7 -> checks children and requires confirmation).
                                     --yes: skips the prompt. --force: skips the children
                                     check ONLY -- the confirmation is always required.
  clean [--orchestrator SID] [--yes] [--dry-run]
                                      Identify every session the orchestrator opened
                                      (its direct children, all [NN] Name workers in
                                      this project, and their transitive subagents) and
                                      DELETE them. Removes the matching tabs from tabs.json
                                      after. The orchestrator is auto-detected as the most
                                      recent [00] session in this project, or pass
                                      --orchestrator SID. R7: requires confirmation or
                                      --yes. Deletion order is topological (children
                                      before parents), so the cascade is safe without
                                      any extra flag.
  dispatch --prompt-file F [--target NN] [--count N|--auto-count] [--wait]
                                     Routes the prompt to an idle or empty worker session (or several,
                                     if complexity or --count warrants). The orchestrator's own
                                     context stays clean -- it only sees the dispatch summary
                                     and the workers' wait-idle outcomes. --auto-count
                                     picks N from a simple heuristic on the prompt file:
                                     words + bullet structure. Workers can recursively split
                                     via their native subagent tool. The orchestrator NEVER
                                     implements the task itself.
USAGE
}

# --- per-project critical section (A-4/A-5) --------------------------------------
# create-worker / ensure-root / init-run all run a check-then-act sequence:
#
#     dedup_guard (query the catalog)  ->  POST /api/session  ->  cache_put
#
# Without mutual exclusion two concurrent invocations BOTH pass the guard and
# BOTH create a session with the same title: the pool invariant "one title =
# one session" breaks, init-run's reuse then picks a nondeterministic winner,
# the duplicate becomes an orphan (A-4), and the paired cache_put calls lose
# one of the two SIDs (A-5: root_session / worker_<title> / dispatch_<SID>).
# init-run stacks three such races: root dedup TOCTOU (duplicate [00]),
# ordinal assignment (both compute the same next ordinal) and the bare `>`
# cache write (now atomic inside cache_put).
#
# The whole sequence now runs under ONE per-project lock -- lock_exec, the very
# same helper that locks tabs.json (DRY: extracted from the tabs.json merge,
# not a second locking strategy). The lock is held for the entire subcommand,
# so the second invocation enters the guard AFTER the first has created and
# cached its session.
#
# SEMANTICS DECISION: REUSE, not "busy". The documented dedup contract of this
# skill is idempotent: "same title (slug) in the same project -> reuse the
# inert session (out=0)"; "same title with prior work -> fail closed with
# collision". Serializing keeps that contract exactly and removes the
# duplicate: the loser re-runs the guard and reuses the winner's session (exit
# 0, printed as `dedup=1 inert-session-reused`). The lock adds one NEW error
# class only for its own failure: when the bounded wait expires it fails closed
# with `lock_status=fail-closed reason=busy` (rc 71) and nothing is created --
# it never hangs forever.
#
# Re-exec through the helper (not a shell trap): the helper owns the lock for
# the lifetime of the child process and the kernel releases it on EVERY exit
# path, including `die`, unexpected errors and signals -- there is no cleanup
# code that can be skipped. ORCHESTRATE_LOCK_HELD=1 marks the child so the
# dispatch below does not try to re-acquire the same lock (which would deadlock
# against its own parent); nested function calls (init-run -> create-worker ->
# send-prompt) never reach the dispatcher anyway.
if [ "${ORCHESTRATE_LOCK_HELD:-0}" != "1" ]; then
  case "$SUBCMD" in
    create-worker|ensure-root|init-run)
      : "${ORCHESTRATE_LOCK_TIMEOUT:=600}"
      _proj_lock="$CACHE_DIR/orchestrate.lock"
      # lock_exec requires an existing lock file (creating a missing lock
      # target silently would mask a mis-resolved CACHE_DIR).
 # symmetry at the LOCK file: a symlink planted here would be
      # followed, so the lock would guard a DIFFERENT inode and the
      # "one session per title" critical section would protect nothing.
 [ -L "$_proj_lock" ] && { printf 'ERROR: the project lock %s is a symlink; refusing to lock through it (CWE-59)\n' "$_proj_lock" >&2; exit 1; }
      [ -f "$_proj_lock" ] || : > "$_proj_lock" 2>/dev/null
      [ -f "$_proj_lock" ] || {
        printf 'ERROR: cannot create the project lock %s; fail-closed (nothing was created)\n' "$_proj_lock" >&2
        exit 70
      }
      export ORCHESTRATE_LOCK_HELD=1
      lock_exec "$_proj_lock" "$ORCHESTRATE_LOCK_TIMEOUT" \
        sh "$SELF_DIR/orchestrate.sh" --os "$OS" "$SUBCMD" "$@"
      exit $?
      ;;
  esac
fi

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
  session-id) sub_session_id "$@" ;;
  delete-session) sub_delete_session "$@" ;;
  clean) sub_clean "$@" ;;
  dispatch) sub_dispatch "$@" ;;
  ""|-h|--help|help) sub_help; exit 0 ;;
  *) printf 'unknown subcommand: %s\n' "$SUBCMD" >&2; sub_help >&2; exit 2 ;;
esac