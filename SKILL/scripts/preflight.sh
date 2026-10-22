#!/bin/sh
# Preflight: one-shot discovery of the OpenCode V2 instance for orchestration runs.
# Emits: endpoint, version, server pid, /openapi.json guard, canonical directory,
# projectID, agent catalogs by mode, default model pair (orchestrator profile),
# root session hint. Never prints credentials. No hardcoded models, endpoints or
# paths: everything is resolved from the live instance at run time.
# Dependencies: POSIX sh, awk, curl, tr. Works on any OS supporting opencode V2
# (Git Bash/WSL included; LF line endings enforced by .gitattributes).
# Usage: preflight.sh [directory]   (default: $PWD)
# Env:   OPENCODE_CLI (default opencode), OPENCODE_STATE_ROOT,
#        OPENCODE_SESSION_ID (root session hint when orchestrating in-session).
# Exit codes: 0 = ok, 1 = discovery failure (no usage/environment path; `set -u` traps misuse early).
set -u
# Deterministic collation for every awk/sort/grep below (same convention as
# validate_dag.sh / validate_ledger_closed.sh; matches are ASCII JSON keys).
LC_ALL=C
export LC_ALL
# shellcheck disable=SC1007  # CDPATH= cd ... | pwd -- the space after = is part of the command substitution syntax (false positive: shellcheck treats = as plain assignment).
# shellcheck source-path=scripts
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DIR="${1:-$PWD}"
CLI="${OPENCODE_CLI:-opencode}"

# F5: a standalone `sh scripts/preflight.sh .` populates the SAME cache that
# `orchestrate.sh preflight` populates (it exports ORCHESTRATE_CACHE_DIR).
# The derivation is NOT duplicated: os/_paths.sh is the single source shared
# with os/_common.sh (PROJ_DIR -> PROJ_HASH -> CACHE_DIR), and os/_common.sh
# is the single source of the cache WRITE contract (atomic + symlink-refusing).
# Both are sourced here so preflight writes through the same hardened helper
# as the rest of the skill instead of 14 raw `>` redirects (which were
# neither atomic nor symlink-safe).
# shellcheck disable=SC1091
. "$SELF_DIR/os/_paths.sh"
if [ -z "${ORCHESTRATE_CACHE_DIR:-}" ]; then
  ORCHESTRATE_CACHE_DIR="$CACHE_DIR"
else
  # The caller (orchestrate.sh) owns the cache location; the shared writer
  # writes to CACHE_DIR, so point it at the same directory.
  CACHE_DIR="$ORCHESTRATE_CACHE_DIR"
fi
export ORCHESTRATE_CACHE_DIR
# shellcheck disable=SC1091
. "$SELF_DIR/os/_common.sh"

# The state root comes from the ONE resolver (state_root in os/_paths.sh,
# sourced above): OPENCODE_STATE_ROOT > ORCHESTRATE_STATE_ROOT > the CLI
# registry > XDG. It is EXPORTED so the TUI detector (a separate process)
# resolves the SAME root: the gate and the tabs merge must name the same
# place. (It must be resolved AFTER the sources: state_root lives in
# os/_paths.sh.)
STATE_ROOT=$(state_root)
export OPENCODE_STATE_ROOT="$STATE_ROOT"
REG="$STATE_ROOT/service.json"

#: an empty or filesystem-root cache dir would turn every
# "$ORCHESTRATE_CACHE_DIR/<key>" into "/<key>". Fail-closed before any write.
case "${ORCHESTRATE_CACHE_DIR-}" in
 ''|/) printf "ERROR: no usable cache dir (ORCHESTRATE_CACHE_DIR='%s'); refusing to write into '/' \n" "${ORCHESTRATE_CACHE_DIR-}" >&2; exit 1;;
esac

