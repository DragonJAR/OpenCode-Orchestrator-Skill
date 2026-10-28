#!/bin/sh
# Shared helpers for the orchestration swissknife. POSIX sh, sourced by orchestrate.sh.
# Contract: per-OS files (sourced BEFORE this one) define os_project_dir and os_tabs_merge.
set -u
# Newline as a data separator for accumulating repeated flag values in POSIX sh.
NL='
'

# F5 (DRY): the project/cache path derivation lives in os/_paths.sh so a
# standalone preflight.sh populates the SAME cache. Callers (orchestrate.sh
# + the test fixtures) must source os/_paths.sh BEFORE this file: it sets
# PROJ_DIR, PROJ_HASH and CACHE_DIR (the same rule used by standalone
# preflight.sh). The require below enforces the contract fail-closed.
[ "${CACHE_DIR+set}" = set ] || { printf '%s\n' 'ERROR: os/_paths.sh must be sourced before os/_common.sh (sets CACHE_DIR)' >&2; exit 1; }
#: also refuse empty or "/" (would turn every "$CACHE_DIR/<key>" into "/<key>").
# This guard comes FIRST: it is the reason a caller sources this file, and it
# must not be masked by anything this file does on its own account.
case "$CACHE_DIR" in ''|/) printf "ERROR: no usable cache dir (CACHE_DIR='%s') \n" "$CACHE_DIR" >&2; exit 1;; esac
# The shared awk library (scripts/_json.awk) holds the ONE JSON extraction
# formula. This file is SOURCED, so $0 is the CALLER's path, not this file's:
# a sourced file CANNOT locate its siblings by itself. The rule is therefore
# ONE: the caller exports SELF_DIR, the directory that holds the library
# (scripts/). orchestrate.sh and preflight.sh do; the regression fixtures do.
#
# The old code ALSO tried the caller's own directory and one level above it.
# That is a GUESS, not a contract: it resolves to whatever $0 happens to be,
# so the same source could find the library in one place and miss it in
# another. It already cost one real failure: the CI step that sourced this
# file without SELF_DIR looked for the library in the shell's own directory
# (/usr/bin) and one level above it (/) -- "shared awk library missing" on
# all three runners. A guess is not a rule: now there is ONE way to point at
# the library, and not meeting it fails closed with a message that says so.
#
# A missing library is NOT fatal HERE: sourcing this file must not fail for a
# reason that has nothing to do with the cache. It is fatal where it is
# actually needed -- at the extraction (see json_get_field), which reports it
# with the same clear message.
_JSON_LIB=""
if [ -n "${SELF_DIR:-}" ] && [ -f "$SELF_DIR/_json.awk" ]; then
  _JSON_LIB=$(cat "$SELF_DIR/_json.awk")
fi
# The cache DIR is prepared HERE (the only writer of the cache keys), so that
# os/_paths.sh stays side-effect free and can be sourced by read-only scripts
# (the TUI detector).
#
# The location MUST stay derived from the project hash: preflight.sh and
# orchestrate.sh are SEPARATE processes that have to agree on it, and the
# endpoint/auth_password/model_default keys only mean something in the shared
# directory. A random fallback (mktemp -d) therefore SPLIT the cache in two:
# preflight wrote the password into one directory and the run read from
# another, so the run went UNAUTHENTICATED with no error anywhere. The
# fallback also broke the (CWE-377/732) property it was meant to provide --
# a per-process random directory is not a place two processes can agree on.
# The unpredictable path IS the project hash, and it is under the user's own
# XDG cache, not /tmp, so a planted symlink there is the user's own doing.
#
# So: create it, and FAIL CLOSED if it cannot be created. A cache that cannot
# be written is reported, not silently replaced by a different one.
mkdir -p "$CACHE_DIR" 2>/dev/null || {
  printf "ERROR: cannot create the cache dir %s\n" "$CACHE_DIR" >&2
  printf 'The cache location is derived from the project hash so that preflight and orchestrate.sh share it; it is NOT replaced by a random directory (that would split the cache in two).\n' >&2
  exit 1
}
# The cache DIR itself must not be a symlink (CWE-59): the per-key guards
# below check the keys, but a symlinked DIRECTORY would redirect every write
# to the target. mkdir -p on a symlink-to-dir SUCCEEDS, so this has to be
# checked explicitly.
[ -L "$CACHE_DIR" ] && { printf 'ERROR: the cache dir %s is a symlink; refusing to write through it (CWE-59)\n' "$CACHE_DIR" >&2; exit 1; }
# 700 keeps other users out of the cache (it holds the endpoint, the project id
# and the password file). The chmod is best effort: the location MUST stay
# derived from the project hash, because preflight and orchestrate.sh have to
# agree on it -- a failure is reported rather than silently falling back to a
# random directory, which would split the cache in two.
chmod 700 "$CACHE_DIR" 2>/dev/null || printf 'warning: could not restrict the cache dir %s to 700\n' "$CACHE_DIR" >&2

# --- http ---------------------------------------------------------------------
# AUTH is intentionally unquoted. The basic-auth password used by
# OpenCode contains characters that, when wrapped in one argument via
# shell word splitting, change how curl parses the colon-separated user:pass
# pair (some curl versions split on the colon and treat the right-hand side
# as a URL, yielding HTTP 401). With AUTH as separate words (no surrounding
# quotes), curl sees -u followed by user:pass as two separate arguments
# and authenticates correctly. Quoting re-breaks this path; the
# corresponding SC2086 warning is a known false positive here.
http_post_json() { curl -fsS -m 30 ${AUTH:-} -H 'Content-Type: application/json' -d "$2" "$1"; }

