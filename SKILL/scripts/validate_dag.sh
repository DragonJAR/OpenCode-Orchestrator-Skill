#!/bin/sh
# Validate the canonical OpenCode two-level orchestration ledger and task DAG.
# Dependencies: POSIX sh and POSIX awk. No YAML library is used.
# Accepted YAML subset: canonical root map, exact indentation, quoted strings,
# null, positive integers, flow lists, blank lines and full-line/inline comments
# (an inline comment is a "#" preceded by whitespace, outside double quotes).
# Encoding: UTF-8 without BOM is canonical; a leading BOM is tolerated and stripped.
# Line endings: LF or CRLF for the ledger. This script itself MUST be checked out
# with LF endings (see .gitattributes); a CRLF-converted copy fails under sh.
# Exit codes: 0 = pass, 1 = validation failure, 2 = usage / environment error.
# Paths: run.location.directory is the SERVER literal path (POSIX, drive-letter
# or UNC). The workspace visible to this validator (physical `pwd -P`) is
# compared with run.location.directory_client when present, otherwise with
# run.location.directory.
set -u
# Byte-exact length/substr/comparisons, independent of the caller's locale.
LC_ALL=C
export LC_ALL
command -v awk >/dev/null 2>&1 || { printf 'ERROR: awk no disponible\n' >&2; exit 2; }

if [ "$#" -ne 1 ]; then
  printf 'Uso: %s <ruta-ledger>\n' "$0" >&2
  exit 2
