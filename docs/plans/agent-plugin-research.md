# Research: from three agent workflows to a core + plugin surface

Research note, 2026-11-23. No code changed. It answers: Lilo now serves agents three ways — (A) outside Lilo (Claude Code, Codex, …) over MCP, (B) inside Lilo over ACP, (C) headless (scripts, cron). (A) and (C) scale for free: the user's harness packages the features, Lilo is a tool. (B) pulls every orchestrator's feature demands into Lilo itself — good for adoption, a maintenance treadmill. Can we keep (B)'s adoption while shrinking what Lilo must maintain? Companion to [AGENT-HARNESS-PLAN.md](AGENT-HARNESS-PLAN.md) and [agents-settings.md](agents-settings.md).

## 1. What each workflow actually costs

| Workflow | What Lilo maintains | Boundaries |
|---|---|---|
| (A) external harness | MCP server, 33 tools, consent gate, Agents Space | The harness owns UX, scheduling, retries, model access |
| (B) in-Lilo ACP | ACP client, agent catalog + installs, conversation UI, checkpoints, worktrees, permission modes, per-agent settings | Lilo owns a whole orchestrator UI that every other harness also ships |
| (C) headless | Socket server, `HarnessDefinition`, flows | Same tool surface as (A), no UI cost |

The cost asymmetry is decisive: (A)/(C) share one tool surface and one consent choke point (`askConsent`); (B) is a second product — T3 Code alone carries provider wizards, thread modes, per-provider settings, session import. [agents-settings.md](agents-settings.md) phase table shows each demand lands as Swift + Svelte + 15 locales + tests.

The strategic read: **(A) + (C) are the moat** — any harness gets a first-class WebKit browser without each browser building agent support. **(B) is the funnel** — the surface people discover Lilo through and where the user watches the agent. The mistake would be treating (B) as a feature race with dedicated orchestrators; the win is making Lilo the browser *layer* every orchestrator composes.

## 2. Turn (B) around: host a small core, let plugins carry the rest

### 2.1 Keep a maintained core: the union nobody else has

Survey the orchestrators named in the brief (Claude Code, Codex CLI, T3 Code, Multica, Paperclip, Orca, DeepSeek harness, Herdr) and the browser-side needs they all share. What every one of them wants from a browser, and only Lilo has natively:

- open/attach a tab, read and act on the page (the tool surface, folded per harness-plan stage 2)
- native trusted input, consent gate on consequential actions
- page snapshots and screenshots, profile/Space isolation, session cookies the agent could not otherwise hold
- an approval surface the user watches without leaving the browser

What none of them needs Lilo to do: model routing, thread management, scheduling, git, IDE features, agent identities. Those belong to the harness or a plugin. So the core contract Lilo commits to maintaining is roughly: **tabs + page tools + consent + isolation + snapshots** — the MCP tool surface, and nothing orchestrator-specific. That is already ~80% of what (A) consumes today, so the commitment costs little new work; the discipline is refusing harness-shaped features into the core.

### 2.2 The plugin surface: out-of-process sidecars, not embedded runtimes

Recommendation: **manifest + sidecar process per plugin**, talking JSON-RPC over stdio to Lilo, in any language. This is the Raycast runtime model (single managed child process, "a thin RPC protocol that only exposes a defined set of APIs") without Raycast's bundled-Node commitment, and it sidesteps the Zed trade entirely — Zed chose Wasm+Component Model and in exchange got Rust-only extensions and a documented ceiling ("no arbitrary HTTP requests, no filesystem, no UI panels").

Why sidecar over the two alternatives:

| Option | Language freedom | Resource cost | Maintenance | Verdict |
|---|---|---|---|---|
| Embedded JS (JSC/Deno) | JS/TS only | near zero | a runtime API surface, deprecation treadmill | rejected: recreates (B)'s burden |
| Wasm components (Zed) | any → wasm, in practice Rust | small | WIT versioning, toolchain churn | rejected: too heavy for a solo maintainer, plugin authors balk |
| **Sidecar + manifest** | **any** | **a process when enabled, zero when not** | **one JSON-RPC protocol + capability list** | **chosen** |

Lilo already proves the model internally: ACP agents are sidecars launched from a catalog with checksummed binaries and pinned installs ([AI-AGENTS.md](../AI-AGENTS.md)), and the MCP socket is already a JSON-RPC boundary. A plugin is the same shape pointed inward: Lilo launches *it*, instead of an agent launching Lilo.

