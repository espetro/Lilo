# Agents settings

Design note for a standalone Settings > Agents section, written against `develop` at 243e2218 (2026-11-20). It changes no code. It audits what the section does today, studies five references (T3 Code, vercel-labs/skills, the ACP registry, Zed, BrowserOS neo), and proposes a phased expansion. [../AI-AGENTS.md](../AI-AGENTS.md) is the user-facing description of what agents do; [../AGENT-HARNESS-PLAN.md](../AGENT-HARNESS-PLAN.md) plans the tool surface and consent internals; this note plans the settings surface only.

## 1. Current state

### What the section is today

One page, three groups (`settingsPanelModel.ts`, `SETTINGS` under section `agents`):

```
Settings > Agents
├─ Conversations with your agents     (ACP, Lilo launches the agent)
│   ├─ agentsEnabled                  toggle
│   ├─ agentsNotifyDone               toggle      (requires agentsEnabled)
│   ├─ agentSystemPrompt(+Text)       subpage     (requires agentsEnabled)
│   └─ customAgent                    subpage     (requires agentsEnabled)
├─ Agent access                       (MCP, the agent drives Lilo)
│   ├─ agentControl                   toggle      master switch, opens the socket
│   ├─ agentAskBeforeActions          toggle      (requires agentControl)
│   ├─ agentActionLog                 toggle      (requires agentControl)
│   └─ agentAlwaysAllowed             site list   (requires agentControl)
└─ Agent clients
    ├─ client tiles                   SettingsAgentRows.svelte
    └─ agentOther                     "copy generic config" row
```

### The two directions, and how each is configured