# api_get_all_pages PATH -> emits concatenated JSON with merged `data` arrays.
# Single source of truth for the opencode cursor pagination pattern (50/page
# base64 cursor). Used by pool_list, sub_sessions and sub_session_id. Why here
# (DRY): all three previously duplicated the same loop inline. Why not curl:
# the opencode API requires auth via service.json, and that auth can be empty
# when preflight cannot populate the cache (e.g. 2.0.29 /openapi.json returns
# HTML); the opencode CLI resolves auth internally. Bypassing curl removes
# the 401 surface for the whole 50+ subcommand set at once.
api_get_all_pages() {
  _p="$1" _cursor="" _prev="x" _first=1 _out="" _resp="" _iter=0
  while [ "$_iter" -lt 30 ] ; do
    _iter=$((_iter+1))
    # Stable-cursor guard: the serve can re-anchor to the same page (cursor.next
    # repeats); without this the loop never ends and the API eventually rc=1.
    [ "$_cursor" = "$_prev" ] && break
    _prev="$_cursor"
    # A path may already carry a query string (e.g. "/api/session?parentID=X"):
    # the separator must then be "&". With "?" the second one became part of
    # the first value (parentID="ses_x?limit=200"), the filter matched nothing
    # and the caller silently got an EMPTY list.
    if [ -n "$_cursor" ]; then
      case "$_p" in
        *\?*) _url="$_p&limit=200&cursor=$_cursor" ;;
        *)    _url="$_p?limit=200&cursor=$_cursor" ;;
      esac
    else
      case "$_p" in
        *\?*) _url="$_p&limit=200" ;;
        *)    _url="$_p?limit=200" ;;
      esac
    fi
    _resp=$(opencode api GET "$_url" 2>/dev/null) || return $?
    [ -z "$_resp" ] && return 3
    # B-page-silent: a transient serve hiccup (e.g. literal newline inside
    # a JSON string, observed 1/5 runs in the baseline) used to either
    # corrupt _out via the except's stdin tail or terminate pagination
    # early on an empty cursor from the bad page. Retry the SAME url once
    # before falling through: a 2nd request typically returns clean JSON.
    if ! printf '%s' "$_resp" | py -c 'import json,sys; json.load(sys.stdin, strict=False)' 2>/dev/null; then
      _resp=$(opencode api GET "$_url" 2>/dev/null) || return $?
      # The retry is RE-VALIDATED. Before, a second malformed page was accepted
      # and the pagination ended with a truncated catalog and rc 0: the callers
      # (pool_list, sub_sessions, sub_session_id) treat the result as the
      # COMPLETE list, so the pool read as "max ordinal 0" and the next worker
      # reused [01]. A malformed page is now fatal (rc 3), never a short list.
      printf '%s' "$_resp" | py -c 'import json,sys; json.load(sys.stdin, strict=False)' 2>/dev/null || return 3
    fi
    if [ "$_first" = 1 ]; then _out="$_resp"; _first=0
    else
      # Merge the two pages. They are NOT split by LINE: the serve
      # sporadically emits a literal newline inside a JSON string (a title with
      # a raw newline), so readline() cut the document in half, the parse
      # failed and the pagination ended with a truncated list (silently, before
      # the fail-closed guard). The raw decoder reads one document at a time
      # and stops at its end, so a newline inside a string is harmless.
      _merged=$(printf '%s\n%s\n' "$_out" "$_resp" | py -c '
import json, sys
raw = sys.stdin.read()
dec = json.JSONDecoder(strict=False)
docs = []
i = 0
while i < len(raw):
    while i < len(raw) and raw[i] in " \t\r\n":
        i += 1
    if i >= len(raw):
        break
    obj, i = dec.raw_decode(raw, i)
    docs.append(obj)
if len(docs) != 2:
    raise SystemExit(1)
a, b = docs
a["data"].extend(b.get("data", []))
if "cursor" not in a:
    a["cursor"] = b.get("cursor", {})
print(json.dumps(a, separators=(",", ":")))
' 2>/dev/null)
      # A merge that produced nothing is NOT "keep the prior pages": the page
      # is valid JSON (it was validated above) but the SHAPE is not what the
      # merge expects, and the caller would then read a truncated list as the
      # complete one. Fail closed instead.
      [ -n "$_merged" ] || return 3
      _out="$_merged"
    fi
    # `or ""`: a JSON null next-cursor must print empty, not the literal
    # string "None" (querying ?cursor=None returns InvalidCursorError and the
    # loop would discard every page already accumulated).
    _cursor=$(printf '%s' "$_resp" | py -c 'import json,sys
d=json.load(sys.stdin, strict=False)
print(d.get("cursor",{}).get("next") or "")' 2>/dev/null) || return 3
    # A FAILED cursor extraction is not "no more pages": before, the empty
    # cursor ended the loop silently and the caller got a truncated catalog
    # with rc 0. The rc of the extraction is checked above; an EMPTY but
    # successful extraction is the real end of the list.
    [ -z "$_cursor" ] && break
  done
  # The iteration cap is a SAFETY VALVE, not a license to truncate. If the
  # loop stopped because it ran out of iterations while a next cursor was
  # still pending, the catalog is INCOMPLETE. Returning it as if it were
  # the whole list is the "truncated list read as complete" class: the
  # pool then reads "max ordinal 0" and the next worker reuses [01].
  # So the cap is FATAL, exactly like a malformed page.
  if [ "$_iter" -ge 30 ] && [ -n "$_cursor" ]; then
    printf 'ERROR: the pagination cap (30 pages) was reached with more pages pending; the catalog is INCOMPLETE and is not returned as if it were complete\n' >&2
    return 3
  fi
  printf '%s' "$_out"
}

# --- json (jq-less; awk) --------------------------------------------------------
# py ARGS... -> runs python3 and prints its output with LF only.
#
# WHY: on Windows a text-mode print() ends the line with CRLF, and the shell
# then reads the CR as part of the VALUE (a session id, a cursor, a count, a
# whole JSON document). Every python invocation of the skill goes through this
# helper, so the shell always receives LF-terminated output. The exit code of
# python is preserved (the callers branch on it).
py() {
  # The output is captured AND the exit code kept: a python that prints a
  # result and exits non-zero (the "ambiguous" case of session-id) must still
  # deliver its output to the caller.
  _py_out=$(python3 "$@"); _py_rc=$?
  [ -n "$_py_out" ] && printf '%s\n' "$_py_out" | tr -d '\r'
  return $_py_rc
}

json_escape() {  # stdin -> JSON string body (no quotes) with \n between lines
  awk 'BEGIN{ORS=""}{gsub(/\\/,"\\\\");gsub(/"/,"\\\"");gsub(/\t/,"\\t");gsub(/\r/,"\\r");if(NR>1)printf "\\n";printf "%s",$0}'
}
# project_sessions_json -> the sessions of THIS project, paginated.
# The query is FILTERED BY PROJECT (the API accepts `directory`): without it
# the whole catalog of the instance was downloaded (thousands of sessions,
# 50 per page -> 30+ requests, the pagination cap) and filtered client-side.
# On a big instance that was slow AND failed intermittently. The client-side
# filter stays as a safety net: the server filter narrows, it does not trust.
project_sessions_json() {
  # The directory filter is only a NARROWING filter: if the encoding fails
  # and the value goes out empty, the server is asked for the WHOLE catalog
  # (thousands of sessions, 50 per page -> the pagination cap) and the
  # client-side filter then has to sift it. So the encoding must FAIL CLOSED:
  # an empty directory is a different query, not the same one.
  _dir_enc=$(url_encode "$PROJ_DIR") || return 3
  [ -n "$_dir_enc" ] || return 3
  api_get_all_pages "/api/session?directory=$_dir_enc" || return 3
}
# url_encode STRING -> percent-encoded for a query parameter. A project
# directory can hold spaces, '+', '&' and non-ASCII, and an unencoded value
# would change the query the server sees (or break the URL).
# A FAILURE is reported (non-zero rc), never turned into an empty value: the
# caller turns that empty value into an unfiltered query.
url_encode() {
  _ue=$(py -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$1" 2>/dev/null) || return 1
  [ -n "$_ue" ] || return 1
  printf '%s' "$_ue"
}
# json_get_field KEY [VALUE_PREFIX] : stdin=JSON -> the value of the "KEY" field.
#
# The offset formula lives in the SHARED library scripts/_json.awk (the ONE
# implementation of ONE offset convention), not here: the same formula was
# duplicated in this file, in orchestrate.sh, in preflight.sh and in
# watch_run.sh, and the copies had already DIVERGED (one of them could not
# read a number at all, another stripped a number to its digits). The library
# is prepended to the program by source concatenation, exactly like
# _validators.awk is for the two validators (not with -f, which is not
# portable when mixed with an inline program in mawk 1.3.3).
#
# The old inline `match(...)/substr(RSTART+n, RLENGTH-m)` extractions mixed
# two conventions: when the regex did NOT include the closing quote of a
# string value but the length still subtracted it, the value lost its last
# character (the message id printed as msg_01HXYZABCDEF instead of
# msg_01HXYZABCDEFG) and every numeric field lost a digit (time.updated
# 1792693166999 -> 79269316699, which then compared as "older" and could
# classify a busy session as idle). The value is located by the KEY and read
# to its natural end, so the length can never disagree with the pattern.
#
# VALUE_PREFIX restricts the match to values starting with it (e.g. "msg_"),
# so `id` never picks up a different id.
json_get_field() {
  # Fail closed HERE, where the library is actually needed: a missing library
  # is a broken install, and a private copy of the formula is the drift this
  # removes. Reporting it at the extraction (not at source time) keeps the
  # cache-dir guard the reason a caller sources this file.
  [ -n "$_JSON_LIB" ] || { printf 'ERROR: shared awk library missing: %s/_json.awk (the caller must export SELF_DIR=<the scripts directory>)\n' "${SELF_DIR:-scripts}" >&2; exit 2; }
  awk -v key="$1" -v pre="${2:-}" "$_JSON_LIB"'
    { buf = buf (NR > 1 ? " " : "") $0 }
    END { json_field(buf, key, pre); if (JSON_FOUND) print JSON_VALUE }'
}

# --- kv cache -------------------------------------------------------------------
# A-5: cache_put used to be a bare `>` truncate. Two concurrent writers to the
# SAME key (root_session / worker_<title> from two parallel init-runs) raced
# between the truncate and the dump: a concurrent cache_get read a torn/partial
# file and one write was lost. The publish below is now atomic: the payload is
# written to a temp file IN THE SAME DIRECTORY and moved with mv(1) -> rename(2),
# so a reader always sees either the previous file or the complete new one.
# Every cache write site (root_session, worker_<title>, dispatch_<SID>, ...) goes
# through this single helper (DRY), so the fix covers all of them at once.
cache_write() {  # KEY VALUE [MODE] -> persists VALUE to CACHE_DIR/KEY. ONE writer.
  # MODE=redact (default) re-serializes a JSON value with the secret fields
  # masked; MODE=raw writes the value VERBATIM.
  # WHY two modes: the redaction RESERIALIZES any value that happens to parse
  # as JSON, so a password of "1.50" would be rewritten as "1.5" and a quoted
  # string would gain quotes. The auth password is written verbatim.
  #
 # (CWE-59): a symlink planted at this path would make the write truncate
  # its TARGET. Fail closed: refuse to write through symlinks at all.
 [ -L "$CACHE_DIR/$1" ] && die "cache key '$1' is a symlink; refusing to write through it (CWE-59)"
  # Redacts apiKey / password / token (case-insensitive) recursively from any JSON
  # value before writing. Non-JSON values pass through unchanged. Defense in depth
  # for S1 (gap V1): even if a future caller routes an /api/model/default body
  # through cache_put, the apiKey never lands in plaintext on disk. Falls back to
  # the legacy plain-printf write when python3 is unavailable (cache consumers
  # are unaffected; only the redaction is skipped). Contract: same signature,
  # same exit codes.
  _ck="$CACHE_DIR/$1"
  # Temp file in the SAME directory (rename must not cross filesystems); mktemp
  # gives cross-process uniqueness; the $$ fallback covers a missing mktemp.
  _ct=$(mktemp "$CACHE_DIR/.cacheput.XXXXXX" 2>/dev/null) || _ct="$_ck.tmp.$$"
 #: the fallback name is predictable (PID-suffixed) on every OS that
  # lacks /dev/null-safe mktemp; an attacker who plants a same-name symlink
 # would make the truncate target it. symmetry at the temp path.
 [ -L "$_ct" ] && die "cache temp '$_ct' is a symlink; refusing to write through it (CWE-59)"
  if [ "${3:-redact}" = "raw" ] || ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "$2" > "$_ct" || { rm -f "$_ct"; return 1; }
  else
    printf '%s\n' "$2" | py -c '
import json, sys
raw = sys.stdin.read()
try:
    obj = json.loads(raw, strict=False)
except Exception:
    sys.stdout.write(raw)
    sys.exit(0)
SECRET = {"apikey", "password", "token"}
def redact(v):
    if isinstance(v, dict):
        return {k: ("[REDACTED]" if str(k).lower() in SECRET else redact(val)) for k, val in v.items()}
    if isinstance(v, list):
        return [redact(x) for x in v]
    return v
out = json.dumps(redact(obj))
if not out.endswith("\n"):
    out += "\n"
sys.stdout.write(out)
' > "$_ct" || { rm -f "$_ct"; return 1; }
  fi
  # Atomic publish. The temp file is never read by cache_get (key prefix ".cacheput"),
  # and a failed mv leaves the previous value in place (fail-closed, no torn state).
  mv -f "$_ct" "$_ck" || { rm -f "$_ct"; return 1; }
}
# cache_put KEY VALUE -> persists VALUE with the JSON secret redaction.
cache_put() { cache_write "$1" "$2" redact; }
# cache_put_raw KEY VALUE -> persists VALUE verbatim (no re-serialization).
cache_put_raw() { cache_write "$1" "$2" raw; }
cache_get() {
 # read path: a poisoned symlink is never trusted; report it and return
  # empty so callers see the key as absent instead of reading the target.
  if [ -L "$CACHE_DIR/$1" ]; then
 printf 'ERROR: cache key %s is a symlink; treated as poison (CWE-59)\n' "$1" >&2
    printf ''; return 0
  fi
  if [ -f "$CACHE_DIR/$1" ]; then cat "$CACHE_DIR/$1"; else printf ''; fi; }
#: same refusal in the presence test, so require_state cannot bless a
# symlinked key (cache_get alone would still be silenced by 2>/dev/null).
cache_has() { [ -f "$CACHE_DIR/$1" ] && [ ! -L "$CACHE_DIR/$1" ] && [ -s "$CACHE_DIR/$1" ]; }

# cache_purge_sid SID -> removes the cache keys that POINT at a deleted
# session (C-12): dispatch_<SID>, plus root_session / root_session_hint /
# worker_* whose VALUE is exactly SID. Keys of sessions that were NOT deleted
# are left alone. Single helper for delete-session and clean (DRY).
cache_purge_sid() {
  rm -f "$CACHE_DIR/dispatch_$1" 2>/dev/null
  for _k in "$CACHE_DIR/root_session" "$CACHE_DIR/root_session_hint" "$CACHE_DIR"/worker_*; do
 #: real cache keys only. `.cacheput.*` and `*.tmp.*` are reserved
    # names for in-flight cache_put artifacts (mv has not published yet, the
    # content is partial). Letting `cat` read or `rm` race the temp turns a
    # concurrent write into a lost or torn value. Same exclusion in
 # preflight.sh's symlink scan.
    case "${_k##*/}" in .cacheput.*|*.tmp.*) continue ;; esac
    [ -f "$_k" ] || continue
    [ "$(cat "$_k" 2>/dev/null)" = "$1" ] && rm -f "$_k"
  done
  return 0
}
# auth_flag: Basic-auth flag for curl. It lives HERE, not in orchestrate.sh,
# because find_dedup and http_* use it and _common.sh is the low layer.
# Defining it in the caller would create a dependency on sourcing order:
# correct at runtime, fragile against any test or direct inclusion of _common.sh.
auth_flag() { if cache_has auth_password; then printf '%s' "-u opencode:$(cache_get auth_password)"; fi; }
require_state() {
  for k in endpoint version projectID model_default; do
    cache_has "$k" || { printf 'ERROR: state not initialized; run: orchestrate.sh preflight %s\n' "$PROJ_DIR" >&2; exit 1; }
  done
}

# --- arg parsing ------------------------------------------------------------------
# assert_value FLAG COUNT : fail closed (exit 2) when a value-taking flag was
# given WITHOUT its value.
#
# WHY this helper exists: `shift 2` with fewer than two arguments left does NOT
# advance the argument list (POSIX: the shift fails and $#/$1 are left
# unchanged). The parse loop then re-reads the same flag on every iteration:
# an INFINITE LOOP with no output, no error and no timeout -- the caller spins
# at 100% CPU forever. `orchestrate.sh send-prompt --session` (no value) hung
# this way. Every value-taking flag validates through this ONE helper (DRY):
# one rule, N call sites, no way to forget it.
assert_value() {
  if [ "${2:-0}" -lt 2 ]; then
    printf 'ERROR: %s requires a value\n' "$1" >&2
    exit 2
  fi
}
# _wt_add TITLE -> append ONE title to the ordered list of requested workers.
# _wt_add_list LIST -> append a comma separated LIST, in order.
#
# WHY ONE ORDERED LIST: the requested titles used to live in TWO variables
# (the --workers group and the --worker group) and the second OVERWROTE the
# first, so `init-run --workers "A, B" --worker C` created ONE worker (C) and
# dropped A and B with no warning -- the same class as the "the loose tokens
# were discarded" defect, moved to another group. The loose tokens were also
# joined with SPACES, so "T1" "T2" "T3" became ONE title ("T2 T3"). One list,
# built in the order the flags arrive, cannot lose a group.
_wt_add() {
  [ -n "${1:-}" ] || return 0
  WORKER_TITLES="${WORKER_TITLES:+$WORKER_TITLES$NL}$1"
}
_wt_add_list() {
  _wl_rest="${1:-}"
  while [ -n "$_wl_rest" ]; do
    case "$_wl_rest" in
      *,*) _wl_one="${_wl_rest%%,*}"; _wl_rest="${_wl_rest#*,}" ;;
      *)   _wl_one="$_wl_rest"; _wl_rest="" ;;
    esac
    # the spaces that surround a comma are not part of the title
    _wt_add "$(printf '%s' "$_wl_one" | sed 's/^[ \t]*//; s/[ \t]*$//')"
  done
}
parse_kv() {
  # The requested worker titles are ONE ordered list (WORKER_TITLES), filled
  # as the flags arrive: --workers "A, B" (a comma separated list), --worker
  # "C" (repeatable) and the loose positional tokens (one title each) all
  # land in it, in the order they were given. See _wt_add above for why it is
  # ONE list and not two.
  WORKER_TITLES=""
  # shellcheck disable=SC2034  # TITLE/AGENT/MODEL/WORKER_ID are populated by parse_kv and read by callers (sub_create_worker, sub_send_prompt, etc.); shellcheck can't see across function boundaries
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) assert_value --title "$#"; TITLE="${2:-}"; shift 2 ;; --title=*) TITLE="${1#--title=}"; shift ;;
      --agent) assert_value --agent "$#"; AGENT="${2:-}"; shift 2 ;; --agent=*) AGENT="${1#--agent=}"; shift ;;
      --model) assert_value --model "$#"; MODEL="${2:-}"; shift 2 ;; --model=*) MODEL="${1#--model=}"; shift ;;
      --session) assert_value --session "$#"; SID="${2:-}"; shift 2 ;; --session=*) SID="${1#--session=}"; shift ;;
      --worker-id) assert_value --worker-id "$#"; WORKER_ID="${2:-}"; shift 2 ;; --worker-id=*) WORKER_ID="${1#--worker-id=}"; shift ;;
      --expected-parent) assert_value --expected-parent "$#"; EXPECTED_PARENT="${2:-}"; shift 2 ;; --expected-parent=*) EXPECTED_PARENT="${1#--expected-parent=}"; shift ;;
      --artifact) assert_value --artifact "$#"; ARTIFACT="${2:-}"; shift 2 ;; --artifact=*) ARTIFACT="${1#--artifact=}"; shift ;;
      --tui-cwd) assert_value --tui-cwd "$#"; TUI_CWD="${2:-}"; shift 2 ;; --tui-cwd=*) TUI_CWD="${1#--tui-cwd=}"; shift ;;
      -d|--deadline) assert_value --deadline "$#"; DEADLINE="${2:-}"; shift 2 ;; --deadline=*) DEADLINE="${1#--deadline=}"; shift ;;
      -i|--interval) assert_value --interval "$#"; INTERVAL="${2:-}"; shift 2 ;; --interval=*) INTERVAL="${1#--interval=}"; shift ;;
      -s) assert_value -s "$#"; SID="${2:-}"; shift 2 ;;
      -a) assert_value -a "$#"; ARTIFACT="${2:-}"; shift 2 ;;
      --workers) assert_value --workers "$#"; _wt_add_list "${2:-}"; shift 2 ;; --workers=*) _wt_add_list "${1#--workers=}"; shift ;;
      --count) assert_value --count "$#"; COUNT="${2:-}"; shift 2 ;; --count=*) COUNT="${1#--count=}"; shift ;;
      --worker) assert_value --worker "$#"; _wt_add "${2:-}"; shift 2 ;;
      --worker=*) _wt_add "${1#--worker=}"; shift ;;
      --prompt-file) assert_value --prompt-file "$#"; PROMPT_FILE="${2:-}"; shift 2 ;; --prompt-file=*) PROMPT_FILE="${1#--prompt-file=}"; shift ;;
      --router-prompt) assert_value --router-prompt "$#"; ROUTER_PROMPT="${2:-}"; shift 2 ;; --router-prompt=*) ROUTER_PROMPT="${1#--router-prompt=}"; shift ;;
      --no-router) NO_ROUTER=1; shift ;;
      --target) assert_value --target "$#"; WORKER="${2:-}"; shift 2 ;; --target=*) WORKER="${1#--target=}"; shift ;;
      --auto-count) AUTO_COUNT=1; shift ;;
      --wait) WAIT=1; shift ;;
      --no-attach-tabs) NO_ATTACH=1; shift ;;
      --force-tabs) FORCE_TABS=1; shift ;;
      --force-new) FORCE_NEW=1; shift ;;
      --yes) YES=1; shift ;;
      --force) FORCE=1; shift ;;
      --) shift; break ;;
      -*) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
      *) _wt_add "$1"; shift ;;
    esac
  done
}

