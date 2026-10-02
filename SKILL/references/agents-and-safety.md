# Agents and safety

The catalog, permissions, and `/openapi.json` of the confirmed instance take precedence. The modes and permissions described here must be verified against that instance before each plan. The OpenCode V2 HTTP API is described as experimental. [V2 Agents](https://opencode.ai/v2/docs/agents), [V2 API](https://opencode.ai/v2/docs/api/)

## Agent selection for the two levels

The root worker agent is selected per the contract of the endpoint that creates the session; the native `subagent` tool is used afterwards inside that session. Do not confuse an API/session with the child tool.

| Built-in agent (if served) | Documented mode | Documented use |
|---|---|---|
| `build` | `primary` | Implementation in the main session |
| `plan` | `primary` | Planning in the main session |
| `general` | `subagent` | Multi-step work with broad tools |
| `explore` | `subagent` | Read and explore without editing: do not use it for a task whose `output_path` must be written |

For a subagent that must write its `output_path` use `general` (broad tool access; that it can edit in your instance `requires verification` in the catalog and effective permissions) or another agent whose effective policy permits editing that scope; or define that the worker writes that output from an `explore` report. These names are documentary references, not proof of availability or permissions. Confirm the ID and its mode in the active catalog. For each worker prepare at least two distinct subagent tasks and valid agents for them; do not try to launch `build` or `plan` as a child unless the instance publishes them with an allowed mode. [V2 Agents](https://opencode.ai/v2/docs/agents), [V2 Tools](https://opencode.ai/v2/docs/tools/)

## Permission rules

A permission rule includes action, resource, and effect (`allow`, `ask`, or `deny`). Review the effective policy of each session and resource, including read, edit, shell, and subagent launch; the worker's permission to invoke `subagent` does not grant its own capabilities to the child. The documentation describes that a child uses its effective configuration, which may differ from the parent's. [V2 Agents](https://opencode.ai/v2/docs/agents), [V2 Tools](https://opencode.ai/v2/docs/tools/), [V2 Permissions](https://opencode.ai/v2/docs/permissions/)

Do not assume that the lack of a specific rule equals denial, nor that a prompt instruction replaces controls. Review the order and scope of rules, saved approvals, and policies published by the instance. A pending approval keeps the resource reserved and the local state is not a terminal result.

The permission inheritance observed in code `v2.0.19` is historical implementation detail. The current pages do not promise that every child inherits the worker's rules; always confirm the effective policy. [Snapshot `session.ts` v2.0.19](https://github.com/anomalyco/opencode/blob/v2.0.19/packages/core/src/session.ts), [V2 Agents](https://opencode.ai/v2/docs/agents)

## Write budget and scopes

**This is the single definition of the scope rules** (R11 of [SKILL.md](../SKILL.md#hard-rules) summarizes it; the rest of the documents link here).

- Sharing server, session, or tab does not imply filesystem or workspace isolation; confirm location and effective permissions. The consulted sources do not document a file lock or a global concurrency limit.
- Each worker receives an explicit write budget from the orchestrator; each subagent's scope is an explicit subset of that budget (inheriting the parent's does not authorize a broader one).
- Siblings (children of the same worker, or root workers) with overlapping scopes are serialized with a DAG dependency: the second does not start until the first is verified-finished. The dependency chain expresses order, not ownership hierarchy.
- Parent and child: the worker integrates when the child finished. While a child is active or its result is unknown, the parent does not write in its scope (a nested scope is valid, simultaneous writing is not).
- A timeout does not free scope or capacity: keep the state as uncertain until reconciling execution, effects, and session.

See also [assignment patterns](agent-patterns.md), [V2 Tools](https://opencode.ai/v2/docs/tools/) and [V2 API](https://opencode.ai/v2/docs/api/).

## Verification evidence

A worker is only marked `verified` with the gate from [ledger-template.md](ledger-template.md#verified-worker-gate). The single orchestrator maintains the ledger and confirms the evidence. `failed`, `blocked`, and `partial` describe legitimate outcomes and do not require inventing missing children.

## Portable location

The `location.directory` value corresponds to the OpenCode server project. Query and validate the run's canonical location on the same instance and pass it literally when creating the root worker session; for children the [single rule for child location](subagent-contract.md#single-rule-for-child-location) applies (inherited or passed if the tool schema exposes it, and verified via `GET /api/session/{childID}`). Do not reconstruct it from a local Windows, Linux, or macOS path nor read secrets from per-OS-specific locations. If the instance does not confirm that all sessions share the exact directory, block dispatch. [V2 API](https://opencode.ai/v2/docs/api/)

Only if the user asked for tabs and you need to display them through private local state, use only the versioned flow and its safety gates described in [recipe-tui-tabs.md](recipe-tui-tabs.md); prefer the documented tab interface when it is already available.

## Official sources

- [V2 Agents](https://opencode.ai/v2/docs/agents) — modes, catalog, and selection.
- [V2 Tools](https://opencode.ai/v2/docs/tools/) — native `subagent` tool.
- [V2 Permissions](https://opencode.ai/v2/docs/permissions/) — permissions and approvals.
- [V2 HTTP API](https://opencode.ai/v2/docs/api/) — location and sessions; experimental surface.