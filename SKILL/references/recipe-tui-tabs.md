# Local recipe: worker sessions and TUI tabs on Windows, Linux, and macOS

> **Unsupported fallback, pinned to a version.** This recipe only runs after the hard gate (exception: the default additive exposure in §6 with a local TUI) from [SKILL.md](../SKILL.md#decision-gates): explicit user authorization, a TUI version on the same major branch as the floor (`OPENCODE_TUI_PINNED_VERSION`; any 2.x works), a compatible lock or demonstrated exclusion, and verification by `sessionID`. If anything fails, prefer the CLI plugin tabs API or mark the tab as not verified. See [versioning and dates](research-evidence.md#versioning-and-dates).

This recipe combines a session HTTP API with a local write of tab state. **OpenCode V2's HTTP API is experimental. `tabs.json` is private TUI storage, not a public API or a stable format.** The private details in this recipe correspond to the inspected tag (pin and date in force in [versioning and dates](research-evidence.md#versioning-and-dates)); before using the fallback, confirm that the exact installed version still follows the same schema and location. If it cannot be validated, use an already-available official tabs interface; if you also cannot confirm the tab by ID, mark the tab as not verified. [API V2](https://opencode.ai/v2/docs/api/), [upstream source v2.0.21](https://github.com/anomalyco/opencode/tree/v2.0.21/packages/tui/src/context)

The task contract — including `schema_version: 3`, the `run.min_subagents_per_worker: 2` minimum, `parentID`, `location_directory`, scopes, and evidence — lives only in [ledger-template.md](ledger-template.md). The TUI displays a session; it is not a third agent and does not replace the worker or the subagents.

## 1. Discover the instance without depending on the shell or operating system

In the same user profile where the TUI runs, query `opencode service status` to get the active background service URL and `opencode debug paths state` to get the real state directory. Both commands are published by the V2 CLI; `debug paths state` locates the state and does not report the TUI's tab configuration. To inspect that effective configuration, open `Settings` → `Tabs` in the active TUI and read `Mode` and `Scope` without using the controls that change values. The concrete configuration file that resolves `tabs.mode`/`tabs.scope` is UNKNOWN to this skill: without confirming it, fail closed; `GET /api/config`, cited in this document, `requires verification` against the active `/openapi.json`. `opencode debug config` and `GET /api/config` query server configuration and do not replace that local read. If the panel is unavailable, inspect read-only the configuration file that TUI loaded to resolve `tabs.mode`/`tabs.scope` (on tag `v2.0.21`, `packages/tui/src/config/index.tsx`, linked below as "TUI resolution") and the `HERDR_ENV` inherited by its process, using the same executable, profile, and working directory; if you cannot confirm a value, fail closed. Never change or save the user's configuration. Do not hunt for the port with `lsof`, PowerShell, processes, or PIDs: the status command uses the service registry and checks availability. If it answers `stopped`, access is missing, or the service is incompatible, stop here; do not start, stop, or replace another service as automatic recovery. [CLI V2: service and debug paths](https://opencode.ai/v2/docs/cli/commands/), [TUI settings](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/component/dialog-config.tsx), [TUI resolution](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/config/index.tsx), [server debug config](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/commands/handlers/debug/config.ts)

The background service corresponds to `opencode serve --service` in the inspected upstream; the published CLI manages that process via `opencode service start/status/stop`. This recipe only discovers/reuses the active service; it neither starts nor stops it implicitly. [service ensure](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/client/src/effect/service.ts), [CLI V2: service](https://opencode.ai/v2/docs/cli/commands/)

Verify the URL with `GET /api/info` and query `/openapi.json` on that same endpoint. The session HTTP routes are experimental. Reuse the authenticated CLI/API client whenever possible; `opencode api` is a documented interface that talks to the server. [API V2](https://opencode.ai/v2/docs/api/), [CLI V2: api](https://opencode.ai/v2/docs/cli/commands/)

### Direct HTTP authentication, only if needed

The inspected upstream implementation keeps two distinct files with the same name: the configuration under the `config` directory, and the active registry under the `state` directory. The configuration accepts `hostname`, `port`, `password`, `cors`, and `env`; the active registry contains `id`, `version`, `url`, `pid`, and an optional `password`. The registry is derived as `STATE_ROOT/service.json` for the `latest`, `dev`, `beta`, and `next` channels, and `STATE_ROOT/service-CHANNEL.json` for other channels. These conditions are the only permitted exception to the "do not hunt for secrets" rule in the [failure matrix](failure-matrix.md). To authenticate a direct call, use only the active registry matching the confirmed URL, PID, and version; do not confuse the two files or read `~/.config/opencode/service.json` as a universal path. This package's scripts (`SKILL/scripts/preflight.sh`) read only `STATE_ROOT/service.json`: on an installation from another channel, export `OPENCODE_STATE_ROOT` pointing to that channel's state or use the CLI instead of the registry-based fallback. [service-config.ts](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/services/service-config.ts), [service-registration.ts](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/services/service-registration.ts), [discovery and auth](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/client/src/effect/service.ts)

The CLI obtains the root state with `opencode debug paths state`; the upstream uses `XDG_STATE_HOME` when defined and, failing that, the user's home followed by `.local/state/opencode`. The inspected source does not use `%LOCALAPPDATA%` as a universal rule. So do not hardcode any per-operating-system path. On a direct HTTP call, the upstream uses HTTP Basic with the user `opencode` when the registry carries a `password`; send credentials only to the active URL you confirmed as the expected endpoint, which must be loopback or HTTPS. Build the header in memory and never put it in process arguments, shell history, prompts, the ledger, or logs. If you cannot obtain the active credential without exposing it, use the authenticated CLI or block the call. The `preflight.sh` internal fallback that reads `$HOME/.config/opencode/service.json` is a script implementation detail pending alignment with this doctrine: an orchestration direct call uses only the confirmed channel's active registry. [global-roots.ts](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/util/src/global-roots.ts), [service status](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/commands/handlers/service/status.ts), [API V2](https://opencode.ai/v2/docs/api/)

## 2. Create a root `worker_session` session

Before creating it, take `run.location.directory` from the canonical location reported by the instance and the orchestrator session. That location belongs to the OpenCode server: pass it literally, in the format the server returns, on Windows, Linux, and macOS alike. Do not rebuild it from the client program's current directory or change separators. [API V2: location and session.create](https://opencode.ai/v2/docs/api/)

The canonical policy for explicit `agent`/`model` from the active catalogs — exact pair, conditional `variant`, and blocking on unconfirmed values — is step 2 of [api-and-sessions.md](api-and-sessions.md#root-worker-session-creating-and-opening-a-tab-are-distinct-actions). Here only the operational part: send `POST /api/session` with explicit `location`, `agent`, and `model`.

Send `POST /api/session` with explicit `location`, `agent`, and `model`; this body is a template: replace every `{{...}}` (including the double braces) with confirmed values; it is not valid JSON until you do:

```json
{
  "title": "{{short worker title}}",
  "agent": "{{exact agent id from the active catalog}}",
  "model": {
    "id": "{{exact model id from the active catalog}}",
    "providerID": "{{exact providerID associated with the model}}"
  },
  "location": {
    "directory": "{{exact run.location.directory}}"
  }
}
```

`agent` and `model` remain optional in the HTTP schema; sending them is this skill's policy, not a claim about the server's required contract. The HTTP response wraps `Session.Info` in `data`; store `data.id` as the `sessionID` (`response.data.id` with the generated client). The response creates a session; it does not open the tab. Re-read `Session.Info` and verify `parentID: null` and the `location.directory` identical to the run's. Do not retry an uncertain creation without reconciling first. [API V2: create session](https://opencode.ai/v2/docs/api/)

Send the initial prompt to `POST /api/session/{sessionID}/prompt` with `text` required and only optional fields published by `/openapi.json`. The worker prompt must convey goal, context, constraints, criterion, and evidence; execute the pre-authorized `subagent` rows in the prompt (at least two distinct, with child scopes included in their budget); forbid simultaneous writes in overlapping scopes; require inspection and integration of both results and a report the orchestrator can read. Do not ask the worker to invent a return channel. [API V2: session.prompt](https://opencode.ai/v2/docs/api/), [Tools V2](https://opencode.ai/v2/docs/tools/)

Every child is launched inside the worker session with the native `subagent` tool. Row identity and the `verified` criterion: [ledger-template.md](ledger-template.md); child verification: [single location rule](subagent-contract.md#single-rule-for-child-location). The `POST /api/session` API does not invoke that tool.

## 3. Resolve the tabs path from the actual TUI client

The v2.0.21 TUI resolves `tabs.mode=auto` and `tabs.scope=cwd` when there is no override. `tabs.mode` takes precedence over the legacy `tabs.enabled`; if `mode` is missing, the legacy `enabled` maps `true` to `on` and `false` to `off`. The effective `auto` mode is enabled except when `HERDR_ENV=1` is in the TUI process environment; an effective `mode` of `on` or `off` decides directly. Obtain the TUI client's exact channel; if an already-existing plugin integration exposes it, the documentation defines `context.app.channel` and `context.app.version`, but this package does not add a plugin. On the verified tag, storage is created under `state/CHANNEL/tui`, and the service registry uses the `state` directory with a channel-dependent file name. Never guess `latest`; if the exact version or channel cannot be established, do not edit the file. [CLI configuration: tabs](https://opencode.ai/v2/docs/cli/config), [CLI plugin API: context](https://opencode.ai/v2/docs/build/plugins/cli/), [TUI configuration v2.0.21](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/config/index.tsx), [TUI storage](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/storage.tsx), [service-config.ts](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/services/service-config.ts)

### Version gate: branch, not exact pin

The gate does not require exact version equality. It accepts **any version of the same major that is `>=` the floor** (`OPENCODE_TUI_PINNED_VERSION`, by default the package's branch-2 value). A newer `2.x` works; a `3.x` blocks, because the schema may have changed there.

The underlying reason: what is protected is not the version number but **the `tabs.json` schema**. That is why the merge validates the file's shape before writing and fails closed on a mismatch (`global.tabs` list, `cwd.PROJECT_PATH.tabs` list, `unread` object, every tab with a string `sessionID`). That validation — not the version string — is the real guarantee, and it is what makes accepting the whole branch 2 safe. Raise the floor only with evidence that the schema did not change, not because the version exists.

With the gate blocked, `attach-tabs` fails closed and writes only with `--force-tabs`, which is the operator's explicit authorization.

The `v2.0.21` tag stores `tabs.json` in this shape:

```json
{
  "global": {
    "tabs": [{ "sessionID": "ses_...", "title": "Worker" }],
    "unread": {}
  },
  "cwd": {
    "{{exact cwd of the TUI process}}": {
      "tabs": [{ "sessionID": "ses_...", "title": "Worker" }],
      "unread": {}
    }
  }
}
```

Each row accepts a `sessionID` and an optional `title`. If `tabs.scope` is `global`, modify only `global`; if it is `cwd`, the key comes from the TUI process's `paths.cwd`. That value is normally the directory the TUI was launched from and **is not guaranteed to equal** `Session.Info.location.directory`. Use `run.location.directory` as the key only after verifying both values are literally equal. Do not create a key with the server path on the assumption it matches the local CWD. The TUI normalizes tab IDs to the session root; add only root worker IDs. [session-tabs.tsx](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/session-tabs.tsx), [session-tabs-model.ts](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/session-tabs-model.ts)

## 4. Merge and write with verification

The TUI file is private and its schema can change. If it already exists, read it just before the update and validate the full shape. Preserve all tabs, `cwd` keys, properties, and `unread` maps; add only each missing root worker and deduplicate by `sessionID`. If it does not parse, has a different schema, or the location/tab does not match, stop without overwriting it. If it does not exist, initialize only the schema confirmed for the installed version.

The fallback may write only if it makes a prior backup outside the tree watched by the TUI and holds, through read, merge, write, and readback, the same `Flock`-compatible lock the TUI takes on `tabs.json`, or if it can demonstrate effective exclusion of the TUI writer for that whole operation. A different lock or an unverifiable pause is not enough. If you cannot guarantee that lock or that exclusion, do not edit `tabs.json`: use an already-available official tabs interface; if none lets you confirm the ID, fail closed and mark the tab as not verified. When the concurrency gate does hold, make a prior backup of the file stored outside the tree watched by the TUI and write the full JSON **over the same descriptor you hold locked** (seek to 0, truncate, write, flush, and fsync). Temp file + atomic rename is FORBIDDEN here: it destroys the inode the lock was taken on, so two concurrent writers could lose a tab while both reported success (S1b-10). Rename atomicity is sacrificed to preserve real mutual exclusion; the backup covers a crash mid-write. Read the destination back and check that every ID appears exactly once and the other entries are still present.

On tag `v2.0.21`, the TUI uses `Flock.withLock` on the `tabs.json` file with the lock directory under `state/CHANNEL/locks`, writes with temp/rename, and watches the folder to reload storage after external changes. An external writer that does not take the same lock can race a TUI update and lose changes; that is why the fallback above fails closed when it cannot take a compatible lock or demonstrate writer exclusion. The watcher can fail and live reload is an implementation detail, not a public contract. [TUI storage](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/storage.tsx), [TUI persistence](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/util/persistence.ts)

## 5. Confirm the visible result and the work

Check each row's `sessionID` in the local state and verify the real tab. The plugin interface documents `context.ui.tabs.open(sessionID)`, `context.ui.tabs.list()`, and `context.ui.tabs.focus(sessionID)`; use it if it is already available in the client. No plugin code is added to this package. In the TUI, an existing session can be opened with `/sessions` or `Ctrl+X`, `L`. Before real work, the active `/openapi.json` must confirm a send route and a read capability for the same session; the orchestrator then sends a unique test nonce and reads the worker's response to validate the exact same `sessionID` and nonce. In this recipe the handshake is mandatory (the `tabs.json` row and the tab do not prove the worker responds); on the default path of [api-and-sessions.md](api-and-sessions.md#root-worker-session-creating-and-opening-a-tab-are-distinct-actions) it is optional (R3a). Without both channels confirmed, do not send the work. When finished, the orchestrator reads the worker session's integrated output through that confirmed read capability and verifies its subagents' results and evidence; do not presume direct messaging between root sessions. A written row does not prove the TUI loaded it or that the worker responded; if the round-trip, the result read, or the tab confirmation by ID is missing, keep the unknown/blocked state and mark the tab as not verified. [CLI plugin API: tabs](https://opencode.ai/v2/docs/build/plugins/cli/), [TUI V2](https://opencode.ai/v2/docs/cli/tui/)

The orchestrator verifies the worker's integrated output, the two verified subagent children, their IDs/relationships/locations, and the inspection evidence. Only the orchestrator writes the ledger. If creation, identity, location, tab, scopes, or the result channel fail, keep the corresponding unknown/partial/blocked state; never fake a minimum or a success. [ledger-template.md](ledger-template.md), [failure matrix](failure-matrix.md)

## 6. Default tabs when a local TUI is present

Default behavior under the tabs gate of [SKILL.md](../SKILL.md#decision-gates): if there is an active local TUI on the orchestrator's machine and both the exact version matching the inspected one and a compatible lock hold, the orchestrator adds each newly created root worker session as a tab, without waiting for an explicit request.

Apply the canonical procedure from [§4](#4-merge-and-write-with-verification) (read, backup outside the watched tree, `Flock` lock, additive merge, atomic write, and readback) with two differences: (1) resolve the **TUI process's real cwd** as the `cwd` key (§3); do not use `run.location.directory` as the key except after literal equality verification; (2) the tab stays **"not verified"** until confirmed by `sessionID` (§5); a written row does not prove the TUI loaded it.

Without an active local TUI, or if any step cannot be completed, `tabs.json` is not written and the tab is marked "not verified".

## Sources consulted

- [HTTP API V2](https://opencode.ai/v2/docs/api/) — experimental surface, `session.create`/`session.prompt` schemas, identity and location.
- [CLI V2](https://opencode.ai/v2/docs/cli/commands/) — `service status`, `debug paths`, and `api`.
- [CLI configuration](https://opencode.ai/v2/docs/cli/config) — `tabs.mode` and `tabs.scope`.
- [TUI V2](https://opencode.ai/v2/docs/cli/tui/) — opening existing sessions.
- [CLI plugin API](https://opencode.ai/v2/docs/build/plugins/cli/) — public tab methods for plugins.
- Private sources cross-checked against the exact tag [`v2.0.21`](https://github.com/anomalyco/opencode/tree/v2.0.21): [roots](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/util/src/global-roots.ts), [service config](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/services/service-config.ts), [service registration](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/services/service-registration.ts), [debug config](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/commands/handlers/debug/config.ts), [TUI config](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/config/index.tsx), [TUI configuration](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/component/dialog-config.tsx), [TUI tabs](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/session-tabs.tsx), [tabs model](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/session-tabs-model.ts), [storage](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/storage.tsx), and [persistence](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/util/persistence.ts).