# --- advisory file lock (ONE implementation for the whole skill; DRY) ------------
# This is the lock that used to live INSIDE the tabs.json merge (python fcntl,
# with a fail-closed guard when the interpreter has no fcntl). It was extracted
# here, unchanged in spirit, so that there is exactly ONE locking mechanism in
# the skill and every caller shares its guarantees:
#
#   * tabs.json merge (os_tabs_merge) and tabs prune (tabs_prune_ids);
#   * the per-project critical section of create-worker / ensure-root /
#     init-run (the guard -> POST -> cache_put sequence that used to be a
#     check-then-act race, A-4/A-5).
#
# WHY python fcntl and not flock(1): flock(1) does not exist on macOS and is
# absent on Windows Git Bash, so it cannot be the portable primitive. python3's
# fcntl.flock is the same POSIX advisory lock on every supported platform
# (darwin, linux, WSL, MSYS2/Git Bash) and it is already a hard dependency of
# the merge path. When the interpreter has no fcntl (e.g. the native Windows
# python on PATH) the helper FAILS CLOSED instead of pretending to lock.
#
# GUARANTEES:
#   * mutual exclusion: the lock is held by the helper process for the whole
#     lifetime of the wrapped command;
#   * BOUNDED wait: after TIMEOUT_S the helper fails closed (rc 71). It never
#     waits forever and never hangs;
#   * released on EVERY exit path: the helper unlocks in a finally block, and
#     the kernel releases the lock even if the helper is killed (SIGKILL) or
#     the command dies. There is no shell trap that can be skipped;
#   * the wrapped command's exit code is propagated unchanged; only the
#     helper's own failures use the reserved codes below.
#
# Exit codes (: the wrapped command's rc is propagated 1:1, not remapped):
#   0..255 the wrapped command's own exit code (128+N if it dies by signal N).
#   70     no usable lock mechanism (python3/fcntl missing, lock file unusable,
#          or the command could not be launched) -> fail-closed, nothing written.
#   71     the lock was still held after the bounded wait -> fail-closed.
#   A wrapped command that itself returns 70/71 collides BY VALUE only; the
#   discriminator is the `lock_status=fail-closed` line on stderr (emitted
#   only on the helper's own failures). Remapping the collision (e.g. to 72)
#   would silently rewrite a legitimate rc and break the caller's contract,
#   so it is deliberately NOT done: the call graph under lock_exec (merge
#   helpers + critical-section guards) never wraps a command exiting 70/71.
LOCK_EXEC_PY='import os, subprocess, sys, time

