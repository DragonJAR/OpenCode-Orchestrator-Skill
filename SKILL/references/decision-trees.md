# Decision trees — two-level OpenCode V2 flow

The active instance contract and the [canonical ledger template](ledger-template.md) take precedence. V2 session HTTP routes are marked experimental; verify against the `/openapi.json` of the confirmed endpoint before calling them. [V2 API](https://opencode.ai/v2/docs/api/)

## Tree 1 — Are instance, location, and controls confirmed?

Before creating a session or delegating:

- Confirm authorization and instance with `GET /api/info`; check `/openapi.json` on that same endpoint for version and available routes.
- Obtain the location from `GET /api/location` and compare it with the orchestrator session. Fix a single canonical `run.location.directory`.
- If the user asked to see the sessions as tabs, check that the TUI's effective tabs mode is not `off` (explicit `tabs.mode` `on`, or `auto` without `HERDR_ENV=1` in the TUI process, or legacy `tabs.enabled: true` without `mode`; full rule in [recipe-tui-tabs.md](recipe-tui-tabs.md) §3) and that the client allows opening the existing session and verifying the tab by `sessionID`; if the user did not ask for tabs, an unverifiable tab does not block (mark "not verified"; see Degraded mode in [SKILL.md](../SKILL.md#degraded-mode)). Creating the session over HTTP does not open the tab (invariant and tab mechanisms: [api-and-sessions.md](api-and-sessions.md#worker-root-session-creating-and-opening-tab-are-distinct-actions)). [V2 TUI](https://opencode.ai/v2/docs/cli/tui/), [CLI plugin API](https://opencode.ai/v2/docs/build/plugins/cli/), [CLI config](https://opencode.ai/v2/docs/cli/config)
- Inspect the catalog of agents, modes, and effective permissions. Confirm the worker can use `subagent`, that the two chosen child agents exist, and that they can run as children. [V2 Agents](https://opencode.ai/v2/docs/agents), [V2 Tools](https://opencode.ai/v2/docs/tools/)

    Are instance, location, permissions, and tools confirmed (and, if the user asked for tabs, the ability to open and verify the tab confirmed)?
    ├── NO  → Record the missing preflight; do not claim success or send work.
    └── YES → Tree 2.

Routes must refer to the OpenCode server filesystem. For Windows, Linux, and macOS pass the canonical value without transforming it by the client system; if it does not correspond to the same instance/location, stop. [V2 API](https://opencode.ai/v2/docs/api/)

## Tree 1b — Which title nomenclature and how do I pass the worker list?

Before creating sessions, decide how they will be named. The canonical pattern is `[NN] Name` (detail in [naming-convention.md](naming-convention.md)):

- **`[00]`** is always the orchestrator root's slot: `init-run` creates it alone, and `--title` changes the name, not the number.
- Workers start at **`[01]`** and follow correlatively. The interface applies the correlative and **reassigns an explicit `[00]`** to the next free ordinal.
- The proper name describes the scope (`[01] Vermithrax` for offensive analysis); the run ID already lives in the ledger, so the title does not repeat it.

How do I pass the worker list?

    ├── Titles with spaces? (almost always yes, they are readable)
    │     ├── YES → `--worker "T1" --worker "T2"` (one flag per session; unambiguous)
    │     │        or `--workers "T1, T2"` (comma-delimited list)
    │     └── NEVER → `--workers "T1 T2"`: the space is part of the title,
    │                  not a delimiter; it would split each title into two sessions.
    └── Without a number and want it auto-numbered?
          └── YES → `worker_list` assigns `01, 02, 03...` in entry order.

Dedup compares by **name ignoring the ordinal**, so `--worker "Vermithrax"` reuses `[01] Vermithrax` instead of creating a duplicate. If `init-run` responds `INCOMPLETO` and exits 1, some worker was not created: rerun with the same titles and dedup completes what was missing. [Nomenclature](naming-convention.md)

## Tree 2 — Can the root worker be started with verifiable identity?

    Does the orchestrator have a documented route to create the worker session?
    ├── NO  → Leave the run blocked with the missing access/capability.
    └── YES → Separately create a root `worker_session` with an explicit
                `location.directory` equal to `run.location.directory`.
                Confirm `sessionID`, `parentID: null`, and `Session.Info.location`.
                Only if the user asked for tabs: open that same session in the TUI
                and verify the tab with that ID (creation by API does not open the
                tab); otherwise mark the tab "not verified" and proceed.
                The API is experimental.

If the current HTTP API is not authorized or cannot verify server, session, or location, do not substitute it with private client routes. If the session was created but the tab could not be verified, keep the session as such and mark the opening as not verified; reconcile before retrying. [V2 API](https://opencode.ai/v2/docs/api/), [V2 TUI](https://opencode.ai/v2/docs/cli/tui/)

When the authorized integration includes the local private-state method, follow its version and concurrency gates in [recipe-tui-tabs.md](recipe-tui-tabs.md); the recipe may fail-closed if it cannot prove it modifies the correct TUI state.

## Tree 3 — Does the worker have a valid child plan?

The worker divides its write budget into tasks whose scope fits within its own. Each child uses the native `subagent` tool from the worker session; each child must have its own `sessionID`, a real `parentID` of the worker, and location per the [single rule](subagent-contract.md#single-rule-for-child-location). The session API is not the `subagent` tool nor does it invoke it. [V2 Tools](https://opencode.ai/v2/docs/tools/), [V2 API](https://opencode.ai/v2/docs/api/)

    Are there at least two distinct child tasks and valid agents?
    ├── NO  → Replan; do not mark the worker `verified`.
    └── YES → Do their write scopes overlap?
        ├── YES → Serialize with a dependency ([scope rule](agents-and-safety.md#write-budget-and-scopes)).
        └── NO  → Can run in parallel if they do not compete for another resource.

A worker only reaches `verified` with the gate from [ledger-template.md](ledger-template.md#verified-worker-gate); it may remain `failed`, `blocked`, or `partial` without faking the minimum.

## Tree 4 — Can it run now without conflict or invented limit?

    Is there a pending dependency or shared scope/resource in parallel?
    ├── YES → Serialize per the DAG and wait for each writer to finish.
    └── NO  → Does the ledger record an observed real limit in
              `run.max_sessions_in_flight` with evidence?
        ├── YES → Count active workers and subagents; keep a reserve for
        │         unknown state and pending approvals.
        └── NO  → Do not impose a fixed, unobserved number. Launch based on observed
                  resources and scopes, keeping dependency order.

The DAG represents execution order, never parent-child ownership. Ownership is expressed with `task_kind`, `parent_task_id`, and the observed runtime `parentID`. The optional limit is defined in [ledger-template.md](ledger-template.md#optional-limit-max_sessions_in_flight); local states live in the ledger. [V2 API](https://opencode.ai/v2/docs/api/)

## Tree 5 — Did the worker integrate and report enough evidence?

    Were every result, effect, and approval of the two levels reconciled?
    ├── NO  → Keep the unknown/active state, preserve occupied scopes,
    │         and reconcile by mechanisms published in the `/openapi.json`
    │         ([wait rules](api-and-sessions.md#wait-reconciliation-rules):
    │         children by `parentID`, envelopes, deadline re-armable).
    └── YES → Does the worker's report inspect and integrate the children and cite
              verifiable evidence?
        ├── NO  → Mark `partial` or `blocked`; request the missing information.
        └── YES → The orchestrator validates evidence, updates the single-owner
                  ledger, and marks `verified` only if the minimum is met.

Do not infer that the tab, a stream silence, or a summary alone proves completion. The return channel and responses must be confirmed by the instance; if they cannot be read, the result is not verifiable. [Failure matrix](failure-matrix.md), [API and sessions](api-and-sessions.md)

## Tree 6 — Is the next action destructive?

    Does it delete sessions, children, or persistent data?
    ├── YES → Stop; require authorization for the exact ID and confirm the cascade
    │         effect in the active `/openapi.json`.
    └── NO  → Proceed within the authorized scope and record evidence.

## Official sources

- [V2 HTTP API](https://opencode.ai/v2/docs/api/) — sessions, location, and schemas; experimental surface.
- [V2 TUI](https://opencode.ai/v2/docs/cli/tui/) — open and switch sessions.
- [CLI plugin API](https://opencode.ai/v2/docs/build/plugins/cli/) — tab opening and listing in an existing interface.
- [CLI config](https://opencode.ai/v2/docs/cli/config) — tabs mode and scope.
- [V2 Agents](https://opencode.ai/v2/docs/agents) and [V2 Tools](https://opencode.ai/v2/docs/tools/) — catalog, permissions, and native delegation.