# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.6.0] - 2026-10-24

The readiness check. A session that asked the skill to "launch 20 sessions and
tell me if they answer" spent 72 tool calls reading the sources and created
NOTHING: the two-level minimum (R3) and the ledger turned a readiness check
into a 60-session, 60-row-ledger run, and the agent had no path that was
cheaper. This release adds that path, and the guards that keep it honest.

### Added
- **The readiness check** (`SKILL.md`): `preflight` -> `init-run --count N` ->
  `dispatch --prompt-file F --count N` -> `pool` -> `clean --yes`. The R3
  minimum does not apply to it: it is labelled **degraded**, never `verified`.
  **R16 — Fit the machinery to the request** says so in the hard rules.
- **The preflight answers the two questions that used to need a manual query**:
  `session_routes=` names the session routes the LIVE schema publishes (the
  Decision Gate B answer) and `children_allowed=` plus `children_subagents=`
  report the effective `subagent` permission (the R3d precondition).
- **A CI step that ties the command table to the code**: a subcommand or a flag
  written in the table of `SKILL.md` and absent from the code is a promise the
  code does not keep. The step was proved by documenting a flag that does not
  exist: it fails.
- **A regression test for the readiness check** (`r9-light-path`): it runs the
  whole path on a live instance and asserts the workers are created, the prompt
  reaches them, `clean` removes them and the `[00]` left behind is deleted.
- **The playbook** explains the two things that only apply to a readiness
  check: the fan-out is what the user asked for (no children are created), and
  the `[00]` may outlive the check.

### Changed
- **`dispatch --wait` is serial** and the docs now say so: N workers cost N
  round trips. Without `--wait` the prompts go out back to back.
- **The prompt template copies the ledger row verbatim** instead of
  re-enumerating its fields: the row schema was listed in three places (the
  ledger contract, the validators and the template) and the template is the
  one that drifts.
- **`SKILL.md` was trimmed by 105 words of duplication** (the "Minimal
  example" re-told the playbook, the `orchestrate.sh` paragraph repeated the
  table above it, the trap warning repeated the reference, the recipe row
  repeated two other places) to pay for the new content. It stays at 4979
  words against a 5000 limit.
- The two new scans (the routes and the subagent permissions) live in
  `scripts/_json.awk`, next to the extraction formula they use: the first
  version of them re-implemented the formula in the preflight, and the class
  guard caught it (R14) before it was published. The routes are printed in
  the canonical order (`create,children,send,read,state,delete`), not in the
  order the schema happens to list them: the list is a fact about the skill.

### Verification
- Regression suite **36/36**; the class sweep 0 hits with all 22 rules proved
  with their own defect; the structural validator 7/7; the package builds.
- **End-to-end validation in a tmux session**: the same request that failed
  before ("launch 20 sessions and tell me if they answer") was run through
  `opencode` with the skill loaded. The agent found the readiness check in
  `SKILL.md`, ran `preflight` (and read the routes from its new output), and
  got to `init-run --count 20` in 15 tool calls instead of 72.

## [1.5.6] - 2026-10-24

The defect-class guard left the public repository. It was always a maintainer
tool — the same kind of thing the regression suite has been since the
beginning — and the public repository carries the skill, its documentation and
the workflow, not the internals of the process that produced them.

### Removed
- **The `tools/` directory** (the class guard and its engine): one rule per
  class in this project's history, with a selftest that proves each rule can
  fail by introducing its own defect. It is maintainer-internal now, like the
  regression suite, and it runs locally. The workflow cannot run it any more
  (a private file is not in its checkout), so from here on the class sweep is
  a LOCAL gate; the CI keeps the checks it can run on its own: shellcheck,
  `sh -n`, the package build, the Windows line-ending proxy and the
  dead-variable check.
- Nothing else. The package, the documentation and the skill's behaviour are
  untouched: this release changes no line of the distributed code.

### Fixed
- **The workflow called a file that was not in the repository.** The moment the
  directory went away, the guard's own rule ("the CI using a file that is not
  published") fired on the workflow — which is exactly what that rule is for,
  and the reason it was worth writing.

### Verification
- The class sweep, from its new private home: 0 hits, all 22 rules proved
  with their own defect.
- Regression suite 35/35, shellcheck and `sh -n` clean, the structural
  validator 7/7, and the package build.
- The CI in the three real runners, with the step that referenced the removed
  directory taken out.

## [1.5.5] - 2026-10-23

Dead-code sweep. The package was read function by function and flow by flow
looking for code that nothing uses, and the answer is that **the distributed
code has no orphans**: every one of the 68 functions it defines is called, and
called from a path that is reachable from an entry point; every file it ships
has an inbound reference; every environment variable it promises is read; and
no variable is assigned and never read. What the sweep did find was outside the
package, and one of those findings was a **missing assertion**, not a missing
line.

