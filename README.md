# OpenCode Orchestrator Skill

> Two-level coordination and auditing skill for OpenCode agents and sessions.

## Overview

This skill enables an orchestrator agent to coordinate multiple OpenCode workers and subagents in a structured two-level hierarchy (`worker_session` → `subagent`). It manages session lifecycle, ledger tracking (schema version 3), write scopes, and closing evidence validation.

## Structure

- [`SKILL/SKILL.md`](SKILL/SKILL.md): Main skill specification, hard rules (R1–R14), decision gates, execution steps, and output contract.
- [`SKILL/references/`](SKILL/references/): In-depth operational guides:
  - `playbook.md`: 8-step operational workflow and closing checklist.
  - `ledger-template.md`: Canonical YAML ledger schema, verification gates, and validator rules.
  - `subagent-contract.md`: Native `subagent` tool contract, preflight, location rules, and nesting depth.
  - `prompt-templates.md`: Structured prompt templates for workers, subagents, forks, and reporting.
  - `api-and-sessions.md`: OpenCode HTTP API reference, bound result reading, and reconciliation rules.
  - `decision-trees.md`: Decision trees for preflight, children, concurrency, and closing.
  - `failure-matrix.md`: Observable failure modes, recovery actions, and anti-patterns.
  - `agents-and-safety.md`: Agent catalog selection, write budgets, and scope isolation.
  - `recipe-tui-tabs.md`: Direct HTTP authentication and local TUI tabs recipe.
- [`SKILL/scripts/`](SKILL/scripts/): POSIX shell validators:
  - `validate_dag.sh`: Structural DAG and ledger schema validator.
  - `validate_ledger_closed.sh`: Final closing gate validator for completed and degraded runs (`--allow-degraded`).

## Validation

Run the validators from the workspace root:

```bash
# Validate ledger DAG and structure in flight:
sh SKILL/scripts/validate_dag.sh <path-to-ledger>

# Validate ledger closure (strict verified mode):
sh SKILL/scripts/validate_ledger_closed.sh --require-evidence <path-to-ledger>

# Validate ledger closure with terminal degraded states (partial, blocked, failed):
sh SKILL/scripts/validate_ledger_closed.sh --allow-degraded <path-to-ledger>
```

## License

[MIT](SKILL/LICENSE) © 2026 DragonJAR.org
