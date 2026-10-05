# Session title nomenclature

Canonical reference for the `[NN] Name` pattern. `SKILL.md` summarizes it; the detail, rationale, and limits live here.

## `[00]` is the orchestrator's slot, always

The `00` ordinal is reserved for the root session. This is not a paperwork convention: **the code enforces it**.

- `init-run` always creates the root, with or without `--title`.
- The default name is `Orquestador`, so the root is called `[00] Orquestador` without you having to type it.
- `ensure-root` normalizes with `title_normalize 0`, which **forces** the ordinal: `--title "My Run"` produces `[00] My Run`, and an explicit `[07]` is corrected to `[00]`. `--title` changes the name, never the number.
- Workers start at `01`, and `worker_list` **reassigns an explicit `[00]`** to the next free ordinal. Two `[00]` slots would make the run's identity ambiguous: not allowed.
- **The correlative lives within one invocation.** `init-run` assigns `01, 02, 03...` to the `--worker`s of that call; if you call it again to add workers, the counter **resets to `[01]`** and you'll end up with two sessions sharing the same ordinal. One run, one `init-run` invocation with all its workers.

Why: if `00` depended on the operator remembering, the first session of the run would be as likely as any other and the convention would degrade on first use. Centralizing it in `title_normalize 0` makes it inevitable.

```sh
orchestrate.sh init-run --worker "Vermithrax"
# root=[00] Orquestador -> ses_...
# created [01] Vermithrax -> ses_...

orchestrate.sh init-run --title "Q3 Audit" --worker "Vermithrax"
# root=[00] Q3 Audit -> ses_...     (same slot 00, different name)
```

## Pattern

**`[NN] Name`** — two-digit sequential ordinal, one space, human-readable name.

```
[00] Orquestador      root / orchestrator
[01] Vermithrax       worker 1
[02] Glacielle        worker 2
[03] Tempestad        worker 3
```

## Why this shape

- **Zero-padded, correlative.** Lexical order matches numeric order: `[00] < [01] < [20]` sorts correctly in the TUI, in `orchestrate.sh sessions`, and with `sort`. A `[9]` without zero would interleave badly.
- **`[00]` reserved for the root.** Distinguishes the orchestrator from its workers at a glance, and the worker correlative starts at `01`.
- **One space, not a dot or dash.** The TUI renders the title and the space is the most readable separator; `[00]Orquestador` and `00-Orquestador` read worse.
- **The proper name carries the scope.** `[01] Vermithrax` says something about the worker without opening anything; `[W1]20261001-t3t3` says nothing. The run ID already lives in the ledger and in `runs/RUN_ID/`, so the title does not repeat it (DRY).
- **The ledger `task_id` (`W1`, `S1a`) does not change.** It is the stable key; the title is the readable identity. Renaming does not invalidate the ledger or its validations.

## Known limits

These are not hidden defects; they are the price of the decisions above:

- **Above `[99]`** the width grows to three digits and lexical order stops matching numeric order (`"100" < "99"`). Split the run instead of continuing to number.
- **Because it is correlative without gaps**, inserting a worker in the middle forces renumbering the following ones. If you expect to grow throughout the run, reserve gaps by hand (`[01]`, `[05]`, `[10]`) instead of letting the correlative fill them.
- **A title with spaces breaks a space-separated list.** This is not a defect of the pattern: it is why `--worker` exists (see below).
- **The pattern is enforced only at creation.** `/openapi.json` (verified in v2.0.22) does not publish a session-rename endpoint. `title_normalize 0` and `worker_list` apply the rule only when `ensure-root` / `create-worker` / `init-run` build a new session. If an existing session has a non-canonical title (created via a direct `POST /api/session` call, or one promoted from a previous run), the scripts do not (and cannot) rename it; use the TUI's `/sessions` view to rename by hand. The pool still parses the ordinal out of any title that does carry `[NN]` and shows the actual slug verbatim when it does not.

## Space is not a list delimiter

A title contains a space by design, so the worker list **cannot** be space-separated: `--workers "W1 Vermithrax"` is ambiguous and would create two sessions.

