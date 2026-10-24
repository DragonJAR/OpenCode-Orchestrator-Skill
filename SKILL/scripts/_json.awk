# _json.awk — the ONE JSON field extractor (single source of truth).
#
# Consumed by os/_common.sh (json_get_field), orchestrate.sh and preflight.sh
# (per-record scans) and watch_run.sh (standalone watcher). The library is
# prepended to each consumer's program by source concatenation, exactly like
# _validators.awk is for the two validators: NOT with -f, which is not
# portable when mixed with an inline program in mawk 1.3.3.
#
# WHY ONE IMPLEMENTATION: the formula used to live in FOUR places, and the
# copies had already DIVERGED. The per-record copies stripped a number to its
# digits ("1.5" -> "15", "-5" -> "5") and one of them could not read a number
# at all (it returned the empty string), while the whole-document getter
# returned the number verbatim. A copy that answers a different question is
# a copy that will answer it wrong somewhere.
#
# The value is located BY ITS KEY and read to its natural end, so the length
# can never disagree with the pattern. The old inline
# `match(...)/substr(RSTART+n, RLENGTH-m)` extractions mixed two conventions:
# when the regex did NOT include the closing quote of a string value but the
# length still subtracted it, the value lost its last character (the message
# id printed as msg_01HXYZABCDEF instead of msg_01HXYZABCDEFG) and every
# numeric field lost a digit (time.updated 1792693166999 -> 79269316699,
# which then compared as "older" and could classify a busy session as idle).
#
# Contract: json_field(TEXT, KEY, PRE) sets
#   JSON_VALUE  the value (string unquoted, number verbatim, object/array raw)
#   JSON_FOUND  1 = a value was found, 0 = the key is absent or no
#               occurrence matched PRE.
# PRE (optional) restricts the match to values starting with it (e.g.
# "msg_"), so `id` never picks up a different id. When the first occurrence
# does not match, the next one is tried.

function json_field(rest, key, pre,   k, i, p, v, q, j, c, d, n, x, e) {
  JSON_VALUE = ""; JSON_FOUND = 0
  k = "\"" key "\""
  while ((i = index(rest, k)) > 0) {
    p = i + length(k)
    while (p <= length(rest) && substr(rest, p, 1) ~ /[ \t]/) p++
    if (substr(rest, p, 1) != ":") { rest = substr(rest, i + length(k)); continue }
    p++
    while (p <= length(rest) && substr(rest, p, 1) ~ /[ \t]/) p++
    v = substr(rest, p)
    rest = substr(rest, p)
    c = substr(v, 1, 1)
    if (c == "\"") {
      if (pre != "" && substr(v, 2, length(pre)) != pre) continue
      q = substr(v, 2); j = index(q, "\"")
      JSON_VALUE = (j > 0 ? substr(q, 1, j - 1) : q)
      JSON_FOUND = 1; return
    }
    if (c == "{" || c == "[") {
      d = 0
      for (n = 1; n <= length(v); n++) {
        x = substr(v, n, 1)
        if (x == c) d++
        else if (x == (c == "{" ? "}" : "]")) { d--; if (d == 0) { JSON_VALUE = substr(v, 1, n); JSON_FOUND = 1; return } }
      }
      JSON_VALUE = v
      JSON_FOUND = 1; return
    }
    if (pre != "" && substr(v, 1, length(pre)) != pre) continue
    e = 1
    while (e <= length(v) && substr(v, e, 1) !~ /[,}\]]/) e++
    JSON_VALUE = substr(v, 1, e - 1)
    sub(/[ \t\r]+$/, "", JSON_VALUE)
    JSON_FOUND = 1; return
  }
}

# json_route_label(METHOD, PATH) -> the skill's name for a session route, or
# "" when the route is not one of them. The table lives HERE so that the
# route set is one fact, not one per caller.
function json_route_label(meth, path) {
  if (meth == "POST"   && path == "/api/session") return "create"
  if (meth == "GET"    && path == "/api/session") return "children"
  if (meth == "POST"   && path == "/api/session/{sessionID}/prompt") return "send"
  if (meth == "GET"    && path == "/api/session/{sessionID}/message") return "read"
  if (meth == "GET"    && path == "/api/session/{sessionID}") return "state"
  if (meth == "DELETE" && path == "/api/session/{sessionID}") return "delete"
  return ""
}

# json_route_labels(RECORD) -> the labels a route record publishes, comma
# separated. RECORD is one route of the paths object ("/api/x":{"get":{...}).
function json_route_labels(rec,   path, rest, meth, key, lbl, out) {
  path = rec
  sub(/":\{.*$/, "", path)
  rest = rec
  while (match(rest, /"(get|post|delete|patch|put)":/)) {
    meth = toupper(substr(rest, RSTART + 1, RLENGTH - 3))
    lbl = json_route_label(meth, path)
    if (lbl != "") out = out (out == "" ? "" : ",") lbl
    rest = substr(rest, RSTART + RLENGTH)
  }
  return out
}

# json_subagent_perms(RECORD) -> "<verdict>|<child types>" for one agent
# record: the effective `subagent` permission, which is the precondition of
# the two-level minimum (R3d). "yes|no|unknown" and the allowed child agent
# ids ("any" when the rule is the wildcard).
function json_subagent_perms(rec,   rest, seg, res, list, deny_any, allow_any, verdict) {
  rest = rec
  while (match(rest, /"action":"subagent","resource":"[^"]*","effect":"(allow|deny)"/)) {
    seg = substr(rest, RSTART, RLENGTH)
    res = seg
    sub(/^"action":"subagent","resource":"/, "", res)
    sub(/","effect".*$/, "", res)
    if (seg ~ /"effect":"deny"/) { if (res == "*") deny_any = 1 }
    else if (res == "*") allow_any = 1
    else list = list (list == "" ? "" : ",") res
    rest = substr(rest, RSTART + RLENGTH)
  }
  verdict = "unknown"
  if (deny_any) verdict = "no"
  else if (list != "" || allow_any) verdict = "yes"
  if (allow_any && list == "") list = "any"
  return verdict "|" list
}
