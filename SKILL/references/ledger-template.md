# Canonical execution ledger

The ledger is the durable local source of truth for identity, ownership, dependencies, scopes, concurrency, and reconciliation. The runtime does not persist it. The model has two levels: first-level worker sessions and subagent children of a worker. DAG dependencies order execution; they never express ownership.

## Single schema

The root is always a map with `schema_version`, `run`, and `tasks` as a list. Do not use a list at the root or put tasks directly in the root map. The empty block and the populated one use the same shape.

~~~~yaml
schema_version: 3
run:
  server:
    mode: "shared-default"
    endpoint_redacted: "http://127.0.0.1:4096"
    observed_id: "server-id-from-api-info"
    version: "version-from-api-info"
  location:
    directory: "/workspace/from-api-location"
    # directory_client: "/path/visible/to/the/validator"   # optional; see the location bullet
    projectID: null
    subpath: null
  root_session:
    sessionID: "root-session-id"
    parentID: null
  client:
    tabs_scope: "current-client"
    active_tab_hint: "optional-ui-hint"
  min_subagents_per_worker: 2

## Optional `run.client` block

The validators accept (and the `attach-tabs` helper writes) an optional `run.client` block with two fields:

- `tabs_scope`: `"global"` or `"current-client"`; determines whether the tab is published in the global `tabs.json` or under the TUI's cwd key.
- `active_tab_hint`: free-form string for the TUI to display an active tab (not used by the validators).

When this block appears, the validator accepts the keys `tabs_scope` and `active_tab_hint` and rejects any other key under `client`. If absent, the validators do not require it. The canonical documentation of the tabs mechanism is in `recipe-tui-tabs.md`.
tasks: []
~~~~