# (CWE-59): the cache WRITER (cache_write in os/_common.sh) now refuses
# to write through a symlink at the key path, so a planted symlink can no
# longer have its TARGET truncated. This scan is kept as the early, obvious
# failure: it reports the whole directory at once, before any discovery work,
# so the reason is unambiguous instead of per-key.
if [ -d "$ORCHESTRATE_CACHE_DIR" ]; then
 #: scan hidden entries too (`*` alone missed ".endpoint"). The two
  # documented internal cache_put temp names — `.cacheput.XXXXXX` (mktemp) and
 # `*.tmp.*` (the `$$` fallback,) — are reserved; per-key guards
  # in cache_put/cache_get/cache_has own the real-key path. A symlink with one
 # of those names is still blocked by the cache_put temp refusal.
  for _f in "$ORCHESTRATE_CACHE_DIR"/* "$ORCHESTRATE_CACHE_DIR"/.[!.]* "$ORCHESTRATE_CACHE_DIR"/..?*; do
    [ -L "$_f" ] || continue
    case "${_f##*/}" in .cacheput.*|*.tmp.*) continue ;; esac
 printf '%s\n' "ERROR: cache entry is a symlink: $_f; refusing to write through it (CWE-59)" >&2
    exit 1
  done
fi

# 1) endpoint + version: prefer CLI, else active registration under state root
URL=""; VERSION=""
if command -v "$CLI" >/dev/null 2>&1; then
  URL=$("$CLI" service status 2>/dev/null | awk '/^https?:\/\//{print $1; exit}')
fi
if [ -z "$URL" ] && [ -f "$REG" ]; then
  # shellcheck disable=SC1003  # tr -d '\\' backslash is correct for tr (deletes single quotes from JSON)
  URL=$(json_get_field url < "$REG" 2>/dev/null | tr -d '\\')
  VERSION=$(json_get_field version < "$REG" 2>/dev/null)
fi
[ -n "$URL" ] || { printf '%s\n' "ERROR: no endpoint (CLI with no active service nor $REG)"; exit 1; }
case "$URL" in
 http://127.0.0.1:*|http://localhost:*|https://*);; #: require port (`:`) so http://127.0.0.1.attacker.tld/ cannot match
  *) printf '%s\n' "ERROR: non-loopback/https endpoint: rejected"; exit 1 ;;
esac
printf 'endpoint=%s\n' "$URL"

# 2) auth: registration password, else config (never echoed).
# Quote convention: AUTH MUST stay unquoted in the curl invocations below
# (same rule as SKILL/scripts/os/_common.sh: wrapping it makes curl treat
# `-u opencode:<password>` as one token whose value starts with a space,
# yielding HTTP 401 against an auth-required serve).
AUTH=""
PW=""
# The password is read with the SHARED json getter (json_get_field in
# os/_common.sh). The old inline awk required the exact bytes `"password":"`,
# so a pretty-printed service.json (`"password": "..."`, a space after the
# colon) yielded an EMPTY password -> the whole run went unauthenticated and
# failed later with an opaque 401.
read_password() {  # FILE -> prints the password value, empty when absent
  [ -f "$1" ] || return 0
  _pw=$(json_get_field password < "$1" 2>/dev/null) || _pw=""
  case "$_pw" in
    ''|null) _pw="" ;;
  esac
  printf '%s' "$_pw"
}
PW=$(read_password "$REG")
[ -z "$PW" ] && PW=$(read_password "$HOME/.config/opencode/service.json")
[ -n "$PW" ] && AUTH="-u opencode:$PW"
[ -z "$PW" ] && printf 'note: no service password found in %s or ~/.config/opencode/service.json; /api/* queries will go unauthenticated\n' "$REG" >&2

# 3) /api/info (version/pid) + openapi guard (an HTML body is not a schema)
# Plain fields are read with the SHARED getter (json_get_field in
# os/_common.sh), so there is ONE offset convention in the package. Two
# extractions keep their own pattern on purpose: the project id is a NESTED
# path ("project":{"id":...}), which the getter reaches with two calls
# (project -> id), and the agent catalog is a per-record scan after splitting
# the array. The endpoint's `https?:` scheme is NOT lost: it is a VALIDATION,
# not a read, and it lives in the `case` guard below. DRY with judgment, not
# dogma.
INFO=$(curl -s -m 10 ${AUTH:-} "$URL/api/info" | tr -d ' \n')
[ -n "$VERSION" ] || VERSION=$(printf '%s' "$INFO" | json_get_field version)
PID=$(printf '%s' "$INFO" | json_get_field pid)
printf 'version=%s\nserver_pid=%s\n' "$VERSION" "${PID:-unknown}"
SCHEMA=$(curl -s -m 10 ${AUTH:-} "$URL/openapi.json" | tr -d ' \n' | json_get_field openapi)
case "$SCHEMA" in
  3.*) printf 'openapi=%s\n' "$SCHEMA" ;;
  *) printf '%s\n' "ERROR: /openapi.json is not a valid schema (HTML or empty)"; exit 1 ;;
