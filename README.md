# OpenCode Orchestrator Skill

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/badge/release-1.8.0-green.svg)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-OpenCode%20V2-8A2BE2.svg)](https://opencode.ai)
[![Author](https://img.shields.io/badge/author-DragonJAR%20SAS-orange.svg)](https://www.DragonJAR.org)
[![Español](https://img.shields.io/badge/read%20in-Espa%C3%B1ol-blue.svg)](README.es.md)

> Fail-closed two-level multi-agent orchestration for OpenCode V2. Provides a reusable **`[NN] Name` worker pool**, a deterministic **POSIX command layer** (**17 subcommands**), a **Schema 3 YAML ledger** enforced by two `sh` + `awk` validators, and **16 hard rules** that stop execution instead of guessing.

## Core Architecture

`init-run` provisions `[00] Orchestrator` and installs the [router instruction](SKILL/scripts/prompt-templates/router-orchestrator.md) as its first prompt. The orchestrator stays a lightweight coordinator with a clean context window and performs only two actions:

| Move | Mechanism | Guarantee |
|---|---|---|
| **Monitor** | `pool`, `wait-idle`, `watch` | Tracks worker states (`empty`, `idle`, `running`), artifacts, and `awaiting-approval` transitions with bounded timeouts. |
| **Route** | `dispatch --target NN`, `--count N`, `--auto-count` | Sends each task to the best-suited worker (or fan-out) by scope and availability; `[00]` is never a task target. |
| **Never implement** | Router prompt + R3 two-level gate | Workers execute and coordinate at least 2 native `subagent` children; the orchestrator never writes deliverables. |

## Quick Start

```sh
# 1. Discover endpoint, OpenAPI 3.1 schema, catalogs, model pair, and TUI gate (once per project)
sh SKILL/scripts/orchestrate.sh preflight .

# 2a. Full two-level run: create [00] root + named workers and attach TUI tabs if gate=ready
# (in a two-level run the prompt file carries the pre-registered child rows; R16 omits them)
sh SKILL/scripts/orchestrate.sh init-run --worker "Auth audit" --worker "Billing audit"
sh SKILL/scripts/orchestrate.sh dispatch --prompt-file ./task.md --target 01
sh SKILL/scripts/orchestrate.sh wait-idle --session ses_xxx --deadline 600
sh SKILL/scripts/orchestrate.sh verify-daughters --worker-id ses_xxx --expected-parent ses_xxx
sh SKILL/scripts/validate_ledger_closed.sh --require-evidence runs/<run>/ledger.yaml

# 2b. Readiness check (light path, R16 — labeled degraded, no child subagents required)
sh SKILL/scripts/orchestrate.sh init-run --count 4
sh SKILL/scripts/orchestrate.sh dispatch --prompt-file ./ping.md --count 4 --wait
sh SKILL/scripts/orchestrate.sh pool
sh SKILL/scripts/orchestrate.sh clean --yes
```

Every subcommand emits parseable `key=value` lines and meaningful exit codes:

```text
worker_id=ses_e9aaf9eafffeXYvpc190MAVeFY
location=/path/to/project
parentID=null
```

## Command Layer & Validators

Run via `sh SKILL/scripts/orchestrate.sh <subcommand> [args]` (all **17 subcommands** support `--flag value` and `--flag=value`):

| Group | Subcommands | Operational Contract |
|---|---|---|
| **Discover** | `preflight`, `self-check`, `sessions`, `pool`, `session-id` | Resolves live server identity, catalogs, session inventory, `[NN]` worker states (`empty`/`idle`/`running`), and compact IDs (`01`, `01s02`). |
| **Provision** | `ensure-root`, `create-worker`, `init-run` | Lock-protected (`lock_exec` via `python3 fcntl`), slug-deduplicated creation. Reuses `empty`/`idle` workers; refuses `running` collisions unless `--force-new`. |
| **Execute & Monitor** | `dispatch`, `send-prompt`, `wait-idle`, `watch`, `verify-daughters` | Validates resolved `model.id` before sending, blocks task prompts to `[00]`, polls with stuck detection (`exit 4`), and verifies R14 child `parentID` + `location`. |
| **TUI Visibility** | `tabs`, `attach-tabs` | Read-only `2.x` TUI gate (`tabs`) and locked, schema-checked, read-back verified `tabs.json` merge (`attach-tabs`). |
| **Teardown** | `delete-session`, `clean` | R7-gated deletion: enumerates children, requires `--yes` (or interactive `yes`), purges dead cache keys, and prunes `tabs.json` in topological leaf-first order. |

**Standalone Ledger Validators** (pure POSIX `sh` + `awk`, sharing `SKILL/scripts/_validators.awk`):
- `sh SKILL/scripts/validate_dag.sh LEDGER_PATH` — validates Schema 3 syntax, run/session identity, acyclic DAG, disjoint write scopes, and the 2-subagent worker gate.
- `sh SKILL/scripts/validate_ledger_closed.sh [--require-evidence] [--allow-degraded] LEDGER_PATH` — runs `validate_dag.sh` plus terminal closure, artifact containment, and evidence verification (`criterion`, `result: "pass"`, `observed`, `subagent_results_integrated`).

## Hard Rules & Fail-Closed Guarantees

Defined in [`SKILL.md`](SKILL/SKILL.md) and backed by **15 references** in [`SKILL/references/`](SKILL/references/):

| Rule | Principle | Enforcement |
|---|---|---|
| **R1–R2** | **Access & Background** | Never simulate execution without live access; use background mode only when published in `/openapi.json` with a bounded read path. |
| **R3** | **Two Levels (`worker` → `≥2 subagents`)** | Root workers have `parentID: null`; each verified worker integrates at least 2 distinct child `subagent` sessions (no 3rd tier). |
| **R4–R5** | **Permissions & Child Policy** | Honor `ask`/`deny` rules; parent `subagent` permissions gate which agents launch, while each child's policy governs its own tools. |
| **R6** | **Self-Contained Context** | Every prompt carries task ID, canonical `location.directory`, write scope, boundaries, and measurable acceptance criteria. |
| **R7–R8** | **Destructive Gate & Continue/Fork** | Deletions require explicit approval (`--yes`); continuing keeps `sessionID` after reconciliation, whereas `fork` creates a new ID. |
| **R9–R10** | **Interruptions & Non-Idempotency** | Missing notifications never imply success or halt; inspect session state, inbox, and disk artifacts before any retry. |
| **R11–R12** | **Disjoint Scopes & State Separation** | Overlapping write scopes require a DAG dependency; `runtime_status`, `execution_outcome`, and ledger `estado` stay separate. |
| **R13** | **Live Capabilities & Router Role** | Resolve routes/models dynamically from `/openapi.json`; `[00]` only monitors and routes (`R13e`), and tabs never substitute for `sessionID` (`R13a`). |
| **R14** | **Untrusted Content & File Ownership** | Verify child IDs via `GET /api/session?parentID=WID`; the orchestrator never overwrites worker `output_path` or `evidence_refs` (`R14a`). |
| **R15–R16** | **Run Registry & Right-Sized Runs** | Never ask the user for a `sessionID` already in the ledger/cache; readiness checks skip R3 and close as **degraded**, never `verified`. |

**Built-in defenses:**
- **No credential leaks:** Rejects non-loopback HTTP endpoints and URLs with `@` userinfo; reads `service.json` passwords into `chmod 600` cache files and redacts secrets on JSON cache writes.
- **No symlink or torn-write poisoning (CWE-59):** Refuses symlinked cache directories/keys and publishes cache updates atomically via same-directory `mktemp` + `mv -f`.
- **No silent truncation:** Cursor pagination (`api_get_all_pages` and `clean`) retries transient malformed pages once and fails closed if malformed or if the 30-page cap is hit with pages pending.

## Installation, Verification & Structure

The runtime reads `<skills-dir>/<name>/SKILL.md`, and the package's `SKILL.md`
lives in the repository's `SKILL/` folder: **that folder is what gets
installed**, renamed to the frontmatter `name`.

```sh
# Into an agent's skills directory (~/.agents/skills/, ~/.config/opencode/skills/, ...)
mkdir -p ~/.agents/skills/opencode-orchestrator-skill
rsync -av --delete --exclude '.git' --exclude '.agents' \
  /path/to/OpenCode-Orchestrator-Skill/SKILL/ ~/.agents/skills/opencode-orchestrator-skill/

# Or develop against the clone: the install follows your working tree
ln -s /path/to/OpenCode-Orchestrator-Skill/SKILL ~/.agents/skills/opencode-orchestrator-skill
```

### Requirements & Local Verification

Requires **POSIX `sh`**, **`awk`**, **`python3`** (with `fcntl` for locks/tabs; MSYS2 Python on Windows Git Bash), **`curl`**, and **OpenCode V2 (`2.x`)**.

```sh
# Syntax, linter, and distributable ZIP build (enforces the closed file list)
find SKILL/scripts -name '*.sh' -exec sh -n {} \;
shellcheck --severity=error SKILL/scripts/*.sh SKILL/scripts/os/*.sh
sh SKILL/scripts/package.sh
sh SKILL/scripts/orchestrate.sh self-check
```

```text
OpenCode-Orchestrator-Skill/
├── .github/workflows/ci.yml     # Cross-OS CI (Linux, macOS, Windows Git Bash)
├── .gitattributes               # LF line endings for every shipped text file
├── .gitignore                   # Strict whitelist: only the package is published
├── README.md / README.es.md     # English and Spanish documentation
├── CHANGELOG.md / LICENSE       # Release history and MIT license
└── SKILL/                       # Distributable skill package
    ├── SKILL.md                 # Agent specification and decision gates
    ├── references/              # 15 operational references (playbook, ledger, API, TUI, failure matrix)
    └── scripts/
        ├── orchestrate.sh       # Multi-OS CLI (17 subcommands) + orchestrate-{darwin,linux,wsl,windows}.sh
        ├── preflight.sh         # Instance discovery, capability checks, and TUI gate cache
        ├── watch_run.sh         # Standalone POSIX+awk session and artifact watcher
        ├── validate_dag.sh      # Schema 3 DAG, scope, and worker-gate validator
        ├── validate_ledger_closed.sh  # Terminal closure and evidence validator
        ├── _json.awk / _validators.awk  # Shared JSON extractor and validator path/YAML library
        ├── dragon_name.sh / package.sh  # Deterministic worker naming and closed-list packager
        ├── os/                  # Shared core (_common.sh, _paths.sh, tui-detect.sh) + OS adapters
        └── prompt-templates/    # Canonical [00] router prompt (router-orchestrator.md)
```

## Contributing

- **POSIX `sh` + `awk`, LF line endings** (`.gitattributes`): the scripts run on dash, bash and Git Bash.
- **The CI must pass**: shellcheck at error level, `sh -n`, the awk libraries, the POSIX dialect, the dead-variable check, the command table against the code, and the version coherence.
- **The closed list must match the tree**: `SKILL/scripts/package.sh` fails when a file is missing from the list or the tree carries one the list does not know.
- **Show the evidence for a behavioural change**: a fixture that fails before the change and passes after it.
- Conventional Commits.

## Author & License

Created by **DragonJAR SAS** ([www.DragonJAR.org](https://www.dragonjar.org) · [Servicios de Seguridad Informática](https://www.dragonjar.org/servicios-de-seguridad-informatica)). Released under the [MIT License](LICENSE).
