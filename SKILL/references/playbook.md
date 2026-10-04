# Operational playbook — two-level coordination

Workflow for OpenCode V2. The active runtime is the authority: confirm server, `/openapi.json`, tool catalog, permissions, and location before operating. The orchestrator exclusively maintains the canonical ledger. It creates root `worker_session` sessions; each worker coordinates at least two distinct `subagent` sessions, inspects and integrates results, and reports to the orchestrator. The ledger's local fields and states are not native OpenCode states.

**Mapping to the 7 steps of [SKILL.md](../SKILL.md#execution-steps)** (this guide breaks them down further): S1 → P1; S2 → P2; S3 → P3; S4 → P2–P3; S5 → P4–P5; S6 → P5–P7; S7 → P8 plus the closing checklist.

## Step 1: Detect intent and scope

- **Input:** the user's request.
- **Output:** verdict (orchestrate / do not orchestrate), goal, deliverables, and constraints.
- **Verification:** the task needs multi-session coordination, delegation, or reconciliation. For single-session work, reply inline.
- **Typical errors:** triggering on a loose keyword → reply inline; splitting a trivial unit → solve it directly.

## Step 2: Preflight of real capabilities

Before creating tasks, consult the catalog, `/openapi.json` (it only counts if it is OpenAPI JSON; an HTML response is not a schema, see [Contract discovery](api-and-sessions.md#contract-discovery)), and the active client/runtime interface. For each operation, record the exact advertised name, its arguments, and the evidence that it exists:

| Operation needed | Evidence that is checked |
|---|---|
| Create a root worker session | The real capability accepts `run.location.directory` as an explicit argument and returns/allows reading the `sessionID`. |
| Send the prompt to that session | The real capability identifies the destination by its session identity and accepts the full prompt. |
| Wait for and read the result | A documented completion signal exists, plus a way to read output/state from that same session. |
| Expose and verify a TUI tab (**only if the user asked for tabs**) | Creating the session over the HTTP API does not demonstrate that it appears in the TUI. Confirm whether the active version offers a CLI plugin tabs API or uses the local `tabs.json` state, verify the schema/mechanism, and confirm that the resulting tab shows the expected `sessionID`; see the [local recipe](recipe-tui-tabs.md). |
| Read a worker's result | The orchestrator can read the session's state and result through the confirmed capability; this is the base channel for reports and change requests. |
| Dynamic worker↔orchestrator channel (optional) | Enabled only if preflight confirms a real round-trip channel to request changes and respond. It is not a requirement for pre-authorized dispatch. |
| Create a subagent from a worker | The catalog and permissions allow the correct native `parentID`, and the child location satisfies the [single rule](subagent-contract.md#single-rule-for-child-location) (including the `GET /api/session/{childID}` check). |

Do not invent tool names, parameters, paths, notifications, or IDs. Do not substitute calling `subagent` for creating/opening/verifying a session or tab. If a capability is missing, record the exact operation, the source consulted, and the effect: stop only the launch that depends on it and report the blockage; continue only with independent preparation. For the child location, apply the [single rule](subagent-contract.md#single-rule-for-child-location); do not invent parameters.

## Step 3: Confirm access, server, and identity

- Confirm authorization and the endpoint to be used. On local clients, record `shared-default`, `explicit-server`, or `standalone` as observed; do not record credentials.
- Query `/openapi.json` to discover the contract, and `/api/info` and `/api/location` only if the active schema publishes them. Record `observed_id`, version, and the canonical `directory`, `projectID`, and `subpath` in the ledger; if the validator sees the workspace under a different path (Windows/UNC server, Git Bash, WSL), also record `directory_client` (see [ledger-template.md](ledger-template.md#single-schema)).
- Check the native `sessionID` and `parentID` of the orchestrator's current session. `run.root_session` represents that session, not a worker session.
- Every new root worker must receive `run.location.directory` as an explicit argument. For a child, apply the [single rule for child location](subagent-contract.md#single-rule-for-child-location). After creating any session, query its real identity/location and require exact equality with `run.location.directory` before sending or counting work.
- **Only if the user asked for tabs:** a tab is only a client view. After creating the session, expose it through the CLI plugin's local tabs API or the `tabs.json` state only if the active version's contract/schema confirms it. Check that the TUI shows the expected `sessionID` and uses `run.location.directory` as its cwd; API creation does not guarantee this exposure. See the [local recipe](recipe-tui-tabs.md), do not invent paths or keys, and do not use the tab as session identity or `parentID`.

**If it fails:** without authorization, a verifiable server, explicit session capability, or a location match, do not fake success or try guessed paths. Report which check or capability is missing.

## Step 4: Design two levels and inherited scopes

The DAG has two execution levels besides the orchestrator:

1. The orchestrator assigns each unit of work to a new `worker_session` task, with `parent_task_id: null` and `parentID: null`.
2. Every worker except the orchestrator runs at least two useful child tasks pre-authorized by the orchestrator, as distinct `subagent` sessions. It may repeat the same `agent_id`; for the minimum, two confirmed `sessionID`s count — not two agent names or two continuations of one session.
3. Subagents do not need to create grandchildren. Do not claim the minimum if child creation failed or if there are not two distinct IDs.

Before sending the work prompt, the orchestrator records in the ledger at least two pre-authorized `subagent` rows per worker, each with `task_id`, scope, `output_path`, and `criterion`; it fills `parentID` with the worker's real `sessionID` and `location_directory` with `run.location.directory`. Include those rows in the prompt. The worker executes only the authorized tasks/scopes and does not write the ledger. The orchestrator reads the results through that session's confirmed capability; a message channel between independent root sessions is not presumed. A dynamic handshake is used only if preflight confirms round-trip. If the worker needs to change a task or scope, it stops and requests an update through the confirmed channel; the orchestrator updates the ledger before sending an updated prompt.

| Rule | Action |
|---|---|
| Dependency | If one task consumes another's output, add a dependency and wait for that output. |
| Scopes and timeouts | A child receives an explicit subset of the worker's scope; overlaps, parent writer, and timeout: [single rule](agents-and-safety.md#write-budget-and-scopes). |
| Capacity | Serialize according to observed capacity and real dependencies; `run.max_sessions_in_flight` only with a real limit and provenance in `notas` ([ledger-template.md](ledger-template.md#optional-max_sessions_in_flight-limit)). |

Declare paths relative to the workspace root (resolved against `run.location.directory_client` or, if absent, `run.location.directory`; see [ledger-template.md](ledger-template.md#single-schema)); check that every output is contained in the assigned write scope. Every task of both kinds carries `task_kind`, `parent_task_id`, native `parentID`, and `location_directory` per the schema 3 contract in [SKILL.md](../SKILL.md#identity-and-ledger).

## Step 5: Register and create worker sessions

The orchestrator creates one row per worker before dispatching: `task_kind: worker_session`, `parent_task_id: null`, `parentID: null`, `location_directory` equal to `run.location.directory`, `source_sessionID: null`, `before_messageID: null`, goal, dependencies, scope, output, and criterion. Rows for new children also carry `source_sessionID: null` and `before_messageID: null`; only a documented fork may record its source/cut IDs. Store the orchestrator's current session separately in `run.root_session`.

**Default path: the deterministic scripts.** Do not assemble this step by hand — the swiss-army script makes the work repeatable and its gate decisions are already centralized.

```sh
sh scripts/orchestrate.sh preflight "$PWD"                                  # P2 + tabs gate
sh scripts/orchestrate.sh init-run --worker "Vermithrax" --worker "Glacielle" # root [00] + workers + tabs
```

`init-run` creates the root `[00] Orquestador`, creates each worker with its verified `sessionID`, applies the sequential numbering from the [naming convention](naming-convention.md), and exposes the tabs when the gate says `ready`. One `--worker` per session: **space cannot be the list delimiter** because it is part of the title. It also accepts `--workers "A, B, C"`.

Use `create-worker` step by step only when you truly need it: creating a single worker, forcing a new one with `--force-new`, or reusing the cached preflight. Each standalone call is an extra round-trip, and looping the `create-worker` flow leaves tab exposure undone.

Cross-check `init-run` against the ledger: the `sessionID`s it emits are the real identity. Dedup is **by name, ignoring the ordinal**, so `--worker "Vermithrax"` reuses `[01] Vermithrax` instead of creating a duplicate.

If `init-run` answers `init-run: INCOMPLETO` and exits with code 1, some worker was not created: **do not treat it as success**. Re-run `init-run` with the same titles; dedup reuses what already exists and completes what is missing.

For each worker, in this order:

1. Record local state `pending` and then `launching` before calling the exact discovered capability.
2. Create a root session with explicit `run.location.directory`. Check the `sessionID`, that the native `parentID` is `null`, and that the real location matches exactly.
3. Before sending the prompt, record at least two pre-authorized `subagent` rows: new `task_id`s, `parent_task_id` equal to the worker, `parentID` equal to the checked native `sessionID`, `location_directory` equal to `run.location.directory`, `sessionID: null`, scope, output, and criterion. Do not use a fake authorization state: the rows start `pending`.
4. Expose the session as a TUI tab through the [SKILL.md tabs gate](../SKILL.md#decision-gates). With an active local TUI, additive `tabs.json` exposure is the default path ([recipe §6](recipe-tui-tabs.md)) and `init-run` already does it; if the gate is not `ready`, the run continues without tabs and it is marked "not verified". Only with the operator's explicit authorization do you pass `--force-tabs`. Check that the TUI shows the worker `sessionID` and the canonical location. The tab does not replace the IDs.
5. Send the self-contained [worker](prompt-templates.md#1-worker-session-dispatch) prompt, including the rows and their exact scopes/criteria.
6. Record the `sessionID`, checked identity, and observed native state. Wait for and read the result through the identified capability.

Do not use `subagent` to create a root worker session or to fake a tab. If a call becomes uncertain, record `outcome-unknown`, keep the scope, and reconcile before repeating.

## Step 6: Coordinate each worker's subagents

Every worker prompt includes at least two useful, self-contained, verifiable tasks already registered by the orchestrator. The worker does not alter their identities, criteria, or scopes. For each pre-authorized child:

1. Each child uses the `task_id` from its pre-authorized row (registered as a new ID by the orchestrator), `task_kind: subagent`, `parent_task_id` equal to the worker's `task_id`, `parentID` equal to the worker's confirmed native `sessionID`, and `location_directory` equal to `run.location.directory`.
2. Launch a new child session through the `subagent` capability the active catalog allows, with the location per the [single rule](subagent-contract.md#single-rule-for-child-location). Check the `sessionID`, real `parentID`, and location before counting it.
3. Use an `agent_id` from the active catalog. Repeating it for a distinct session is allowed.
4. Give it only the assigned child scope, minimal data, output format, criterion, and the required check.
5. Record and report the result/failure. Do not repeat uncertain launches until reconciling; a creation failure receives no invented ID and does not count toward the minimum.

If a pre-authorized task or scope needs to change, the worker stops that work and requests an update through the confirmed channel; it never modifies the ledger or creates a new row/scope. Without a confirmed dynamic channel, leave the request in the result the orchestrator can read and do not resume the changed work until the updated prompt arrives. If a child could not be created, advance only the other already-authorized independent tasks and report to the orchestrator the confirmed IDs, results, literal failure, and missing capability. Partially executed work stays `partial`; the worker does not declare itself `verified` or claim two children without the full gate.

## Step 7: Monitor and reconcile

- Wait for the session's documented signal and read the result with the [bounded result read](api-and-sessions.md#bounded-result-reading) and the [reconciliation rules](api-and-sessions.md#wait-reconciliation-rules): confirm the children with `GET /api/session?parentID=`, review pending permissions on every cycle, and re-arm the deadline only while the worker stays active (capped; then `outcome-unknown`). Do not poll without limit or duplicate prompts.
- Keep separate the literal `runtime_status`, the local `execution_outcome` (`unknown`, `succeeded`, `failed`, `interrupted`, `cancelled`), and the ledger's local `estado`.
- A timeout, disconnect, or missing notice does not prove the session stopped. Reconnect to the same endpoint; reconfirm location and IDs; use only reads/reconciliation documented in the active `/openapi.json`.
- Until reconciled, keep the child's scope and prevent the parent or an overlapping sibling from writing. Do not resend a request whose effect is uncertain.
- The orchestrator integrates the ledger with each worker report. If a worker could not create children, record which children do exist, their results, the failure, and the unmet minimum; do not turn that shortfall into success.

## Step 8: Inspect, integrate, and close

A worker's `verified` gate (minimum of two distinct subagents, correct `parentID` and location, `subagent_results_integrated` with the verified children's `task_id`s) is defined only in [ledger-template.md](ledger-template.md#verified-worker-gate). Here the worker reads the deliverables, checks each `criterion`, resolves contradictions by evidence, and leaves a synthesis integrating all verified results; the orchestrator inspects the worker's report and artifacts before closing its task.

- The mere existence of `output_path` or a terminal notification does not prove the criterion; an empty final message does not prove non-execution either (a turn can close after tool-calls with no text): verify artifacts and `git diff` before diagnosing.
- Linked evidence follows the [canonical format](ledger-template.md#evidence-format); the parent inspects the artifact, not just the shape of the note.
- A `blocked`, `failed`, `interrupted`, `cancelled`, `partial`, `launching`, `outcome-unknown`, `running`, `awaiting-approval`, or `completed` keeps its real result; none by itself satisfies the `verified` gate.
- The synthesis separates runtime facts, inferences, local conventions, sessions/IDs, missing children, and pending limits.

## Closing checklist

1. The real capabilities for creating, prompting, and waiting/reading (and, only if the user asked for tabs, opening/checking tabs) were discovered; any missing ones were reported with their source.
2. Server and location confirmed; every root worker received explicit `run.location.directory`, every child satisfied the [single rule for child location](subagent-contract.md#single-rule-for-child-location), checked with `GET /api/session/{childID}`, and every real location matches exactly.
3. Ledger schema 3: `run.min_subagents_per_worker: 2`; every row has coherent type, native/local parents, and location.
4. Every verified worker satisfies the [verified worker gate](ledger-template.md#verified-worker-gate) and its evidence follows the [canonical format](ledger-template.md#evidence-format).
5. Workers reported state and results; only the orchestrator modified the ledger.
6. Inherited scopes; overlapping siblings serialized; the parent did not write into active scopes; timeout reconciled before release.
7. If `run.max_sessions_in_flight` appears, it satisfies the [optional limit rule](ledger-template.md#optional-max_sessions_in_flight-limit).
8. Artifacts checked against criteria; limitations and pending integration points are recorded in the close-out.

### Failure paths

- If the catalog or `/openapi.json` does not confirm an operation, do not guess its name or call a speculative path.
- If session-creation, prompt-sending, result wait/read, or (only if tabs were requested) local tab exposure/verification capability is missing, name the absent capability and the source consulted exactly; block only the work that depends on it. The worker result is read from its session; do not assume an independent reporting channel.
- If the root worker did not receive the explicit location, or if any session's real location does not match the canonical one, do not send or count that work. If the [single rule for child location](subagent-contract.md#single-rule-for-child-location) is not satisfied, report the blockage.
- If the worker's policy does not allow `subagent`, or the child location does not satisfy the single rule, record the blockage; do not invent arguments or substitute the child session with a tab or another task kind.
- If scopes overlap, serialize; if an execution has uncertain state, keep the scope until reconciled.
- If fewer than two distinct children were created, record the IDs/results/failures and leave the minimum unmet (`partial` if progress was incomplete; never `verified`; see the [gate](ledger-template.md#verified-worker-gate)).
