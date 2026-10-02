#!/bin/sh
# Final gate for a closed two-level ledger. YAML structure, IDs, ownership,
# dependencies, cycles, scopes, timestamps and concurrency are delegated to validate_dag.sh.
# Dependencies: POSIX sh, awk and the POSIX dirname utility.
# Exit codes: 0 = pass, 1 = validation failure, 2 = usage / environment error.
# Run it from the workspace root: relative output_path / evidence_refs resolve from the
# physical working directory (pwd -P). Paths under run.location.directory are rebased onto
# run.location.directory_client (when present), like validate_dag.sh does; any absolute
# path that ends outside the workspace is rejected.
# Windows-form directory_client (C:\...) with a POSIX view of the same drive in the
# shell (Git Bash /c/..., WSL /mnt/c/..., Cygwin /cygdrive/c/...) is mapped back onto the
# physical view before the file tests. Only drive letters are mappable: for UNC or custom
# mounts declare run.location.directory_client as the POSIX path the shell sees.
# Encoding: UTF-8 without BOM is canonical (a leading BOM is tolerated). This script MUST
# be checked out with LF endings (see .gitattributes).
set -u
# Byte-exact length/substr/comparisons, independent of the caller's locale.
LC_ALL=C
export LC_ALL
command -v awk >/dev/null 2>&1 || { printf 'ERROR: awk no disponible\n' >&2; exit 2; }

usage() {
  printf 'Uso: %s <ruta-ledger> [--require-evidence] [--allow-degraded]\n' "$0" >&2
  exit 2
}

LEDGER=
REQUIRE_EVIDENCE=0
ALLOW_DEGRADED=0
for arg in "$@"; do
  case "$arg" in
    --require-evidence) REQUIRE_EVIDENCE=1 ;;
    --allow-degraded) ALLOW_DEGRADED=1 ;;
    -*) printf 'ERROR: flag desconocido: %s\n' "$arg" >&2; usage ;;
    *) [ -z "$LEDGER" ] || usage; LEDGER=$arg ;;
  esac
done
[ -n "$LEDGER" ] || usage
[ -f "$LEDGER" ] && [ -r "$LEDGER" ] || {
  printf 'ERROR: no puedo leer el ledger: %s\n' "$LEDGER" >&2
  exit 2
}

WS_PHYS=$(pwd -P 2>/dev/null) || {
  printf 'ERROR: no puedo determinar el directorio actual (pwd -P)\n' >&2
  exit 2
}
export WS_PHYS

SCRIPT_DIR=$(dirname "$0") || exit 2
DAG_VALIDATOR=$SCRIPT_DIR/validate_dag.sh
[ -f "$DAG_VALIDATOR" ] && [ -r "$DAG_VALIDATOR" ] || {
  printf 'ERROR: falta el validador DAG: %s\n' "$DAG_VALIDATOR" >&2
  exit 2
}

sh "$DAG_VALIDATOR" "$LEDGER"
DAG_RC=$?
[ "$DAG_RC" -ne 2 ] || exit 2