**Agents Lilo runs (ACP).** `ACPAgentCatalog` fetches `cdn.agentclientprotocol.com/registry/v1/latest/registry.json`, caches it on disk for 24 h, resolves `binary`/`npx`/`uvx` distributions (SHA-256 checked for binaries, pinned installs under the app's support folder), and launches the agent itself for conversations. Four featured ids are hardcoded as fallback. The only settings surface is `customAgent`: one JSON blob (`name`, `executable`, `arguments`, `environment`) edited through a four-field form, so Lilo supports exactly one custom command. Agents are picked in the `AskBar` dropdown (`agentsLastAgent` remembers the last one); every runnable agent the registry offers appears, enabled or not. Sign-in happens inside the conversation (`SignInCard`), nowhere in settings.

**Agents that drive Lilo (MCP).** `AgentSocketServer` binds a user-private Unix socket; the `lilo-mcp` helper in the app bundle pipes a client to it (stdio transport only). `AgentClientConfig` is a four-case enum (`claudeCode`, `claudeDesktop`, `codex`, `cursor`) with hand-written writers per client: `claude mcp add` for Claude Code, a `mcpServers.lilo` JSON merge for Claude Desktop and Cursor, a `[mcp_servers.lilo]` TOML table for Codex. Detection reads the same files back (`connectedClients`) plus app/binary fingerprints (`iconApp`). Each tile in SettingsAgentRows shows installed/configured/allowed/connected/acting status with Connect or Revoke buttons; `agentOther` copies a generic `{"mcpServers":{"lilo":{"command":…}}}` blob to the clipboard. `repairMovedConfigs` repoints stale paths at launch.

**Permissions.** The connection gate approves each client once by name plus code identity (`AgentMCP.ask`, persisted in `agentAllowedClients`); the action gate asks before consequential clicks and non-GET fetches (structure-first, word list as fallback), keeps a global always-allowed host list (`agentAlwaysAllowedSites`), always asks for file uploads, and asks once per client for borrowing a user profile. The action log writes one JSONL line per call to `Agents/Actions/` (per-client file, rotated at a size cap; `AgentActionLog`).

### What is manual and unorganized

- **Four hardcoded clients.** Every other MCP-capable harness (Zed, VS Code, OpenCode, Gemini CLI, Goose, Windsurf, Claude Code project scope, JetBrains) gets a JSON blob on the clipboard and no guidance: the user must find the right file, format and merge rules alone. The enum knows each client's config but nothing else does; adding one means a new case, a new writer and a new detector in the same switch.
- **No discovery.** Lilo checks the four known fingerprints but never scans for harnesses it does not know. A user with OpenCode installed sees nothing suggesting Lilo can wire it.
- **No preview.** Connect writes immediately; the user cannot see which file changes or what gets added before it happens. Removal is equally invisible (there is no Disconnect; Revoke only withdraws the stored approval).
- **Registry agents are managed nowhere.** The catalog exists only to launch conversations. There is no list of enabled agents, no per-agent environment or arguments beyond the single custom agent, no disabled state, no way to prefer an installed binary over the registry distribution, and no surface for auth status outside a live conversation.
- **Permissions are global.** One ask/allow switch and one site list cover every client. The consent model already keys stored approvals and asks by client identity, but nothing in settings distinguishes them. The action log has no viewer: it is a write-only JSONL dump the user would have to know exists.
- **Browser config is invisible to agents.** The 33 tools expose tabs, pages and devtools but nothing about Lilo itself. An agent that needs "which profile can I use" calls `list_profiles`; anything else (is the blocker on, which is the terminal, what is the default zoom) cannot be read at all.

## 2. Reference research

### T3 Code (pingdotgg/t3code): providers and the ACP registry

T3 Code's model is **provider instances**. Settings → Providers lists configured instances; "Add provider" runs a wizard (Provider → Identity → Config, or Sign-in for registry agents). An instance is a label, an accent color, an instance id and driver-specific config: environment overrides, an executable override, custom model ids, an authentication method (`apps/web/src/components/settings/AddProviderInstanceDialog.tsx`, `AddProviderInstanceDialog.logic.ts`, `docs/user/providers-acp.md`).

Registry discovery is a search step in the wizard (`AcpRegistrySearchStep.tsx`): query the registry, show agents minus the ids T3 ships as first-class providers (`FIRST_CLASS_REGISTRY_AGENT_IDS`), Add prepares (downloads) the agent, then the sign-in step. "Local ACP command" is a separate wizard branch: executable, one literal argument per row, env overrides. The contract layer (`packages/contracts/src/acpRegistry.ts`) defines the whole lifecycle: `search`, `prepare`, `probe` (a disposable ACP session that reports models, auth methods, config options and session management capabilities: list/load/resume/delete/logout), session import into threads, and write-only secret headers.

Permissions are **per-thread modes**, not per-tool rules: Supervised, Auto-accept edits, Auto, Full access, set in the composer, default under Settings → Threads, with per-provider degradations documented (`docs/user/permission-modes.md`). ACP agents run their own tools in their own mode; T3 answers their approval requests by the thread's mode.

What transfers to Lilo: the instance concept (a list of named, enabled agents rather than one custom blob), the wizard shape (pick from registry or add a command), environment overrides per instance, and probing the agent for its auth methods and models rather than hardcoding them.

### vercel-labs/skills: harness detection as a table

`src/agents.ts` is one declarative record of ~80 harnesses, each `{ name, displayName, skillsDir, globalSkillsDir, detectInstalled, showInUniversalPrompt, globalReadsCanonical }`. `detectInstalled` is a path-existence check against config dirs, app bundles or env-var-defined homes (`$CLAUDE_CONFIG_DIR`, `$CODEX_HOME`, …). `detectInstalledAgents` runs all predicates and returns what is present; install then symlinks a canonical `.agents/skills` into each harness's own dir, skipping the harnesses that read the canonical location anyway. `detect-agent.ts` separately detects when the CLI itself runs inside an agent via environment markers.

What transfers: discovery is data, not code. A per-harness entry (detect paths, config path, format, entry shape) replaces Lilo's enum switch, and new harnesses become rows, not cases. Also their `verified` discipline: each entry carries the date and the doc URL its config shape was last checked against (visible in BrowserOS's catalog, below), which is the honest answer to "per-harness config shapes go stale".

### ACP registry (agentclientprotocol/registry)

The registry is the shared discovery source (`FORMAT.md`): per-agent `id`, `name`, `version`, `description`, `repository`, `license`, `icon`, and `distribution` with `binary` per-platform archives (`archive`, `sha256`, `cmd`, `args`, `env`), `npx` or `uvx` package specs, plus an optional `preview` channel served as a separate published file. ~50 agents today (claude-acp, codex-acp, gemini, cursor, goose, opencode, kiro, pi-acp, devin, …). Icons are served per id from the CDN, which is how T3 and Lilo both render tiles without bundling marks.