- `mode` is a ledger convention: `shared-default`, `explicit-server`, or `standalone`. Record what was observed (`shared-default` by default on a local client); the semantics of the CLI flags (`--server`, `--standalone`) requires verification with your installation's help ([api-and-sessions.md](api-and-sessions.md#call-transport)).
- `min_subagents_per_worker` must be exactly `2`. `max_sessions_in_flight` is optional and is governed by the section [Optional limit `max_sessions_in_flight`](#optional-limit-max_sessions_in_flight).
- `location.directory` is the literal OpenCode server path exactly as `/api/location` returns it, in any absolute form: POSIX (`/srv/p`), Windows drive (`C:\Users\dev\p`), or UNC (`\\host\share\p`); **in the YAML, inside double quotes, each backslash is written doubled**: `"C:\\Users\\dev\\p"`, `"\\\\host\\share\\p"` (the validator decodes `\\` to `\`; a single backslash fails with "invalid scalar"). It is copied untransformed to `location_directory` of every task and to every session creation.
- `location.directory_client` (optional) is the path of the same workspace as the validator sees it (`pwd -P`): use it when the server uses a path different from the one visible in the shell (Windows server, UNC, a different mount or mapping, Git Bash `/c/...`, WSL `/mnt/c/...`). If it is missing, the validator compares `location.directory` with `pwd -P`. Relative scopes resolve against `directory_client` (or `directory` if missing), and absolute scopes hanging from `location.directory` are remapped to that base.
- Current V2 facts: confirm the server's identity and location (detail in the next two bullets) and the runtime IDs before operating. Tabs are client hints without public HTTP identity. The native child is `subagent`; its permission policy follows the canonical rule of [agents-and-safety.md](agents-and-safety.md#permission-rules) (the parent's permission controls which agents to launch; the child's policy governs its tools; the inheritance described is of session-specific rules, not of agent policy).
- Confirm `endpoint_redacted`, `observed_id`, and `version` with `/api/info`; strip secrets from the endpoint.
- Confirm `directory`, `projectID`, and `subpath` with `/api/location` and compare them with `Session.Info.location`.
- `root_session.sessionID` and `parentID` are confirmed runtime IDs of the run's root session. Each task's fields separately describe the worker or subagent session and its real `parentID`.
- Session routes are experimental: before using them, verify their presence in the active `/openapi.json` of the saved endpoint.

## Task fields

Each task uses the exact keys shown in the example. `task_id`, `agent_id`, and the IDs are written as double-quoted strings. `task_id` is unique and starts with a letter or digit, followed by letters, digits, dot, hyphen, or underscore. Dependencies, scopes, and evidence are flow-style lists of double-quoted strings.

- `task_kind`: `worker_session` for a first-level worker; `subagent` for a native child session.
- `parent_task_id`: `null` for `worker_session`; the owning worker's `task_id` for `subagent`.
- `parentID`: the real `parentID` reported by OpenCode. It is `null` for a root worker session and the worker's runtime `sessionID` for a subagent.
- `location_directory`: exact copy of `run.location.directory` in every row, even if the location also appears in the runtime metadata.
- `sessionID`: confirmed runtime session, or `null` in `pending`/pre-creation rows before creating it. A `null` does not count toward the minimum of children of a verified worker. Do not reuse a `sessionID` across tasks.
- `agent_id`: confirmed ID of the agent used for the session.
- `dependencias`: IDs of tasks that must be verified before starting this task. Do not use dependencies to represent `parent_task_id`.
- `scope_escritura`: list of the task's write budget. Every subagent scope must fall inside some write scope of its worker.
- `criterion`: concrete assertion that the owning worker can check before dispatching or closing the task.
- `output_path`: expected artifact; it must fall inside at least one `scope_escritura`. `null` is valid while the task is in `pending`/`launching`/`running`/`awaiting-approval`/`outcome-unknown` (no artifact yet); the closing validator requires it non-null and existing on disk for `verified`, and with justifying `notas` for the unverified terminals.
- `evidence_refs`: list of evidence files. For `verified`, every verified subagent task writes its evidence file inside its `scope_escritura` with criterion, result ("pass"), and observed; a verified worker's evidence additionally includes `subagent_results_integrated` with all its verified children that it inspects and integrates into its report.
- `estado`: local state among `pending`, `launching`, `outcome-unknown`, `running`, `awaiting-approval`, `completed`, `verified`, `blocked`, `failed`, `interrupted`, `cancelled`, and `partial`.
- `runtime_status`: literal value observed from the active runtime, or `null`; it is not the local state.
- `execution_outcome`: local classification `unknown`, `succeeded`, `failed`, `interrupted`, or `cancelled`; it does not replace the runtime state.
- `source_sessionID` and `before_messageID`: both `null`, or both present for a confirmed fork.
- `created_at` never changes; `last_state_at` advances on every transition. Both are UTC `YYYY-MM-DDTHH:MM:SSZ`.
- `notas`: reason, decision, or operating context in text.

## Verified worker gate

This section is the single definition of the two-subagent minimum; the other documents link here.

The canonical gate only allows marking a `worker_session` as `verified` if it has at least `run.min_subagents_per_worker` (exactly two in this schema) child `subagent` rows in `verified` state. To count, each row must have `parent_task_id` equal to the worker's `task_id`, `parentID` equal to the worker's confirmed non-null runtime `sessionID`, its own non-null `sessionID` distinct from that of every other counted row, and `location_directory` equal to `run.location.directory`, a location confirmed by comparing it with `/api/location` and `Session.Info.location`. Therefore, rows with `sessionID: null` do not count, and two rows with duplicate IDs do not satisfy the minimum of two distinct sessions. In addition, the worker's evidence must confirm that its report inspects and integrates all of its children's verified results. `failed`, `blocked`, or `partial` workers may be recorded without meeting the minimum; do not mark them `verified` to represent incomplete work.

## Scopes and write order

Single canonical definition in [agents-and-safety.md#write-budget-and-scopes](agents-and-safety.md#write-budget-and-scopes). This section only anchors the reference: scopes are compared by path components; two tasks with no parent-child relation and overlapping scopes need a transitive DAG dependency (also for siblings); the worker↔subagent relation allows a nested scope but forbids the parent writing simultaneously in the overlapping part.

## Optional limit `max_sessions_in_flight`

The consulted sources publish no global OpenCode concurrency cap, and the skill defines no default value: do not import a limit from another version or use `max_in_flight` (removed in schema 3). Add `run.max_sessions_in_flight: N` (positive integer) only in the presence of a real limit observed on the active instance. If configured, it counts workers and subagents together in `launching`, `outcome-unknown`, `running`, and `awaiting-approval`; `outcome-unknown` and a pending approval keep the reservation. For both `run` integers (`min_subagents_per_worker` and `max_sessions_in_flight`) the validator accepts the range 1–2147483647 (internal cap).

The validator only accepts the integer; it has no provenance field in `run`. Keep source, runtime context, version/instance, and date in `notas` of a `worker_session` row (accepted task field), and do not invent a `run.*_source` key. If you cannot leave that provenance durably in an accepted field, omit the limit until the schema and validator are extended.

## Write-ahead and reconciliation

Edit the ledger with a programmatic helper or by regenerating it from an in-memory model; in-place `sed`/regex substitutions are a source of corruption (silently lost fields). Create/edit:

1. Create each row as `pending`; fill in criterion, ownership, location, dependencies, scopes, output, and the real/null `parentID` per level.
2. Before invoking a worker or subagent, write state `launching` and update `last_state_at`. If you configured `max_sessions_in_flight`, count the slot in both levels before launching.
3. If you do not know whether the send took effect, record state `outcome-unknown` and `execution_outcome: "unknown"`. Keep the slot and the scope; do not resend until you reconcile endpoint, location, sessionID, and parentID.
4. On confirmed execution or pending permission, record the local and runtime states separately. `running` and `awaiting-approval` count against the configured limit; `outcome-unknown` also keeps the reservation.
5. On a terminal result, record the literal `runtime_status` and the `execution_outcome`. Move to `completed`; the owning worker must still inspect the artifact. A worker does not write in an active child's scope while that child writes.
6. Only after checking `output_path` against `criterion` and that every `evidence_refs` exists and satisfies the [evidence gate](#evidence-format), move to `verified`. The worker's report integrates its subagents' verified results, and its evidence lists them in `subagent_results_integrated`. The states `blocked`, `failed`, `interrupted`, `cancelled`, and `partial` keep the reason in `notas`.
7. A confirmed fork records the new `sessionID`, together with `source_sessionID` and `before_messageID`. Check the active `/openapi.json` before calling an experimental session route.

The inheritance of session-specific rules when creating a child is described in the [Current V2 facts](#single-schema) bullet; do not generalize it to the child agent's configured policy.

## Populated two-level example

The paths are illustrative and relative to the workspace root; replace them with real paths. Subagents write their `output_path`, so they use `general`; `explore` is read-only ([agents-and-safety.md](agents-and-safety.md#agent-selection-for-the-two-levels)). The example shows the shape of a valid two-level ledger. The illustrative output and evidence paths must exist and contain the indicated records before marking the rows `verified` or passing the closing gate.

~~~~yaml
schema_version: 3
run:
  server:
    mode: "shared-default"
    endpoint_redacted: "http://127.0.0.1:4096"
    observed_id: "server-42"
    version: "version-confirmed-by-api-info"
  location:
    directory: "/workspace/project"
    projectID: "project-7"
    subpath: "src"
  root_session:
    sessionID: "sid-root"
    parentID: null
  client:
    tabs_scope: "current-client"
    active_tab_hint: "workers"
  min_subagents_per_worker: 2
tasks:
  - task_id: "W1"
    task_kind: "worker_session"
    parent_task_id: null
    location_directory: "/workspace/project"
    sessionID: "sid-worker"
    parentID: null
    agent_id: "build"
    dependencias: []
    scope_escritura: ["artifacts"]
    criterion: "The report inspects and integrates both verified subagent results."
    output_path: "artifacts/W1-report.md"
    evidence_refs: ["artifacts/W1-evidence.yml"]
    estado: "verified"
    runtime_status: "completed"
    execution_outcome: "succeeded"
    source_sessionID: null
    before_messageID: null
    created_at: "2026-09-30T12:00:00Z"
    last_state_at: "2026-09-30T12:30:00Z"
    notas: ""
  - task_id: "S1"
    task_kind: "subagent"
    parent_task_id: "W1"
    location_directory: "/workspace/project"
    sessionID: "sid-subagent-1"
    parentID: "sid-worker"
    agent_id: "general"
    dependencias: []
    scope_escritura: ["artifacts/subagent-1"]
    criterion: "The output records the first independent result."
    output_path: "artifacts/subagent-1/S1-output.md"
    evidence_refs: ["artifacts/subagent-1/S1-evidence.yml"]
    estado: "verified"
    runtime_status: "completed"
    execution_outcome: "succeeded"
    source_sessionID: null
    before_messageID: null
    created_at: "2026-09-30T12:05:00Z"
    last_state_at: "2026-09-30T12:20:00Z"
    notas: ""
  - task_id: "S2"
    task_kind: "subagent"
    parent_task_id: "W1"
    location_directory: "/workspace/project"
    sessionID: "sid-subagent-2"
    parentID: "sid-worker"
    agent_id: "general"
    dependencias: []
    scope_escritura: ["artifacts/subagent-2"]
    criterion: "The output records the second independent result."
    output_path: "artifacts/subagent-2/S2-output.md"
    evidence_refs: ["artifacts/subagent-2/S2-evidence.yml"]
    estado: "verified"
    runtime_status: "completed"
    execution_outcome: "succeeded"
    source_sessionID: null
    before_messageID: null
    created_at: "2026-09-30T12:06:00Z"
    last_state_at: "2026-09-30T12:21:00Z"
    notas: ""
~~~~

## Evidence format

Each file in `evidence_refs` of a verified task uses a flat YAML-formatted record, with the base values in double quotes. Each verified `subagent` task writes its evidence file inside its assigned `scope_escritura` with criterion, result ("pass"), and observed (or includes it in its deliverable to the worker, which integrates it into its report, for the orchestrator to persist it):

~~~~yaml
criterion: "The output records the first independent result."
result: "pass"
observed: "Ran test suite; all 12 tests passed successfully."
~~~~

The verified worker's evidence file additionally includes the exact list `subagent_results_integrated` with the `task_id` of its verified subagent children that the report inspects and integrates:

~~~~yaml
criterion: "The report inspects and integrates both verified subagent results."
result: "pass"
observed: "Inspected W1-report.md; it compares and integrates the findings from S1 and S2."
subagent_results_integrated: ["S1", "S2"]
~~~~

The file extension is the one `evidence_refs` declares: if a child wrote `.yaml` instead of `.yml`, reconcile `evidence_refs` toward the existing file (never rewrite the child's file; R14a). The gate requires that the record's `criterion` exactly match the task, that `result` be `pass`, and that `observed` not be empty. For a verified worker, it also requires `subagent_results_integrated` with all its verified children. This records that the report was inspected to check integration; the evidence gate does not replace review of the report's content. An existing file, without that content and correspondence, is not enough. The validator checks in the file: existence, containment in the workspace root, and this content; that it stays inside the subagent's `scope_escritura` is an authoring obligation the script does not check.

## Accepted YAML subset

The scripts use POSIX sh and awk, not a YAML library. They accept only the illustrated format: root map with `schema_version: 3`, `run:`, and `tasks:`; exact-space indentation; tasks as list items under `tasks`; double-quoted strings; literal `null`; positive integer for `min_subagents_per_worker` and, optionally, `max_sessions_in_flight`; flow-style lists. Encoding: UTF-8 without BOM (a leading BOM is tolerated and discarded; accented characters are valid). Blank lines, full-line comments, and inline comments are allowed (`#` preceded by a space and outside double quotes); a value like `null  ` or `null # root` equals `null` in both validators. Rejected: a root list, blocks, anchors, aliases, tabs, duplicate/unknown keys, inline maps, and values or indentations outside that subset. A schema 2 ledger gets an error stating the required migration.

The scopes and relative paths resolve from the workspace root, which is the current physical directory (`pwd -P`, with symlinks resolved). That root must match `run.location.directory_client` or, if missing, `run.location.directory`, after the form normalization applied by the validator (drive uppercased, POSIX views `/c/...`, and `.`/`..` collapse). Every `location_directory` must be identical to `run.location.directory` (server literal). A relative path that normalizes outside the root fails. Absolute scopes are preserved; those hanging from `run.location.directory` are remapped to the workspace root when `directory_client` differs. Scopes are compared lexically by path components; `src` overlaps `src/a.py`, but not `src2`. A subagent inherits its worker's DAG order: if `W2` depends (directly or transitively) on `W1`, the children of both trees are not considered parallel; in contrast, siblings of the same worker, or parallel workers with overlapping scopes and no dependency, still fail. Internal workspace symlinks are not resolved. A ledger with CRLF line endings is accepted: both validators discard the trailing `\r` and the trailing spaces of `run:`/`tasks:`. Paths with spaces must be double-quoted. Closing extraction errors indicate the line (`[FAIL] line N: ...`).

Absolute path forms accepted: POSIX, Windows drive (`C:\x` or `C:/x`, the letter normalized to uppercase), and UNC with backslashes (`\\host\share\x`). Remember to write the backslashes doubled (`"C:\\x"`, `"\\\\host\\share\\x"`) because only the escapes `\\` and `\"` are supported inside quotes. In Windows/UNC paths the already-decoded backslashes are converted to `/` for comparison; the case of the rest of the path is not normalized. If the declared workspace is a Windows drive and the shell is Git Bash, WSL, or Cygwin, the validator accepts the POSIX view `/c/x`, `/mnt/c/x`, or `/cygdrive/c/x` of the same directory. For POSIX paths the behavior is the same as before.

**`directory_client` in Windows form, and an honest limit:** `validate_ledger_closed.sh` converts the physical root (`pwd -P`) to the same Windows form (only the `/c/...`, `/mnt/c/...`, `/cygdrive/c/...` views), checks containment there, and returns to the physical view before `[ -f ]`. There is no automatic conversion for UNC or arbitrary mounts (for example, a network share mounted at `/mnt/share` or `\\wsl$`): in those cases declare `directory_client` with the **POSIX path the shell sees**; it is the most robust option for Git Bash and WSL too. If the conversion is not possible, the validator fails closed (the path is left "outside the workspace root").

## Validators: dependencies, usage, and exit codes

Both scripts are POSIX `sh` + `awk`; `validate_ledger_closed.sh` additionally uses `dirname`. They set `LC_ALL=C` (lengths and comparisons by byte, locale-independent) and, if `awk` is missing, exit with code 2 and `ERROR: awk not available`. They must be extracted with **LF** line endings (the repository forces it via `.gitattributes`: `*.sh text eol=lf`); a copy converted to CRLF fails under `sh` with a non-zero code. They need no Python, yq, or data outside the ledger, the evidence, and the workspace. On Windows, run them from Git Bash or WSL; with no shell, follow the manual fallback of [SKILL.md](../SKILL.md#validators).

| Script | Usage | What it checks |
| --- | --- | --- |
| `scripts/validate_dag.sh` | `sh validate_dag.sh LEDGER_PATH` | Canonical YAML shape, identity and location, states, cycle-free DAG, scopes, optional limit, verified worker gate |
| `scripts/validate_ledger_closed.sh` | `sh validate_ledger_closed.sh [--require-evidence] [--allow-degraded] LEDGER_PATH` | Runs the previous one and enforces closure: in strict mode all tasks `verified`, `execution_outcome: succeeded`, evidence with criterion/result/observed and integration; with `--allow-degraded`, states and requirements per the "Single invocation" paragraph below |

`output_path` and `evidence_refs` follow the same path rule as the scopes: `validate_ledger_closed.sh` remaps to `directory_client` the absolute paths under `run.location.directory`, returns them to the shell's physical view, and rejects every path (absolute, or relative with `..`) that ends outside the workspace's physical root (for example, `/etc/hosts`).

**Single invocation:** `validate_ledger_closed.sh` already runs `validate_dag.sh`; for a full closure, `sh scripts/validate_ledger_closed.sh --require-evidence LEDGER_PATH` is enough. If the run closed in degraded terminal states (`failed`, `blocked`, `partial`, `cancelled`, `interrupted`), add `--allow-degraded`: `verified` tasks keep the strict requirements (`execution_outcome: succeeded`, `output_path`, `evidence_refs`), while tasks in unverified terminal states require non-empty `notas` with the reason/cause and check evidence if present; the active states (`pending`, `launching`, `running`, `awaiting-approval`, `outcome-unknown`) remain forbidden at closing, and so does `completed`: it is a transient ledger state, so every row must move from `completed` to `verified` or to a degraded terminal state before validating (the validator rejects it in both modes). Run `validate_dag.sh` separately only to validate a still-open (in-progress) ledger. Run them with the workspace as the current directory. Exit codes: `0` passes, `1` validation failure, `2` usage or environment error (arguments, unreadable ledger, invalid `pwd -P`, missing `awk`). The last line is `TOTAL: N passed, M failed`, with real check counts.
