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
# Shared awk helpers (single source of truth, S1c-09): trim, strip_comment,
# parse_scalar and split_items live in _validators.awk and are prepended to
# the awk program below. Never re-define them here.
# shellcheck disable=SC1007  # CDPATH= cd ... | pwd -- the space after = is part of the command substitution syntax (false positive: shellcheck treats = as plain assignment).
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
_VAL_LIB=""
[ -f "$SCRIPT_DIR/_validators.awk" ] && _VAL_LIB=$(cat "$SCRIPT_DIR/_validators.awk")
command -v awk >/dev/null 2>&1 || { printf 'ERROR: awk not available\n' >&2; exit 2; }

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s <ledger-path>\n' "$0" >&2
  exit 2
fi
LEDGER=$1
# Physical working directory (resolves symlinks); never rely on a logical $PWD.
WS_PHYS=$(pwd -P 2>/dev/null) || {
  printf 'ERROR: cannot determine the current directory (pwd -P)\n' >&2
  exit 2
}
case "$WS_PHYS" in
  /*) ;;
  [A-Za-z]:[/\\]*) ;;
  \\\\*) ;;
  *) printf 'ERROR: the current directory must be an absolute path to validate scopes\n' >&2; exit 2 ;;
esac
if [ ! -f "$LEDGER" ] || [ ! -r "$LEDGER" ]; then
  printf 'ERROR: cannot read the ledger: %s\n' "$LEDGER" >&2
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

awk -v pwd="$WS_ESC" "$_VAL_LIB
"'
function fail(msg) {
  printf "[FAIL] %s\n", msg
  failures++
}
function ok(msg) {
  printf "[OK] %s\n", msg
  passed++
}
function parse_list(raw,   i) {
  # Delegates to the shared list_items (single source of truth, S1c-09).
  # Same contract this function always had: strips the brackets, validates
  # every quoted item with parse_scalar, rejects empty items, fills
  # LIST_VALUE/LIST_COUNT. Direct use of split_items was removed because the
  # shared split_items takes the FULL bracketed list while this parser used
  # to pass the bracket-stripped inside: a contract mismatch that silently
  # dropped every scope_escritura and dependencias list.
  LIST_COUNT = 0
  for (i in LIST_VALUE) delete LIST_VALUE[i]
  if (!list_items(raw, LIST_VALUE)) return 0
  LIST_COUNT = LIST_N
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
    fail("unknown key in run." subsec ": " key)
    return
  }
  if (seen_run[full]++) { fail("duplicate key: run." full); return }
  allow_null = (full == "location.projectID" || full == "location.subpath" ||
                full == "location.directory_client" ||
                full == "root_session.parentID" || full == "client.tabs_scope" ||
                full == "client.active_tab_hint")
  if (!parse_scalar(raw, allow_null)) { fail("invalid scalar: run." full SCALAR_HINT); return }
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
    fail("unknown task key: " key)
    return
  }
  if (seen_task[i, key]++) { fail("duplicate task key at position " i ": " key); return }
  if (key == "dependencias" || key == "scope_escritura" || key == "evidence_refs") {
    if (!parse_list(raw)) { fail("invalid flow-style list in task " i ": " key); return }
    task_count[i, key] = LIST_COUNT
    for (j = 1; j <= LIST_COUNT; j++) task_list[i, key, j] = LIST_VALUE[j]
    return
  }
  allow_null = (key == "parent_task_id" || key == "sessionID" || key == "parentID" || key == "runtime_status" ||
                key == "source_sessionID" || key == "before_messageID" ||
                key == "output_path")
  if (!parse_scalar(raw, allow_null)) { fail("invalid scalar in task " i ": " key SCALAR_HINT); return }
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
  if (!(key in seen_run)) { fail("missing run." key); return }
  if (nonempty && (run_null[key] || run_value[key] == "")) fail("run." key " cannot be empty/null")
}
function active_state(s) {
  return s == "launching" || s == "outcome-unknown" || s == "running" || s == "awaiting-approval"
}
BEGIN {
  SCALAR_HINT = " (use double quotes; in Windows or UNC paths double every backslash: \"C:\\\\path\"; only the \\\\ and \\\" escapes are allowed)"
  ws = normpath(pwd)
  if (!is_abs(ws)) fail("the current directory (pwd -P) is not an absolute path")
}
{
  if (FNR == 1 && substr($0, 1, 3) == "\357\273\277") $0 = substr($0, 4)   # strip UTF-8 BOM
  original = $0
  sub(/\r$/, "", original)
  if (index(original, "\t")) { fail("tabs not allowed, line " FNR); next }
  line = strip_comment(original)
  if (trim(line) == "") next
  indent = 0
  while (substr(line, indent + 1, 1) == " ") indent++
  content = substr(line, indent + 1)
  sub(/[ \t]+$/, "", content)   # right-trim so trailing spaces after "tasks:" / "run:" do not cascade

  if (indent == 0) {
    if (content == "run:") {
      if (seen_root["run"]++) fail("duplicate run block")
      root_section = "run"; run_sub = ""; next
    }
    if (content == "tasks:") {
      if (seen_root["tasks"]++) fail("duplicate tasks block")
      root_section = "tasks"; tasks_empty = 0; run_sub = ""; next
    }
    if (content == "tasks: []") {
      if (seen_root["tasks"]++) fail("duplicate tasks block")
      root_section = "tasks"; tasks_empty = 1; run_sub = ""; next
    }
    if (!split_key(content)) { fail("invalid root structure, line " FNR); next }
    if (KEY != "schema_version") { fail("unknown root key: " KEY); next }
    if (seen_root["schema_version"]++) { fail("duplicate schema_version"); next }
    if (RAW != "3") {
      if (RAW == "2") fail("schema_version 2 is obsolete; migrate the ledger to the two-level schema_version 3")
      else fail("schema_version must be the integer 3; migrate the ledger to the two-level model")
    }
    next
  }

  if (indent == 2 && root_section == "run") {
    if (content == "server:" || content == "location:" ||
        content == "root_session:" || content == "client:") {
      subname = substr(content, 1, length(content) - 1)
      if (seen_sub[subname]++) fail("duplicate run." subname " block")
      run_sub = subname
      next
    }
    if (!split_key(content)) {
      fail("invalid key or indentation inside run, line " FNR); next
    }
    if (KEY == "max_in_flight") {
      fail("run.max_in_flight was removed in schema 3; use max_sessions_in_flight only if you observed a real limit")
      next
    }
    if (KEY != "min_subagents_per_worker" && KEY != "max_sessions_in_flight") {
      fail("unknown key in run: " KEY); next
    }
    if (seen_run[KEY]++) { fail("duplicate run key: " KEY); next }
    if (RAW !~ /^[1-9][0-9]*$/ || RAW + 0 > 2147483647) {
      fail("run." KEY " must be a positive integer between 1 and 2147483647")
      if (KEY == "min_subagents_per_worker") min_bad = 1
    } else run_value[KEY] = RAW + 0
    next
  }

  if (indent == 4 && root_section == "run") {
    if (run_sub == "" || !split_key(content)) { fail("field outside a run block, line " FNR); next }
    set_run(run_sub, KEY, RAW)
    next
  }

  if (indent == 2 && root_section == "tasks") {
    if (tasks_empty) { fail("tasks: [] does not accept elements, line " FNR); next }
    if (substr(content, 1, 2) != "- ") { fail("each task must be a list element under tasks, line " FNR); next }
    if (!split_key(substr(content, 3)) || KEY != "task_id") {
      fail("each task must start with task_id, line " FNR); next
    }
    task_n++; current_task = task_n
    set_task(current_task, KEY, RAW)
    next
  }

  if (indent == 4 && root_section == "tasks" && current_task > 0) {
    if (!split_key(content)) { fail("invalid task field, line " FNR); next }
    set_task(current_task, KEY, RAW)
    next
  }

  fail("indentation or placement outside the YAML subset at line " FNR)
}
END {
  if (!("schema_version" in seen_root)) fail("missing schema_version")
  if (!("run" in seen_root)) fail("missing run block")
  if (!("tasks" in seen_root)) fail("missing tasks block")
  req_run("server.mode", 1)
  req_run("server.endpoint_redacted", 1)
  req_run("server.observed_id", 1)
  req_run("server.version", 1)
  req_run("location.directory", 1)
  req_run("location.projectID", 0)
  req_run("location.subpath", 0)
  req_run("root_session.sessionID", 1)
  req_run("root_session.parentID", 0)
  if (!("min_subagents_per_worker" in seen_run)) fail("missing run.min_subagents_per_worker")
  else if (!min_bad && run_value["min_subagents_per_worker"] != 2)
    fail("run.min_subagents_per_worker must be exactly 2")
  optional_run = "location.directory_client location.projectID location.subpath root_session.parentID client.tabs_scope client.active_tab_hint"
  optional_count = split(optional_run, optional_key, " ")
  for (r = 1; r <= optional_count; r++)
    if (optional_key[r] in seen_run && !run_null[optional_key[r]] && run_value[optional_key[r]] == "")
      fail("run." optional_key[r] " cannot be an empty string; use null if not available")
  loc_dir = run_value["location.directory"]
  root_sid = (("root_session.sessionID" in seen_run) && !run_null["root_session.sessionID"]) ? run_value["root_session.sessionID"] : ""
  has_client = (("location.directory_client" in seen_run) && !run_null["location.directory_client"] &&
                run_value["location.directory_client"] != "")
  client_dir = has_client ? run_value["location.directory_client"] : loc_dir
  if (!is_abs(loc_dir))
    fail("run.location.directory must be a confirmed absolute path (POSIX, Windows drive or UNC)")
  else if (!is_abs(client_dir))
    fail("run.location.directory_client must be an absolute path (POSIX, Windows drive or UNC)")
  else {
    SRV = normpath(loc_dir)
    BASE = normpath(client_dir)
    NS_WIN = is_win(BASE)
    wsn = (NS_WIN && !is_win(ws)) ? posix_to_win(ws) : ws
    if (BASE != wsn) {
      if (has_client)
        fail("run.location.directory_client does not match the physical current directory (pwd -P); run the validator from that workspace")
      else
        fail("run.location.directory does not match the physical current directory (pwd -P); run the validator from the workspace root or declare run.location.directory_client with the path visible to the validator (e.g. when the server uses a Windows/UNC path)")
    }
  }
  if (run_value["server.mode"] != "shared-default" &&
      run_value["server.mode"] != "explicit-server" &&
      run_value["server.mode"] != "standalone") fail("invalid run.server.mode")
  if (run_value["server.endpoint_redacted"] ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\/]*@/)
    fail("run.server.endpoint_redacted contains userinfo; remove credentials")

  required = "task_id task_kind parent_task_id location_directory sessionID parentID agent_id dependencias scope_escritura criterion output_path evidence_refs estado runtime_status execution_outcome source_sessionID before_messageID created_at last_state_at notas"
  count = split(required, req, " ")
  for (i = 1; i <= task_n; i++) {
    for (r = 1; r <= count; r++)
      if (!((i, req[r]) in seen_task)) fail("task " i " missing required field " req[r])
  }
  if (task_n == 0 && !tasks_empty) fail("tasks must be [] or contain list elements")

  if (failures > 0) {
    printf "TOTAL: %d passed, %d failed\n", passed, failures
    exit 1
  }

  if (task_n == 0) {
    ok("canonical form and run metadata valid; empty tasks")
    ok("no tasks to validate")
    printf "TOTAL: %d passed, %d failed\n", passed, failures
    exit 0
  }

  for (i = 1; i <= task_n; i++) {
    id = task_value[i, "task_id"]
    if (id !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) {
      fail("empty task_id or outside grammar in task " i ": " id)
    } else if (id in id_index) fail("duplicate task_id: " id)
    else id_index[id] = i

    state = task_value[i, "estado"]
    if (state != "pending" && state != "launching" && state != "outcome-unknown" &&
        state != "running" && state != "awaiting-approval" && state != "completed" &&
        state != "verified" && state != "blocked" && state != "failed" &&
        state != "interrupted" && state != "cancelled" && state != "partial")
      fail(id " has invalid local state: " state)
    kind = task_value[i, "task_kind"]
    if (kind != "worker_session" && kind != "subagent")
      fail(id " has invalid task_kind: " kind)
    if (task_null[i, "location_directory"] || task_value[i, "location_directory"] != run_value["location.directory"])
      fail(id " location_directory must be identical to run.location.directory")
    outcome = task_value[i, "execution_outcome"]
    if (outcome != "unknown" && outcome != "succeeded" && outcome != "failed" &&
        outcome != "interrupted" && outcome != "cancelled")
      fail(id " has invalid local execution_outcome: " outcome)
    if (active_state(state) && outcome != "unknown")
      fail(id " in an in-flight state must have execution_outcome unknown")
    if (state == "verified" && outcome != "succeeded")
      fail(id " verified requires execution_outcome succeeded")
    if (state == "verified" && task_null[i, "output_path"])
      fail(id " verified requires a non-null output_path")
    if (state == "completed" && outcome != "succeeded")
      fail(id " completed requires terminal execution_outcome succeeded")

    if (!task_null[i, "parent_task_id"] && task_value[i, "parent_task_id"] == "")
      fail(id " has empty parent_task_id; use null for a root worker_session")
    if (!task_null[i, "parentID"] && task_value[i, "parentID"] == "")
      fail(id " has empty parentID; use null only for a root worker_session")
    for (r = 1; r <= 4; r++) {
      if (r == 1) optional_task = "sessionID"
      else if (r == 2) optional_task = "runtime_status"
      else if (r == 3) optional_task = "source_sessionID"
      else optional_task = "before_messageID"
      if (!task_null[i, optional_task] && task_value[i, optional_task] == "")
        fail(id " has empty " optional_task "; use null or a confirmed value")
    }
    if (task_null[i, "agent_id"] || task_value[i, "agent_id"] == "")
      fail(id " requires agent_id")
    if (task_value[i, "criterion"] == "") fail(id " requires a non-empty criterion")
    if (task_null[i, "output_path"] == 0 && task_value[i, "output_path"] == "")
      fail(id " empty output_path; use null if there is no artifact")
    if (task_null[i, "source_sessionID"] != task_null[i, "before_messageID"])
      fail(id " requires source_sessionID and before_messageID together for a fork")
    else if (task_null[i, "source_sessionID"] == 0 &&
        (task_value[i, "source_sessionID"] == "" || task_value[i, "before_messageID"] == ""))
      fail(id " does not allow empty fork IDs")

    active = active_state(state)
    if (active) active_total++
    if ((state == "running" || state == "completed" || state == "verified") &&
        (task_null[i, "sessionID"] || task_value[i, "sessionID"] == ""))
      fail(id " in state " state " requires a confirmed sessionID")
    if ((state == "running" || state == "completed" || state == "verified") &&
        (task_null[i, "runtime_status"] || task_value[i, "runtime_status"] == ""))
      fail(id " in state " state " requires an observed runtime_status")
    if (task_null[i, "sessionID"] == 0 && task_value[i, "sessionID"] != "") {
      sid = task_value[i, "sessionID"]
      if (sid == root_sid) fail(id " reuses the sessionID of run.root_session (orchestrator root session): " sid)
      else if (sid in session_index) fail(id " repeats sessionID of " session_index[sid])
      else session_index[sid] = id
    }
    if (active && state != "launching" && state != "outcome-unknown" &&
        task_null[i, "sessionID"])
      fail(id " in active execution requires sessionID; if the dispatch was not confirmed use outcome-unknown")

    cr = norm_time(task_value[i, "created_at"])
    ls = norm_time(task_value[i, "last_state_at"])
    if (cr == "" || ls == "") fail(id " has an invalid timestamp; requires UTC YYYY-MM-DDTHH:MM:SSZ")
    else if (ls < cr) fail(id " has last_state_at earlier than created_at")

    for (k = 1; k <= task_count[i, "dependencias"]; k++) {
      d = task_list[i, "dependencias", k]
      if (d !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/)
        fail(id " has a dependency with invalid ID: " d)
      if (dep_seen[i, d]++) fail(id " repeats dependency " d)
      deps[i]++
      dependency[i, deps[i]] = d
    }
    for (k = 1; k <= task_count[i, "scope_escritura"]; k++) {
      p = task_list[i, "scope_escritura", k]
      if (p == "") fail(id " contains an empty scope")
      else {
        scopes[i]++; scope[i, scopes[i]] = p
        if (scanon(i, k) == "!OUTSIDE_WORKSPACE!")
          fail(id " scope_escritura escapes the workspace root: " p)
      }
    }
    for (k = 1; k <= task_count[i, "evidence_refs"]; k++) {
      if (evidence_seen[i, task_list[i, "evidence_refs", k]]++)
        fail(id " repeats evidence_ref " task_list[i, "evidence_refs", k])
      if (canon_path(task_list[i, "evidence_refs", k]) == "!OUTSIDE_WORKSPACE!")
        fail(id " evidence_ref escapes the workspace root: " task_list[i, "evidence_refs", k])
    }

    outp = task_value[i, "output_path"]
    if (!task_null[i, "output_path"] && outp != "") {
      if (scopes[i] == 0) fail(id " defines output_path but no scope_escritura")
      outcanon = canon_path(outp)
      if (outcanon == "!OUTSIDE_WORKSPACE!") fail(id " output_path escapes the workspace root")
      covered = 0
      for (k = 1; k <= scopes[i]; k++)
        if (covers(scanon(i, k), outcanon)) covered = 1
      if (!covered) fail(id " output_path lies outside scope_escritura")
    }
  }

  for (i = 1; i <= task_n; i++) {
    id = task_value[i, "task_id"]
    kind = task_value[i, "task_kind"]
    parent_id = task_value[i, "parent_task_id"]
    runtime_parent = task_value[i, "parentID"]
    if (kind == "worker_session") {
      if (!task_null[i, "parent_task_id"])
        fail(id " worker_session must have parent_task_id: null")
      if (!task_null[i, "parentID"])
        fail(id " root worker_session must have parentID: null")
    } else if (kind == "subagent") {
      if (task_null[i, "parent_task_id"] || parent_id == "")
        fail(id " subagent requires the parent_task_id of a worker_session")
      else if (!(parent_id in id_index))
        fail(id " nonexistent parent_task_id: " parent_id)
      else {
        parent_i = id_index[parent_id]
        if (task_value[parent_i, "task_kind"] != "worker_session")
          fail(id " parent_task_id must refer to task_kind worker_session: " parent_id)
        if (task_null[parent_i, "sessionID"] || task_value[parent_i, "sessionID"] == "")
          fail(id " parent worker_session " parent_id " has no confirmed runtime sessionID")
        if (task_null[i, "parentID"] || runtime_parent == "" ||
            runtime_parent != task_value[parent_i, "sessionID"])
          fail(id " parentID must match the runtime sessionID of worker " parent_id)
        parent_child[i] = parent_i
        for (p = 1; p <= scopes[i]; p++) {
          child_scope = scanon(i, p)
          covered = 0
          for (q = 1; q <= scopes[parent_i]; q++)
            if (covers(scanon(parent_i, q), child_scope)) covered = 1
          if (!covered)
            fail(id " scope_escritura lies outside the scope budget of worker " parent_id ": " scope[i, p])
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
        fail(id " verified requires at least " run_value["min_subagents_per_worker"] " verified subagent children with distinct sessionIDs")
    }
  }

  for (i = 1; i <= task_n; i++) {
    id = task_value[i, "task_id"]
    for (k = 1; k <= deps[i]; k++) {
      d = dependency[i, k]
      if (!(d in id_index)) fail(id " depends on nonexistent task_id: " d)
      else {
        j = id_index[d]
        indeg[i]++
        successor[j] = successor[j] " " i
        if (active_state(task_value[i, "estado"]) &&
            task_value[j, "estado"] != "verified")
          fail(id " cannot be in flight until dependency " d " is verified")
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
  if (done < task_n) fail("cycle detected in dependencias")
  else ok("all dependencias exist and the DAG is acyclic")

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
      fail(task_value[i, "task_id"] " and " task_value[j, "task_id"] " share scope without a dependency")
      scope_bad = 1
    }
  }
  if (!scope_bad) ok("scopes do not overlap between tasks without a dependency")

  if ("max_sessions_in_flight" in seen_run) {
    if (active_total > run_value["max_sessions_in_flight"])
      fail("max_sessions_in_flight exceeded counting workers and subagents: " active_total " active, limit " run_value["max_sessions_in_flight"])
    else ok(sprintf("%d active sessions (workers and subagents) out of a local maximum of %d", active_total, run_value["max_sessions_in_flight"]))
  } else ok(sprintf("%d active sessions; no local limit configured", active_total))

  if (failures == 0) ok("canonical schema, IDs, states and dates valid")
  printf "TOTAL: %d passed, %d failed\n", passed, failures
  exit (failures > 0 ? 1 : 0)
}
' < "$LEDGER"