def fail(code, msg):
    sys.stderr.write("lock_status=fail-closed reason=%s\n" % msg)
    sys.exit(code)

if len(sys.argv) < 4:
    fail(70, "usage: lock_exec LOCKFILE TIMEOUT_S COMMAND [ARG...]")
lockfile, timeout, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    import fcntl
except Exception:
    fail(70, "this python3 has no fcntl (e.g. native Windows python); no lock was taken")
try:
    tmo = float(timeout)
except Exception:
    fail(70, "invalid timeout: %s" % timeout)
try:
    fd = os.open(lockfile, os.O_RDWR)
except Exception as exc:
    fail(70, "cannot open lock file %s: %s" % (lockfile, exc))
deadline = time.time() + tmo
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except OSError:
        if time.time() >= deadline:
            os.close(fd)
            fail(71, "busy: %s is still locked after %ss" % (lockfile, timeout))
        time.sleep(0.2)
try:
    rc = subprocess.call(cmd)
except Exception as exc:
    rc = 70
    sys.stderr.write("lock_status=fail-closed reason=cannot run command: %s\n" % exc)
finally:
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except Exception:
        pass
    try:
        os.close(fd)
    except Exception:
        pass
if rc < 0:
    rc = 128 + (-rc)
sys.exit(rc)'

