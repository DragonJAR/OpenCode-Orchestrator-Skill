#!/bin/sh
# watch_run.sh - bounded watcher for an OpenCode orchestration run.
# POSIX sh + awk + curl. No python, no heredocs. Consumes preflight output via
# env (OPENCODE_URL, optional OPENCODE_PW); performs no discovery itself.
# Usage: watch_run.sh -s SESSION_ID -a ARTIFACT[,ARTIFACT2...] [-d DEADLINE_SEC] [-i INTERVAL_SEC]
# Exit codes: 0 = artifacts present and session idle; 3 = deadline; 2 = usage/env.
# Prints one line per state transition: TS idle=<y/n> outcome=<x> artifacts=<n/m> [awaiting-approval]
# shellcheck source-path=scripts
set -u
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
command -v awk >/dev/null 2>&1 || { printf '%s\n' "ERROR: awk not available" >&2; exit 2; }
AUTH=""
[ -n "${OPENCODE_PW:-}" ] && AUTH="-u opencode:$OPENCODE_PW"
START=$(date +%s)
prev=""
printf '%s\n' "watch_run: session=$SESSION deadline=${DEADLINE}s interval=${INTERVAL}s artifacts=$ARTIFACTS"
while : ; do
  now=$(date +%s); [ $((now - START)) -ge "$DEADLINE" ] && { printf '%s\n' "watch_run: TIMEOUT"; exit 3; }
  resp=$(curl -s -m 10 "$AUTH" "$OPENCODE_URL/api/session/$SESSION" 2>/dev/null || printf '')
  idle=$(printf '%s' "$resp" | awk 'match($0,/"idle":[0-9]+/){print substr($0,RSTART+7,RLENGTH-7); exit}')
  outcome=$(printf '%s' "$resp" | awk -F'"outcome":"' 'NF>1{split($2,a,"\""); print a[1]; exit}')
  nart=0; oldIFS=$IFS; IFS=,
  for f in $ARTIFACTS; do [ -f "$f" ] && nart=$((nart + 1)); done
  IFS=$oldIFS
  total=$(printf '%s' "$ARTIFACTS" | awk -F, '{print NF}')
  warn=""
  if [ -n "$OPENCODE_PW" ]; then
    plist=$(curl -s -m 10 "$AUTH" "$OPENCODE_URL/api/session/$SESSION/permission" 2>/dev/null | tr -d ' \n' | awk 'match($0,/"data":\[[^]]*\]/){print substr($0,RSTART+8,RLENGTH-9); exit}')
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
