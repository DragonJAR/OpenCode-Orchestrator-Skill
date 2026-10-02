# OpenCode V2 API and sessions

**Documentation cutoff:** 2026-09-30 (see [Versioning and dates](research-evidence.md#versioning-and-dates)). The V2 reference labels the HTTP surface experimental; session routes are also marked experimental. Before each use, confirm the endpoint, version, and schema published by `/openapi.json` on the active instance (see [Contract discovery](#contract-discovery)). "V2" names the product generation, not a promise of API stability. Nothing here authorizes access to an unauthorized instance. [API V2](https://opencode.ai/v2/docs/api/)

This package coordinates two levels: the orchestrator creates `worker_session` root sessions; each worker uses the native `subagent` tool to coordinate at least two distinct child sessions, integrate their results, and report to the orchestrator. The session HTTP API and the `subagent` tool are distinct mechanisms; creating an HTTP session does not invoke `subagent`. The `subagent` contract is in [subagent-contract.md](subagent-contract.md), and the single ledger schema in [ledger-template.md](ledger-template.md).

## Contract discovery

The instance's live schema is `GET {endpoint}/openapi.json` (OpenAPI 3.1, with the same authentication as the rest of the API). Evidence for the route (and that `/doc` belongs only to the V1 generation): canonical record in [research-evidence.md](research-evidence.md#versioning-and-dates). If you have the CLI, `opencode api` queries that schema by operation (`requires verification` for its flags with `--help` from your installation).

- **Guard:** a response that is HTML, is not JSON, or does not declare `openapi`/`paths` **is not a valid schema** (unknown routes can fall through to the web UI and return HTTP 200 with HTML). Treat it as "unverifiable schema" and apply Degraded mode.
- **Precedence:** the instance schema prevails over this skill. Do not use `/doc` or any other route to discover the contract unless the instance publishes it.

## Call transport

- **Preferred route:** `opencode api METHOD PATH [--data 'JSON_BODY'] [--param key=value] [--header name:value]` (also accepts an `operationId` from `/openapi.json`). The query string goes in the PATH (`/api/session?parentID=...`); in v2.0.21 `--param` is unverified for query params and may be silently ignored. It resolves the server and authentication for you, prints the response body, and, if HTTP is not 2xx, writes `HTTP STATUS` to stderr and exits with code 1. Source: `packages/cli/src/commands/commands.ts:100-115` and `handlers/api.ts` of tag `v2.0.21`; `--server`/`--standalone` and any other flag of your installation: `requires verification` with `opencode api --help`. The PATH may carry a query (`/api/session?parentID=ses_...`).
- **`curl` or another direct HTTP client:** requires the active service credential; do not hunt for secrets on your own. The only bounded exception is the one in [recipe-tui-tabs.md](recipe-tui-tabs.md#direct-http-authentication-only-if-needed); if it does not apply, use `opencode api` or block the call (R1).
- **Windows quoting:** the `--data 'JSON_BODY'` example uses POSIX single quotes; they break in cmd.exe or PowerShell. Run the call from Git Bash/WSL or escape the JSON double quotes per your shell, and validate with `GET` before the `POST`.
- **Own session and same instance:** if the shell exposes `OPENCODE_SESSION_ID` (variable observed in the v2.0.21 code; `requires verification` in your installation), use it as `run.root_session.sessionID` and check that `GET /api/session/$OPENCODE_SESSION_ID` answers 200 against the same server you will use; otherwise stop (wrong instance).
- Do not record credentials or authentication headers in the ledger, logs, or prompts.

## Root worker session: creating and opening a tab are distinct actions

1. **Preflight:** confirm authorization, instance via `GET /api/info`, version, and active `/openapi.json`. Obtain the canonical location from `GET /api/location` and from the orchestrator session. Session HTTP routes are experimental; invoke them only if the active `/openapi.json` publishes them. [API V2](https://opencode.ai/v2/docs/api/)
2. **Create session:** the schema of `POST /api/session` accepts `location`, and the location must be `run.location.directory` literally. Even though the public schema leaves `agent` and `model` optional, this skill's policy requires resolving them from the instance's active catalogs and sending them explicitly: use the exact ID of an available agent and the exact `model.id`/`model.providerID` pair; include `variant` only if the active catalog publishes it and the task requires it. Query the catalogs `GET /api/agent` and `GET /api/model` (or the equivalents the active `/openapi.json` publishes); do not pin `build` as an assumed value or invent model, provider, or variant. If there are no valid exact values or you cannot confirm them before creating the session, block the flow before `POST /api/session`. The full illustrative body is in [recipe-tui-tabs.md](recipe-tui-tabs.md). The API does not document `parentID` in the creation body. Save `response.data.id` as `sessionID` and check in `Session.Info` that `parentID` is `null` (absent = `null`, see `subagent-contract.md#single-rule-for-child-location`) and that `location.directory` is identical to the run's canonical directory; do not send `parentID` to mimic a GUI session. [Create session, API V2](https://opencode.ai/v2/docs/api/)
3. **Open tab (only if the user asked for tabs):** creating via HTTP does not open a TUI tab. In the documented TUI, `/sessions` or `Ctrl+X`, `L` returns to an existing session; tabs may be disabled by configuration. The plugin interface documentation also defines `context.ui.tabs.open(sessionID)`, `context.ui.tabs.list()`, and `context.ui.tabs.focus(sessionID)`. Use only a client control that is already available and authorized; this package does not install or provide plugin code. [TUI V2](https://opencode.ai/v2/docs/cli/tui/), [CLI plugin API: tabs](https://opencode.ai/v2/docs/build/plugins/cli/), [tabs configuration](https://opencode.ai/v2/docs/cli/config)
4. **Verify the tab (only if the user asked for tabs):** confirm the visible tab corresponds to the same registered `sessionID`, using `context.ui.tabs.list()` if that interface is available. The HTTP API does not enumerate tabs. If the client cannot verify the tab's identity, register the session as unverified and block the claim that it was opened; do not invent deep links. The `tabs.mode` option can be `auto`, `on`, or `off`. The version-dependent private local method is described in [recipe-tui-tabs.md](recipe-tui-tabs.md). [CLI plugin API: tabs](https://opencode.ai/v2/docs/build/plugins/cli/), [tabs configuration](https://opencode.ai/v2/docs/cli/config)
5. **Worker execution (optional handshake):** first confirm in the active `/openapi.json` that the same instance publishes both a send route and a read capability for the worker session; if not, do not send work and keep the state as blocked/unknown. In the default route the nonce handshake is **optional** (R3a): use it only if you need to confirm the round-trip channel (send a short challenge with a unique nonce, ask the worker to reply with it alone, and validate the exact `sessionID` and nonce). It is mandatory only in the tabs recipe, where it is required to verify that the tab corresponds to the session ([recipe-tui-tabs.md](recipe-tui-tabs.md)). The worker must use the agent and the native `subagent` tool its instance advertises. When finished, the orchestrator reads the integrated result from the same worker session with the [bounded read procedure](#bounded-result-read) and verifies result and evidence; do not assume direct messaging between root sessions. An open tab or an accepted send does not prove the worker replied. If you cannot read and verify its result, do not claim success.

If the authorized integration uses the TUI's private local state to open tabs, follow the versioned recipe and its concurrency conditions in [recipe-tui-tabs.md](recipe-tui-tabs.md); do not treat that file as a public API.

The location lives in the OpenCode server's environment. For Windows, Linux, and macOS, reuse the canonical `location.directory` served by the same instance literally; do not build paths with client-machine conventions, do not convert separators, and do not assume a client-local directory exists on the server. If orchestrator and worker use different instances or locations, stop. [API V2: location and session](https://opencode.ai/v2/docs/api/)

## Base path for sending and reading the result

Default route, only if the active `/openapi.json` publishes it (if it differs, use the published one and record the difference):

1. **Send:** `POST /api/session/{sessionID}/prompt` with `text` (required) and only the optional fields `/openapi.json` publishes. The send is not idempotent: do not repeat it without reconciling.
2. **Read:** `GET /api/session/{sessionID}/message` returns that session's projected, paginated history. If `/openapi.json` publishes `GET /api/session/{sessionID}/inbox`, use it to see durable work not yet delivered and reconcile both views before retrying.
3. **Verify:** determine termination with the [bounded read](#bounded-result-read) (`Session.Info.outcome`/`time.idle` or the `idle` message; `outcome` does not live in the assistant message), read the worker's report in the messages after the send, and contrast artifacts and evidence against the `criterion`. The response shape, the pagination, and how to link a prompt with its reply require verification in the active `/openapi.json`.

If the `/openapi.json` does not publish both routes (send and read) for the same session, apply the Degraded mode of [SKILL.md](../SKILL.md#degraded-mode).

## Bounded result read

The terminal marker of an execution is the `type: "idle"` message, which carries `outcome` (`succeeded`, `failed`, or `interrupted`); `Session.Info` exposes the same `outcome` (that of the last completed execution) and `time.idle` (the instant it was recorded). An assistant message does **not** have an `outcome`. The numbers are **default values**, adjustable per task.

1. **Before sending:** read `GET /api/session/{sessionID}` and save the prior `time.idle` and `outcome` (they may be missing), the instant of the send, and the most recent `messageID` (`last_messageID` pre-send, outside the ledger schema; the ledger's `before_messageID` field is reserved for documented forks, see [ledger-template.md](ledger-template.md)).
2. **Wait:** after an accepted send, repeat at a fixed interval (default 10 s) `GET /api/session/{sessionID}`, with a default deadline of 10 min and up to 3 windows (see reconciliation rules). The execution ended when `time.idle` exists and is later than the saved prior one; then `outcome` is this execution's. An `outcome` present without a new `time.idle` belongs to an earlier turn and is useless. Message-based alternative: `GET /api/session/{sessionID}/message?type=idle&order=desc&limit=1`; the route documents the parameters `type`, `order`, `limit`, and `cursor`, but the `type` enum shown by the reference does not list `idle` (`requires verification` in the active `/openapi.json`); if it does not accept it, read `?order=desc&limit=N` without the filter and look for the `idle` message after `last_messageID`.
3. **In each iteration**, apply the [wait reconciliation rules](#wait-reconciliation-rules): pending permissions, deadline, and re-arm.
4. **Optional shortcut:** `POST /api/experimental/session/{sessionID}/wait` ("wait for a session agent loop to become idle", returns 204 with no body) only if the active `/openapi.json` publishes it; its deadline is not documented, so bound it with your own deadline and read `outcome` afterwards with step 2. If a documented completion notification exists, use it instead of polling. An event stream may only be used if the schema lists it (`requires verification`).
5. If the deadline expires without a new `time.idle`: do not resend (R9, R10); reconcile according to the rules below.

## Wait reconciliation rules

- **(a) Children confirmed by the orchestrator (R14):** at completion or at deadline expiry, list `GET /api/session?parentID=WORKER_SESSION_ID` (also accepts `limit`, `order`, `directory`, `project`, `subpath`, `cursor`) and compare against the `subagent` rows. Never count an ID that appears only in the worker's report; verify each child with `GET /api/session/{childID}` (`parentID`, `location.directory`, `outcome`). A listed child that is not in the ledger is a finding: do not count it and report it.
- **(b) Pending permissions:** an HTTP worker has no human in the session; an `ask` rule leaves it blocked. In each iteration, query `GET /api/session/{id}/permission` for the worker and each active child (or `GET /api/permission/request`, which lists the pending ones by location). If one is pending, the local state moves to `awaiting-approval` (keeps slot and scope); it is not a timeout: escalate to the user with the exact resource and action (R4); it is only answered with `POST /api/session/{id}/permission/{requestID}/reply` (`decision`, `message`; `decision` values per `Permission.Reply`, `requires verification`) following the user's explicit decision or a prior authorization that covers exactly that request. Never auto-approve for convenience.
- **(c) Re-armable deadline:** the 10 min are a default deadline. On expiry, check whether the worker is still running (`GET /api/session/active`: absent sessions are inactive; or `Session.Info` without a new `time.idle`). If it is still active, re-arm another 10-min window up to a cap (default 3 windows, 30 min total, adjustable with the user). Once the cap is exhausted, or if you cannot determine whether it is still active, mark `outcome-unknown`, keep slot and scope, and reconcile (messages, `inbox` if published, artifacts). `POST /api/session/{id}/interrupt` interrupts the execution (the body accepts `resume=true|false`, and the response field `interrupted` is `false` if the session was already idle, `true` if the interrupt took effect); do not use it as automatic recovery, and record the effect. Before interrupting, check `time.updated`: if it is recent, the worker is still making progress and re-arming the deadline is appropriate; interrupt only on stalled activity.

## Experimental HTTP API

The list below orients reading, but does not replace the live schema. Confirm route, method, arguments, and responses in `/openapi.json`; the V2 reference marks this surface and the session routes experimental. [API V2](https://opencode.ai/v2/docs/api/)

| Published operation | Restricted use | Caution |
| --- | --- | --- |
| `GET /api/info`, `GET /api/location` | Server identity and location | By themselves they do not prove a tab is open |
| `GET /api/config` | Server configuration (via `opencode debug config`) | `requires verification` in the active `/openapi.json`; it does not replace local reading of the TUI tabs configuration ([recipe-tui-tabs.md](recipe-tui-tabs.md)) |
| `GET /api/agent`, `GET /api/agent/{agentID}`, `GET /api/model`, `GET /api/model/default` | Catalogs to resolve exact `agent` and `model` (they accept `location`) | Use the literal IDs; `model/default` may return `null` |
| `POST /api/session` | Create a session with explicit `location` | Does not open a tab or start the `subagent` tool; reconcile before repeating |
| `GET /api/session`, `GET /api/session/{sessionID}` | Find/read sessions; `?parentID=` lists the direct children | Verify the exact ID and `Session.Info.location`/`parentID`/`outcome`/`time.idle` |
| `GET /api/session/active` | Sessions with an execution in progress in that process; the absent ones are inactive | The shape of `data` is not documented |
| `POST /api/session/{sessionID}/interrupt` | Interrupt the execution (`resume=true\|false`) | Has effect; see [wait rules](#wait-reconciliation-rules) |
| `POST /api/experimental/session/{sessionID}/wait` | Wait for the loop to become idle (204) | Experimental; undocumented deadline; the wake-up mechanism `requires verification` |
| Message routes of a session | Send or read the conversation per the active contract | Non-idempotent effect when sending; do not invent routes or payloads |
| `GET /api/permission/request`, `GET /api/session/{sessionID}/permission`, `GET .../permission/{requestID}`, `POST .../permission/{requestID}/reply` | Query and answer approvals | Respect the human decision and the exact scope |
| `DELETE /api/session/{sessionID}` | Delete a session | **Published in the active v2.0.21 schema** (verified 2026-10-02; successful purge of 9 zombies). The documentation says it also deletes child sessions: check `GET /api/session?parentID=` first and ask for explicit approval (R7). Primary defense against stomps: dedup by title in `create-worker`. Additional caution: | **Published in the active v2.0.21 schema** (verified 2026-10-02; successful purge of 9 zombies). The documentation says it also deletes child sessions: check `GET /api/session?parentID=` first and ask for explicit approval (R7). Primary defense against stomps: dedup by title in `create-worker`. |

The creation schema enumerates `id`, `title`, `agent`, `model`, `location`, `metadata`, and `permissions` as optional body fields; that API optionality does not change this skill's policy of sending `agent` and `model` explicitly from the active catalogs. The session reference offers no parameter to turn an HTTP-created session into a TUI tab or to invoke the native `subagent` tool. [API V2](https://opencode.ai/v2/docs/api/)

## Identity, hierarchy, and ledger

Canonical identity and hierarchy — fields, the `verified` gate, and child checking —: [ledger-template.md](ledger-template.md) and [subagent-contract.md](subagent-contract.md); this section does not replicate the schema. The DAG expresses execution order, not ownership; the tab only presents a session.

A worker can be `verified` only through the gate of [ledger-template.md](ledger-template.md#verified-worker-gate). The orchestrator reads the worker session's integrated report through a read capability confirmed by the instance's `/openapi.json`; do not assume direct messaging between root sessions, or that a tab implies notification or reply. If no such verified channel exists, leave the result unknown and escalate.

On concurrency (`run.max_sessions_in_flight`, no default value), apply the single rule of [ledger-template.md](ledger-template.md#optional-limit-max_sessions_in_flight). Terminal and local states are reconciled per the active `/openapi.json` and the ledger.

## Assistant message `retry` field

`Session.Message.Assistant.retry` is optional metadata of an assistant message in the current schema published by `/openapi.json`; its exact shape requires verification on the active instance. It is not the runtime state `retry` observed in the `v2.0.19` snapshot (`idle`/`busy`/`retry`) nor is it equivalent to the terminal outcome of the idle message (`Session.Message.Idle.outcome`: `succeeded`, `failed`, or `interrupted`). Do not treat them as a single execution state. [API V2](https://opencode.ai/v2/docs/api/)

## Historical snapshot

The details of the `v2.0.19` tagged code (`completed`/`running` return of `subagent`, permission inheritance, compaction buffer floor, CLI flags) are not a current public contract and live in [research-evidence.md](research-evidence.md) (rows a.3, d.5, e.3, x.4, and x.5). Do not extrapolate them to another version.

## Primary sources

- [HTTP API V2](https://opencode.ai/v2/docs/api/) — routes, schemas, location, and experimental status.
- [TUI V2](https://opencode.ai/v2/docs/cli/tui/) — existing sessions and tabs navigation.
- [CLI plugin API](https://opencode.ai/v2/docs/build/plugins/cli/) — documented tabs methods for an existing plugin host.
- [CLI configuration](https://opencode.ai/v2/docs/cli/config) — `tabs.mode` and other presentation options.
- [Agents V2](https://opencode.ai/v2/docs/agents) and [Tools V2](https://opencode.ai/v2/docs/tools/) — agents, permissions, and the native `subagent` tool.