What transfers: the registry is the enable-list source for (a); Lilo already implements the whole consumer side (`ACPAgentCatalog.parse`, icon cache, pinned installs, checksum verify). What it lacks is only the settings model around it.

### Zed: agent_servers and the registry

Zed's External Agents page offers "Install from Registry" and "Add Custom Agent"; a custom agent is an `agent_servers.<id>` settings entry `{ "type": "custom", "command": …, "args": […], "env": {} }`, and registry-installed agents accept per-agent overrides under the same key (`docs/src/ai/external-agents.md`). The boundary is explicit: the agent owns auth, models and its native config; the editor owns the list and the launch command.

What transfers: the custom-agent shape Lilo already has is the Zed shape. Making it a list (`agent_servers`-style named entries) rather than a single JSON is the small move that unlocks several custom harnesses.

### BrowserOS neo: the connect board and harness-integrations

BrowserOS neo's MCP page is the closest shipped equivalent of what (b) and (c) ask for: one endpoint at the top, then a board of supported AI tools with a Connect button each; the row flips to Connected when the tool's config actually names the server (`docs/neo/mcp/index.mdx`). The implementation is a catalog, `packages/browseros-agent/crates/harness-integrations/src/catalog.rs`: seven harnesses (Claude Code, Codex, Cursor, OpenCode, Antigravity, VS Code, Zed), each a `HarnessDefinition { install_check_paths, mcp: McpSurface, skill }` where `McpSurface` declares per-OS `system_paths` (with `$ENV` expansion), the project-scope file, the `ConfigFormat` (Json, Jsonc, Toml), supported transports and `StdioShape`/`HttpShape` (top-level key, nested servers key, field names, tag keys, per-harness `injects` like Zed's `"source": "custom"` or OpenCode's `"type": "local"`, plus notes citing the first-party doc each shape was verified against). `mcp/paths.rs` detects installed harnesses from fingerprints; `mcp/manager.rs` plus `planner` produce a *plan* (`plan_link`, `plan_unlink`, `plan_rescan`, migration) that `apply_plan` executes, which is exactly the diff-preview architecture: plan, show, apply.

What transfers: the catalog-as-data for (c), the install fingerprints for (b), the plan/apply split for the write preview, and the `sources.verified` field as the answer to config-shape drift. What does not: BrowserOS serves one HTTP endpoint, so its shapes cover stdio/sse/http plus OAuth headers; Lilo ships one stdio command, so its surface is a fraction of that table.

## 3. Proposal

Four capabilities, each small, in dependency order. The section keeps its name and gains a fourth group; the existing three are reorganized so each direction (Lilo runs agents / agents drive Lilo) has one provider list and one permission story.

```
Settings > Agents
│
├─ Agents you talk to                                    ← (a)
│   ├─ toggle: Conversations with your agents (existing)
│   ├─ notify when done / system prompt (existing)
│   └─ AGENTS ─────────────────────────────────────────
│      ● Claude Agent      registry · signed in    [on]
│      ● Codex             registry · installed    [on]
│      ● dsh               command   /usr/local/bin/dsh --profile acp
│                                                    [on]
│      ○ Gemini CLI        registry                [off]
│      [+ Add agent]  → registry search | custom command
│
├─ Agents that drive Lilo                                ← (b)+(c)
│   ├─ toggle: Let agents use Lilo (existing master switch)
│   └─ APPS ───────────────────────────────────────────
│      ● Claude Code       connected · acting 3 tabs   [Revoke]
│      ● Codex             configured                  [Preview]
│      ○ OpenCode          installed, not set up       [Connect]
│      ○ Zed               not installed               —
│      [Other…] generic JSON to copy (existing)
│
├─ What agents may do                                    ← (e)
│   ├─ Ask before acting            toggle (existing)
│   ├─ Per client ── Claude Code ──────────────────────
│   │   Read pages            [allow]
│   │   Act on pages          [ask]   · always allowed: 2 sites
│   │   Sensitive (uploads,   [always ask]
│   │   payments, profiles)
│   ├─ Per client ── Codex ── (same three rows)
│   └─ Sites always allowed   host list (existing)
│
└─ Activity                                              ← (e)
    ├─ Record agent actions   toggle (existing)
    └─ [Open action log]      ~/Library/…/Agents/Actions
```

