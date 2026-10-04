# OpenCode V2 operational patterns

This index summarizes the two-level flow. The orchestrator owns the ledger and creates root `worker_session`s; each worker coordinates at least two native `subagent` sessions, integrates evidence, and returns a report to the orchestrator. The fields and verification criterion live in the [canonical ledger template](ledger-template.md); the child tool contract, in [subagent-contract.md](subagent-contract.md).

| Need | Mechanism | Canonical reference |
|---|---|---|
| Create a root session for a worker | `POST /api/session` with explicit `location.directory`; the V2 HTTP API is experimental | [API and sessions](api-and-sessions.md) |
| Show the root session in the TUI (only if the user asked for tabs) | Separate action of opening an already-created session/tab; verify the tab by `sessionID` with a documented client interface that is available | [API and sessions](api-and-sessions.md), [decision trees](decision-trees.md) |
| Delegate worker work | Native `subagent` tool inside the worker session; minimum two distinct children for a `verified` worker | [Subagent contract](subagent-contract.md), [assignment patterns](agent-patterns.md) |
| Order tasks | Orchestrator DAG; dependencies express order, not ownership; root workers with overlapping scopes go in order | [Playbook](playbook.md), [decision trees](decision-trees.md) |
| Wait, reconcile, or recover | Use the result mechanism confirmed by the instance; when losing it verify inbox, messages, approval, outcome, and effects per `/openapi.json` | [Subagent contract](subagent-contract.md), [failure matrix](failure-matrix.md) |

HTTP creation does not open a tab nor call `subagent` (invariant and tab mechanisms, canonical in [api-and-sessions.md](api-and-sessions.md#root-worker-session-creating-a-session-and-opening-a-tab-are-distinct-actions)). The package does not include plugin code. If the available interface does not allow verifying that the visible tab has the created ID, record the verification as incomplete. [V2 API](https://opencode.ai/v2/docs/api/), [V2 TUI](https://opencode.ai/v2/docs/cli/tui/), [CLI plugin API](https://opencode.ai/v2/docs/build/plugins/cli/)

For the local, versioned, non-public alternative that writes `tabs.json`, see [recipe-tui-tabs.md](recipe-tui-tabs.md); it requires channel, scope, CWD, and schema verified.

Use the same canonical `location.directory` served by the instance for the orchestrator and workers (children inherit it per the [single rule for child location](subagent-contract.md#single-rule-for-child-location)), without rewriting paths by the client OS; for children the [single location rule](subagent-contract.md#single-rule-for-child-location) applies: if the tool does not expose location, inheritance is acceptable and do not invent a `location` field. The consulted sources do not publish a global session cap. Do not add a fixed concurrency value: apply the single rule from [ledger-template.md](ledger-template.md#optional-max_sessions_in_flight-limit). [V2 API](https://opencode.ai/v2/docs/api/)

The scope rules (budget, overlaps, parent/child, timeout) live in a single section: [Agents and safety](agents-and-safety.md#write-budget-and-scopes); see also the [decision trees](decision-trees.md).