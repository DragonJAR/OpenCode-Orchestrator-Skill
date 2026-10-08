# RSI_LOG — Recursive Self-Improvement on OpenCode-Orchestrator-Skill

## Scope

The recursive self-improvement applies to the public skill package:
`SKILL.md`, `LICENSE`, `references/`, `scripts/` (per `AGENTS.md`).
Excluded from RSI scope (AGENTS.md says "estos recursos son solo para
mantenimiento local. No los enlaces desde SKILL.md ni desde references/, y
no los incluyas en una distribución de la skill"):

- `.agents/`, `.atl/`, `.coordination/` — internal maintenance only.
- `.agents/maintenance/`, `.agents/maintenance/scripts/` — testing/iteration
  resources. Untouched.
- Root-level `README.md`, `README.es.md`, `CHANGELOG.md`,
  `INFORME-auditoria-20261001.md` — public docs, not the package.
- `analytics/`, `cache/`, `codegen/`, `collaboration/`, `learning/`,
  `memory/`, `predictive/`, `prompt-library/`, `swarm/`, `templates/`,
  `android-battery/`, `android-logs/`, `android-performance/`,
  `android-screenshots/` — not in git, foreign, untouched.
- `runs/` — tracked evidence from prior runs; left alone.
- `reports/` — tracked audit artifacts; left alone.
- `Skill-for-Claude.txt` — original prompt for creating the skill.

Pre-existing local changes are preserved: the parallel orchestrator session
and prior turns have already created committed work (cf. `git log`) —
none of that is to be touched.

## Reference projects with comparable objectives

Web searched for "OpenCode agent skill multi-agent orchestrator repository
github", "POSIX shell skill OpenCode testing shellcheck lint multi-OS", and
"Agent skill validator ledger YAML CI workflow reusable template". The three
references whose quality criteria I extract (without copying their
implementation):

1. [hyw007726/multi-agent-orchestrator-skill](https://github.com/hyw007726/multi-agent-orchestrator-skill)
   — multi-agent orchestrator with git-worktree isolation, scoped prompts,
   validation, restarts, multi-CLI. **Comparable architecture**: same
   two-level orchestrator pattern (orchestrator → workers → subagents). The
   relevant quality criteria they expose: scoped write budgets, restarts on
   stalled work, validation gates between phases.
2. [nopperabbo/bash-script-validator](https://skills.rest/skill/bash-script-validator-nopperabbo)
   — POSIX-sh + ShellCheck analysis. **Directly comparable validation**:
   same toolchain target (POSIX sh + POSIX awk). Their acceptance
   threshold: ShellCheck emits zero findings at the project's chosen level.
3. [daemon-blockint-tech/Agentic-Enteprises-Skill](https://github.com/daemon-blockint-tech/Agentic-Enteprises-Skill)
   — Agent skills with GitHub Actions validation + release workflow.
   **Comparable packaging**: same shape of one-port skill with public
   package contract. Their criterion: every PR runs a skill-validate
   workflow that checks structure and content before merge.

I do NOT copy their implementations. I extract only the *quality bar*
(ShellCheck clean; structured CI; scoped write boundaries) as the target,
and verify the current package against it.

## Environment

| Item | Value |
|---|---|
| Repository | OpenCode-Orchestrator-Skill |
| Package | `SKILL/` (35 tracked files, public) |
| Shell | `/opt/homebrew/bin/sh` (BSD/bash compatible) |
| shellcheck | 0.11.0 (GNU GPL v3) |
| awk | BSD awk (`/usr/bin/awk`) |
| python3 | Homebrew 3.14.8 |
| Git | `git` client + `origin/main` at SHA `afcffba5a2e73...` |
| Local HEAD | `afcffba5a2e73...` |
| GitHub remote | `https://github.com/DragonJAR/OpenCode-Orchestrator-Skill.git` |
| Live OpenCode instance | `http://127.0.0.1:49374` v2.0.22 (verified in turn 8) |
| Replica run | `runs/20261001-replica/` (the ledger the validators were built for) |

## Budget

- **Iterations**: 3 cycles maximum (then evaluate "tres ciclos consecutivos que
  exploren oportunidades distintas no encuentren mejoras aceptables").
- **Per cycle**: 1 small reversible improvement only.
- **Measurement budget**: one shellcheck re-run + one validator re-run + one
  `sh -n` re-run + one `python3` anchors re-run per cycle.
- **Resources**: the user's local macOS workstation + the already-running
  OpenCode instance + the replica run as a static fixture.

## Baseline (measured before any RSI change)

| Metric | Value | Notes |
|---|---|---|
| shellcheck findings (error / warning / info) | **0 / 33 / 22** | `SKILL/scripts/*.sh` + `SKILL/scripts/os/*.sh`; severity=error → 0 |
| `sh -n` failures (the 23 scripts) | **0** | |
| Validators strict (`runs/20261001-replica/ledger.yaml`) | **7 passed, 0 failed** | |
| Validators `--allow-degraded` | **7 passed, 0 failed** | |
| Validators `validate_dag.sh` | **4 passed, 0 failed** | |
| SKILL.md anchors → references | **24 / 24** | |
| LOC total in `SKILL/` | **4551 lines** | per file: orchestrate.sh=697, validate_ledger_closed=424, _common.sh=414, validate_dag=652, etc. |
| Time to run `orchestrate.sh preflight` (5 samples) | 0.74s, 0.82s, 0.75s, 0.78s, 0.81s | mean ≈ 0.78s |
| Time to run `preflight.sh` (5 samples) | 0.52s, 0.55s, 0.58s, 0.62s, 0.60s | mean ≈ 0.57s |
| Time to run `dragon_name.sh N` (5 samples) | 0.01s, 0.01s, 0.02s, 0.01s, 0.02s | mean ≈ 0.01s |

### Acceptance thresholds (before/after for each cycle)

A change is kept only if ALL hold:

- shellcheck errors stay at 0 (warning count may change; must be `<=` baseline
  unless I am deliberately fixing warnings, in which case the new count must be
  lower).
- `sh -n` failures stay at 0.
- Validators stay at `7/0 + 7/0 + 4/0` (within noise).
- Anclas `SKILL.md → references` stay at 24/24.
- LOC delta is bounded: a single cycle may add `≤ +20%` of the LOC it touches
  (i.e. no bloat).
- Performance for the touched hot path stays within `±10%` mean over 5 runs.

If a cycle does not produce a measurable improvement against baseline, it
is reverted and recorded in the log.

## Distinguishing pre-existing issues from regressions

All shellcheck warnings counted at baseline are **pre-existing** (they
preceded any RSI cycle). If a cycle introduces a *new* warning type or a
new shellcheck *error* level finding, that's a regression — the cycle is
reverted.

If a cycle does not change the count, that is NOT a regression. It is a
non-event.

## Not evaluated

Per the rules: "marca como no evaluado lo que no puedas comprobar".

- **Coverage**: this package has no formal test suite. I cannot evaluate
  line coverage in the conventional way (no tests to run). **Marked as
  not evaluated.**
- **Static type checking**: n/a; this is shell + awk + python, not a typed
  language. **Marked as not applicable.**
- **CI**: there is no `.github/workflows/`. I cannot claim "tests run on
  every commit". **Marked as not evaluated** (could be added as an
  improvement).
- **Security audit**: there is no automated SAST, only shellcheck. **Marked
  as not evaluated** beyond shellcheck + manual code review.
- **Performance regression suite**: only 5-sample timings of the touch hot
  path; not statistically robust. **Marked as not robust**.
- **Cross-OS live**: only macOS has been live-tested; linux/wsl/windows-gbash
  are validated by code review only. **Marked as not live-evaluated**.

## Cycles

### Cycle 1 — Quote `$AUTH` in curl calls in `orchestrate.sh`

- **Hypothesis**: shellcheck reports `SC2086 Double quote to prevent globbing
  and word splitting` for `$AUTH` in curl calls (22 info-severity findings,
  all in `orchestrate.sh`). Quoting the variable is a low-risk readability
  + robustness fix. Even when `$AUTH` is empty (the most common case), an
  unquoted empty parameter passes as a single empty argument; quoting does
  not change semantics but keeps the code uniform.
- **Pre-state**: shellcheck info count = 22; shellcheck warning count = 33.
- **Acceptance**: shellcheck info count `≤ 22`, errors stay 0, validators
  7/0 + 4/0, anchors 24/24, `sh -n` 0 failures, no change to replicas
  (orchestrate.sh smoke), LOC delta bounded.
- **Measurement of success**: shellcheck `--severity=info` count drops by the
  number of unquoted curl `$AUTH` references (target: drop by `≥ 18`).

## Cycle 2

TBD (chosen after Cycle 1 lands and is measured).

## Cycle 3

TBD.

## Final report

After all cycles, the log gets appended with:

- Number of cycles run.
- Per-cycle before/after metrics (shellcheck count, validators, anchors,
  sh -n failures, LOC).
- Kept vs reverted changes.
- Whether the "tres ciclos consecutivos que exploren oportunidades distintas no
  encuentren mejoras aceptables" stop criterion was hit, or whether the
  budget was exhausted, or whether a human-intervention blocker was hit.
- Residual risks + pending decisions.