# lock_py_file -> prints the path of a temp .py holding LOCK_EXEC_PY.
lock_py_file() {
  _lpf=$(mktemp "${TMPDIR:-/tmp}/orchlock.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n' "$LOCK_EXEC_PY" > "$_lpf" || { rm -f "$_lpf"; return 1; }
  printf '%s' "$_lpf"
}

# lock_exec LOCKFILE TIMEOUT_S COMMAND [ARG...]
# Runs COMMAND with an exclusive advisory lock on LOCKFILE held for its whole
# lifetime. The lock file must already exist (the caller owns its creation:
# a lock target that does not exist is a bug, not something to create silently).
# (exit-code contract): the wrapped command's rc propagates 1:1 (a
# signal death is reported as 128+N by the helper). 70/71 are the helper's OWN
# reserved codes (no-lock-mechanism / busy). NOT remapped: no wrapped command
# in this skill exits 70/71 (verified R5: orchestrate.sh exits 70 only in the
# block the re-exec'd child skips), and remapping would falsify real codes.
lock_exec() {
  # Arity is checked before the shift: `shift 2` with fewer than two arguments
  # left does NOT advance the list (POSIX), so the helper would receive the
  # wrong argv. Usage error -> 70 (the helper's own reserved fail-closed code).
  [ $# -ge 3 ] || { printf 'ERROR: lock_exec: need LOCKFILE TIMEOUT_S COMMAND\n' >&2; return 70; }
  _lf="$1"; _lt="$2"; shift 2
  [ $# -gt 0 ] || { printf 'ERROR: lock_exec: no command to run\n' >&2; return 70; }
  command -v python3 >/dev/null 2>&1 || {
    printf 'lock_status=fail-closed reason=python3 not found; no lock mechanism\n' >&2
    return 70
  }
  _lpy=$(lock_py_file) || {
    printf 'lock_status=fail-closed reason=cannot create the lock helper\n' >&2
    return 70
  }
  # On Git Bash a native Win32 python cannot open an MSYS path; cygpath -m
  # converts it (no-op where cygpath does not exist: darwin/linux/WSL).
  # BOTH paths need it: the helper script AND the lock file. Without the
  # lock-file conversion the helper failed closed with "cannot open lock file"
  # on every create-worker / ensure-root / init-run under Git Bash (the
  # lockfile path comes from CACHE_DIR, which is an MSYS path there).
  _lpy_run="$_lpy"; _lf_run="$_lf"
  if command -v cygpath >/dev/null 2>&1; then
    _lpy_run=$(cygpath -m "$_lpy" 2>/dev/null || printf '%s' "$_lpy")
    _lf_run=$(cygpath -m "$_lf" 2>/dev/null || printf '%s' "$_lf")
  fi
  python3 "$_lpy_run" "$_lf_run" "$_lt" "$@"
  _lrc=$?
  rm -f "$_lpy"
  return $_lrc
}

# --- tabs merge engine (python3; THE lock comes from lock_exec, not from here) ----
# The merge no longer locks on its own: the per-OS adapters wrap it in
# lock_exec (the ONE lock above), which holds an exclusive fcntl lock on the
# tabs.json inode for the whole merge. The merge writes through an "r+"
# descriptor WITHOUT renaming the file, so the inode (and therefore the
# external lock) stays valid for the entire critical section (S1b-10 note).
TABS_MERGE_PY='import json, os, shutil, sys
sid, title, tui_cwd, bk = sys.argv[1:5]
chan = os.environ.get("OPENCODE_TUI_CHANNEL","latest")
# The path is RESOLVED BY THE SHELL (tabs_target_path) and exported. This
# python used to carry its OWN resolver (state root -> channel -> tabs.json,
# with its own fallbacks) which could name a DIFFERENT file than the one the
# lock guarded: the lock protected one file and the merge wrote another.
# There is now ONE resolver; the python only consumes its result and fails
# closed when it is missing.
p = os.environ.get("ORCHESTRATE_TABS_JSON")
if not p:
    print("tabs_status=no-tui"); sys.exit(4)
if not os.path.exists(p):
    print("tabs_status=no-tui"); sys.exit(4)
f = open(p, "r+")
try:
    d = json.load(f, strict=False)
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
        for v in d["cwd"].values():
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
 #: setdefault "unread" so a cwd scope created by THIS merge also
    # satisfies the schema guard above. Without it, the next merge fails
    # closed with "esquema-distinto" (L240) and reports a phantom error.
    tabs_scope = d.setdefault("cwd", {}).setdefault(tui_cwd, {})
    tabs = tabs_scope.setdefault("tabs", [])
    tabs_scope.setdefault("unread", {})
    for t in tabs:
        if t.get("sessionID") == sid:
            if title and t.get("title") != title:
                t["title"] = title
            break
    else:
        tabs.append({"sessionID": sid, "title": title})
    # Write through the SAME "r+" descriptor, WITHOUT renaming the file. A
    # temp + os.replace would destroy the inode: the lock held by lock_exec
    # would end up on a file that no longer existed and two concurrent merges
    # could lose one tab while BOTH reported ok-verified (S1b-10). We lose
    # rename atomicity but keep real mutual exclusion, which is what prevents
    # silent loss; the backup above covers the crash-mid-write case.
    f.seek(0); f.truncate()
    json.dump(d, f, indent=2)
    f.flush()
    os.fsync(f.fileno())
    with open(p) as rb:
        rt = next((t for t in json.load(rb, strict=False).get("cwd", {}).get(tui_cwd, {}).get("tabs", [])
                   if t.get("sessionID") == sid), None)
        ok = rt is not None
        title_ok = ok and (not title or rt.get("title") == title)
    print("tabs_status=%s" % ("ok-verificada-title" if title_ok else "readback-fail"))
    sys.exit(0 if ok and title_ok else 5)
finally:
    f.close()'

tabs_merge_py_file() {  # emits path to a temp .py with TABS_MERGE_PY
 #: same fail-closed contract as lock_py_file (DRY symmetry): check
  # mktemp AND the write, and leave a trail when either fails (a bare rc from
  # `python3 ""` tells the caller nothing).
  _tmf=$(mktemp "${TMPDIR:-/tmp}/tabsmerge.XXXXXX" 2>/dev/null) || { printf 'tabs_status=fail-closed reason=cannot create the merge helper\n' >&2; return 1; }
  printf '%s\n' "$TABS_MERGE_PY" > "$_tmf" || { rm -f "$_tmf"; printf 'tabs_status=fail-closed reason=cannot write the merge helper\n' >&2; return 1; }
  printf '%s' "$_tmf"
}

# tabs_merge_helper -> prints the path of the temp merge helper, or fails
# closed (rc 2) with the reason. ONE check for EVERY adapter (DRY): only
# windows-gbash.sh verified the helper, so on darwin/linux/wsl a failed
# mktemp produced an opaque `python3 ""` error instead of the documented
# fail-closed reason. Callers use `_pyf=$(tabs_merge_helper) || return 2`.
tabs_merge_helper() {
  _tmh=$(tabs_merge_py_file) || return 2
  if [ -z "$_tmh" ]; then
    printf 'tabs_status=fail-closed reason=merge-helper-unavailable\n' >&2
    return 2
  fi
  printf '%s' "$_tmh"
}

# --- tabs merge: the ONE implementation for every OS adapter -----------------
# The four adapters (darwin, linux, wsl, windows-gbash) used to carry their own
# copy of this skeleton, and they had DRIFTED: windows-gbash.sh had the arity
# guard and the others did not (so a wrong arity returned 4 "no-tui" there and
# 2 "usage" on Git Bash), and windows-gbash.sh had NO "tabs.json must exist"
# check (so a missing file returned 70, a raw lock error, instead of 4
# "no-tui"). A guard that exists in ONE adapter and not the others is a defect
# (the class), and the drift is invisible until someone runs the other
# OS. Now the skeleton lives HERE and the adapter only declares what is
# genuinely OS-specific:
#   os_tabs_extra_check PATH  -> an extra fail-closed check (WSL: drvfs)
#   os_tabs_adapt_paths       -> path adaptation (Git Bash: cygpath -m)
#   os_tabs_python_hint       -> extra guidance when python3 is missing
# A hook is OPTIONAL: the defaults below apply when the adapter does not
# define it.
#
# Exit codes (IDENTICAL on every OS now):
#   2  usage / no python3 / merge helper unavailable
#   3  OS-specific fail-closed (WSL: state on drvfs)
#   4  no TUI storage (no tabs.json)
#   rc the exit code of the merge itself
if ! command -v os_tabs_extra_check >/dev/null 2>&1; then
  os_tabs_extra_check() { return 0; }
fi
if ! command -v os_tabs_adapt_paths >/dev/null 2>&1; then
  # Default: no adaptation. Sets the globals the skeleton uses.
  os_tabs_adapt_paths() { TABS_PATH="$1"; TABS_HELPER="$2"; }
fi
if ! command -v os_tabs_python_hint >/dev/null 2>&1; then
  os_tabs_python_hint() { :; }
fi
os_tabs_merge_shared() {  # SID TITLE TUI_CWD BACKUP_DIR
  [ $# -eq 4 ] || { printf 'os_tabs_merge: internal usage: SID TITLE TUI_CWD BACKUP_DIR\n' >&2; return 2; }
  # 1) The tabs.json to operate on (ONE resolver: tabs_target_path). It is
  #    EXPORTED, so the merge python writes EXACTLY the file locked below.
  _tabs=$(tabs_target_path) || { printf 'tabs_status=no-tui\n'; return 4; }
  export ORCHESTRATE_TABS_JSON="$_tabs"
  # 2) OS-specific fail-closed check (WSL: state on drvfs -> unreliable lock).
  os_tabs_extra_check "$_tabs" || return $?
  # 3) python3 (the merge helper and the lock both need it).
  command -v python3 >/dev/null 2>&1 || {
    printf 'python3 required for tabs (nothing was written)\n' >&2
    os_tabs_python_hint
    return 2
  }
  # 3b) The interpreter must have fcntl: the shared lock is python fcntl. The
  # probe lived ONLY in the Git Bash adapter (where a native python.org
  # python is on PATH), so the same condition failed closed with rc 2 + a
  # guidance line there and with rc 70 + a raw lock error everywhere else.
  # Now the probe is in the shared skeleton: the same rc and message on every
  # OS. (On darwin/linux/wsl the probe always passes.)
  py -c 'import fcntl' >/dev/null 2>&1 || {
    printf 'tabs_status=fail-closed (this python3 has no fcntl; e.g. native Windows python on PATH; nothing was written)\n' >&2
    printf 'Next: put an MSYS2 python3 on PATH, or open the session in the TUI (/sessions or Ctrl+X L) and mark the tab as not verified.\n' >&2
    return 2
  }
  # 4) The merge helper (ONE shared check for every adapter).
  _pyf=$(tabs_merge_helper) || return 2
  # 5) OS-specific path adaptation (Git Bash: cygpath -m, so a native Win32
  #    python can open the file). It happens BEFORE the existence check, so the
  #    check, the lock and the write all name the SAME file: the check used to
  #    run on the UNCONVERTED path while the lock and the merge used the
  #    converted one, and a tabs.json reachable only under the converted path
  #    was reported as "no-tui" (or, worse, locked one file and wrote another).
  os_tabs_adapt_paths "$_tabs" "$_pyf"
  _tabs="$TABS_PATH"; _pyf="$TABS_HELPER"
  export ORCHESTRATE_TABS_JSON="$_tabs"
  # 6) The file must exist: no tabs.json -> no-tui. On every OS.
  [ -f "$_tabs" ] || { printf 'tabs_status=no-tui\n'; return 4; }
  # DRY: the ONE lock of the skill (lock_exec). It locks exactly the file the
  # merge writes (ORCHESTRATE_TABS_JSON) and holds it for the whole merge.
  lock_exec "$_tabs" "${ORCHESTRATE_TABS_LOCK_TIMEOUT:-5}" python3 "$_pyf" "$1" "$2" "$3" "$4"
  _rc=$?
  rm -f "$_pyf"
  return $_rc
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

# tabs_target_path -> prints the tabs.json the skill must operate on:
# ORCHESTRATE_TABS_JSON when the caller pre-set it (a redirected tabs.json),
# else tabs_json_path (the SINGLE SOURCE of the discovery).
#
# ONE resolver for the four merge adapters, the prune and the merge python
# (DRY). The same 6-line "if [ -n ... ] else tabs_json_path" block was
# copy-pasted in linux.sh, wsl.sh, windows-gbash.sh, darwin.sh (inverted) and
# orchestrate.sh's tabs_prune_ids, and the merge python carried a SIXTH
# resolver with DIFFERENT rules (no `opencode debug paths state` fallback, no
# XDG_STATE_HOME default, no channel scan, channel default "latest"). The two
# could therefore name DIFFERENT files: the lock guarded one and the merge
# wrote the other -- exactly what the "the lock locks exactly the file the
# merge writes" comment claims cannot happen.
# The caller EXPORTS the result, so the python never resolves anything.
tabs_target_path() {
  if [ -n "${ORCHESTRATE_TABS_JSON:-}" ]; then
    printf '%s\n' "$ORCHESTRATE_TABS_JSON"
    return 0
  fi
  tabs_json_path
}

# tabs_json_path -> prints the ABSOLUTE path of the active TUI's tabs.json.
# SINGLE SOURCE of the resolution (DRY): before, darwin/tui-detect discovered
# the channel by glob and honored XDG_STATE_HOME, while linux/wsl/windows
# guessed "latest" and hardcoded ~/.local/state — 8 sites that could write a
# tab into a channel the TUI never reads. The adapters only decide the lock
# mechanism.
# Exit 4 = no TUI with storage (the caller reports no-tui).
# tui_pin -> prints the validated TUI branch pin.
# ONE definition of the default and of the "major branch only" rule: the pin
# was re-declared in four places and the rule in three, so the copies could
# drift (and did: one of them accepted a pin with a minor version).
# The detector (os/tui-detect.sh) is standalone and keeps its own copy of the
# rule on purpose; it is the only second copy.
tui_pin() {
  _tp=${OPENCODE_TUI_PINNED_VERSION:-2}
  case "$_tp" in
    *.*) die "OPENCODE_TUI_PINNED_VERSION must be the major branch (e.g. 2), not $_tp" ;;
  esac
  printf '%s' "$_tp"
}
tabs_json_path() {
  # The state root comes from the ONE resolver (state_root in os/_paths.sh):
  # OPENCODE_STATE_ROOT > ORCHESTRATE_STATE_ROOT > the CLI registry > XDG.
  # The merge python used to carry its own resolution with DIFFERENT rules
  # (no CLI fallback, no XDG default, no channel scan), so the lock and the
  # merge could name different files.
  SR=$(state_root)
  if [ -n "${OPENCODE_TUI_CHANNEL:-}" ] && [ -f "$SR/$OPENCODE_TUI_CHANNEL/tui/tabs.json" ]; then
    printf '%s\n' "$SR/$OPENCODE_TUI_CHANNEL/tui/tabs.json"; return 0
  fi
  for c in "$SR"/*; do
    [ -d "$c" ] || continue
    if [ -f "$c/tui/tabs.json" ]; then printf '%s\n' "$c/tui/tabs.json"; return 0; fi
  done
  return 4
}

# session_state OUT IDLE UPDATED CREATED HAS_OUTCOME -> "idle" | "running" | "empty"
# SINGLE SOURCE of the pool-state derivation (F1/F2/F3: one root cause, one
# helper; pool_list and sub_wait_idle BOTH call it). Before, the rule was
# inline in pool_list (`idle if idle and updated and idle>=updated else
# running`): a session created by create-worker has NEITHER time.idle NOR any
# activity, so it was classified `running`, dispatch refused its FIRST prompt
# (bootstrap deadlock: create-worker -> dispatch exited 1 "not idle") and
# pool/wait-idle lied about brand-new workers. Truthful states:
#   idle    - time.idle exists and is not older than time.updated (finished).
#   running - any activity without idle: output tokens, an outcome, a stale
#             idle (no updated to compare), or time.updated > time.created
#             (a prompt was received). This is the fail-closed collision
#             guard: dispatch refuses it and it is never overwritten.
#   empty   - created but never used (out=0, no outcome, no idle,
#             updated <= created): dispatchable (it needs its FIRST prompt)
#             and reusable (it has no prior work to lose).
# Non-numeric input normalizes to 0; the parsers only emit digits.
session_state() {
  _ssn() { case "$1" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac; }
  _ss_o=$(_ssn "${1:-0}"); _ss_i=$(_ssn "${2:-0}")
  _ss_u=$(_ssn "${3:-0}"); _ss_c=$(_ssn "${4:-0}")
  if [ "$_ss_i" -gt 0 ] && [ "$_ss_u" -gt 0 ] && [ "$_ss_i" -ge "$_ss_u" ]; then
    printf 'idle\n'
  elif [ "$_ss_o" -gt 0 ] || [ "${5:-0}" = "1" ] || [ "$_ss_i" -gt 0 ] || [ "$_ss_u" -gt "$_ss_c" ]; then
    printf 'running\n'
  else
    printf 'empty\n'
  fi
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
  # Uses api_get_all_pages (DRY: same pagination as sub_sessions and
  # sub_session_id) so >50 sessions do not silently miss dedup matches.
  #
  # The query is FILTERED BY PROJECT: GET /api/session accepts `directory` and
  # `project`. Without the filter the pool query downloaded the WHOLE catalog
  # of the instance (thousands of sessions, 50 per page -> 30+ requests, the
  # pagination cap) and then filtered it client-side, which is slow and fails
  # intermittently on a big instance -- the run died with "could not query the
  # worker pool". The client-side filter stays as a safety net: the server
  # filter is a narrowing, not a trust boundary.
  RESP=$(project_sessions_json) || return 3
  [ -n "$RESP" ] || return 3
  # F1/F3: the STATE column is derived by session_state (ONE helper, shared
  # with sub_wait_idle/F2). The python stage emits the RAW fields as
  # ordinal<TAB>name<TAB>slug<TAB>sid<TAB>out<TAB>parent<TAB>idle<TAB>
  # updated<TAB>created<TAB>outcome_flag; a shell loop computes state and
  # re-emits the canonical 7-column layout below (state stays column 3, sid
  # 5, out 6, parent 7: find_dedup, sub_dispatch, sub_pool and init-run keep
  # their contract). `out` also reads tokens.output as a fallback: 2.0.32's
  # /api/session LIST no longer emits top-level `output` (only
  # tokens.output), so `s.get('output', 0)` was always 0 and the dedup
  # collision guard could never see prior work; the fallback restores the
  # fail-closed round-5 semantics (out > 0 and no time.idle => running).
  # The parse is a SEPARATE step whose exit code is KEPT: inside a pipeline
  # the status is the LAST command's (sort), so a parse failure read as an
  # EMPTY POOL with rc 0 -- and the pool then said "max ordinal 0" and the
  # next worker reused [01] (the same class as the pool-ordinal defect of
  # 1.5.0). The first page is validated as JSON but not as an OBJECT, so a
  # serve that answers with an array reaches this parse.
  _rows=$(printf '%s' "$RESP" | py -c "
import json, sys, re
d = sys.argv[1]
data = json.loads(sys.stdin.read(), strict=False).get('data', [])
for s in data:
    loc = s.get('location', {}).get('directory', '')
    if loc != d:
        continue
    title = s.get('title', '')
    m = re.match(r'^\[(\d+)\](?:s\[(\d+)\])?\s+(.*)$', title)
    if not m:
        continue
    tm = s.get('time', {}) or {}
    out = s.get('output', 0) or (s.get('tokens', {}) or {}).get('output', 0) or 0
    nm = m.group(3)
    print('\t'.join([str(int(m.group(1))), nm, re.sub(r'[ \t]', '', nm), s.get('id', ''),
                     str(out), m.group(2) or '',
                     str(tm.get('idle', 0) or 0), str(tm.get('updated', 0) or 0),
                     str(tm.get('created', 0) or 0), '1' if s.get('outcome') else '0']))
" "$PROJ_DIR") || return 3
  printf '%s\n' "$_rows" | while IFS= read -r _row; do
    [ -n "$_row" ] || continue
    _col() { printf '%s' "$_row" | cut -f"$1"; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(_col 1)" "$(_col 2)" \
      "$(session_state "$(_col 5)" "$(_col 7)" "$(_col 8)" "$(_col 9)" "$(_col 10)")" \
      "$(_col 3)" "$(_col 4)" "$(_col 5)" "$(_col 6)"
  done | sort -t'	' -k7,7 -k1,1n
}


# pool_max_ordinal POOL -> the highest ordinal deployed in POOL (0 when empty).
# POOL is the tab-separated output of pool_list and is PASSED IN, not fetched
# here. Before, this ran its own SECOND api call and the failure was swallowed:
# `pool_list | awk ...` keeps the awk exit code, so pool_list's `|| return 3`
# was invisible and a failed fetch read as "max=0" (empty pool). The next
# worker then took ordinal 01, which was already deployed -> two workers with
# the same [NN]. One fetch, one derivation (DRY).
pool_max_ordinal() {
  printf '%s\n' "$1" | awk -F'\t' 'BEGIN{m=0}{if($1+0>m)m=$1+0}END{print m}'
}

# --- the orchestrator: ONE fact, shared by everyone who must not target it ------
# The naming convention reserves the [00] slot for the root/orchestrator (the
# title parser below refuses to hand it to a worker), and the run records its
# root in the cache key root_session (root_session_hint for the root the
# operator declared). The orchestrator is NEVER the target of a prompt: the
# prompt would come back to the agent that is supposed to delegate, and the
# task would end up being done by the orchestrator instead of by a worker.
# The constant is the ORDINAL (the pool prints it without the brackets), so
# the two places that must agree cannot drift.
ORCHESTRATOR_ORDINAL=0

# orchestrator_sid -> the run's orchestrator (the root the run used).
# The run's own record of its root is the source: root_session is written when
# the root is created or reused, and root_session_hint is the root the
# operator declared. Reading it is free (the cache is already required by
# every command that sends a prompt).
orchestrator_sid() {
  for _os_k in root_session root_session_hint; do
    cache_has "$_os_k" || continue
    _os_v=$(cache_get "$_os_k")
    [ -n "$_os_v" ] || continue
    printf '%s' "$_os_v"
    return 0
  done
  return 1
}

# is_orchestrator_sid SID -> 0 when the SID is the run's orchestrator.
is_orchestrator_sid() {
  _is_sid="${1:-}"
  [ -n "$_is_sid" ] || return 1
  _is_root=$(orchestrator_sid) || return 1
  [ "$_is_root" = "$_is_sid" ]
}

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
  printf '%s' "$1" | tr ',' '\n' | awk -v orch="$ORCHESTRATOR_ORDINAL" '
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
      if (ordtxt + 0 == orch + 0) { n += 1; ord = n; ordtxt = sprintf("%02d", n) }
      key = "[" ordtxt "] " line
      # Same criterion as find_dedup: the slug ignores the ordinal, so
      # "Vermithrax" and "[01] Vermithrax" are recognized as the same worker.
      if (seen[slug(key)]++) next
      print key
    }'
}

# session_exists_json JSON -> 0 when JSON carries a ses_* session id (DRY:
# shared by wait-idle, verify-daughters and watch_run). Uses json_get_field
# with the ses_ prefix so pretty-printed JSON or a preceding model.id never
# misleads the check.
session_exists_json() {
  case "$(printf '%s' "${1:-}" | json_get_field id ses_)" in
    ses_*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- session creation (shared by ensure-root and create-worker; DRY) -----------
# model_pair_assert PAIR -> dies unless PAIR is a valid id@provider (portable
# sh case-match; no regex(3) dependency).: preflight refuses to CACHE a
# bogus pair; this re-validates at the POINT OF USE so a tampered/poisoned
# model_default (or --model) cannot create a session that silently ends in
# outcome=failed with 0 tokens. Same refusal wording family as preflight.
model_pair_assert() {
  _ok=""; _id="${1%@*}"; _prov="${1#*@}"
  [ "$1" != "$_prov" ] && [ -n "$_id" ] && [ -n "$_prov" ] && [ "$_id" = "${_id#*@}" ] && _ok=1
  case "${_id}@${_prov}" in *[!A-Za-z0-9._:/@-]*|none@none|null@null) _ok="" ;; esac
  [ -n "$_ok" ] && return 0
  die "model pair '$1' is not a valid id@provider; refusing to use a bogus model_default (fix: orchestrate.sh preflight, or --model id@prov)"
}
# session_body TITLE AGENT MODEL -> JSON for POST /api/session (nothing hardcoded)
session_body() {  # $1=title $2=agent $3=model(id@prov|empty)
  _t=$(printf '%s' "$1" | json_escape); _d=$(printf '%s' "$PROJ_DIR" | json_escape)
 _a=$(printf '%s' "${2:-build}" | json_escape) #: agent reached shell via --agent from caller; must be escaped
  _m="$3"
  MID="${_m%@*}"; MPROV="${_m#*@}"
  if [ -z "$_m" ] || [ "$MID" = "$MPROV" ]; then
    # The cache key is `model_default` (the one preflight.sh writes). Before,
    # `default_model` was read — a name that existed nowhere: every session
    # created by the script ended up with model {id:"",providerID:""} and,
    # when the prompt was sent, there was no model to infer with -> 0 tokens
    # and outcome=failed. The old name is accepted as a fallback for old caches.
    D=$(cache_get model_default)
    [ -n "$D" ] || D=$(cache_get default_model)
 model_pair_assert "$D" #: poison never reaches the POST body
 #: cached model pair escapes too (poisoned server response could
    # try to break out of the JSON).
    MID=$(printf '%s' "${D%@*}" | json_escape); MPROV=$(printf '%s' "${D#*@}" | json_escape)
  else
 model_pair_assert "$_m" #: explicit --model is validated too
    MID=$(printf '%s' "$MID" | json_escape); MPROV=$(printf '%s' "$MPROV" | json_escape)
  fi
  printf '{"title":"%s","agent":"%s","model":{"id":"%s","providerID":"%s"},"location":{"directory":"%s"}}' \
    "$_t" "$_a" "$MID" "$MPROV" "$_d"
}

# find_dedup TITLE -> "id out state" if a session with that title exists (compared
# by slug) in the project; empty if there is no match.
#
# The slug deliberately ignores the [NN] ordinal. "Vermithrax" and
# "[01] Vermithrax" are the SAME worker: if the slug included the brackets,
# searching by name would never find the numbered session and init-run created
# duplicates. The ordinal is ordering decoration; the identity is the name.
# F1: the third field is the session_state value, so dedup_guard can refuse a
# RUNNING match even while its output is still 0 (a prompt in flight, out not
# yet grown) instead of silently "reusing" a live session.
find_dedup() {
  # Thin filter over pool_list (SINGLE SOURCE of the fetch: DRY). Returns the
  # "id out state" of the session whose title matches by slug ignoring the
  # ordinal — "Vermithrax" finds "[01] Vermithrax" — or nothing if there is
  # no match. rc 3 = the pool could not be queried: the caller must fail closed.
  POOL=$(pool_list) || return 3
  printf '%s\n' "$POOL" | awk -F'\t' -v t="$1" '
      function slug(s, x) { x = s; sub(/^\[[0-9]+\][ \t]*/, "", x); gsub(/[ \t]/, "", x); return x }
      BEGIN { t = slug(t) }
      $4 == t { print $5, $6, $3; exit }'
}

# dedup_guard TITLE: single anti-overwrite guard for ensure-root and create-worker.
# It is invoked INSIDE $( ) by the callers: never uses die here (only the
# subshell would die and the caller would still create the session). Output
# contract:
#   0 + stdout "worker_id=..." -> inert session reused (the caller uses it).
#   1 -> no match (nor --force-new): create a new one.
#   2 + stdout "COLLISION out=N state=<running|prior-work>" -> the matched
#       session is not reusable (it is genuinely running, F1 state derivation,
#       or it has prior work): the CALLER dies. Fail-closed is unchanged.
dedup_guard() {
  [ "${FORCE_NEW:-0}" -eq 1 ] && return 1
  HIT=$(find_dedup "$1"); DRC=$?
  # rc 3 = the session catalog could not be queried. Treating it as "no
  # match" was exactly the door to duplicates: if the API fails, the session
  # is NOT created and the run stops.
  [ "$DRC" -eq 3 ] && return 3
  [ -n "$HIT" ] || return 1
  EX_ID=${HIT%% *}; EX_REST=${HIT#* }; EX_OUT=${EX_REST%% *}; EX_ST=${EX_REST#* }
  if [ "$EX_ST" = "running" ]; then
    printf 'COLLISION out=%s state=running id=%s\n' "$EX_OUT" "$EX_ID"
    return 2
  fi
  if [ "${EX_OUT:-0}" = "0" ]; then
    printf 'worker_id=%s\ndedup=1 inert-session-reused\n' "$EX_ID"
    return 0
  fi
  printf 'COLLISION out=%s state=prior-work id=%s\n' "$EX_OUT" "$EX_ID"
  return 2
}

# post_new_session BODY -> emits worker_id=/location=/parentID=null (validated)
post_new_session() {
 # companion: session_body dies inside its $(...) subshell when the model
  # pair is bogus and emits NO body; never POST emptiness to the serve
  # (fail-closed; an empty body could fall back to a server default).
  [ -n "$1" ] || die 'empty session body (bogus model pair? see the error above)'
  AUTH=$(auth_flag 2>/dev/null || printf '')
  RESP=$(http_post_json "$(cache_get endpoint)/api/session" "$1") || die 'POST /api/session failed'
  ID=$(printf '%s' "$RESP" | json_get_field id ses_)
  # Validating the id was the missing piece: without this check a "ok" POST
  # whose response lacked an id printed an empty worker_id= as validated, and
  # the caller cached an empty root returning 0 (nonexistent session believed
  # created).
  [ -n "$ID" ] && [ "${ID#ses_}" != "$ID" ] || die 'POST /api/session returned no ses_* sessionID; no usable session was created'
  PARENT=$(printf '%s' "$RESP" | json_get_field parentID)
  # decode JSON \\ escapes: on windows-gbash the echoed directory is
  # "C:\\Users\\..." while $PROJ_DIR holds single backslashes; without the
 # decode every create-worker would die on location mismatch.
  LOC=$(printf '%s' "$RESP" | json_get_field directory | sed 's/\\\\/\\/g')
  [ -z "$PARENT" ] || [ "$PARENT" = "null" ] || die "expected null parentID; got $PARENT"
  [ "$LOC" = "$PROJ_DIR" ] || die "location mismatch: $LOC != $PROJ_DIR"
  printf 'worker_id=%s\nlocation=%s\nparentID=null\n' "$ID" "$LOC"
}