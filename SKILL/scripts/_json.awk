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