### Fixed
**The Git Bash simulation computed the converted path and never used it.**
The Windows simulation derived the drive form of the tabs path (`TAB_WIN` and
friends) and then asserted on the ORIGINAL path. The `cygpath` stub
materialises the drive as a symlink to the MSYS root, so both paths name the
SAME file and the assertion could not tell whether the conversion happened at
all — the very thing the fixture claims to guard ("the check, the lock and the
write must name the same file"). A second stub that does NOT materialise the
drive makes the converted path a different file, and the merge then has to
write there and leave the original untouched. That case is now asserted, and
it was proved by moving the existence check back before the conversion: the
fixture fails with `tabs_status=no-tui`, which is the exact symptom of the
defect of 1.5.0.

**A line that looked dead was load-bearing.** The XOS-04 fixture captured the
output of `cache_put` into a variable it never read, which the linter duly
flagged. The capture is not inert: `cache_write`'s guard calls `die`, and
`die` EXITS — inside a command substitution that exit only ends the SUBSHELL,
so the capture is what lets the fixture go on and check the exit code and the
stderr marker. Removing it took the whole fixture with it. The capture is
restored and the reason is written where the next reader will find it.

### Added
- **A CI step that fails on a dead variable** (shellcheck `SC2034`) in the
  shipped tree. `SC2034` is a *warning*, so the error-level lint the CI has
  always run never saw it; a variable that is assigned and never read is dead
  code, and this is what keeps it from coming back. Only `SC2034` is checked:
  it is a stable check, so a newer shellcheck cannot turn the build red for
  an unrelated warning.
- The local recipe (`.agents/maintenance/testing-and-iteration.md`) now
  carries the warning-level lint and the class sweep, because the regression
  net is local and the CI cannot see it — and it records the two lessons of
  this round: a line that looks inert can be holding an `exit` in place, and
  a variable that is computed and never used can be the intent of an
  assertion that was never written.

### Removed
- Four `.bak` copies of live scripts, on disk and in no repository: two
  `.authquote.bak` next to the scripts they predate and two
  `.prototype-v0.bak` in the maintainer directory. Nothing referenced them,
  they are not in the closed list, so they never shipped; and each one is
  byte-identical to a commit in the history (`ff38a8c`, `04d7565`), so the
  history still holds every version they were keeping.

### Verification
- Regression suite **35/35**, with the Windows simulation now asserting the
  conversion (three new checks) and the new case proved against the code that
  must fail it.
- The class sweep: 0 hits, all 22 rules proved with their own defect.
- The new CI step was run with a dead variable introduced: it catches it.
- The dead-code audit itself: 68/68 functions reachable and called, 0 unused
  variables in the shipped tree, 0 shipped files without an inbound
  reference, 0 promised environment variables unread.

## [1.5.4] - 2026-10-23

Third pass, on a different axis. The first two passes swept the defect
CLASSES of the history; this one sweeps the PROMISES — what the package says
about itself against what the code does. The command table, the failure
matrix, the exit codes and the flags are contracts, and a contract the code
does not keep is a defect like any other.

### Fixed
**The tabs prune never ran.**
`clean` prunes `tabs.json` under a lock, and the command under the lock was a
shell FUNCTION (`py`). `lock_exec` launches the command with python's
subprocess, WITHOUT a shell: a function cannot be launched, so the lock failed
closed with `cannot run command: py` and the prune never happened — the tabs of
the deleted sessions stayed in `tabs.json` forever, silently, because the prune
is optional and nothing failed loudly. The cause is old: the CR fix of v1.5.0
migrated every `python3 -c` to `py -c`, and one of those was inside the lock
call. The command is `python3` again, with a BINARY write so the count the
shell reads is LF-only on every platform. The promise `clean ... prunes
tabs.json` is now kept.

**`init-run` created fewer workers than asked for, without saying so.**
The requested titles lived in TWO variables: the `--workers` group and the
`--worker` group, and the second OVERWROTE the first. So
`init-run --workers "A, B" --worker C` created ONE worker (C) and dropped A
and B with no warning — and the `requested=` line printed the merged (already
truncated) list, so the operator had no way to see the loss. The loose
positional tokens were also joined with SPACES, so `init-run --workers "T1"
T2 T3` created ONE worker named "T2 T3". The titles are now ONE ordered
list, filled as the flags arrive, and the `requested=` line prints the list
that is actually used. This is the same class as the "the loose tokens were
discarded" defect of an earlier round, moved to another group: the group that
was dropped changed, the silence did not.

### Added
- **A rule for the promises axis**: a flag written in the command table of
  `SKILL.md` that the code never parses is now a hit of the class guard. The
  table is a contract about the command surface, and a flag that is
  documented but not implemented is a promise the code does not keep.
- **A rule for the locked commands**: a command launched under `lock_exec`
  that is a shell function is now a hit. The lock launches the command
  without a shell, so a function cannot be launched at all — the class that
  broke the tabs prune.
- **Two regression tests**: `r9-worker-title-union` (the requested titles are
  a union, in the order the flags were given) and `r9-tabs-prune-runs` (the
  prune removes the tab of the deleted session and leaves the other one).
  Both were run against the code BEFORE the fixes: they fail there and pass
  here.
- **A row in the failure matrix** for each symptom, so an operator who sees
  it knows what it is and what to do.

### Verification
- Regression suite **35/35** (two new assertions), each run against the code
  that must fail it.
- The class sweep: 0 hits on the tree, and all **22** rules proved with
  their own defect.
- The failure matrix was checked row by row against the code: its claims
  about the fixes hold, and the exit-code table it publishes
  (0/2/3/4/5/6/70/71) is grounded in the code, including the `6` that comes
  from the embedded python.

## [1.5.3] - 2026-10-23

Second pass over the history. Every defect class in the project's log was
mined again — this time from the whole commit history, not only from the
cycles already recorded — and the classes the guard of 1.5.2 did not cover
became rules. **No new live defect was found**: all eight are closed, and
each one now has a rule that can actually fail.

### Added
- **Eight more rules** in the defect-class guard (maintainer-internal since
  1.5.6), each one proved by introducing its own defect:
  a bash-only construct in a script that declares POSIX sh (the CI only
  linted in bash mode, so a bashism reached a dash runner and broke there
  only); the JSON extraction formula outside the shared library; a JSON parse
  that refuses control characters inside strings (the serve emits a literal
  newline inside a JSON string); the CI using a file that is not published (a
  fixture under `runs/` is gitignored, so the checkout the CI sees never had
  it); the same function body in two shipped files; a random directory as a
  fallback for a path two processes must share (the cache split in two); a
  query parameter that can be empty (an empty parameter is a different query:
  the whole catalog instead of the project's); and the docs invoking `bash`
  over a `#!/bin/sh` script.
- **A test for the two implementations of the `[NN] Name` pattern.**
  `title_normalize` and `worker_list` know the same pattern in two separate
  ways. The project accepts that (consolidating them would add a shared
  library to the package for one regex, and the copies have not drifted), but
  a silent divergence was unguarded: the symptom would be a double ordinal
  ("[01] [01] Vermithrax"), the C-COS defect of round 6. The test now asserts
  that both read the same ordinal out of the same title, that an old ordinal
  is replaced and not doubled, and that the slug still ignores it.

### Fixed
- **The POSIX rule was never checked.** The skill promises "POSIX sh + awk" and
  the CI linted with shellcheck's default shell (bash), so a bashism would
  pass every push and only break on Linux, WSL or Alpine. The guard now
  lints in `sh` mode and only counts the POSIX-compatibility findings (the
  SC3xxx family): the rest of the warning level is not about POSIX — the
  `CDPATH= cd` idiom trips SC1007 in every shell, and it is correct.

### Verification
- The new POSIX rule was written first with `--severity=error`, and the
  selftest caught it: in `sh` mode the POSIX findings are *warnings*, so the
  rule could never have failed. It is now precise, and it is proved.
- Regression suite **33/33** (one new assertion, `r8-title-pattern-coherence`),
  and the new assertion was run against a deliberately diverged
  `title_normalize`: it fails there (with the double ordinal in the message)
  and passes here.
- The class sweep: 0 hits on the tree, and all **20** rules proved with their
  own defect.

## [1.5.2] - 2026-10-23

Class sweep over the whole history: every defect class in the project's log was
turned into a detector and run against the whole tree. Four instances were still
open, and they are closed here. The classes are now guarded on every push, with a
selftest that proves each rule can fail.

### Fixed
**A project path with a quote broke the clean lookup.**
`clean` found the `[00]` orchestrator with a python block that SPLICED the project
directory into the python source (`proj = "<path>"`). A path with a quote or a
newline — both legal in a POSIX filename — produced a SyntaxError, the stderr was
discarded and the empty result was reported as "no [00] orchestrator in this
project": the wrong diagnosis, and `clean` could not be run on that project at
all. The directory now travels through the ENVIRONMENT, the way the enumeration
block right below it already did, and a parse failure is reported instead of
being turned into a different message.

**A page with a broken shape read as an empty pool.**
`pool_list` piped the python into `while` and `sort`: the status of a pipeline
is the LAST command's, so a parse failure returned rc 0 with an empty table. The
pool then said "max ordinal 0" and the next worker reused `[01]` — the same class
as the pool-ordinal defect of 1.5.0. The parse is now a step of its own whose
status is kept, and the pool fails closed (rc 3) instead of answering "no
workers".

**The shared awk library was located by guessing.**
`os/_common.sh` is SOURCED, so `$0` inside it is the path of the script that
sourced it, not its own. The library (`scripts/_json.awk`) was therefore looked
up by GUESS: first from `SELF_DIR`, then from the caller's own directory, then
one level above it. A guess is not a contract — the same source could find the
library in one place and miss it in another. It already cost one real failure:
the CI step that sourced the file without `SELF_DIR` looked for the library in
the shell's own directory and one level above it, and failed closed with
"shared awk library missing" on all three runners. There is now ONE rule (the
caller exports `SELF_DIR`, the directory that holds the library) and not meeting
it fails closed with a message that says which rule to meet.

**The ok-list swallowed the status of its own reader.**
`clean` extracted the ids of the sessions it had really deleted with
`awk ... 2>/dev/null; true | tr '\n' ' '`: the `true` swallowed the status of
the `awk`, and the pipe hung off the `true`, so it never transformed the awk
output at all. An unreadable log therefore read as "nothing was deleted", and the
cache purge and the tabs prune were skipped while the command claimed it was
done. The status is kept now, the pipe is where it belongs, and an unreadable
log is reported.

### Added
- **A guard for the defect classes**: one rule per class in this project's
  history. It was public and ran on every push in 1.5.2-1.5.5; since 1.5.6 it
  is maintainer-internal, like the regression suite, and runs locally. Every
  rule resolves the class of what it looks at — a comment from code, a
  definition from a call, a sourced file from an executed one — because a
  detector that cries is worse than no detector: it gets ignored and then
  disabled.
- **A selftest for the guard** (`--selftest`): each rule is proved by
  introducing its own defect into a copy of the tree and checking that the rule
  fires, and that it does not fire on the clean tree. A guard that has never
  been seen to fail is a hypothesis, not a guard. Two rules failed that proof on
  their first run and were tightened until they were worth trusting.

### Verification
- Regression suite **32/32** (one new assertion: `r8-fail-closed-parsers`).
- The new assertion was run against the code BEFORE these fixes: it fails there
  and passes here, so it measures the defects and not the implementation.
- The class sweep: 0 hits on the tree, and every one of the 12 rules proved with
  its own defect.

## [1.5.1] - 2026-10-22

Patch release over v1.5.0. Three paths that used to fail open now fail closed, the
JSON extraction formula lives in one place, and the CI step that exercises the
Windows line endings finds the shared library again.

### Fixed
**The cache could be split in two by a permission error.**
The cache directory is derived from the project hash, and `preflight.sh` and
`orchestrate.sh` are separate processes that have to agree on it. When the
directory could not be created, the code fell back to a random `mktemp -d`
directory: each process then got a *different* one, `preflight` wrote the
password into one and the run read from the other, and the run went
unauthenticated with no error anywhere. The fallback also gave up the property
it was meant to provide — a per-process random directory is not a place two
processes can agree on. The location is now used as derived, and a cache that
cannot be created is reported instead of silently replaced by a different one.
The cache directory itself is also refused when it is a symlink: `mkdir -p` on
a symlink-to-directory succeeds, so the per-key guards could not catch it.

**A failed URL encoding turned into an unfiltered query.**
The project directory is sent to the API percent-encoded. The encoding ran
through python and discarded its exit code, so a python failure produced an
EMPTY directory parameter — a different query, not the same one: the server
was asked for the whole catalog of the instance (thousands of sessions, 50
per page, straight into the pagination cap) and the client-side filter had to
sift it. The encoding now fails closed, and the caller refuses to issue the
unfiltered query.

**The pagination cap returned a truncated catalog as if it were complete.**
The page loop stops after 30 iterations as a safety valve, but the cap was
reached silently: the accumulated pages were returned with a success code and
the caller read them as the WHOLE list. That is the same class as the
truncated-list defect of 1.5.0 (the pool then reads "max ordinal 0" and the
next worker reuses `[01]`). Reaching the cap with a page still pending is
now fatal, exactly like a malformed page.

**The CI could not find the shared library the extraction depends on.**
`os/_common.sh` is SOURCED, so `$0` inside it is the path of the script that
sourced it, not its own. The shared awk library (`scripts/_json.awk`) is therefore
located from what the CALLER knows: the real callers export `SELF_DIR`, and the
regression fixtures rely on their own directory. The CI step that checks the Windows
line endings sourced the file directly and exported nothing, so the library was
looked up in the shell's own directory and one level above it, where it does not
exist, and the step failed closed with "shared awk library missing" on all three
runners. The step now exports `SELF_DIR` like the real callers do, which also makes
it load the per-OS adapter and exercise the real resolution instead of a crippled
one.

**The CI step that checks the Windows line endings could not fail.**
The step forces python to emit CRLF and then asserts that the values the shell
reads are clean — but it asserted them on `json_get_field`, which is pure awk and
could never carry a CR. The defect the step was written for (a value read from
python arriving with a stray CR) lives in the `py` helper, and the step never
called it: the guard would have passed with the defect reintroduced. The step now
exercises `py` itself. Checked both ways — reintroducing the defect makes the step
fail, and it passes again once the fix is back.

### Changed
**The same JSON extraction was written four times, and the copies differed.**
The offset formula existed in `os/_common.sh`, `orchestrate.sh`,
`preflight.sh` and `watch_run.sh`, and they had already drifted: two of them
stripped a number to its digits (so `1.5` came out as `15` and `-5` as `5`),
one could not read a number at all (it returned the empty string), and only
one returned the value verbatim. A copy that answers a different question is
a copy that will answer it wrong somewhere. The formula now lives once, in
`scripts/_json.awk` (the same shared-library pattern `_validators.awk` uses
for the two validators), and all four consumers call it.

## [1.5.0] - 2026-10-22

Audit and hardening release: a line-by-line read of every script and every
reference document of the package, a sweep that looked for each defect class
in every other place it could occur, and the rewrite of the public
documentation around what the skill actually does.

### Fixed
Each entry below names the observable symptom the defect produced, not the
mechanism that fixed it.

**A flag without a value hung the process.**
`shift 2` with fewer than two arguments left does not advance the argument list
(POSIX: the shift fails and `$#`/`$1` stay unchanged), so the flag parser
re-read the same flag on every iteration: `orchestrate.sh send-prompt --session`
(no value) spun at 100% CPU with no output and no timeout. 21 call sites were
affected. One shared guard (`assert_value` in `os/_common.sh`) now fails closed
with exit `2` and a clear message on every value-taking flag.

**Extracted values were silently truncated.**
The JSON extractions mixed two offset conventions: when the pattern did not
include a string value's closing quote but the length still subtracted it, the
value lost its last character and every numeric field lost a digit. The printed
`msgID` was not a real id (`msg_01HXYZABCDEF`) and `time.updated` came back as
`79269316699` instead of `1792693166999`, so a busy session could compare as
"older than idle". Every extraction now goes through one shared getter
(`json_get_field`), and the per-record scans derive their offsets from the key
instead of hardcoding them.

**A prompt could reach the wrong session.**
`dispatch --target NNsMM` — the form the router prompt documents — matched the
**parent worker**: awk coerces `01s02` to the number `1`, and the idle set only
held workers, so a sub-agent target was unreachable. The selector now compares
the ordinal *and* the sub-agent index.

**`delete-session --force` deleted without asking.**
It skipped the children check *and* the confirmation, so a destructive delete ran
with no approval, while the documentation promised only the children check.
`--force` now waives ONLY the children check; the confirmation always applies.

**A failed fetch could be read as an empty one.**
The pool ordinal was derived from a second, unguarded API call whose failure was
swallowed (a pipeline keeps the exit code of its last stage), so a failed fetch
read as "max ordinal 0" and the next worker took an ordinal that was already
deployed. The pool is now fetched once and the ordinal derived from that
snapshot.

**Pagination could return a truncated list as if it were complete.**
The paginator always appended `?limit=200`, so a path that already carried a
query string (`/api/session?parentID=X`) got a second `?` inside the value:
the filter matched nothing and the child enumeration silently returned an empty
list, losing the topological order. `clean` also stopped at the first malformed
page and reported a partial list as the whole one. A malformed page is now
fatal, and the three filtered fetches go through the paginated helper.

**`clean` could report success having deleted nothing.**
If its temporary deletion log was missing or unwritable, both counters read zero
and the command exited 0 with the tabs prune and the cache purge skipped. The
counts must now add up to the plan, or the run stops.

**Cross-OS: every session creation failed under Git Bash.**
The lock helper converted the helper script path for Git Bash but not the lock
file, so a native Win32 python could not open it and `create-worker`,
`ensure-root` and `init-run` all failed closed. The lock file is converted too.

**The four OS adapters had drifted.**
Each carried its own copy of the tabs-merge skeleton: the Git Bash one had the
arity guard and the others did not (a wrong arity returned "no-tui" on three
operating systems and "usage" on Git Bash), and it had no "tabs.json must
exist" check (a missing file returned a raw lock error instead of "no-tui").
The skeleton now lives in `os/_common.sh` and each adapter declares only what is
genuinely OS-specific.

**Six resolvers for one path.**
The tabs.json path was resolved in six places, and the merge python's copy had
different rules (no CLI fallback, no XDG default, no channel scan), so the lock
guarded one file while the merge wrote another. There is now one resolver, and
the state root has one too: with `ORCHESTRATE_STATE_ROOT` set, the TUI gate and
the tabs merge used to resolve different roots and the tabs feature broke
silently.

**The cache could be written non-atomically, or through a symlink.**
Preflight wrote 14 keys with plain redirects (neither atomic nor symlink-safe)
and read the service password with a pattern that required `"password":"`
exactly, so a pretty-printed `service.json` left the run silently
unauthenticated. One hardened writer is now used everywhere, and the password
is written verbatim so the redaction cannot corrupt it.

**The packaged skill was incomplete.**
The closed list shipped 2 of the 22 regression fixtures, so the published
package referenced files it did not contain, and the ZIP itself was written
inside the temporary directory the cleanup trap deletes — the recipe produced
no durable artifact. The distributable now carries exactly the runtime, and
the package build fails when the closed list and the tree disagree.

**A page with a literal newline broke the pagination.**
The serve sporadically emits a page whose JSON string contains a raw newline
(a title with an embedded line break). The pages were merged by reading them
LINE by LINE, so that newline cut the document in half: the parse failed, the
pagination stopped and the caller received a truncated list. Once a truncated
list became fatal (see above), the whole run died instead. The pages are now
decoded one document at a time with the raw JSON decoder, and every parse of a
serve response accepts control characters inside strings.

**The Git Bash adapter checked one file and wrote another.**
The existence check on `tabs.json` ran on the path BEFORE the OS-specific
conversion, while the lock and the merge used the converted one. A file
reachable only under the converted path was reported as "no-tui". The
conversion now happens first, so the check, the lock and the write always name
the same file.

**The pool query downloaded the whole catalog of the instance.**
`GET /api/session` accepts a `directory` filter, but the pool, the inventory
and the session lookup ignored it: they fetched every session of the serve
(thousands, 50 per page) and filtered client-side. On a big instance that is
30+ requests per command, it can fail intermittently, and the run died with
"could not query the worker pool". The query is now filtered by project (the
client-side filter stays as a safety net): the pool went from ~30 s to ~3 s
and stopped failing.

**`init-run` could not be run twice.**
The `[00]` root is reused when it already exists, but the dedup guard treats a
busy session as a collision, and the router prompt alone leaves the root
busy: the second `init-run` aborted with "collision: '[00] Orchestrator' is not
reusable". The root slot belongs to `init-run` and survives runs, so an
existing root is now reused (never replaced) and the router instruction is
only installed on a freshly created one -- sending it again would post a
message into the operator's live session.

**On Windows, every value read from python carried a stray CR.**
Python's text-mode stdout ends the line with CRLF on Windows, so every value
the shell read back from it (a session id, a cursor, a count, a whole JSON
document) ended with a `\r`. The values that were compared or used in a URL
were corrupted: the session lookup lost its candidates, a cursor carried a
control character into the query string, and the packaged inventory check
reported a mismatch between two byte-identical lists. All the python calls
now go through one helper that keeps the exit code and prints LF only, and the
package inventory is compared with the shell instead of `cmp(1)` (which Git for
Windows does not ship either).

**The orchestrator's role is now explicit: it monitors and it routes.**
The router instruction installed on `[00] Orchestrator` stated that it never
implements the task, but not what it *does*: it never said that its standing
duty is to watch the other sessions continuously, nor that every **new** task
goes to the session the orchestrator judges the most convenient for it (the
old text said "pick any idle worker", which is not the same thing). The
router, the rule it comes from (R13e) and the README now say the same thing:
two moves — monitor continuously, route each new task to the best-suited
session — and nothing else.

**Other corrections:** the router install no longer hides a failure; the
unguarded API calls report a transport error instead of misdiagnosing it as a
missing model or a wrong id; the temporary file used by `clean` no longer falls
back to a predictable `/tmp` path; the project lock refuses to be created
through a symlink; `tabs` and `attach-tabs` compare the same field; the
`clean --force` flag that did nothing was removed; the `session-id` subcommand
and the `--force-tabs` flag were missing from the help text.

### Changed
- The `tabs.json` merge, the state-root resolution and the pool ordinal are now
  single-sourced instead of being re-implemented per script or per operating
  system.
- Every JSON field extraction goes through the shared getter, or through a
  derived-offset scan where a whole-document read does not apply. No hand-written
  offset remains in the package.
- The documentation now matches the code: the default root name, the sub-agent
  title form, the pool-derived ordinal, the tab-gate field names, the version
  gate, the subcommand count and the endpoint placeholders
  (`/api/session/{sessionID}`, verified against the live `/openapi.json`).

### Added
- A root `LICENSE`: GitHub could not detect the license, which lived only
  inside the package.
- The README (English and Spanish) was rewritten around what the skill
  actually does: the orchestrator's two moves, the command layer, the contract
  layer, a runnable quick start, and the refusals. Every claim in it is now
  checked against the code, and the two false ones are gone: the number of
  hard rules (it listed 15; there are more, so the number was dropped rather
  than restated) and the list of commands that change something (it named
  four; six do).
- CI now runs on **Linux, macOS and Windows** (Git Bash): syntax, shellcheck
  and the package build on every push, so the three platforms are verified
  instead of inspected.
- The release was verified against a **live OpenCode instance** on macOS and
  Linux (the full create/inspect/send/collect/delete cycle of a real run), and
  the regression suite was run on both, plus a Windows line-ending proxy, so
  the Windows fixes were exercised rather than reasoned about.

## [1.0.2] - 2026-10-14

Post-v1.0.0 fleet hardening (2026-10-13 skill review). Tabs lock target
fixed on linux/wsl; watch_run/preflight guards; clean validator error when
`_validators.awk` is missing; docs synced with SKILL.md reality (README,
naming-convention, prompt-templates R14a/R15); gitignore now excludes
concurrent-session backup files.

## [1.0.1] - 2026-10-08

Patch release over v1.0.0. Closes the post-v1.0.0 hardening cycle and ships
the 1 new subcommand + the shellcheck reductions + the CI workflow. Each entry
cites the commit that introduced it (no other source of truth).

### Summary

- 1 new public subcommand: `orchestrate.sh session-id COMPACT_REF`.
- 14 shellcheck reductions: 33 warnings → 4 (−88%); 22 info → 4
  (−82%); 55 total → 8 total findings (−85%). 0 errors throughout.
- New CI: `.github/workflows/ci.yml` runs `shellcheck` + `sh -n`
  on every push and pull request to `main` (Linux runner; 2/2
  steps green).
- 1 regression introduced and reverted: the
  `${AUTH:-}` quoting in `os/_common.sh` http wrappers caused
  HTTP 401; the unquoted form is restored and documented inline.
- 0 changes to the public API of `watch_run.sh`; the short
  flags `-s` and `-a` are preserved (they are part of the
  public API documented in `watch_run.sh`'s help text).
- Validators `7/0 / 7/0 / 4/0` (strict / --allow-degraded /
  dag-only) on the replica ledger; all stable.
- Round-trip `local == origin/main`; tag `v1.0.1` points to
  this release.

### Fixed

- **pool_list empty pool** (`orchestrate.sh pool` returned "empty pool"
  when `[NN]` workers existed) — root cause was a chain of nawk
  bracket-escape bugs. `pool_list` now parses the API response with
  python3 (a dependency that already existed for `sub_dispatch` and
  `verify-daughters`), so it parses records by line, strips the
  wrapping `{"data":[{...},{...}` and trailing `]}` artifacts, and
  matches the regex `^\[(\d+)\](?:s\[(\d+)\])?\s+(.*)$` once per row.
  Commits: `04c3df8`, `3dd76cf`, `37a7cb9`, `dbc8e45`, `11bd36f`,
  `7a41579`, `d03a223`, `8866d25`, `5695315`, `6751a2f`, `75315e6`.
- **pool_list NAME column empty** — the output line used `m.group(2)`
  (the second capture group, which is the parent ordinal or `None`
  for plain workers like `[00] Orquestador`) instead of the named
  variable `nm` (the third capture group, the readable name). Commit:
  `75315e6`.
- **wait-idle stuck message** — was in Spanish (`sin progreso...
  reasigna la tarea`); now English (`no progress in Ns; reassign the
  task`). Commit: `d266d97`.

### Documentation

- **Skill is English-only inside the package.** The frontmatter
  `description` is EN-only; the Spanish trigger list moved to
  `SKILL/references/triggers-es.md` (which is linked from the
  References table). Commit: `6fe561c`.
- **CHANGELOG entries for the bugs above** — this section closes the
  drift between git history and the documented release.

### Added (post-v1.0.0, tracked but not part of v1.0.0)

- **`orchestrate.sh session-id COMPACT_REF`** subcommand. Closes the
  long-standing gap between `naming-convention.md` (which described
  the subcommand) and the implementation (which was missing). Uses
  the existing but-dead helper `parse_short_id` in
  `os/_common.sh`. Resolves a compact ref like `00`, `01`, `01s02`,
  `[01]`, or `[01s02]` to the raw `sessionID` (`ses_XXX`) for the
  project. The implementation matches against the session
  `title` field, which must contain the `[NN]` or `[NN]s[MM]`
  prefix; legacy / parallel / ad-hoc titles that lack the prefix
  are not matched (use `pool` to enumerate). The
  `naming-convention.md` was extended with a "Matching behavior"
  section that documents this. Commits: `d361957` (orchestrate.sh),
  `5f6d230` (naming-convention.md).

- **CI workflow** at `.github/workflows/ci.yml`. Runs
  `shellcheck --severity=error` and `sh -n` on every push to
  `main` and on every pull request. The first version also tried
  to run the ledger validators, but `runs/` is gitignored per
  AGENTS.md (the directory holds prior-run evidence and is
  default-deny), so the validator step was moved to a comment
  explaining that the validators stay local. Whitelist for
  `.github/` added to `.gitignore`. Commits: `f7af214`,
  `1f008b4`.

### Known issues (tracked, not yet resolved)

- `pool_list` is filtered to titles that begin with `[NN]` (or
  `[NN]s[MM]` for sub-agents). Sessions whose title was created
  without the bracket prefix are not enumerated by `pool` and
  cannot be resolved by `session-id`. This is a pre-existing
  contract for `sub_create_worker` (the title is set to the
  worker name; the bracket prefix is added at session creation,
  but the exact field where it is set is in the same code path
  that some parallel sessions have been observed to bypass).
  Resolution requires a decision about whether to retroactively
  fix the `sub_create_worker` title format (breaking change for
  any workflow that scrapes the title) or to maintain a
  parallel index that maps sessionIDs to their intended
  `[NN] Name` regardless of what the title actually says.
  Tracked here so the decision is visible; not part of v1.0.0.

## [1.0.0] - 2026-10-03

First public release of the OpenCode V2 two-level orchestration skill.

### Added

- `SKILL/scripts/orchestrate.sh` — multi-OS swiss-army knife with 12 subcommands:
  `preflight`, `ensure-root`, `create-worker`, `send-prompt`, `attach-tabs`,
  `watch`, `wait-idle`, `init-run`, `sessions`, `self-check`, `pool`,
  `tabs`, `verify-daughters`, `delete-session`.
- `SKILL/scripts/orchestrate-{darwin,linux,wsl,windows}.sh` — explicit OS
  dispatch wrappers (per-OS invocation without relying on `uname`).
- `SKILL/scripts/os/{_common,darwin,linux,wsl,windows-gbash,tui-detect}.sh` —
  shared helpers + OS adapters; lock mechanism per OS (`flock(1)` on
  linux/wsl, `python3 fcntl` on darwin/windows-gbash).
- `SKILL/scripts/dragon_name.sh` — catalog of 100 dragon names grouped by
  element (Fire/Ice/Storm/Abyssal/Arcane) plus deterministic synthesis for
  runs with >100 workers.
- `SKILL/scripts/preflight.sh` — one-shot discovery: endpoint, version,
  `/openapi.json` guard, agent catalogs, default model pair, root session
  hint, TUI/tabs gate. Caches state under `ORCHESTRATE_CACHE_DIR` (chmod 600
  on the auth password file; never echoed to stdout).
- `SKILL/scripts/watch_run.sh` — bounded POSIX+awk watcher (idle + outcome +
  artifacts + permissions) with fixed deadline.
- `SKILL/scripts/validate_dag.sh` — canonical YAML/DAG/scope/state validator.
- `SKILL/scripts/validate_ledger_closed.sh` — closure validator (strict and
  `--allow-degraded` modes; `--require-evidence` for the evidence gate).
- 14 `SKILL/references/*.md` — operational, contractual, evidence, and pattern
  documentation.
- `SKILL/LICENSE` (MIT, DragonJAR.org 2026).

### Multi-OS portability

- POSIX sh + awk + sed + curl only; no bashisms, no `local`, no `[[ ]]`.
- OS-specific behavior isolated to `os/{darwin,linux,wsl,windows-gbash}.sh` via
  a uniform `os_project_dir` + `os_tabs_merge SID TITLE TUI_CWD BACKUP_DIR`
  interface.
- `windows-gbash.sh` uses `cygpath -w` for the Windows literal path and probes
  `fcntl` availability in MSYS2 python3 (fail-closed otherwise).
- `wsl.sh` detects drvfs (`/mnt/c`) and refuses to take a lock there.
- Cross-OS verification on darwin; linux/wsl/windows-gbash verified by code
  inspection (POSIX conformance).

### Fail-closed gates

- `dedup_guard TITLE` (return code contract: 0 reuse, 1 create, 2 collision,
  3 catalog query failure): never allows a duplicate or an unchecked creation.
- `pool_list` reads `time.updated` vs `time.idle` to correctly mark a session
  as `running` when active (previous code marked everything `idle` if `time.idle`
  existed, which led to overwrite races).
- `verify-daughters --worker-id WID` aborts with exit 2 when the query
  returns zero children (a mistyped worker-id would otherwise read as
  success).
- `delete-session` enumerates children via `GET /api/session?parentID=` and
  aborts unless the count is known; `--force` does NOT override this gate.
- `send-prompt` verifies the session has a resolved `model.id` before
  sending; an empty prompt file dies; a `dispatch_$SID` timestamp is cached
  so `wait-idle` only accepts an idle timestamp that is NEWER than the
  dispatch (pool-safe).
- `attach-tabs` consumes the tabs gate (single source: `tui-detect.sh`) and
  fails closed when the gate is blocked, when `--tui-cwd` contradicts the
  detected cwd, or when the cwd directory does not exist.

### DRY

- `auth_flag`, `cache_put/get/has`, `require_state`, `parse_kv`, `die`,
  `tabs_json_path`, `pool_list`, `pool_max_ordinal`, `session_body`,
  `find_dedup`, `dedup_guard`, `post_new_session`, `json_escape`,
  `json_get_field` — all live once in `SKILL/scripts/os/_common.sh`.
- The tabs gate is decided ONCE in `tui-detect.sh`; `resolve_gate` in
  `orchestrate.sh` re-probes only when the cache's pin is stale.
- `pool_list` is the single source of the deployed workers' table; both
  `pool` (visibility) and `init-run` (reuse/create) read it via the same call.
- `worker_list` + `title_normalize` are the only two functions that know the
  `[NN] Name` pattern.

### Known limitations

- i18n: if the orchestrator session is created with different `[00]`
  names across languages (e.g., Spanish `Orquestador` vs English `Orchestrator`),
  both will coexist in the pool. Use `pool` to inspect, and `delete-session`
  to clean.
- Cross-OS live verification was performed only on darwin. Linux / WSL /
  Windows Git Bash are verified by code inspection; the first deployment on
  each should run the full battery documented in the install section.
- The `/openapi.json` is the single source of truth. Some paths documented in
  references/ are flagged with `requiere verificación` (e.g. `--param`,
  `opencode ai --server`); the skill's default routes are HTTP-direct via
  the cached endpoint and Basic auth.
[Unreleased]: https://github.com/DragonJAR/OpenCode-Orchestrator-Skill/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/DragonJAR/OpenCode-Orchestrator-Skill/compare/v1.5.6...v1.6.0
[1.5.6]: https://github.com/DragonJAR/OpenCode-Orchestrator-Skill/compare/v1.5.5...v1.5.6
[1.5.5]: https://github.com/DragonJAR/OpenCode-Orchestrator-Skill/compare/v1.5.4...v1.5.5
[1.5.4]: https://github.com/DragonJAR/OpenCode-Orchestrator-Skill/compare/v1.5.3...v1.5.4
[1.5.3]: https://github.com/DragonJAR/OpenCode-Orchestrator-Skill/compare/v1.5.2...v1.5.3
[1.5.2]: https://github.com/DragonJAR/OpenCode-Orchestrator-Skill/compare/v1.5.1...v1.5.2
[1.5.1]: https://github.com/DragonJAR/OpenCode-Orchestrator-Skill/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/DragonJAR/OpenCode-Orchestrator-Skill/compare/v1.0.2...v1.5.0
[1.0.2]: https://github.com/DragonJAR/OpenCode-Orchestrator-Skill/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/DragonJAR/OpenCode-Orchestrator-Skill/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/DragonJAR/OpenCode-Orchestrator-Skill/releases/tag/v1.0.0