Sketch of the manifest (Raycast-style, deliberately boring):

```jsonc
// lilo-plugin.json
{
  "id": "com.example.automations",
  "title": "Automations",
  "version": "1.2.0",
  "entry": "bin/automations",            // executable; any language
  "capabilities": ["tabs:read", "tabs:open", "schedule", "settings:store"],
  "contributes": {
    "tools": [{ "name": "schedule_tab_check", "description": "…", "consent": "reversible-write" }],
    "settings": [                          // rendered by Lilo's panel — no UI code in the plugin
      { "name": "interval", "type": "dropdown", "title": "Check every", "options": ["15m","1h","1d"] },
      { "name": "token", "type": "password" }
    ]
  }
}
```

Key properties:

- **Declarative UI**: the plugin declares settings and tools; Lilo renders the panel and enforces the consent tiers from harness-plan stage 3. Plugins never write AppKit/Svelte — this is what keeps the surface cheap to maintain.
- **Capabilities, not trust**: a plugin gets exactly the host API its manifest declares; anything it does on its own (files, network) is its own business, exactly as for ACP agents today ([agents-settings.md](agents-settings.md): "an ACP agent's fs/terminal activity is its own process's business; Lilo can only gate what the agent does in the browser"). Same consent choke point, same answer.
- **Resource discipline**: nothing runs when disabled or at idle, honoring AGENTS.md's efficiency rule. One process per *enabled* plugin, not one per tool call.
- **Distribution**: local folder first (`~/Library/Application Support/Lilo/Plugins/`), dev reload, no store. A curated registry can come much later, if ever.

### 2.3 The manager panel

Mirror the Extensions popover, which Lilo already ships:

- Settings → Plugins: list with enable/disable, version, capabilities summary, "kill process" for a stuck one; **an entry per plugin that renders its contributed settings** (Raycast's Preferences → Extensions pattern, `settings` array above).
- Plugin-contributed *tools* appear in the agent tool surface with an owner badge (like agent icons in the bottom bar today) and inherit the consent tiers — an agent calling a plugin tool goes through the same gate, so plugins cannot become a consent bypass.
- Plugin-contributed *commands* appear in the command palette (already ranked and extensible).

This reuses the mental model users already have from browser extensions: same panel shape, per-entry settings, but the capability axis is the app (tabs, scheduling, automation) rather than the web page.

### 2.4 What moves out of core on day one

The brief's example is right: Automations/cron is the canonical plugin. Lilo ships no scheduler today and shouldn't: a sidecar that owns launchd/its own timer, exposes `schedule_*` tools, and declares `schedule` + `tabs` capabilities is ~a weekend of work *outside* Lilo's hot paths, and it is also exactly workflow (C) in plugin form. Candidates for the same treatment over time: workflow-specific flows (`AgentFlows` extras), harness-specific shims, site-skill packs (the stage-7 "skills as Boosts" idea held back by the non-goal — a skill pack is a plugin contributing declarative, not executable, content, which is a different thing than the single-use plugin framework the non-goal fears).

## 3. The ROADMAP non-goal, answered

"No generic plugin framework for single-use features" is not violated by this design if the framework is defined by **stable host capabilities** (tabs, schedule, settings, consent) rather than by feature insertion. The non-goal bans plugins that hack single features into the app; this surface gives plugins a *protocol* and makes Lilo the only renderer and the only policy point. The rule to adopt alongside it: **a host capability is added only when two independent plugins need it** (the same two-adapter rule AGENTS.md already applies to Swift ports). That keeps the capability list small forever, which is what makes "maintained by us" credible.

## 4. Phasing

| Phase | Content | Size |
|---|---|---|
| 0 | Define the core commitment in AGENT-HARNESS-PLAN: the tool surface stages already planned (fold tools, consent tiers, CDP) *are* the core; no harness-shaped features enter it | doc |
| 1 | Plugin manifest + loader + JSON-RPC stdio host (one capability: `tabs:read/open`), manager panel with enable/disable, one dogfood plugin (Automations) | ~600 lines Swift + panel |
| 2 | `settings` contributions rendered in the panel; `schedule` capability; plugin tools into the MCP surface with consent tiers and owner badge | ~400 lines |
| 3 | Move first-party-ish extras (skills-as-Boosts packs, flow recipes) into plugins; consider a curated list, not a store | ongoing |

Measurement: before phase 1, record (a) monthly diff volume attributable to (B)-only features vs the tool surface — the baseline the plugin surface must bend; after, each capability addition is judged by the two-plugin rule, and `make validate` time must not grow from plugin code (plugins live outside the app build entirely).

## 5. Generative UI: a catalog contract, not a free-form one

Surveyed against Lilo's needs (A2UI v1.0, vercel-labs/json-render, OpenUI Lang, CopilotKit OpenGenerativeUI):

| | Format | Streaming | Renderer model | Fit for Lilo |
|---|---|---|---|---|
| [A2UI](https://a2ui.org/specification/v1.0-a2ui/) (Google) | JSON envelopes over 3 schemas, `agent_to_renderer`/`renderer_to_agent`, data bindings (`@path`), bidirectional function RPC, swappable component catalogs | yes (progressive, missing refs render placeholders) | **client maps descriptions to trusted, platform-native components** | best match |
| [json-render](https://github.com/vercel-labs/json-render) (Vercel) | JSONL of RFC 6902 patches over a component catalog | yes | in-app renderer from a registry; React, Vue, **Svelte**, Solid, RN bindings | good; simplest to adopt |
| [OpenUI Lang](https://github.com/thesysdev/openui) (Thesys) | line-oriented DSL, claimed ~2× fewer tokens and ~2× faster render than the JSON ones (vendor-published benchmark, unverified) | yes | runtimes for React, Vue, **Svelte**, Angular | model-facing efficiency irrelevant to Lilo (no model ships); vendor DSL |
| CopilotKit [OpenGenerativeUI](https://www.openui.com/docs/openui-lang/comparison) | free-form HTML/SVG in a sandboxed iframe | partial | iframe | **rejected**: against the Apple/Arc native bar, and an iframe surface next to an agent-controlled page is a consent-bypass shape |

The honest reading of the token/latency table: it is Thesys's own marketing page, derived from the same LLM output and projected into the compared formats — directional at best, and it measures the *generator's* cost, which Lilo does not pay. Lilo is a renderer.

**Where generative UI lands in Lilo** — two places, one catalog:

1. **Plugin surfaces beyond settings.** The manifest's declarative `settings` array covers preferences; a generative-UI catalog covers what settings cannot — a dashboards-style panel, a form, a review card. The plugin (or the agent driving it) emits JSON constrained to a Lilo-owned catalog; Lilo renders it with native chrome (HIG spacing, VoiceOver, Reduce motion come free because it is one renderer we own). Actions route back over the plugin's JSON-RPC as calls, through the same consent choke point.
2. **Agent answers in workflow (B).** An agent answering with an interactive surface (a confirm card, a diff with buttons, a small form) instead of markdown is the highest-value (B) feature that does *not* add per-orchestrator maintenance: the surface is declarative, the catalog is Lilo's, and every orchestrator that adopts A2UI or json-render speaks it without Lilo doing anything. This is the mechanism that turns (B) from a feature race into a rendering role.

**Verdict:** adopt an A2UI-shaped catalog contract — sender-side declarative JSON, receiver-side trusted native rendering, actions as RPC — delivered as the plugin capability `ui:surface` in phase 2, and later offered to ACP conversations. The catalog stays small (roughly Text, Row/Column, Button, Input, Select, Card, Table, Chart) and Lilo-owned; swappable catalogs and inline catalogs stay out, because the moment plugins define components, Lilo is back to maintaining a UI runtime instead of a contract. json-render's Svelte binding makes the implementation cheap; A2UI's renderer/agent split makes the contract durable across agents and plugins alike.

## 6. What to extract from the current setup to plugins

Audited against the core commitment (§2.1: tabs + page tools + consent + isolation + snapshots):

**Extract — plugins from day one:**

- **Harness connectors** ([HarnessDefinition.swift](../../Lilo/Agent/HarnessDefinition.swift), ~60 lines). Writing each harness's MCP config is per-harness knowledge that churns weekly (a new orchestrator, a changed config format, an app that takes comments). A "connectors" plugin with `settings:store` + file-write-in-support-dir capabilities adds detect-and-configure entries without a Lilo release. Smallest, cleanest first extraction; proves the surface end to end.
- **Flow authoring and management** ([AgentFlows.swift](../../Lilo/Agent/AgentFlows.swift), 405 lines) — *half*. The execution path stays core: replay runs through `AgentTools.call`, so the consent gate, action log and delta are non-negotiable core behavior (the doc says it best: "a saved flow is a recording, not a standing authorization"). But list, edit, share and inspect saved flows, and any future flow-store/skill-pack format, is plugin material: it needs only `tabs:read` and file access, and the stage-7 skills-as-Boosts idea (held on the non-goal) becomes a *plugin* instead of a core feature.

**Keep core — visibility and safety, not features:**

- The page/tab tool surface, `askConsent`, the action log, the consent UI, agent cursor/badges and the Agents Space. These are the reasons (A)/(C) work at all and the user's only window into what an agent does; none of them is a candidate.
- The ACP connection itself, agent catalog and install pipeline. This is (B)'s irreducible floor: launching and talking to the agent's process. Everything layered on conversations beyond it is where the plugin question begins.

**Watch, do not move yet:**

- **Meet modules.** AGENTS.md already declares them "no precedent" for the generic-first rule; if written today they would be plugins. But video-call quality is daily-driver core UX for the maintainer, and a plugin boundary would add a failure mode where it hurts most. Revisit only if a generic WebKit-level fix lands.
- **Conversation checkpoints and worktrees.** The heaviest (B)-only surface ([Lilo/Conversations/](../../Lilo/Conversations/), 3.8k lines, save/restore/undo per prompt, git worktrees). An ACP agent already does its own git; Lilo could eventually keep only lightweight save/restore in core and let a plugin or the agent itself own worktree orchestration. This is the single largest (B) maintenance line item, so it is the extraction that matters most if (B)'s burden stays heavy — but it is also the differentiator that makes (B) feel first-party today. Sequence it as a phase-3 decision, taken on the measured diff volume from §4, not on principle.

**Substrate notes** (both user-flagged, both compatible with the sidecar choice):

- [stencil-hq/dquickts](https://github.com/stencil-hq/dquickts) (already the stage-4 spike in [AGENT-HARNESS-PLAN.md](AGENT-HARNESS-PLAN.md)): a host-call park-and-resume runtime is also exactly what a *plugin sidecar* waiting on a consent answer wants — the same mechanism serves the plugin surface, not only core `run`. One spike, two consumers.
- [vercel-labs/scriptc](https://github.com/vercel-labs/scriptc) (TS→native/Wasm, npm packages compile in) and [sigilco/pyscriptc](https://github.com/sigilco/pyscriptc) (typed-Python→native, CPython island for the rest): they strengthen the any-language sidecar case rather than change it. A plugin author who wants a low-resource sidecar compiles TS or Python to a static binary — no Node or Python at runtime, exactly the "low-resource-use tooling" from the brief. Lilo bundles and pins nothing: the manifest's `entry` is an executable, however it was produced. Experimental compilers stay the author's risk, not Lilo's.

## 7. Coordinate: take the integration, not the code

Assessed `espetro/coordinate` (same owner): a durable job queue as one 4 MB binary — SQLite job rows, leases that survive crashes, park-and-wake on events, per-machine/repo caps, an event stream, and its own ACP agent-session lane (`src/acp.ts`: spawn from a `{name: {command, args}}` registry, initialize → session/new/load → prompt → stopReason, ~300 lines of hand-rolled JSON-RPC).

Nothing should be extracted into Lilo, for a simple reason: Lilo ships no daemon and must not gain one — an idle scheduler inside the browser violates the efficiency-first rule, and everything coordinate does durably, it does better as a separate process. The ACP lane proves it: Lilo's `ACPConnection` + `ACPAgentCatalog` (registry fetch, SHA-256 checks, pinned installs, probe) is strictly the richer implementation; coordinate's lane is a subset for its dispatcher.

What the plugin surface should take instead is **coordinate as the backend for the Automations plugin** (the §2.4 dogfood). That inverts the design for the better:

- Lilo never grows a cron. The plugin's `schedule` capability is a thin shim: its sidecar enqueues a `coordinate` job (or runs its own timer when coordinate is absent) and, when the job fires, calls Lilo's `tabs`/page tools over the plugin RPC.
- Scheduling gets durability for free — leases, restarts, park-and-wake on an event ("when this job finishes…"), caps as the OOM control — none of which a naive in-app timer has.
- It is also the natural bridge for workflow (C): a headless script that wants the browser enqueues a job whose command drives Lilo's socket/MCP surface, so background work and automations share one queue and one audit trail (coordinate's event stream) instead of Lilo building its own.

Core-side counterpart: if headless-from-a-queue becomes a common pattern, the only core change worth considering is documenting the socket server + a `coordinate enqueue --shell -- lilo-agent …` recipe in [COMPATIBILITY.md](../COMPATIBILITY.md) or the agent docs — no code. The plugin manager panel should simply show an Automations plugin with a "runs via coordinate" badge when the daemon is detected; no ownership, no lifecycle, no settings migration.

The reusable *idea* from coordinate is architectural: a Lilo capability can be a delegation to an existing tool rather than an implementation. That keeps the capability list small (§3's two-plugin rule) and is the same move as the harness-connectors plugin — Lilo orchestrates, it does not own. Implementation is planned in [plugin-surface-plan.md](plugin-surface-plan.md) (PR 6).

## 8. Clarifications

**"Harness connectors" is workflow (A), not ACP.** [HarnessDefinition.swift](../../Lilo/Agent/HarnessDefinition.swift) registers *Lilo as a tool in other agent apps*: each row is one harness (Claude Code, Codex, Zed, OpenCode…), where its config file lives, what entry shape its `mcpServers` takes (`command`/`stdio`/`local`, JSON vs TOML vs `claude mcp add`), and how to detect the app is installed. Writing Lilo's MCP server into Claude Code's config is what it does — nothing to do with launching ACP agents inside Lilo, which is `ACPAgentCatalog` + `ACPConnection` and stays core. It belongs in the extract list precisely because it is (A)-facing: the knowledge churns with *other apps'* config formats, and a stale row is a broken first-run experience Lilo can only fix by shipping.

**The three "watch" features:**

- **Meet modules** ([Lilo/Meetings/](../../Lilo/Meetings/)): native handling of video-call sites (Google Meet's compact call view, PiP handoff, screen-share integration, `TabShare`). The problem they solve is real and Lilo-specific, but they work by adapting to specific call products' internals — the one place AGENTS.md admits the generic-first rule is "no precedent". Why not move to a plugin: it is daily-driver UX for the maintainer and a plugin boundary adds a process hop exactly where latency and breakage hurt most. Why it stays on the watch list: if a generic WebKit-level mechanism ever replaces the per-site adaptation, the modules die anyway.
- **Conversation checkpoints** ([ConversationCheckpoints.swift](../../Lilo/Conversations/ConversationCheckpoints.swift), part of the 3.8k-line `Lilo/Conversations/`): before each prompt, Lilo saves the project folder's files as they were, so Settings-side "Restore to here" rolls the workspace back to that moment and Undo puts back one file. It is (B)-only — workflow (A) agents do their own git, and Lilo's MCP surface never touches it — which makes it the largest single block of (B)-specific maintenance.
- **Worktrees**: the same conversations section lets an agent work on its own `git worktree` copy of the project instead of the working tree, so its edits never touch the user's checkout until merged. Again agent-launching knowledge (git porcelain, branch naming, cleanup) that (A) harnesses already implement themselves.

The phase-3 question for both: checkpoints/worktrees are what make an in-Lilo conversation feel first-party (nothing else offers restore-and-undo over a browser-driven agent), so extract only if the measured (B)-diff baseline (§4) says the burden is real — and if so, the checkpoint journal itself (a plain file format) is the part that could become a plugin contract, while the restore UI stays core.

## References

- Zed: Rust+WIT+Wasm extensions, acknowledged API ceiling — https://zed.dev/blog/zed-decoded-extensions
- Raycast: single managed Node sidecar, thin RPC, manifest-declared commands/preferences, per-plugin settings panel — https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast, https://developers.raycast.com/information/manifest
- A2UI v1.0 (renderer/agent split, catalogs, function RPC) — https://a2ui.org/specification/v1.0-a2ui/
- json-render (Vercel): JSONL patches over a catalog, Svelte binding — https://github.com/vercel-labs/json-render
- OpenUI Lang (Thesys): line DSL, vendor benchmark — https://github.com/thesysdev/openui
- scriptc (TS→native/Wasm) — https://github.com/vercel-labs/scriptc; pyscriptc (typed Python→native) — https://github.com/sigilco/pyscriptc; dquickts (park/resume host calls) — https://github.com/stencil-hq/dquickts
- coordinate (durable job queue; assessed §7, integration not code) — local sibling project, https://github.com/espetro/coordinate
- Local: [AGENT-HARNESS-PLAN.md](AGENT-HARNESS-PLAN.md) (tool surface, consent tiers, skills), [agents-settings.md](agents-settings.md) (ACP providers, per-entry settings precedent), [docs/ARCHITECTURE.md](../ARCHITECTURE.md) (placement).
