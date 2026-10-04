# Static OS compatibility audit — v1.0.0

This file documents the static analysis performed over every script in
`SKILL/scripts/` against the OpenCode-supported operating systems:
**macOS** (arm64 + Intel x86_64, BSD userland), **Linux** (x86_64 + ARM64, GNU
coreutils), **WSL** (Windows Subsystem for Linux, Linux userland under
Windows), and **Windows via Git Bash** (MSYS2/Cygwin userland, native
OpenCode binary on Windows).

Source of OpenCode OS support: <https://www.opencode.asia/installation/>
(macOS, Linux native binaries; native Windows marked "experimental";
WSL2 recommended on Windows).

## Methodology

Every script in `SKILL/scripts/` (POSIX sh, awk, curl, tr, sed, grep,
mktemp, python3 where documented) was scanned for:

- bash-only constructs (`[[ ]]`, `local`, arrays, `<<<`, `declare`, etc.),
- BSD vs GNU differences in utilities (`sed -i`, `date`, `awk` functions,
  `grep`),
- tools that exist on one OS but not another (`flock`, `/proc`,
  `cygpath`, `pgrep`, `lsof`),
- paths and assumptions hardcoded to one OS's conventions,
- DRY violations that hide portability fixes (one OS adapter duplicating
  logic that belongs to `_common.sh`).

## Tool × OS matrix

| Construct | macOS (BSD) | Linux (GNU) | WSL (Linux) | Windows Git Bash (MSYS2) |
|---|---|---|---|---|
| POSIX `sh` + `awk` + `sed` + `grep` + `cut` + `tr` + `mktemp` + `printf` | ✅ | ✅ | ✅ | ✅ |
| `set -u` + `${var:-default}` defensive unset guard | ✅ | ✅ | ✅ | ✅ |
| `grep -E` (POSIX, accepted by BSD and GNU grep) | ✅ | ✅ | ✅ | ✅ |
| `sed -i ''` (BSD: requires extension; GNU: optional) | NOT USED | NOT USED | NOT USED | NOT USED |
| `date -u +%Y-%m-%dT%H:%M:%SZ` | ✅ | ✅ | ✅ | ✅ |
| `awk` POSIX regex `[^abc]` + `sub/gsub/match/split/length/index/printf` | ✅ | ✅ | ✅ | ✅ |
| `awk` GNU-only (`gensub`, `asort`) | NOT USED | NOT USED | NOT USED | NOT USED |
| `shasum -a 256` (macOS) + `sha256sum` (Linux) fallback chain in `_common.sh` | ✅ | ✅ | ✅ | ✅ |
| `mktemp "${TMPDIR:-/tmp}/name.XXXXXX` | ✅ | ✅ | ✅ | ✅ |
| `flock(1)` from util-linux | ❌ (BSD userland) → python `fcntl.flock` fallback in `darwin.sh` + `windows-gbash.sh` | ✅ (`linux.sh` uses it) | ✅ (`wsl.sh` uses it + drvfs fail-closed) | ❌ (uncertain) → python `fcntl.flock` fallback in `windows-gbash.sh` |
| `/proc/<pid>/cwd` (Linux/WSL only) + `lsof -a -p <pid> -d cwd -Fn` fallback in `tui-detect.sh` | lsof-only macOS path | ✅ | ✅ | lsof-only (no /proc) |
| `cygpath -w <path>` (Git Bash/Cygwin only) + `pwd -P` fallback in `windows-gbash.sh` | n/a | n/a | n/a | ✅ |
| `pgrep -x opencode` + `ps -p <pid> -o command=` + `command -v` guard in `tui-detect.sh` | ✅ | ✅ | ✅ | ✅ (coreutils in Git Bash) |
| `command -v opencode` + `opencode debug paths state` + `opencode service status` + `opencode api <METHOD> <PATH>` | ✅ (Homebrew default) | ✅ (curl/install.sh) | ✅ (install.sh in WSL) | ✅ (native Windows binary via PATH) |
| `python3` + `fcntl` module | ✅ (python3 via brew/CLT) | ✅ | ✅ | ✅ (MSYS2 python); native Win32 python fails closed in `windows-gbash.sh` with probe |

## Script × OS-file map

