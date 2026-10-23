#!/bin/sh
# watch_run.sh - bounded watcher for an OpenCode orchestration run.
# POSIX sh + awk + curl. No python, no heredocs. Consumes preflight output via
# env (OPENCODE_URL, optional OPENCODE_PW); performs no discovery itself.
# Usage: watch_run.sh -s SESSION_ID -a ARTIFACT[,ARTIFACT2...] [-d DEADLINE_SEC] [-i INTERVAL_SEC]
# Exit codes: 0 = artifacts present and session idle; 3 = deadline; 2 = usage/env.
# Prints one line per state transition: TS idle=<y/n> outcome=<x> artifacts=<n/m> [awaiting-approval]
# shellcheck source-path=scripts
set -u
# Deterministic collation for the awk field extraction below (ASCII JSON keys).
LC_ALL=C
export LC_ALL
# A watcher killed by the orchestrator (SIGTERM) or the operator (Ctrl-C)
# otherwise dies silently with no final state line: the log ends without
# DONE/TIMEOUT and the caller cannot distinguish "killed" from "still running".
trap 'printf "%s\n" "watch_run: INTERRUPTED"; exit 143' TERM INT
SESSION=""; ARTIFACTS=""; DEADLINE=1200; INTERVAL=15
while getopts ":s:a:d:i:" opt; do
  case "$opt" in
    s) SESSION="$OPTARG" ;;
    a) ARTIFACTS="$OPTARG" ;;
    d) DEADLINE="$OPTARG" ;;
    i) INTERVAL="$OPTARG" ;;
    *) printf '%s\n' "usage: $0 -s SESSION_ID -a ARTIFACT[,ARTIFACT2...] [-d sec] [-i sec]" >&2; exit 2 ;;
  esac
done
[ -n "$SESSION" ] && [ -n "$ARTIFACTS" ] && [ -n "${OPENCODE_URL:-}" ] || {
  printf '%s\n' "ERROR: -s and -a required; OPENCODE_URL must come from preflight" >&2; exit 2; }
# D1: -d/-i are compared with `[ ... -ge ... ]` and passed to `sleep`. A
# non-integer ("120s") made the comparison error out and the loop keep going,
# so the deadline was never enforced. Same guard as orchestrate.sh's
# assert_uint (this script is standalone and cannot source it).
for _n in "$DEADLINE" "$INTERVAL"; do
  case "$_n" in ''|*[!0-9]*)
    printf 'watch_run: -d/-i must be a positive integer of seconds, got: %s\n' "$_n" >&2; exit 2 ;;
  esac
  [ "$_n" -ge 1 ] 2>/dev/null || { printf 'watch_run: -d/-i must be >= 1, got: %s\n' "$_n" >&2; exit 2; }
done
command -v awk >/dev/null 2>&1 || { printf '%s\n' "ERROR: awk not available" >&2; exit 2; }
# S1 (class): one existence probe BEFORE the loop. The poll below retries
# every API error until TIMEOUT, so a typo'd/never-existing session id used
# to block silently for the whole deadline. Same probe as sub_wait_idle's
# (GET /api/session/<id>, answer must carry a ses_ id); exit 2 is this
# script's documented usage/environment code (see SKILL.md watch row), NOT a
# new code.
_wprobe=$(opencode api GET "/api/session/$SESSION" 2>/dev/null || printf '')
case "$_wprobe" in *'"id":"ses_'*) : ;;
  *) printf '%s\n' "watch_run: session-not-found session=$SESSION (fail-closed; not polling to the deadline)" >&2; exit 2 ;;
esac
START=$(date +%s)
prev=""
# ONE derived-offset extractor, the SHARED one (scripts/_json.awk, the same
# library json_get_field uses): the value starts at the key prefix and is
# read to its natural end. The offsets are DERIVED, never hardcoded: a typo
# can no longer shift a field by one digit or one character -- the class that
# truncated a millisecond timestamp and a message id in wait-idle.
# The formula used to be repeated here (a FOURTH copy, next to the ones in
# os/_common.sh, orchestrate.sh and preflight.sh); the copies had already
# diverged, and this one stripped a number to its digits. It is now the same
# library the rest of the skill uses, read from THIS directory (this script
# is always invoked as "$SELF_DIR/watch_run.sh" and ships beside it).
# It still sources no shell library: it stays POSIX sh + awk + curl, with no
# python, and it fails closed if the library is missing.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
_JSON_LIB=""
if [ -f "$SCRIPT_DIR/_json.awk" ]; then
  _JSON_LIB=$(cat "$SCRIPT_DIR/_json.awk")
else
  printf '%s\n' "watch_run: ERROR: shared awk library missing: $SCRIPT_DIR/_json.awk" >&2
  exit 2
fi
_wfield() {  # KEY JSON -> the value (string, number or raw array)
  printf '%s' "$2" | awk -v key="$1" "$_JSON_LIB"'
    { json_field($0, key, ""); print JSON_VALUE }'
}
printf '%s\n' "watch_run: session=$SESSION deadline=${DEADLINE}s interval=${INTERVAL}s artifacts=$ARTIFACTS"
while : ; do
  now=$(date +%s); [ $((now - START)) -ge "$DEADLINE" ] && { printf '%s\n' "watch_run: TIMEOUT"; exit 3; }
  resp=$(opencode api GET "/api/session/$SESSION" 2>/dev/null || printf '')
  idle=$(_wfield idle "$resp")
  outcome=$(printf '%s' "$resp" | awk -F'"outcome":"' 'NF>1{split($2,a,"\""); print a[1]; exit}')
  nart=0; oldIFS=$IFS; IFS=,
  for f in $ARTIFACTS; do [ -f "$f" ] && nart=$((nart + 1)); done
  IFS=$oldIFS
  total=$(printf '%s' "$ARTIFACTS" | awk -F, '{print NF}')
  warn=""
  # ${OPENCODE_PW:-}: sub_watch only exports it when the cache holds a password;
  # the bare $OPENCODE_PW here aborted the whole watcher with "unbound variable"
  # under set -u on no-auth instances (line 24 already used the :- form).
  if [ -n "${OPENCODE_PW:-}" ]; then
    _perm=$(opencode api GET "/api/session/$SESSION/permission" 2>/dev/null | tr -d ' \n')
    plist=$(_wfield data "$_perm")
    [ -n "$plist" ] && warn="awaiting-approval"
  fi
  cur="idle=${idle:-no} outcome=${outcome:-none} artifacts=$nart/$total $warn"
  if [ "$cur" != "$prev" ]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cur"
    prev=$cur
  fi
  [ "$nart" -eq "$total" ] && [ -n "$idle" ] && { printf '%s\n' "watch_run: DONE"; exit 0; }
  sleep "$INTERVAL"
done
