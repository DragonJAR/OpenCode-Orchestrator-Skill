# _validators.awk — functions shared by validate_dag.sh and
# validate_ledger_closed.sh. SINGLE SOURCE (DRY, S1c-09): trim, strip_comment,
# scalar and list_items used to live duplicated (validate_dag.sh had its own;
# validate_ledger_closed.sh had TWO copies that already diverged in the result
# variable: SCALAR vs VALUE). This library is prepended to each validator's
# program by source concatenation (not with -f, which is not portable when
# mixed with an inline program in mawk 1.3.3).
#
# Contract: parse_scalar sets PVAL/PNULL and accepts allow_null; split_items
# sets RAW_ITEM[1..n] WITHOUT validating; list_items validates each item with
# parse_scalar and sets LIST_ITEM[1..LIST_N].

function trim(s) {
  gsub(/^[ \t]+|[ \t]+$/, "", s)
  return s
}

function strip_comment(s,   i, c, q, esc, out) {
  q = 0; esc = 0; out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q) {
      out = out c
      if (esc) esc = 0
      else if (c == "\\") esc = 1
      else if (c == "\"") q = 0
    } else if (c == "\"") { q = 1; out = out c }
    else if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) break
    else out = out c
  }
  return out
}

function parse_scalar(raw, allow_null,   s, n, i, c, nx, out) {
  s = trim(raw); PVAL = ""; PNULL = 0
  if (allow_null && s == "null") { PNULL = 1; return 1 }
  n = length(s)
  if (n < 2 || substr(s, 1, 1) != "\"" || substr(s, n, 1) != "\"") return 0
  out = ""
  for (i = 2; i < n; i++) {
    c = substr(s, i, 1)
    if (c < " " || c == "\177") return 0   # control chars; avoids [[:cntrl:]] (mawk 1.3.3)
    if (c == "\\") {
      if (i + 1 >= n) return 0
      nx = substr(s, ++i, 1)
      if (nx != "\\" && nx != "\"") return 0
      out = out nx
    } else if (c == "\"") return 0
    else out = out c
  }
  PVAL = out
  return 1
}

function split_items(raw, arr,   s, inside, i, c, q, esc, cur, n) {
  for (i in arr) delete arr[i]
  q = 0; esc = 0; cur = ""; n = 0
  s = trim(raw); if (s == "[]") return 1
  if (length(s) < 2 || substr(s, 1, 1) != "[" || substr(s, length(s), 1) != "]") return 0
  inside = trim(substr(s, 2, length(s) - 2))
  if (inside == "") return 0
  for (i = 1; i <= length(inside); i++) {
    c = substr(inside, i, 1)
    if (q) {
      cur = cur c
      if (esc) esc = 0
      else if (c == "\\") esc = 1
      else if (c == "\"") q = 0
    } else if (c == "\"") { q = 1; cur = cur c }
    else if (c == ",") { arr[++n] = cur; cur = "" }
    else cur = cur c
  }
  if (q || esc) return 0
  arr[++n] = cur
  return 1
}

function list_items(raw, arr,   s, inside, i, c, q, esc, cur, n, j) {
  for (i in arr) delete arr[i]
  s = trim(raw)
  if (s == "[]") return 1
  if (length(s) < 2 || substr(s, 1, 1) != "[" || substr(s, length(s), 1) != "]") return 0
  inside = trim(substr(s, 2, length(s) - 2))
  if (inside == "") return 0
  q = 0; esc = 0; cur = ""; n = 0
  for (i = 1; i <= length(inside); i++) {
    c = substr(inside, i, 1)
    if (q) {
      cur = cur c
      if (esc) esc = 0
      else if (c == "\\") esc = 1
      else if (c == "\"") q = 0
    } else if (c == "\"") { q = 1; cur = cur c }
    else if (c == ",") { RAW_ITEM[++n] = cur; cur = "" }
    else cur = cur c
  }
  if (q || esc) return 0
  RAW_ITEM[++n] = cur
  for (j = 1; j <= n; j++) {
    if (!parse_scalar(RAW_ITEM[j], "") || PVAL == "") return 0
    arr[++LIST_N] = PVAL
  }
  return 1
}