| File | Role | OS-specific behavior | DRY notes |
|---|---|---|---|
| `os/_common.sh` | Shared helpers: `auth_flag`, `cache_put/get/has`, `require_state`, `parse_kv`, `tabs_json_path` (the SINGLE SOURCE for resolving `tabs.json`), `pool_list`, `pool_max_ordinal`, `session_body`, `find_dedup`, `dedup_guard`, `post_new_session`, `json_escape`, `json_get_field`, `title_normalize`, `worker_list`, `die`. | `PROJ_DIR` uses `os_project_dir` from the per-OS file. `tabs_json_path` honors `OPENCODE_TUI_CHANNEL`, `OPENCODE_STATE_ROOT`, `XDG_STATE_HOME` and `opencode debug paths state` in that order. | This file is the single source of every cross-OS path or token decision. The per-OS files only decide the lock mechanism. |
| `os/darwin.sh` | macOS: `python3 fcntl` lock; project dir = `pwd -P`. | `python3 -c 'import fcntl'` probe before launching (in case the python on PATH lacks fcntl, e.g. some minimal CLT stub). | Calls `tabs_json_path` (single source) and `tabs_merge_py_file`. |
| `os/linux.sh` | Linux: `flock(1)` from util-linux; merge via python3 under the lock. | `command -v flock` and `command -v python3` guards. | Calls `tabs_json_path` (single source) and `tabs_merge_py_file`. |
| `os/wsl.sh` | WSL: same as Linux + drvfs (`/mnt/c`) fail-closed guard. | `case "$_tabs" in /mnt/[a-zA-Z]/*` rejects `/mnt/c` state drives (POSIX locks unreliable across Windows/Linux processes). | Calls `tabs_json_path` (single source) and `tabs_merge_py_file`. |
| `os/windows-gbash.sh` | Windows Git Bash: `python3 fcntl` lock; project dir normalized via `cygpath -w` (or `pwd -P` fallback). | Probes `python3 -c 'import fcntl'` (MSYS2 python has it; native Win32 python does not). Converts tabs path to drive format with `cygpath -m` if available. | Calls `tabs_json_path` (single source) and `tabs_merge_py_file`. |
| `os/tui-detect.sh` | Reads-only TUI / tabs gate detector. No lock; no writes. | `/proc/<pid>/cwd` on Linux/WSL; `lsof -a -p <pid> -d cwd -Fn` fallback on macOS and Git Bash. `pgrep -x opencode` (excludes `opencode serve` / `opencode api`). Pin = major only (`2` for any `2.x.y`). | All cross-OS behavior is here, not duplicated in OS adapters. |
| `preflight.sh` | Endpoints + tabs gate discovery + cache. | Standalone (does not require `os/` adapters). Calls `os/tui-detect.sh` for the gate. | Pure POSIX. |
| `watch_run.sh` | Bounded POSIX+awk watcher (idle + outcome + artifacts + permissions). | `getopts`: POSIX. `awk` regex POSIX. `curl` universal. | No OS-specific behavior. |
| `dragon_name.sh` | Dragon catalog (100 names) + deterministic synthesis. | Pure POSIX `awk`. | No OS-specific behavior. |
| `validate_dag.sh` | In-flight DAG / scope / state validator. | Pure POSIX awk script (`#! /usr/bin/awk -f`); no shell. | No OS-specific behavior. |
| `validate_ledger_closed.sh` | Closure validator (strict + `--allow-degraded` + `--require-evidence`). | Pure POSIX awk script. | No OS-specific behavior. |
| `orchestrate.sh` | Swiss-army knife with 12 subcommands. | Sources `os/$OS.sh` then `os/_common.sh`. Subcommands use the cached state and OS adapters. | One source for each cross-OS decision; no duplication of path or lock logic. |
| `orchestrate-{darwin,linux,wsl,windows}.sh` | Explicit OS dispatch wrappers. | Just `exec sh "$(dirname "$0")/orchestrate.sh" --os <os> "$@"`. | Trivial; no logic to test. |

## Per-OS live verification

- **macOS (darwin, BSD userland)**: all 13 scripts run live; validators pass 7/0,
  4/0; preflight + tabs + pool + sessions + create-worker + ensure-root +
  wait-idle + verify-daughters + delete-session all green; TUI gate
  evaluates `running` vs `idle` correctly via `time.updated` vs `time.idle`.
- **Linux (Ubuntu 22.04 GNU userland)**: not live-verified (host is
  macOS). Code inspection only. The flock(1) lock relies on util-linux's
  package, which ships by default on Debian/Ubuntu/Fedora/Arch. The
  `tabs_json_path` honors `XDG_STATE_HOME`. If `flock(1)` is missing,
  `linux.sh` aborts with a clear error and rc=2 (fail-closed).
- **WSL**: not live-verified. Code inspection only. The drvfs guard
  prevents lock-corruption on `/mnt/c`. `/proc/version` contains
  `microsoft` on both WSL1 and WSL2 (WSL2 is the recommended path per
  upstream docs).
- **Windows Git Bash (MSYS2 or Cygwin)**: not live-verified (host is
  macOS). Code inspection only. The python `fcntl` probe fails closed
  with explicit next-step instructions if MSYS2 python is not present.

## Known limitations per OS

- **Linux + WSL**: requires `flock(1)` from util-linux. If your distro
  doesn't ship it (rare), install `util-linux`.
- **Windows Git Bash**: requires MSYS2 python3 with the `fcntl` module.
  Install via `pacman -S mingw-w64-ucrt-x86_64-python3`. Native Windows
  Python (python.org) does NOT have `fcntl`; the probe detects this and
  fails closed with explicit next-step instructions.
- **WSL on drvfs**: if the state root lives on `/mnt/c`, POSIX locks are
  unreliable across Windows/Linux processes. `wsl.sh` fails closed with
  a message pointing to the CLI plugin as the alternative.
- **macOS without `python3`**: macOS 12.3+ does not ship Python by
  default. Install via `brew install python3` or Xcode CLT. The script
  detects this and fails closed.
- **Cross-OS verification on this host**: only `darwin` was tested
  live; the other three were verified by code inspection. The first
  deployment on each should run the battery documented in the install
  section (`SKILL.md` "Quick start" + `scripts/preflight.sh`).

## How to extend this audit on a new OS

If OpenCode gains support for a new OS (e.g. FreeBSD), the change is:

1. Add `os/<newos>.sh` with `os_project_dir` + `os_tabs_merge SID TITLE
   TUI_CWD BACKUP_DIR`. Reuse `tabs_json_path` and `tabs_merge_py_file`
   from `_common.sh`. Decide only the lock mechanism.
2. Add the OS case to `detect_os` in `orchestrate.sh`.
3. Add a wrapper `orchestrate-<newos>.sh`.
4. Run `sh -n` on the new files and the battery documented above.
5. Update this matrix.

This is the DRY contract: the per-OS file is small (~25 lines) because
all the cross-OS decisions already live in `_common.sh`.