```sh
orchestrate.sh init-run --worker "Vermithrax" --worker "Glacielle"   # ok, unambiguous
orchestrate.sh init-run --workers "Vermithrax, Glacielle"            # ok, comma-delimited
orchestrate.sh init-run --workers "W1 Vermithrax"                    # WRONG: 2 sessions
```

`--worker` is the recommended path: one flag per session, no ambiguity.

## Automation (DRY)

Do not write the pattern by hand: the scripts already apply it. Both live in `scripts/os/_common.sh` and are the only implementation of the pattern.

- **`title_normalize ORDINAL NAME`** — produces `[NN] Name`. It is idempotent: a title that already carries `[NN]` is returned intact.
- **`worker_list LIST`** — splits on commas or newlines (**never** on spaces), applies the correlative `01, 02, 03...` to entries without a number, respects an explicit `[NN]` and advances the counter so an automatic one never collides, and deduplicates by slug.

Verified behavior:

| Input | Output |
|---|---|
| `Vermithrax, Glacielle, Tempestad` | `[01] Vermithrax`, `[02] Glacielle`, `[03] Tempestad` |
| `Uno, [05] Quinto, Dos` | `[01] Uno`, `[05] Quinto`, `[06] Dos` |
| `[01] Vermithrax, [01]Vermithrax` | `[01] Vermithrax` (slug dedup, ordinal ignored) |
| `[00] Worker` | `[01] Worker` (the 00 is reassigned; it is reserved for the root) |

## Dragon catalog

The name catalog lives in `scripts/dragon_name.sh`, which is its single source: the documentation does not repeat all 100 names. Five families of 20, and the ordinal communicates the element without opening the session:

| Ordinals | Family |
|---|---|
| `01`–`20` | Fire (`Vermithrax`, `Pyreclaw`, `Cinderfang`, ...) |
| `21`–`40` | Ice (`Glacielle`, `Frostfang`, `Wintermaw`, ...) |
| `41`–`60` | Storm (`Tempestad`, `Stormwing`, `Thundercoil`, ...) |
| `61`–`80` | Abyssal/primordial (`Eldryth`, `Abysswing`, `Voidmaw`, ...) |
| `81`–`100` | Arcane (`Dracolith`, `Wyrmbinder`, `Soulforge`, ...) |

```sh
sh scripts/dragon_name.sh list     # full catalog: "NN Name" per line
sh scripts/dragon_name.sh N        # name for ordinal N
sh scripts/dragon_name.sh count    # 100
sh scripts/dragon_name.sh --json   # catalog as JSON
```

**When exhausted, names are generated dynamically.** For an ordinal `N > 100` the script synthesizes deterministically using the dragon world morphology — lineage + nature + epithet, the three roots of the lore (Greek and Latin draco/wyrm/serpentes; mythological Vritra, Nidhogg, Tiamat, Shesha and Vasuki; and the anatomical epithets of every draco):

```sh
sh scripts/dragon_name.sh 101   # Jorm-aetherfang
sh scripts/dragon_name.sh 102   # Nidh-aetherfang
sh scripts/dragon_name.sh 112   # Vritr-pyromaw
sh scripts/dragon_name.sh 5000  # the same N always produces the same name
```

Deterministic, not random: the same ordinal always produces the same name on any machine, which is what a resumable run needs. The capacity before qualifying with the cycle is the product of the three families of morphemes (12 × 9 × 12 = 1,296 combinations).

Two invariants the script checks on load and fails with exit 2 if they are not met: exactly 100 names and all distinct. They were added because a duplicate (`Dracolith` at ordinals 66 and 81) went unnoticed until a check caught it.

## Renaming an existing session

```sh
orchestrate.sh attach-tabs --session SESSION_ID --title "[01] Vermithrax"
```

The merge updates the title if the `sessionID` already exists, instead of silently deduplicating (fixed behavior; renaming was previously lost). Verify with `tabs_status=ok-verificada-title`.

To rename only the session, without touching the tab, use `session_rename` in the CLI API. Prefer `attach-tabs` when you want both surfaces aligned: a session with one title and a tab with another is inconsistent state.