fi
LEDGER=$1
# Physical working directory (resolves symlinks); never rely on a logical $PWD.
WS_PHYS=$(pwd -P 2>/dev/null) || {
  printf 'ERROR: no puedo determinar el directorio actual (pwd -P)\n' >&2
  exit 2
}
case "$WS_PHYS" in
  /*) ;;
  [A-Za-z]:[/\\]*) ;;
  \\\\*) ;;
  *) printf 'ERROR: el directorio actual debe ser una ruta absoluta para validar scopes\n' >&2; exit 2 ;;
esac
if [ ! -f "$LEDGER" ] || [ ! -r "$LEDGER" ]; then
  printf 'ERROR: no puedo leer el ledger: %s\n' "$LEDGER" >&2
  exit 2
fi

# awk -v interprets backslash escapes: double every backslash so that Windows
# or UNC paths reach awk literally.
WS_ESC=
_rest=$WS_PHYS
# shellcheck disable=SC1003
while :; do
  case $_rest in
    *\\*) WS_ESC=$WS_ESC${_rest%%\\*}'\\'; _rest=${_rest#*\\} ;;
    *) WS_ESC=$WS_ESC$_rest; break ;;
  esac
done

awk -v pwd="$WS_ESC" '
function trim(s) {
  gsub(/^[ \t]+|[ \t]+$/, "", s)
  return s
}
function fail(msg) {
  printf "[FAIL] %s\n", msg
  failures++
}
function ok(msg) {
  printf "[OK] %s\n", msg
  passed++
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
    } else if (c == "\"") {
      q = 1; out = out c
    } else if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) break
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
    if (c < " " || c == "\177") return 0   # control chars; avoids [[:cntrl:]] (unsupported by mawk 1.3.3)
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
function split_items(s, arr,   i, c, q, esc, cur, m) {
  for (i in arr) delete arr[i]
  q = 0; esc = 0; cur = ""; m = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q) {
      cur = cur c
      if (esc) esc = 0
      else if (c == "\\") esc = 1
      else if (c == "\"") q = 0
    } else if (c == "\"") { q = 1; cur = cur c }
    else if (c == ",") { arr[++m] = cur; cur = "" }
    else cur = cur c
  }
  if (q || esc) return -1
  arr[++m] = cur
  return m
}
function parse_list(raw,   s, inside, n, i) {
  LIST_COUNT = 0
  for (i in LIST_VALUE) delete LIST_VALUE[i]
  s = trim(raw)
  if (s == "[]") return 1
  if (length(s) < 2 || substr(s, 1, 1) != "[" || substr(s, length(s), 1) != "]") return 0
  inside = trim(substr(s, 2, length(s) - 2))
  if (inside == "") return 0
  n = split_items(inside, RAW_ITEM)
  if (n < 0) return 0
  for (i = 1; i <= n; i++) {
    if (!parse_scalar(RAW_ITEM[i], 0) || PVAL == "") return 0
    LIST_VALUE[++LIST_COUNT] = PVAL
  }
  return 1
}
function split_key(s,   n) {
  if (!match(s, /^[A-Za-z_][A-Za-z0-9_]*:/)) return 0
  n = RLENGTH
  KEY = substr(s, 1, n - 1)
  RAW = trim(substr(s, n + 1))
  return 1
}
function set_run(subsec, key, raw,   full, allow_null) {
  full = subsec "." key
  if ((subsec == "server" && key != "mode" && key != "endpoint_redacted" && key != "observed_id" && key != "version") ||
      (subsec == "location" && key != "directory" && key != "directory_client" && key != "projectID" && key != "subpath") ||
      (subsec == "root_session" && key != "sessionID" && key != "parentID") ||
      (subsec == "client" && key != "tabs_scope" && key != "active_tab_hint")) {
    fail("clave desconocida en run." subsec ": " key)
    return
  }
  if (seen_run[full]++) { fail("clave duplicada: run." full); return }
  allow_null = (full == "location.projectID" || full == "location.subpath" ||
                full == "location.directory_client" ||
                full == "root_session.parentID" || full == "client.tabs_scope" ||
                full == "client.active_tab_hint")
  if (!parse_scalar(raw, allow_null)) { fail("scalar inválido: run." full SCALAR_HINT); return }
  run_value[full] = PVAL
  run_null[full] = PNULL
}
# Task ownership is separate from DAG ordering: only parent_task_id expresses
# worker/subagent ownership; dependencias always express execution order.
function set_task(i, key, raw,   allow_null, j) {
  if (key != "task_id" && key != "task_kind" && key != "parent_task_id" &&
      key != "location_directory" && key != "sessionID" && key != "parentID" && key != "agent_id" &&
      key != "dependencias" && key != "scope_escritura" && key != "criterion" &&
      key != "output_path" && key != "evidence_refs" && key != "estado" &&
      key != "runtime_status" && key != "execution_outcome" &&
      key != "source_sessionID" && key != "before_messageID" &&
      key != "created_at" && key != "last_state_at" && key != "notas") {
    fail("clave de tarea desconocida: " key)
    return
  }
  if (seen_task[i, key]++) { fail("clave de tarea duplicada en posición " i ": " key); return }
  if (key == "dependencias" || key == "scope_escritura" || key == "evidence_refs") {
    if (!parse_list(raw)) { fail("lista flow-style inválida en tarea " i ": " key); return }
    task_count[i, key] = LIST_COUNT
    for (j = 1; j <= LIST_COUNT; j++) task_list[i, key, j] = LIST_VALUE[j]
    return
  }
  allow_null = (key == "parent_task_id" || key == "sessionID" || key == "parentID" || key == "runtime_status" ||
                key == "source_sessionID" || key == "before_messageID" ||
                key == "output_path")
  if (!parse_scalar(raw, allow_null)) { fail("scalar inválido en tarea " i ": " key SCALAR_HINT); return }
  task_value[i, key] = PVAL
  task_null[i, key] = PNULL
}
# Path helpers. Three absolute forms are recognised: POSIX (/a/b), Windows
# drive (C:\a or C:/a) and UNC (\\host\share\a). Backslashes are only converted
# for the Windows forms, so POSIX paths keep their previous behaviour.
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
# SRV  = server literal run.location.directory (normalised).
# BASE = workspace as seen by the validator (run.location.directory_client, or
#        run.location.directory when absent). Relative scopes resolve against
#        BASE; absolute scopes under SRV are rewritten onto BASE.
function canon_path(p,   n, rel) {
  if (p == "") return ""
  if (NS_WIN && !is_abs(p)) gsub(/\\/, "/", p)
  if (is_abs(p)) {
    n = normpath(p)
    if (NS_WIN && !is_win(n)) n = posix_to_win(n)
    if (SRV != "" && SRV != BASE && covers(SRV, n)) {
      rel = (n == SRV) ? "" : substr(n, length(SRV) + (substr(SRV, length(SRV), 1) == "/" ? 1 : 2))
      return (rel == "") ? BASE : normpath(BASE "/" rel)
    }
    return n
  }
  n = normpath(p)
  if (n == ".." || substr(n, 1, 3) == "../") return "!OUTSIDE_WORKSPACE!"
  if (n == ".") return BASE
  return normpath(BASE "/" n)
}
# Memoised canon_path for scope entries. SRV, BASE and NS_WIN are resolved in the
# END block before the task loops run, so the canonical form of a given scope is
# constant for the whole validation and can be computed once per (task, scope).
function scanon(i, k) {
  if (!((i, k) in canon_scope)) canon_scope[i, k] = canon_path(scope[i, k])
  return canon_scope[i, k]
}
function touches(a, b,   la, lb) {
  if (a == b) return 1
  la = length(a); lb = length(b)
  if (la < lb && substr(b, 1, la) == a &&
      (substr(a, la, 1) == "/" || substr(b, la + 1, 1) == "/")) return 1
  if (lb < la && substr(a, 1, lb) == b &&
      (substr(b, lb, 1) == "/" || substr(a, lb + 1, 1) == "/")) return 1
  return 0
}
function covers(parent, child,   lp) {
  if (parent == child) return 1
  lp = length(parent)
  if (substr(parent, lp, 1) == "/") return substr(child, 1, lp) == parent
  return substr(child, 1, lp) == parent && substr(child, lp + 1, 1) == "/"
}
function norm_time(ts,   y, mo, day, hh, mi, ss, yn, mn, dn, hn, min, sn, mdays, leap) {
  if (length(ts) != 20 || substr(ts, 5, 1) != "-" || substr(ts, 8, 1) != "-" ||
      substr(ts, 11, 1) != "T" || substr(ts, 14, 1) != ":" ||
      substr(ts, 17, 1) != ":" || substr(ts, 20, 1) != "Z") return ""
  y = substr(ts, 1, 4); mo = substr(ts, 6, 2); day = substr(ts, 9, 2)
  hh = substr(ts, 12, 2); mi = substr(ts, 15, 2); ss = substr(ts, 18, 2)
  if (y !~ /^[0-9][0-9][0-9][0-9]$/ || mo !~ /^[0-9][0-9]$/ ||
      day !~ /^[0-9][0-9]$/ || hh !~ /^[0-9][0-9]$/ ||
      mi !~ /^[0-9][0-9]$/ || ss !~ /^[0-9][0-9]$/) return ""
  yn = y + 0; mn = mo + 0; dn = day + 0
  hn = hh + 0; min = mi + 0; sn = ss + 0
  if (yn < 1 || mn < 1 || mn > 12 || hn > 23 || min > 59 || sn > 59) return ""
  mdays = 31
  if (mn == 4 || mn == 6 || mn == 9 || mn == 11) mdays = 30
  if (mn == 2) {
    leap = (yn % 4 == 0 && (yn % 100 != 0 || yn % 400 == 0))
    mdays = leap ? 29 : 28
  }
  if (dn < 1 || dn > mdays) return ""
  return y mo day "T" hh mi ss
}
function req_run(key, nonempty) {
  if (!(key in seen_run)) { fail("falta run." key); return }
  if (nonempty && (run_null[key] || run_value[key] == "")) fail("run." key " no puede estar vacío/null")
}
function active_state(s) {
  return s == "launching" || s == "outcome-unknown" || s == "running" || s == "awaiting-approval"
}
BEGIN {
  SCALAR_HINT = " (usa comillas dobles; en rutas Windows o UNC duplica cada barra invertida: \"C:\\\\ruta\"; solo se admiten los escapes \\\\ y \\\")"
  ws = normpath(pwd)
  if (!is_abs(ws)) fail("el directorio actual (pwd -P) no es una ruta absoluta")
}
{
  if (FNR == 1 && substr($0, 1, 3) == "\357\273\277") $0 = substr($0, 4)   # strip UTF-8 BOM
  original = $0
  sub(/\r$/, "", original)
  if (index(original, "\t")) { fail("tabs no permitidos, línea " FNR); next }
  line = strip_comment(original)
  if (trim(line) == "") next
  indent = 0
  while (substr(line, indent + 1, 1) == " ") indent++
  content = substr(line, indent + 1)
  sub(/[ \t]+$/, "", content)   # right-trim so trailing spaces after "tasks:" / "run:" do not cascade

  if (indent == 0) {
    if (content == "run:") {
      if (seen_root["run"]++) fail("bloque run duplicado")
      root_section = "run"; run_sub = ""; next
    }
    if (content == "tasks:") {
      if (seen_root["tasks"]++) fail("bloque tasks duplicado")
      root_section = "tasks"; tasks_empty = 0; run_sub = ""; next
    }
    if (content == "tasks: []") {
      if (seen_root["tasks"]++) fail("bloque tasks duplicado")
      root_section = "tasks"; tasks_empty = 1; run_sub = ""; next
    }
    if (!split_key(content)) { fail("estructura raíz inválida, línea " FNR); next }
    if (KEY != "schema_version") { fail("clave raíz desconocida: " KEY); next }
    if (seen_root["schema_version"]++) { fail("schema_version duplicado"); next }
    if (RAW != "3") {
      if (RAW == "2") fail("schema_version 2 obsoleto; migra el ledger al schema_version 3 de dos niveles")
      else fail("schema_version debe ser el entero 3; migra el ledger al modelo de dos niveles")
    }
    next
  }

  if (indent == 2 && root_section == "run") {
    if (content == "server:" || content == "location:" ||
        content == "root_session:" || content == "client:") {
      subname = substr(content, 1, length(content) - 1)
      if (seen_sub[subname]++) fail("bloque run." subname " duplicado")
      run_sub = subname
      next
    }
    if (!split_key(content)) {
      fail("clave o indentación inválida dentro de run, línea " FNR); next
    }
    if (KEY == "max_in_flight") {
      fail("run.max_in_flight fue eliminado en schema 3; usa max_sessions_in_flight solo si observaste un límite real")
      next
    }
    if (KEY != "min_subagents_per_worker" && KEY != "max_sessions_in_flight") {
      fail("clave desconocida en run: " KEY); next
    }
    if (seen_run[KEY]++) { fail("clave run duplicada: " KEY); next }
    if (RAW !~ /^[1-9][0-9]*$/ || RAW + 0 > 2147483647) {
      fail("run." KEY " debe ser entero positivo entre 1 y 2147483647")
      if (KEY == "min_subagents_per_worker") min_bad = 1
    } else run_value[KEY] = RAW + 0
    next
  }

  if (indent == 4 && root_section == "run") {
    if (run_sub == "" || !split_key(content)) { fail("campo fuera de un bloque run, línea " FNR); next }
    set_run(run_sub, KEY, RAW)
    next
  }

  if (indent == 2 && root_section == "tasks") {
    if (tasks_empty) { fail("tasks: [] no admite elementos, línea " FNR); next }
    if (substr(content, 1, 2) != "- ") { fail("cada tarea debe ser elemento de lista bajo tasks, línea " FNR); next }
    if (!split_key(substr(content, 3)) || KEY != "task_id") {
      fail("cada tarea debe comenzar con task_id, línea " FNR); next
    }
    task_n++; current_task = task_n
    set_task(current_task, KEY, RAW)
    next
  }

  if (indent == 4 && root_section == "tasks" && current_task > 0) {
    if (!split_key(content)) { fail("campo de tarea inválido, línea " FNR); next }
    set_task(current_task, KEY, RAW)
    next
  }

  fail("indentación o ubicación fuera del subconjunto YAML en línea " FNR)
}
END {
  if (!("schema_version" in seen_root)) fail("falta schema_version")
  if (!("run" in seen_root)) fail("falta bloque run")
  if (!("tasks" in seen_root)) fail("falta bloque tasks")
  req_run("server.mode", 1)
  req_run("server.endpoint_redacted", 1)
  req_run("server.observed_id", 1)
  req_run("server.version", 1)
  req_run("location.directory", 1)
  req_run("location.projectID", 0)
  req_run("location.subpath", 0)
  req_run("root_session.sessionID", 1)
  req_run("root_session.parentID", 0)
  if (!("min_subagents_per_worker" in seen_run)) fail("falta run.min_subagents_per_worker")
  else if (!min_bad && run_value["min_subagents_per_worker"] != 2)
    fail("run.min_subagents_per_worker debe ser exactamente 2")
  optional_run = "location.directory_client location.projectID location.subpath root_session.parentID client.tabs_scope client.active_tab_hint"
  optional_count = split(optional_run, optional_key, " ")
  for (r = 1; r <= optional_count; r++)
    if (optional_key[r] in seen_run && !run_null[optional_key[r]] && run_value[optional_key[r]] == "")
      fail("run." optional_key[r] " no puede ser string vacío; usa null si no está disponible")
  loc_dir = run_value["location.directory"]
  root_sid = (("root_session.sessionID" in seen_run) && !run_null["root_session.sessionID"]) ? run_value["root_session.sessionID"] : ""
  has_client = (("location.directory_client" in seen_run) && !run_null["location.directory_client"] &&
                run_value["location.directory_client"] != "")
  client_dir = has_client ? run_value["location.directory_client"] : loc_dir
  if (!is_abs(loc_dir))
    fail("run.location.directory debe ser una ruta absoluta confirmada (POSIX, unidad Windows o UNC)")
  else if (!is_abs(client_dir))
    fail("run.location.directory_client debe ser una ruta absoluta (POSIX, unidad Windows o UNC)")
  else {
    SRV = normpath(loc_dir)
    BASE = normpath(client_dir)
    NS_WIN = is_win(BASE)
    wsn = (NS_WIN && !is_win(ws)) ? posix_to_win(ws) : ws
    if (BASE != wsn) {
      if (has_client)
        fail("run.location.directory_client no coincide con el directorio actual físico (pwd -P); ejecuta el validador desde ese workspace")
      else
        fail("run.location.directory no coincide con el directorio actual físico (pwd -P); ejecuta el validador desde la raíz del workspace o declara run.location.directory_client con la ruta visible para el validador (p. ej. cuando el servidor usa una ruta Windows/UNC)")
    }
  }
  if (run_value["server.mode"] != "shared-default" &&
      run_value["server.mode"] != "explicit-server" &&
      run_value["server.mode"] != "standalone") fail("run.server.mode inválido")
  if (run_value["server.endpoint_redacted"] ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\/]*@/)
    fail("run.server.endpoint_redacted contiene userinfo; elimina credenciales")

  required = "task_id task_kind parent_task_id location_directory sessionID parentID agent_id dependencias scope_escritura criterion output_path evidence_refs estado runtime_status execution_outcome source_sessionID before_messageID created_at last_state_at notas"
  count = split(required, req, " ")
  for (i = 1; i <= task_n; i++) {
    for (r = 1; r <= count; r++)
      if (!((i, req[r]) in seen_task)) fail("tarea " i " sin campo requerido " req[r])
  }
  if (task_n == 0 && !tasks_empty) fail("tasks debe ser [] o contener elementos de lista")

  if (failures > 0) {
    printf "TOTAL: %d passed, %d failed\n", passed, failures
    exit 1
  }

  if (task_n == 0) {
    ok("forma canónica y metadata de run válidas; tasks vacío")
    ok("sin tareas que validar")
    printf "TOTAL: %d passed, %d failed\n", passed, failures
    exit 0
  }

  for (i = 1; i <= task_n; i++) {
    id = task_value[i, "task_id"]
    if (id !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) {
      fail("task_id vacío o fuera de gramática en tarea " i ": " id)
    } else if (id in id_index) fail("task_id duplicado: " id)
    else id_index[id] = i

    state = task_value[i, "estado"]
    if (state != "pending" && state != "launching" && state != "outcome-unknown" &&
        state != "running" && state != "awaiting-approval" && state != "completed" &&
        state != "verified" && state != "blocked" && state != "failed" &&
        state != "interrupted" && state != "cancelled" && state != "partial")
      fail(id " tiene estado local inválido: " state)
    kind = task_value[i, "task_kind"]
    if (kind != "worker_session" && kind != "subagent")
      fail(id " tiene task_kind inválido: " kind)
    if (task_null[i, "location_directory"] || task_value[i, "location_directory"] != run_value["location.directory"])
      fail(id " location_directory debe ser idéntico a run.location.directory")
    outcome = task_value[i, "execution_outcome"]
    if (outcome != "unknown" && outcome != "succeeded" && outcome != "failed" &&
        outcome != "interrupted" && outcome != "cancelled")
      fail(id " tiene execution_outcome local inválido: " outcome)
    if (active_state(state) && outcome != "unknown")
      fail(id " en estado en vuelo debe tener execution_outcome unknown")
    if (state == "verified" && outcome != "succeeded")
      fail(id " verified requiere execution_outcome succeeded")
    if (state == "verified" && task_null[i, "output_path"])
      fail(id " verified requiere output_path no nulo")
    if (state == "completed" && outcome != "succeeded")
      fail(id " completed requiere execution_outcome terminal succeeded")

    if (!task_null[i, "parent_task_id"] && task_value[i, "parent_task_id"] == "")
      fail(id " tiene parent_task_id vacío; usa null para un worker_session raíz")
    if (!task_null[i, "parentID"] && task_value[i, "parentID"] == "")
      fail(id " tiene parentID vacío; usa null solo para un worker_session raíz")
    for (r = 1; r <= 4; r++) {
      if (r == 1) optional_task = "sessionID"
      else if (r == 2) optional_task = "runtime_status"
      else if (r == 3) optional_task = "source_sessionID"
      else optional_task = "before_messageID"
      if (!task_null[i, optional_task] && task_value[i, optional_task] == "")
        fail(id " tiene " optional_task " vacío; usa null o un valor confirmado")
    }
    if (task_null[i, "agent_id"] || task_value[i, "agent_id"] == "")
      fail(id " requiere agent_id")
    if (task_value[i, "criterion"] == "") fail(id " requiere criterion no vacío")
    if (task_null[i, "output_path"] == 0 && task_value[i, "output_path"] == "")
      fail(id " output_path vacío; usa null si no hay artefacto")
    if (task_null[i, "source_sessionID"] != task_null[i, "before_messageID"])
      fail(id " requiere source_sessionID y before_messageID juntos para un fork")
    else if (task_null[i, "source_sessionID"] == 0 &&
        (task_value[i, "source_sessionID"] == "" || task_value[i, "before_messageID"] == ""))
      fail(id " no permite IDs de fork vacíos")

    active = active_state(state)
    if (active) active_total++
    if ((state == "running" || state == "completed" || state == "verified") &&
        (task_null[i, "sessionID"] || task_value[i, "sessionID"] == ""))
      fail(id " en estado " state " requiere sessionID confirmado")
    if ((state == "running" || state == "completed" || state == "verified") &&
        (task_null[i, "runtime_status"] || task_value[i, "runtime_status"] == ""))
      fail(id " en estado " state " requiere runtime_status observado")
    if (task_null[i, "sessionID"] == 0 && task_value[i, "sessionID"] != "") {
      sid = task_value[i, "sessionID"]
      if (sid == root_sid) fail(id " reutiliza el sessionID de run.root_session (sesión raíz del orquestador): " sid)
      else if (sid in session_index) fail(id " repite sessionID de " session_index[sid])
      else session_index[sid] = id
    }
    if (active && state != "launching" && state != "outcome-unknown" &&
        task_null[i, "sessionID"])
      fail(id " en ejecución activa requiere sessionID; si el envío no se confirmó usa outcome-unknown")

    cr = norm_time(task_value[i, "created_at"])
    ls = norm_time(task_value[i, "last_state_at"])
    if (cr == "" || ls == "") fail(id " tiene timestamp inválido; requiere UTC YYYY-MM-DDTHH:MM:SSZ")
    else if (ls < cr) fail(id " tiene last_state_at anterior a created_at")

    for (k = 1; k <= task_count[i, "dependencias"]; k++) {
      d = task_list[i, "dependencias", k]
      if (d !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/)
        fail(id " tiene dependencia con ID inválido: " d)
      if (dep_seen[i, d]++) fail(id " repite dependencia " d)
      deps[i]++
      dependency[i, deps[i]] = d
    }
    for (k = 1; k <= task_count[i, "scope_escritura"]; k++) {
      p = task_list[i, "scope_escritura", k]
      if (p == "") fail(id " contiene scope vacío")
      else {
        scopes[i]++; scope[i, scopes[i]] = p
        if (scanon(i, k) == "!OUTSIDE_WORKSPACE!")
          fail(id " scope_escritura sale de la raíz del workspace: " p)
      }
    }
    for (k = 1; k <= task_count[i, "evidence_refs"]; k++) {
      if (evidence_seen[i, task_list[i, "evidence_refs", k]]++)
        fail(id " repite evidence_ref " task_list[i, "evidence_refs", k])
      if (canon_path(task_list[i, "evidence_refs", k]) == "!OUTSIDE_WORKSPACE!")
        fail(id " evidence_ref sale de la raíz del workspace: " task_list[i, "evidence_refs", k])
    }

    outp = task_value[i, "output_path"]
    if (!task_null[i, "output_path"] && outp != "") {
      if (scopes[i] == 0) fail(id " define output_path pero no scope_escritura")
      outcanon = canon_path(outp)
      if (outcanon == "!OUTSIDE_WORKSPACE!") fail(id " output_path sale de la raíz del workspace")
      covered = 0
      for (k = 1; k <= scopes[i]; k++)
        if (covers(scanon(i, k), outcanon)) covered = 1
      if (!covered) fail(id " output_path queda fuera de scope_escritura")
    }
  }

  for (i = 1; i <= task_n; i++) {
    id = task_value[i, "task_id"]
    kind = task_value[i, "task_kind"]
    parent_id = task_value[i, "parent_task_id"]
    runtime_parent = task_value[i, "parentID"]
    if (kind == "worker_session") {
      if (!task_null[i, "parent_task_id"])
        fail(id " worker_session debe tener parent_task_id: null")
      if (!task_null[i, "parentID"])
        fail(id " worker_session raíz debe tener parentID: null")
    } else if (kind == "subagent") {
      if (task_null[i, "parent_task_id"] || parent_id == "")
        fail(id " subagent requiere parent_task_id de un worker_session")
      else if (!(parent_id in id_index))
        fail(id " parent_task_id inexistente: " parent_id)
      else {
        parent_i = id_index[parent_id]
        if (task_value[parent_i, "task_kind"] != "worker_session")
          fail(id " parent_task_id debe referir a task_kind worker_session: " parent_id)
        if (task_null[parent_i, "sessionID"] || task_value[parent_i, "sessionID"] == "")
          fail(id " parent worker_session " parent_id " no tiene sessionID runtime confirmado")
        if (task_null[i, "parentID"] || runtime_parent == "" ||
            runtime_parent != task_value[parent_i, "sessionID"])
          fail(id " parentID debe coincidir con el sessionID runtime del worker " parent_id)
        parent_child[i] = parent_i
        for (p = 1; p <= scopes[i]; p++) {
          child_scope = scanon(i, p)
          covered = 0
          for (q = 1; q <= scopes[parent_i]; q++)
            if (covers(scanon(parent_i, q), child_scope)) covered = 1
          if (!covered)
            fail(id " scope_escritura queda fuera del presupuesto del worker " parent_id ": " scope[i, p])
        }
      }
    }
  }

  for (i = 1; i <= task_n; i++) {
    id = task_value[i, "task_id"]
    if (task_value[i, "task_kind"] == "worker_session" && task_value[i, "estado"] == "verified") {
      verified_children = 0
      for (j = 1; j <= task_n; j++) {
        if (task_value[j, "task_kind"] == "subagent" &&
            !task_null[j, "parent_task_id"] && task_value[j, "parent_task_id"] == id &&
            task_value[j, "estado"] == "verified" &&
            !task_null[j, "sessionID"] && task_value[j, "sessionID"] != "") {
          sid = task_value[j, "sessionID"]
          child_session_key = id SUBSEP sid
          if (!(child_session_key in verified_child_sessions)) {
            verified_child_sessions[child_session_key] = 1
            verified_children++
          }
        }
      }
      if (verified_children < run_value["min_subagents_per_worker"])
        fail(id " verified requiere al menos " run_value["min_subagents_per_worker"] " hijos subagent verified con sessionID distintos")
    }
  }

  for (i = 1; i <= task_n; i++) {
    id = task_value[i, "task_id"]
    for (k = 1; k <= deps[i]; k++) {
      d = dependency[i, k]
      if (!(d in id_index)) fail(id " depende de task_id inexistente: " d)
      else {
        j = id_index[d]
        indeg[i]++
        successor[j] = successor[j] " " i
        if (active_state(task_value[i, "estado"]) &&
            task_value[j, "estado"] != "verified")
          fail(id " no puede estar en vuelo hasta verificar dependencia " d)
      }
    }
  }

  tail = 0
  for (i = 1; i <= task_n; i++) if (indeg[i] == 0) queue[++tail] = i
  head = 1; done = 0
  while (head <= tail) {
    u = queue[head++]; done++
    m = split(successor[u], next_nodes)
    for (k = 1; k <= m; k++) if (--indeg[next_nodes[k]] == 0) queue[++tail] = next_nodes[k]
  }
  if (done < task_n) fail("ciclo detectado en dependencias")
  else ok("dependencias existentes y DAG acíclico")

  for (i = 1; i <= task_n; i++) for (k = 1; k <= deps[i]; k++)
    if (dependency[i, k] in id_index) adjacency[i, id_index[dependency[i, k]]] = 1
  for (k = 1; k <= task_n; k++) for (i = 1; i <= task_n; i++)
    if (adjacency[i, k]) for (j = 1; j <= task_n; j++) if (adjacency[k, j]) adjacency[i, j] = 1

  scope_bad = 0
  for (i = 1; i <= task_n; i++) for (j = i + 1; j <= task_n; j++) {
    if (adjacency[i, j] || adjacency[j, i] || parent_child[i] == j || parent_child[j] == i) continue
    # Ordered trees: a subagent inherits the DAG ordering edges of its worker, so
    # tasks in different worker trees are not parallel when either tree is ordered
    # (directly or transitively) before the other. Siblings in one tree still need
    # their own direct edge.
    ti = parent_child[i] ? parent_child[i] : i
    tj = parent_child[j] ? parent_child[j] : j
    if (ti != tj && (adjacency[ti, tj] || adjacency[tj, ti] ||
        adjacency[ti, j] || adjacency[j, ti] || adjacency[i, tj] || adjacency[tj, i])) continue
    found = 0
    for (p = 1; p <= scopes[i]; p++) for (q = 1; q <= scopes[j]; q++)
      if (touches(scanon(i, p), scanon(j, q))) found = 1
    if (found) {
      fail(task_value[i, "task_id"] " y " task_value[j, "task_id"] " sin dependencia comparten scope")
      scope_bad = 1
    }
  }
  if (!scope_bad) ok("scopes no se solapan entre tareas sin dependencia")

  if ("max_sessions_in_flight" in seen_run) {
    if (active_total > run_value["max_sessions_in_flight"])
      fail("max_sessions_in_flight excedido contando workers y subagents: " active_total " activas, límite " run_value["max_sessions_in_flight"])
    else ok(sprintf("%d sesiones activas (workers y subagents) de un máximo local de %d", active_total, run_value["max_sessions_in_flight"]))
  } else ok(sprintf("%d sesiones activas; no se configuró límite local", active_total))

  if (failures == 0) ok("esquema canónico, IDs, estados y fechas válidos")
  printf "TOTAL: %d passed, %d failed\n", passed, failures
  exit (failures > 0 ? 1 : 0)
}
' < "$LEDGER"