esac

# 4) canonical location + projectID for DIR (deepObject query)
LOC=$(curl -s -m 10 -G ${AUTH:-} "$URL/api/location" --data-urlencode "location[directory]=$DIR" | tr -d ' \n')
CANON=$(printf '%s' "$LOC" | json_get_field canonical)
# The project id is a NESTED path ("project":{"id":...}): two calls of the same
# getter, instead of a nested regex carrying its own offsets.
_proj_obj=$(printf '%s' "$LOC" | json_get_field project)
PROJ=$(printf '%s' "$_proj_obj" | json_get_field id)
printf 'canonical_directory=%s\nprojectID=%s\n' "$CANON" "${PROJ:-none}"

# 5) agent catalog split by mode (records are split at boundaries; first id per record)
AG=$(curl -s -m 10 ${AUTH:-} "$URL/api/agent" | tr -d ' \n')
# The catalog is a PER-RECORD scan (the array is split first), so the
# whole-document getter does not apply; the offset is DERIVED from the key
# instead of hardcoded, so a typo cannot shift an id by one character.
_ag_field() {  # MODE -> the comma-separated ids of that mode
  printf '%s' "$AG" | sed 's/},{"id":"/\n{"id":"/g' | \
    awk -v mode="$1" '
    function field(s, key,   k, p, v, q, j) {
      k = "\"" key "\""
      p = index(s, k); if (!p) return ""
      p += length(k)
      while (p <= length(s) && substr(s, p, 1) ~ /[ \t]/) p++
      if (substr(s, p, 1) != ":") return ""
      p++
      while (p <= length(s) && substr(s, p, 1) ~ /[ \t]/) p++
      v = substr(s, p)
      if (substr(v, 1, 1) == "\"") { q = substr(v, 2); j = index(q, "\""); return (j > 0 ? substr(q, 1, j - 1) : q) }
      return ""
    }
    index($0, "\"mode\":\"" mode "\"") { i = field($0, "id"); if (i != "") print i }' | paste -sd, -
}
P=$(_ag_field primary)
S=$(_ag_field subagent)
printf 'agents_primary=%s\nagents_subagent=%s\n' "${P:-none}" "${S:-none}"

# 6) default model pair (orchestrator profile; resolves exact ids, never hardcoded)
MD=$(curl -s -m 10 ${AUTH:-} "$URL/api/model/default" | tr -d ' \n')
MID=$(printf '%s' "$MD" | json_get_field modelID)
PROV=$(printf '%s' "$MD" | json_get_field providerID)
# Fail-closed: caching a bogus pair (none@none) poisoned every session created
# afterwards -- model.id "none" is non-empty, so send-prompt's empty-model
# guard does NOT catch it and the failure surfaces later as an opaque 0-token
# outcome=failed. require_state makes this key mandatory downstream anyway.
if [ -z "$MID" ] || [ -z "$PROV" ]; then
  printf '%s\n' "ERROR: /api/model/default returned no modelID/providerID pair; refusing to cache a bogus model_default" >&2
  exit 1
fi
printf 'model_default=%s@%s\n' "$MID" "$PROV"

# 7) root session hint
if [ -n "${OPENCODE_SESSION_ID:-}" ]; then
  printf 'root_session_hint=%s (env)\n' "$OPENCODE_SESSION_ID"
  if [ -n "${ORCHESTRATE_CACHE_DIR:-}" ]; then
    # Caches the orchestrator root: init-run REUSES it instead of trying to
    # create another one, which collided with the live orchestrator session
    # (fail-closed on collision and the run aborted having done nothing).
 # Through the shared writer: atomic + symlink-refusing.
    cache_put_raw root_session_hint "$OPENCODE_SESSION_ID" || {
      printf 'ERROR: could not write the cache key root_session_hint\n' >&2; exit 1; }
  fi
else
  printf '%s\n' "root_session_hint=none (orchestrator is external; create a root session or record TUI session)"
fi