# The DAG validator rejects syntax outside the canonical YAML subset. This
# pass extracts close-gate fields and emits delimiter-safe records.
SEP=$(printf '\034')
RECORDS=$(awk -v sep="$SEP" '
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
# Report the first extraction problem with its line number (stderr; stdout carries records).
function badline(msg) {
  bad = 1
  if (!reported) { printf "[FAIL] línea %d: %s\n", FNR, msg | "cat 1>&2"; reported = 1 }
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
function is_drive(p) {
  return length(p) >= 3 && substr(p, 1, 1) ~ /[A-Za-z]/ && substr(p, 2, 1) == ":" &&
         (substr(p, 3, 1) == "/" || substr(p, 3, 1) == "\\")
}
function is_unc(p) { return substr(p, 1, 2) == "\\\\" }
function is_abs(p) { return substr(p, 1, 1) == "/" || is_drive(p) || is_unc(p) }
# Collapse ".", ".." and repeated separators; Windows forms use "/" and an upper-case drive.
function normp(p,   root, rest, n, parts, i, m, out, k, res, abs) {
  root = ""; rest = p; abs = 0
  if (is_drive(p)) { root = toupper(substr(p, 1, 1)) ":/"; rest = substr(p, 3); gsub(/\\/, "/", rest); abs = 1 }
  else if (is_unc(p)) { root = "//"; rest = substr(p, 3); gsub(/\\/, "/", rest); abs = 1 }
  else if (substr(p, 1, 1) == "/") { root = "/"; abs = 1 }
  n = split(rest, parts, "/"); m = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == "..") { if (m > 0 && out[m] != "..") m--; else if (!abs) out[++m] = ".." }
    else out[++m] = parts[i]
  }
  res = ""
  for (k = 1; k <= m; k++) res = res (k > 1 ? "/" : "") out[k]
  if (abs) return root res
  return (res == "") ? "." : res
}
function under(base, p,   lb) {
  if (base == p) return 1
  lb = length(base)
  if (substr(base, lb, 1) == "/") return substr(p, 1, lb) == base
  return substr(p, 1, lb) == base && substr(p, lb + 1, 1) == "/"
}
# Git Bash / WSL / Cygwin POSIX view of a drive (/c/x, /mnt/c/x, /cygdrive/c/x) to C:/x.
function posix_to_win(p,   q) {
  q = p
  if (substr(q, 1, 5) == "/mnt/") q = substr(q, 5)
  else if (substr(q, 1, 10) == "/cygdrive/") q = substr(q, 10)
  if (length(q) >= 2 && substr(q, 1, 1) == "/" && substr(q, 2, 1) ~ /[A-Za-z]/ &&
      (length(q) == 2 || substr(q, 3, 1) == "/"))
    return normp(toupper(substr(q, 2, 1)) ":" (length(q) == 2 ? "/" : substr(q, 3)))
  return p
}
function is_drive_norm(p) { return p ~ /^[A-Za-z]:\// }
# Rebase a path under run.location.directory onto run.location.directory_client, check
# workspace containment and return the path in the PHYSICAL view of the shell (pwd -P), so
# that [ -f ] works. A path that ends outside the workspace is prefixed with !OUTSIDE!
# (absolute paths outside it, or relative paths with "..").
function resolve_path(p,   q, srv, cli, rel, wsn, wsw, winmode) {
  if (p == "") return p
  q = normp(p)
  # Workspace form is resolved once for BOTH branches: winmode drives the
  # backslash->slash conversion of a relative path, which must match
  # validate_dag.sh canon_path (NS_WIN && !is_abs(p)). Reading winmode without
  # assigning it here left the relative branch below as dead code.
  srv = (SRVDIR != "") ? normp(SRVDIR) : ""
  cli = (CLIDIR != "") ? normp(CLIDIR) : srv
  winmode = (cli != "" && is_drive_norm(cli))
  if (is_abs(p)) {
    if (winmode && !is_drive_norm(q)) q = posix_to_win(q)
    if (srv != "" && cli != "" && under(srv, q)) {
      rel = (q == srv) ? "" : substr(q, length(srv) + (substr(srv, length(srv), 1) == "/" ? 1 : 2))
      q = (rel == "") ? cli : normp(cli "/" rel)
    }
    wsn = normp(ENVIRON["WS_PHYS"]); wsw = wsn
    if (winmode && !is_drive_norm(wsn)) wsw = posix_to_win(wsn)
    if (!under(wsw, q)) return "!OUTSIDE!" p
    rel = (q == wsw) ? "" : substr(q, length(wsw) + (substr(wsw, length(wsw), 1) == "/" ? 1 : 2))
    return (rel == "") ? wsn : normp(wsn "/" rel)
  }
  if (q == ".." || substr(q, 1, 3) == "../") return "!OUTSIDE!" p
  if (winmode) gsub(/\\/, "/", q)
  return q
}
function scalar(raw,   s, n, i, c, nx, out) {
  s = trim(raw); SCALAR = ""
  n = length(s)
  if (n < 2 || substr(s, 1, 1) != "\"" || substr(s, n, 1) != "\"") return 0
  out = ""
  for (i = 2; i < n; i++) {
    c = substr(s, i, 1)
    if (c < " " || c == "\177") return 0   # control chars; same rule as validate_dag.sh parse_scalar
    if (c == "\\") {
      if (i + 1 >= n) return 0
      nx = substr(s, ++i, 1)
      if (nx != "\\" && nx != "\"") return 0
      out = out nx
    } else if (c == "\"") return 0
    else out = out c
  }
  SCALAR = out
  return 1
}
function list_items(raw,   s, inside, i, c, q, esc, cur, n) {
  s = trim(raw); LIST_N = 0
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
  for (i = 1; i <= n; i++) {
    if (!scalar(RAW_ITEM[i]) || SCALAR == "") return 0
    LIST_ITEM[++LIST_N] = SCALAR
  }
  return 1
}
{
  if (FNR == 1 && substr($0, 1, 3) == "\357\273\277") $0 = substr($0, 4)   # strip UTF-8 BOM
  cr_line = $0; sub(/\r$/, "", cr_line)
  line = strip_comment(cr_line)
  if (line ~ /^run:/) { sect = "run"; in_loc = 0 }
  else if (line ~ /^tasks:/) { sect = "tasks"; in_loc = 0 }
  else if (sect == "run") {
    if (line ~ /^  [A-Za-z_]+:/) in_loc = (line ~ /^  location:[ \t]*$/)
    else if (in_loc && line ~ /^    (directory|directory_client):/) {
      loc_key = line; sub(/^    /, "", loc_key); sub(/:.*/, "", loc_key)
      loc_raw = line; sub(/^    [A-Za-z_]+:[ \t]*/, "", loc_raw)
      if (scalar(loc_raw)) { if (loc_key == "directory") SRVDIR = SCALAR; else CLIDIR = SCALAR }
    }
  }
  if (line ~ /^  - task_id:/) {
    raw = line; sub(/^  - task_id:[ \t]*/, "", raw)
    if (!scalar(raw)) { badline("task_id inválido (usa string entre comillas dobles)"); next }
    task_n++; current = task_n
    task_id[current] = SCALAR
    task_state[current] = task_outcome[current] = task_runtime[current] = ""
    task_kind[current] = task_parent[current] = task_criterion[current] = task_output[current] = ""
    task_notas[current] = ""
    task_runtime_null[current] = 0; task_output_null[current] = 0
    task_evidence_n[current] = 0; task_open = 1
    next
  }
  if (task_open && line ~ /^    [A-Za-z_][A-Za-z0-9_]*:/) {
    key = line; sub(/^    /, "", key); sub(/:.*/, "", key)
    raw = line; sub(/^    [A-Za-z_][A-Za-z0-9_]*:[ \t]*/, "", raw)
    raw = trim(raw)   # "null  " and "null # c" (comment already stripped) must equal "null"
    if (key == "evidence_refs") {
      if (!list_items(raw)) { badline("lista flow-style inválida en evidence_refs"); next }
      task_evidence_n[current] = LIST_N
      for (i = 1; i <= LIST_N; i++) task_evidence[current, i] = LIST_ITEM[i]
    } else if (key == "parent_task_id") {
      if (raw == "null") task_parent_null[current] = 1
      else if (!scalar(raw)) { badline("scalar inválido en parent_task_id"); next }
      else { task_parent[current] = SCALAR; task_parent_null[current] = 0 }
    } else if (key == "task_kind" || key == "estado" || key == "execution_outcome" ||
               key == "sessionID" || key == "runtime_status" || key == "criterion" ||
               key == "output_path" || key == "notas") {
      val_is_null = 0
      if (raw == "null" && (key == "sessionID" || key == "runtime_status" || key == "output_path")) {
        val = ""; val_is_null = 1
      } else if (!scalar(raw)) { badline("scalar inválido en " key); next }
      else val = SCALAR
      if (key == "task_kind") task_kind[current] = val
      else if (key == "estado") task_state[current] = val
      else if (key == "execution_outcome") task_outcome[current] = val
      else if (key == "sessionID") task_session_null[current] = val_is_null
      else if (key == "runtime_status") { task_runtime[current] = val; task_runtime_null[current] = val_is_null }
      else if (key == "criterion") task_criterion[current] = val
      else if (key == "output_path") { task_output[current] = val; task_output_null[current] = val_is_null }
      else if (key == "notas") task_notas[current] = val
    }
  }
}
END {
  for (i = 1; i <= task_n; i++) {
    integrated = ""
    if (task_kind[i] == "worker_session" && task_state[i] == "verified") {
      for (j = 1; j <= task_n; j++)
        if (task_kind[j] == "subagent" && !task_parent_null[j] &&
            task_parent[j] == task_id[i] && task_state[j] == "verified" &&
            !task_session_null[j])
          integrated = integrated (integrated == "" ? "" : ",") task_id[j]
    }
    clean_notas = task_notas[i]
    gsub(/\034/, " ", clean_notas)
    print "TASK" sep task_id[i] sep task_kind[i] sep task_state[i] sep task_outcome[i] sep task_runtime[i] sep task_runtime_null[i] sep task_criterion[i] sep resolve_path(task_output[i]) sep task_output_null[i] sep task_evidence_n[i] sep integrated sep clean_notas
    for (k = 1; k <= task_evidence_n[i]; k++)
      print "EVIDENCE" sep task_id[i] sep task_criterion[i] sep resolve_path(task_evidence[i, k]) sep task_kind[i] sep integrated
  }
  if (bad) exit 1
}
' "$LEDGER")
EXTRACT_RC=$?
if [ "$EXTRACT_RC" -ne 0 ]; then
  printf '[FAIL] no se pudieron extraer campos del ledger canónico\n' >&2
  exit 1
fi

FAILS=0
PASSED=0
TASKS=0
PATH_FAILURES=0
if [ "$DAG_RC" -ne 0 ]; then
  FAILS=$((FAILS + 1))
  printf '[FAIL] el gate DAG rechazó el ledger (exit %s)\n' "$DAG_RC"
fi

# Close-gate requirements for a task whose estado is "verified". These checks are
# identical in strict mode and in --allow-degraded mode (only the strict branch
# adds the "no está en estado local verified" precondition before calling).
# Operates on the record fields already unpacked by the read loop below.
check_verified() {
  if [ "$outcome" != "succeeded" ]; then
    printf '[FAIL] %s requiere execution_outcome succeeded (actual: %s)\n' "$task_id" "$outcome"
    task_bad=1
  fi
  if [ "$runtime_is_null" = "1" ] || [ -z "$runtime" ]; then
    printf '[FAIL] %s no registra runtime_status observado\n' "$task_id"
    task_bad=1
  fi
  if [ -z "$criterion" ]; then
    printf '[FAIL] %s no registra criterion\n' "$task_id"
    task_bad=1
  fi
  if [ -z "$evidence_count" ] || [ "$evidence_count" -eq 0 ]; then
    printf '[FAIL] %s verified sin evidence_refs\n' "$task_id"
    task_bad=1
  fi
  if [ "$output_is_null" = "1" ] || [ -z "$path" ]; then
    printf '[FAIL] %s no registra output_path\n' "$task_id"
    task_bad=1
  fi
  if [ "$task_bad" -eq 0 ]; then
    printf '[OK] %s tiene resultado terminal verificado y criterion\n' "$task_id"
    PASSED=$((PASSED + 1))
  fi
}

# field10 (integrated children) and field11 (notas) are delimiter-safe.
# shellcheck disable=SC2034
while IFS="$SEP" read -r kind task_id field1 field2 field3 field4 field5 field6 field7 field8 field9 field10 field11; do
  [ -n "$kind" ] || continue
  if [ "$kind" = "TASK" ]; then
    estado=$field2
    outcome=$field3
    runtime=$field4
    runtime_is_null=$field5
    criterion=$field6
    path=$field7
    output_is_null=$field8
    evidence_count=$field9
    integrated=$field10
    notas=$field11
    TASKS=$((TASKS + 1))
    task_bad=0
    if [ "$ALLOW_DEGRADED" -eq 1 ]; then
      case "$estado" in
        verified)
          check_verified
          ;;
        failed|blocked|partial|cancelled|interrupted)
          if [ -z "$notas" ]; then
            printf '[FAIL] %s en estado %s requiere notas no vacías con el motivo/causa\n' "$task_id" "$estado"
            task_bad=1
          fi
          if [ -z "$criterion" ]; then
            printf '[FAIL] %s no registra criterion\n' "$task_id"
            task_bad=1
          fi
          if [ "$task_bad" -eq 0 ]; then
            printf '[OK] %s tiene resultado terminal degradado (%s) con motivo en notas\n' "$task_id" "$estado"
            PASSED=$((PASSED + 1))
          fi
          ;;
        pending|launching|running|awaiting-approval|outcome-unknown)
          printf '[FAIL] %s en estado activo no permitido al cerrar (estado: %s)\n' "$task_id" "$estado"
          task_bad=1
          ;;
        *)
          printf '[FAIL] %s en estado no terminal para cierre degradado (estado: %s)\n' "$task_id" "$estado"
          task_bad=1
          ;;
      esac
    else
      if [ "$estado" != "verified" ]; then
        printf '[FAIL] %s no está en estado local verified (estado: %s)\n' "$task_id" "$estado"
        task_bad=1
      fi
      check_verified
    fi
    FAILS=$((FAILS + task_bad))
    if [ "$REQUIRE_EVIDENCE" -eq 1 ] && [ "$output_is_null" != "1" ] && [ -n "$path" ]; then
      case "$path" in
        '!OUTSIDE!'*)
          printf '[FAIL] %s output_path sale de la raíz del workspace: %s\n' "$task_id" "${path#'!OUTSIDE!'}"
          FAILS=$((FAILS + 1)); PATH_FAILURES=$((PATH_FAILURES + 1)); continue ;;
        /*|[A-Za-z]:[/\\]*) resolved=$path ;;
        *) resolved=$WS_PHYS/$path ;;
      esac
      if [ "$estado" = "verified" ] && [ ! -f "$resolved" ]; then
        printf '[FAIL] %s output_path inexistente: %s (--require-evidence)\n' "$task_id" "$path"
        FAILS=$((FAILS + 1)); PATH_FAILURES=$((PATH_FAILURES + 1))
      fi
    fi
  elif [ "$kind" = "EVIDENCE" ]; then
    evidence_criterion=$field1
    evidence_path=$field2
    evidence_task_kind=$field3
    expected_children=$field4
    evidence_bad=0
    case "$evidence_path" in
      '!OUTSIDE!'*)
        printf '[FAIL] %s evidence_refs sale de la raíz del workspace: %s\n' "$task_id" "${evidence_path#'!OUTSIDE!'}"
        FAILS=$((FAILS + 1)); PATH_FAILURES=$((PATH_FAILURES + 1)); continue ;;
      /*|[A-Za-z]:[/\\]*) resolved=$evidence_path ;;
      *) resolved=$WS_PHYS/$evidence_path ;;
    esac
    if [ ! -f "$resolved" ]; then
      if [ "$REQUIRE_EVIDENCE" -eq 1 ]; then
        printf '[FAIL] %s evidence_refs inexistente: %s (--require-evidence)\n' "$task_id" "$evidence_path"
      else
        printf '[FAIL] %s evidence_refs inexistente o ilegible: %s\n' "$task_id" "$evidence_path"
      fi
      FAILS=$((FAILS + 1)); PATH_FAILURES=$((PATH_FAILURES + 1)); evidence_bad=1
    elif ! CRITERION="$evidence_criterion" EXPECTED_CHILDREN="$expected_children" awk '
      function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
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
      function scalar(raw,   s, n, i, c, nx, out) {
        s = trim(raw); VALUE = ""; n = length(s)
        if (n < 2 || substr(s, 1, 1) != "\"" || substr(s, n, 1) != "\"") return 0
        out = ""
        for (i = 2; i < n; i++) {
          c = substr(s, i, 1)
          if (c < " " || c == "\177") return 0   # control chars; same rule as validate_dag.sh parse_scalar
          if (c == "\\") {
            if (i + 1 >= n) return 0
            nx = substr(s, ++i, 1)
            if (nx != "\\" && nx != "\"") return 0
            out = out nx
          } else if (c == "\"") return 0
          else out = out c
        }
        VALUE = out; return 1
      }
      function list_items(raw,   s, inside, i, c, q, esc, cur, n, j) {
        s = trim(raw); LIST_N = 0
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
          if (!scalar(RAW_ITEM[j]) || VALUE == "") return 0
          LIST_ITEM[++LIST_N] = VALUE
        }
        return 1
      }
      {
        if (FNR == 1 && substr($0, 1, 3) == "\357\273\277") $0 = substr($0, 4)   # strip UTF-8 BOM
        line = $0; sub(/\r$/, "", line); line = strip_comment(line)
        if (index(line, "\t")) { bad = 1; next }
        # A tab is already rejected above, so only spaces can lead a comment line.
        if (trim(line) == "" || line ~ /^ *#/) next
        if (line !~ /^[A-Za-z_][A-Za-z0-9_]*:[ \t]*/) { bad = 1; next }
        key = line; sub(/:.*/, "", key)
        raw = line; sub(/^[A-Za-z_][A-Za-z0-9_]*:[ \t]*/, "", raw)
        if (key != "criterion" && key != "result" && key != "observed" && key != "subagent_results_integrated") { bad = 1; next }
        if (seen[key]++) { bad = 1; next }
        if (key == "subagent_results_integrated") {
          if (!list_items(raw)) { bad = 1; next }
          integration_n = LIST_N
          for (i = 1; i <= LIST_N; i++) {
            if (integration_seen[LIST_ITEM[i]]++) bad = 1
            integration[LIST_ITEM[i]] = 1
          }
        } else {
          if (!scalar(raw)) { bad = 1; next }
          value[key] = VALUE
        }
      }
      END {
        if (!seen["criterion"] || !seen["result"] || !seen["observed"]) bad = 1
        if (value["criterion"] != ENVIRON["CRITERION"]) bad = 1
        if (value["result"] != "pass") bad = 1
        if (trim(value["observed"]) == "") bad = 1
        expected_count = split(ENVIRON["EXPECTED_CHILDREN"], expected_item, ",")
        if (ENVIRON["EXPECTED_CHILDREN"] != "") {
          for (i = 1; i <= expected_count; i++) expected[expected_item[i]] = 1
          if (!seen["subagent_results_integrated"] || integration_n != expected_count) bad = 1
          for (i = 1; i <= expected_count; i++) if (!(expected_item[i] in integration)) bad = 1
          for (i in integration) if (!(i in expected)) bad = 1
        }
        if (bad) exit 1
        exit 0
      }
    ' "$resolved"; then
      if [ "$evidence_task_kind" = "worker_session" ] && [ -n "$expected_children" ]; then
        printf '[FAIL] %s evidencia no confirma criterion/result/observed ni integra todos los hijos verificados: %s\n' "$task_id" "$evidence_path"
      else
        printf '[FAIL] %s evidencia no demuestra criterion/result/observed: %s\n' "$task_id" "$evidence_path"
      fi
      FAILS=$((FAILS + 1)); evidence_bad=1
    fi
    if [ "$evidence_bad" -eq 0 ]; then
      printf '[OK] %s evidence_refs confirma criterion: %s\n' "$task_id" "$evidence_path"
      PASSED=$((PASSED + 1))
    fi
  fi
done <<EOF
$RECORDS
EOF

if [ "$TASKS" -eq 0 ]; then
  printf '[FAIL] ledger sin tareas que cerrar\n'
  FAILS=$((FAILS + 1))
fi
if [ "$REQUIRE_EVIDENCE" -eq 1 ] && [ "$PATH_FAILURES" -eq 0 ] && [ "$FAILS" -eq 0 ]; then
  if [ "$ALLOW_DEGRADED" -eq 1 ]; then
    printf '[OK] todas las rutas output_path y evidence_refs requeridas existen como archivos\n'
  else
    printf '[OK] todas las rutas output_path y evidence_refs existen como archivos\n'
  fi
  PASSED=$((PASSED + 1))
fi
printf 'TOTAL: %d passed, %d failed\n' "$PASSED" "$FAILS"
[ "$FAILS" -eq 0 ]