### (a) ACP agent providers: configured, listed, enabled

Model on T3's instance list, cut to what conversations need.

- `agentAcpInstances`: a JSON array in the settings store, each `{ id, source: "registry"|"command", registryId?, name, executable?, args?, env?, enabled }`. Today's `customAgent` JSON migrates to the first `command` entry.
- The group lists every instance with its registry icon (the catalog already caches them), a state line (installed, needs Node/uv, signed in when a probe reports it), an enable toggle, and Edit/Remove for command entries. Disabled ids are filtered out of the `AskBar` picker; `runnableAgents` already returns the full set, so the picker joins it with the list instead of changing shape.
- "+ Add agent" opens a sheet with two tabs: **From registry** (search over the already-cached `ACPAgentCatalog.agents`, Add writes an instance; no install until first use, as today) and **Custom command** (the existing `SettingsCustomAgent` form, reused per instance: name, executable, one argument per line, `NAME=value` env lines). T3's wizard steps Provider → Identity → Sign-in collapse to this one sheet because Lilo defers sign-in to the conversation.
- Deferred on purpose: multiple instances of one registry agent, per-instance model pickers (models belong to `session/new`, offered in the conversation's model menu), executable overrides, session import. Each has a home in [AGENT-HARNESS-PLAN.md](../AGENT-HARNESS-PLAN.md) stage 6; none is needed for the list to be useful.

### (b) Auto-discovery of installed harnesses

One cheap pass when the Agents section opens, nothing at idle:

- `connectedClients` already reads the four config files; generalize to a **harness catalog** entry `{ id, name, detect: [paths], icon, config: ConfigSpec, docsURL, verified: date }`, where `detect` covers app bundles (`/Applications/Cursor.app`), home config dirs (`~/.codex`, `~/.claude`), binaries on the user PATH (the existing `binary()` lookup) and env-var homes (`$CLAUDE_CONFIG_DIR`, `$CODEX_HOME`) — the same fingerprint style as vercel-labs/skills and BrowserOS's `install_check_paths`.
- Tiles get a fourth state: **detected, not configured** ("OpenCode is installed"), which is the discoverable one-click path. Not-installed catalog entries collapse under a "More apps" disclosure so the board stays short.
- MCP is the discovery surface Lilo controls; ACP-side, "discovery" is the registry (already fetched) plus detecting an agent's own CLI on PATH for command entries (a `command` instance whose executable exists gets a "runs" badge — cheap, no launch needed).

### (c) Lilo as MCP server: one-click, per harness, with preview

Keep the writers, make them data, show the diff first.

- `AgentClientConfig.Client` becomes the same catalog as (b): `ConfigSpec { paths: [candidate paths, first existing wins else first resolvable], format: json|jsonc|toml, topKey: "mcpServers", entry: {"command": helperPath} | {"type":"stdio",…} | tomlTable, injects: [(key, value)] }`. Lilo's transport is one stdio command, so the spec is far smaller than BrowserOS's `McpSurface`; the per-harness quirks that remain are Codex's TOML, Zed's `context_servers` key plus `source`/`enabled` injects, Gemini's `mcpServers` under `settings.json`, and OpenCode's `type: "local"`.
- Claude Code keeps its CLI path (`claude mcp add` owns `~/.claude.json` semantics); everything else is a merge that preserves other keys, as today.
- **Preview**: Connect opens a sheet showing the resolved file path and the exact lines Lilo will add (unified-diff style: existing `mcpServers` context faded, the `lilo` entry highlighted), with Write, Copy and Cancel. Already configured → the sheet shows the live entry and offers Remove (new) and Repair when the helper path moved (`repairMovedConfigs` already knows how).
- Candidate first additions, cheap because the writers converge: Zed (`~/.config/zed/settings.json` on macOS per Zed's docs; verify at implementation), VS Code (`~/Library/Application Support/Code/User/mcp.json`), OpenCode (`~/.config/opencode/opencode.json`, `type: "local"`), Gemini CLI (`~/.gemini/settings.json`), Goose (`~/.config/goose/config.yaml` — YAML, so mark "copy" until a YAML writer exists; honest about format coverage). Each catalog row cites its first-party doc and a `verified` date, following BrowserOS's `McpSurfaceSources`.

### (d) Lilo config as a read-only tool

One tool, `browser_config`, returning a curated snapshot agents legitimately need: Lilo version, whether the blocker is on, the default zoom, the terminal program, the agent's own permission state (allowed sites, ask-before-acting, whether the action log is on), and non-private space names so a task can name where it should work.

- **Read-only is a hard line**: no setter, ever, through MCP. A write path would let a hijacked session edit its own permission store; if agents ever need to change config it is a separate proposal with per-key approval.
- **An allowlist, not a store dump**: keys are named in code, mapped by hand. `settingsStore` holds things an agent must not read (exact profile identities beyond what `list_profiles` gives, per-site permission grants, private data). Private Spaces are never listed (existing rule: agents can never see them).
- Shape: `{ "lilo": "0.9.1", "features": { "contentBlocker": true, "askBeforeActions": true }, "agent": { "allowedSites": ["example.com"], "actionLog": true }, "spaces": [{ "id": "…", "name": "Work" }] }`. It costs nothing at idle and one serialization per call.

### (e) Permissions: what is feasible, and how it shows

The consent model is already client-aware (`AgentConsentTests`, `agentAllowedClients`, per-client approvals) and the action gate already distinguishes read-never-asked from consequential-asked. The gap is configuration surface, and, for tiers, the classifier [AGENT-HARNESS-PLAN.md](../AGENT-HARNESS-PLAN.md) stage 3/8 plans.

**Feasible now, with the existing machinery:**

| Tier | What it means | Config surface |
|---|---|---|
| Read | read tools (`read_page`, `find`, `get_page_text`, `read_console_messages`, `list_profiles`, …) | never asked, per existing design; not configurable |
| Act | consequential actions on a page (click, Enter, fetch non-GET) | global ask/allow + per-site allow (exists); **per-client default**: ask / always ask / allow (new) |
| Sensitive | file uploads, profile borrow, payments-shaped submits | always ask (uploads and profiles already are); never allow-listed |
| Connect | new client handshake | once per client + code identity (exists); per-client Revoke (exists) |

- **Per-client defaults** are the smallest real step: the consent decision already knows the client; storing `ask|always` per client id in the allowlist record makes "Codex may act on example.com, Claude must ask" expressible without a policy engine. UI: each client's tile in the "Agents that drive Lilo" group gains a detail row (the three-tier table above), reusing `SettingsAgentRows`.
- **Per-site × per-client**: extend `agentAlwaysAllowedSites` entries from `host` to `{host, client?}`; a grant with no client keeps today's global meaning. UI stays one list with a client badge.
- **Per-tool deny**: the `tools/call` dispatch in `AgentMCP.handle` is a single choke point, so a per-client tool deny-list is a `Set<String>` check before dispatch. Worth doing only for whole tools; note that `computer`, `run`, `javascript_tool` and `devtools_command` span tiers by argument, so a tool-class tier for them needs argument-level classification — which is exactly the stage 3 work on `consequential`. Until then, advertise tool-deny for the unambiguous tools only, or hold it.
- **Audit log viewer**: the JSONL exists; phase it as "Open action log" (reveal in Finder) first, an in-app recent-calls list (tail N lines per client, redacted as the writer already redacts) second. The viewer is what makes ask/allow/deny auditable rather than trust-based.

**Not yet technically possible, flagged:**

- **Argument-level tiers** (allow `computer` scrolls but always ask on submits): needs the classifier result plumbed into dispatch as a tier enum; today `consequential` is a boolean inside `AgentPage.js`. The consent-enum work in [AGENT-CONSENT-MODEL.md](../AGENT-CONSENT-MODEL.md) is a prerequisite.
- **ACP-side permissions for agents Lilo launches**: an ACP agent's fs/terminal activity is its own process's business; Lilo can only gate what the agent does in the browser, through the same tool path. A per-agent browser-permission column in the (a) list is possible only because conversations drive the same consent path (client name is the agent id).
- **Session-scoped grants** ("allow this site for this run"): deliberately out per AGENT-CONSENT-MODEL (a standing permission a prompt-injected agent reuses; no evidence the once/always gap is real).
- **ACP permission modes** (T3's Supervised/Auto/Full access): requires Lilo to translate its consent answers into per-mode replies and the agent to honor ACP `session/request_permission` options; the modes themselves belong to the agent. A "mode" for how Lilo answers an ACP agent's browser-side questions is feasible (the same per-client default), labeled differently to avoid promising the agent's sandbox semantics.

## 4. Phase breakdown

Each phase is one issue + one PR, sized for a single session, in merge order. Phases 1–3 are independent; 4 needs 1; 5–6 are independent of all.

| # | Phase | Scope | Size |
|---|---|---|---|
| 1 | Harness catalog | `AgentClientConfig` enum → declarative `HarnessDefinition` table (detect paths, config spec, docs URL, verified); no behavior change beyond making add/remove/repair table-driven | ~300 lines Swift |
| 2 | Connect preview + Remove | sheet showing target path and the exact entry/lines before write; Remove for configured clients; repairs reuse the sheet | ~250 lines UI + writers |
| 3 | Discovery + more harnesses | fingerprint scan on section open; add Zed, VS Code, OpenCode, Gemini CLI; "detected, not configured" state; "More apps" disclosure | ~200 lines + catalog rows |
| 4 | ACP providers list | `agentAcpInstances` array, migrate `customAgent`; enabled list UI; "+ Add agent" sheet (registry search + custom command, reusing `SettingsCustomAgent`); `AskBar` filters disabled | ~350 lines UI + settings migration |
| 5 | `browser_config` read-only tool | curated allowlist serializer + tool definition + docs-site regeneration (`make docs-build` reads the tool catalog) | ~150 lines Swift |
| 6 | Activity surface | "Open action log" reveal button; per-client recent-calls list (tails the JSONL the user opted into) | ~200 lines UI |
| 7 | Per-client permission defaults | `ask|always` per client for Act tier; per-site×per-client allowlist entries; client detail row in settings | ~250 lines, needs the consent path to read the client key (exists) |
| 8 | Permissions tiers UI | lands only after AGENT-HARNESS-PLAN stage 3 classifier tiers exist; three-row table per client as mocked | blocked, do not start |

Watch items per phase: locales (every new string in all 15 catalogs), `docs-check` whenever a watched file changes (settings model, tool catalog), and a release note per phase that users notice.

## 5. Open questions

- **Registry trust**: enabling a registry agent installs third-party code (npx/uvx/binary). T3 warns "review source and license"; does the add sheet show repository + license from the registry entry (both are in the format), or is that noise? Leaning: one line of meta under the name.
- **Instances or agents**: is one instance per registry agent enough (KISS), or does the first concrete need for two (e.g., work/personal Claude) justify T3's full instance model now? Proposal assumes one; a second instance is `source:"command"` pointing at the same binary with different env, which lands free with (a).
- **Zed's settings.json is user-owned and comment-tolerant**: JSONC read support is needed before Zed lands in phase 3, or Zed waits for a JSONC-tolerant merge (write only if the file parses as strict JSON, else show copy instructions — same fallback `mergeServer` uses today).
- **YAML for Goose**: no YAML writer in the codebase; catalog marks it copy-only until one exists, or Goose is left off the board.
- **Does enabling/disabling an ACP agent also hide its conversations?** Proposal: no — the toggle filters the picker, existing conversations keep working (a disabled agent's conversation still resumes). Confirm this matches the mental model of "enabled".
- **browser_config scope**: should it expose enabled *settings* at all, or only agent-relevant capabilities? The safer minimal version exposes only the agent's own state (its permissions, its allowed sites, Lilo's version); broader browser config can grow per-key as needs appear.
- **Where does the action log live long-term**: JSONL per client under `Agents/Actions` suits tail-and-show; if the timeline plan (stage 4) lands, the viewer reads the same files — no migration needed.