# 7b) TUI/tabs gate (recipe-tui-tabs.md §3/§6). The gate becomes DATA, not an
# orchestrator judgment: init-run decides on its own and its reason stays in the output.
TUI_DETECT="$SELF_DIR/os/tui-detect.sh"
if [ -f "$TUI_DETECT" ]; then
  # The pin belongs to the detector (branch major) and only to it: passing a
  # version with minor/patch here made it fail with exit 2, and the
  # 2>/dev/null turned that error into an empty gate. One single pin owner (DRY).
  TUI_OUT=$(sh "$TUI_DETECT" "$CANON" 2>/dev/null)
  if [ -z "$TUI_OUT" ]; then
    printf '%s\n' 'gate=blocked' 'gate_reason=tui-detect.sh returned no output; run sh os/tui-detect.sh to see the error'
  else
    printf '%s\n' "$TUI_OUT" | grep -E '^(tui_pids|tui_cwd|tui_cwd_match|tui_channel|tabs_json|tui_version|version_ok|gate|gate_reason)='
  fi
else
  printf '%s\n' 'gate=blocked' 'gate_reason=tui-detect.sh missing from the package'
fi

# 8) optional cache for orchestrate.sh (secret only to a chmod 600 file; never to stdout)
if [ -n "${ORCHESTRATE_CACHE_DIR:-}" ]; then
  mkdir -p "$ORCHESTRATE_CACHE_DIR" 2>/dev/null || { printf '%s\n' "ERROR: cannot create cache dir" >&2; exit 1; }
  # ONE writer for every key (DRY): cache_put_raw is atomic (temp + mv) and
 # refuses to write through a symlink (CWE-59). These 14 keys used to
  # be plain `>` redirects: a truncated (non-atomic) write and no symlink
  # guard at all. A failed write is fatal: a half-populated cache would look
  # like a discovered instance to the next command.
  # RAW (verbatim): every value here is a scalar. The redacting writer
  # re-serializes any value that parses as JSON, which would rewrite a
  # version like "2.10" as "2.1".
  for _kv in \
    "endpoint|$URL" \
    "version|$VERSION" \
    "server_pid|${PID:-}" \
    "canonical_directory|$CANON" \
    "projectID|${PROJ:-}" \
    "model_default|${MID:-}@${PROV:-}" ; do
    _k=${_kv%%|*}; _v=${_kv#*|}
    cache_put_raw "$_k" "$_v" || { printf 'ERROR: could not write the cache key %s\n' "$_k" >&2; exit 1; }
  done
  case "$P" in
    ""|none) : ;;
    *) cache_put_raw default_agent "${P%%,*}" || { printf 'ERROR: could not write the cache key default_agent\n' >&2; exit 1; } ;;
  esac
  if [ -n "$PW" ]; then
    # The password is written VERBATIM (cache_put_raw): the redacting writer
    # re-serializes any value that parses as JSON, which would corrupt a
    # password such as "1.50" into "1.5".
    cache_put_raw auth_password "$PW" || { printf 'ERROR: could not write the cache key auth_password\n' >&2; exit 1; }
    chmod 600 "$ORCHESTRATE_CACHE_DIR/auth_password" 2>/dev/null \
      || { rm -f "$ORCHESTRATE_CACHE_DIR/auth_password"; printf 'ERROR: cannot chmod 600 auth_password (filesystem may not support POSIX perms); cache cleared for safety\n' >&2; exit 1; }
  fi
  # Caches the tabs gate: init-run reads it and decides without asking for --tui-cwd.
  if [ -f "$TUI_DETECT" ]; then
    # The cache holds VALUES, one format per key: preflight wrote the raw
    # "gate=ready" line while orchestrate.sh wrote the bare "ready", so the
    # same key had two on-disk shapes (the readers stripped the prefix, so
    # both happened to work). The prefix is stripped here, at the writer.
    for _pair in 'tabs_gate:gate' 'tabs_cwd:tui_cwd' 'tabs_channel:tui_channel' 'tabs_reason:gate_reason' 'tui_version:tui_version_norm'; do
      _ck=${_pair%%:*}; _sk=${_pair#*:}
      _val=$(printf '%s\n' "$TUI_OUT" | sed -n "s/^$_sk=//p" 2>/dev/null) || _val=""
      [ -n "$_val" ] || continue
      cache_put_raw "$_ck" "$_val" || { printf 'ERROR: could not write the cache key %s\n' "$_ck" >&2; exit 1; }
    done
  fi
fi
exit 0
