# _validators.awk — functions shared by validate_dag.sh and
# validate_ledger_closed.sh. SINGLE SOURCE (DRY, S1c-09): trim, strip_comment,
# parse_scalar, list_items and path normalization helpers (is_drive, is_unc,
# is_win, is_abs, normpath, posix_to_win, covers) live here in one place.
# This library is prepended to each validator's program by source concatenation
# (not with -f, which is not portable when mixed with an inline program in
# mawk 1.3.3).
#
# Contract: parse_scalar sets PVAL/PNULL and accepts allow_null; list_items
# validates each item with parse_scalar and sets LIST_ITEM[1..LIST_N].

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

function list_items(raw, arr,   s, inside, i, c, q, esc, cur, n, j, RAW_ITEM) {
  for (i in arr) delete arr[i]
  LIST_N = 0
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

# Path helpers (SINGLE SOURCE for validate_dag.sh and validate_ledger_closed.sh).
# Three absolute forms are recognised: POSIX (/a/b), Windows drive (C:\a or C:/a)
# and UNC (\\host\share\a). Backslashes are only converted for the Windows forms,
# so POSIX paths keep their behaviour. UNC roots preserve //host/share/ so ".."
# can never climb out of the share into //host.
function is_drive(p) {
  return length(p) >= 3 && substr(p, 1, 1) ~ /[A-Za-z]/ && substr(p, 2, 1) == ":" &&
         (substr(p, 3, 1) == "/" || substr(p, 3, 1) == "\\")
}
function is_unc(p) { return substr(p, 1, 2) == "\\\\" }
function is_win(p) { return is_drive(p) || is_unc(p) }
function is_abs(p) { return substr(p, 1, 1) == "/" || is_win(p) }
function normpath(p,   n, parts, i, seg, m, out, k, root, rest, abs, res, hs) {
  if (p == "") return ""
  root = ""; rest = p; abs = 0
  if (is_drive(p)) {
    root = toupper(substr(p, 1, 1)) ":/"; rest = substr(p, 3); gsub(/\\/, "/", rest); abs = 1
  } else if (is_unc(p)) {
    rest = p; gsub(/\\/, "/", rest)
    n = split(rest, parts, "/"); hs = 0; rest = ""; root = "//"
    for (i = 1; i <= n; i++) {
      if (parts[i] == "") continue
      if (hs < 2) { root = root parts[i] "/"; hs++ }
      else rest = rest "/" parts[i]
    }
    if (hs < 2) return p
    abs = 1
  } else if (substr(p, 1, 1) == "/") { root = "/"; abs = 1 }
  n = split(rest, parts, "/"); m = 0
  for (i = 1; i <= n; i++) {
    seg = parts[i]
    if (seg == "" || seg == ".") continue
    if (seg == "..") {
      if (m > 0 && out[m] != "..") m--
      else if (!abs) out[++m] = ".."
    } else out[++m] = seg
  }
  res = ""
  for (k = 1; k <= m; k++) res = res (k > 1 ? "/" : "") out[k]
  if (abs) return root res
  return (res == "") ? "." : res
}
# Git Bash / WSL / Cygwin POSIX view of a drive (/c/x, /mnt/c/x, /cygdrive/c/x)
# to the Windows form C:/x. Only used when the declared workspace is Windows-style.
function posix_to_win(p,   q) {
  q = p
  if (substr(q, 1, 5) == "/mnt/") q = substr(q, 5)
  else if (substr(q, 1, 10) == "/cygdrive/") q = substr(q, 10)
  if (length(q) >= 2 && substr(q, 1, 1) == "/" && substr(q, 2, 1) ~ /[A-Za-z]/ &&
      (length(q) == 2 || substr(q, 3, 1) == "/"))
    return normpath(toupper(substr(q, 2, 1)) ":" (length(q) == 2 ? "/" : substr(q, 3)))
  return p
}
function covers(parent, child,   lp) {
  if (parent == child) return 1
  lp = length(parent)
  if (substr(parent, lp, 1) == "/") return substr(child, 1, lp) == parent
  return substr(child, 1, lp) == parent && substr(child, lp + 1, 1) == "/"
}
