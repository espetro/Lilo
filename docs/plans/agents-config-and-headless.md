# Delivery plan: agent configurability + headless agent runs

Plan for two agreed work streams, written against `develop` + `spike/agent-tab-throttle` (2026-11-23). Companion to [AGENT-HARNESS-PLAN.md](AGENT-HARNESS-PLAN.md) (tool surface, consent internals) and [plans/agents-settings.md](plans/agents-settings.md) (settings surface). Each item is an issue+PR pair; every PR carries measured numbers per [CONTRIBUTING.md](../CONTRIBUTING.md#pr-evidence).

## Stream A — agent configurability (setup in seconds)

Scope decided in the research report (T3 thread "Lilo: agent-configurable setup research", 2026-11-23): **no config-write tools**; deliver docs + read-only verification. The consent boundary stays where [plans/agents-settings.md](plans/agents-settings.md) (d) put it: agents read config, never write it.

### A1. Ship per-harness connect snippets in the docs

`AgentClientConfig.manualSnippet` ([Lilo/Agent/AgentClientConfig.swift:102](../Lilo/Agent/AgentClientConfig.swift)) already produces the exact one-liner per harness (`claude mcp add --scope user lilo -- <helper>` for Claude CLI, JSON/TOML blocks for the rest), but it is reachable only through the Settings UI. Publish it:

- Watch-path: add a `docs-site` reference page generated from `HarnessDefinition.all` + `manualSnippet` (the generator already reads the catalogs; see docs-site/README.md). One line per harness: command or snippet + what it writes + the consent step that follows.
- AI-AGENTS.md gets a "connect a harness without opening Lilo" section pointing at that page.
- Verify: `make docs-check docs-test`.

### A2. `connect_status` read-only tool — the agent verifies its own setup

One new MCP tool, doctor-style. Extends `AgentBrowserConfig.swift`'s allowlist pattern ([Lilo/Agent/AgentBrowserConfig.swift](../Lilo/Agent/AgentBrowserConfig.swift)) — same hard line: read-only, no setter, in the header comment.

Returns, for the calling client: harness row from `HarnessDefinition.all` (or `other`), whether its config file contains a live `lilo-mcp` entry (reuse `AgentClientConfig.connectedClients`, [AgentClientConfig.swift:127](../Lilo/Agent/AgentClientConfig.swift)), the exact `manualSnippet` to fix it if missing or stale, and this session's consent state (`askBeforeActions`, acts-on-pages tier — the fields `browser_config` already shows).

An agent then answers "am I set up? what should my user click?" in one call. UI change: none. Tests mirror `AgentBrowserConfigTests`. Update the mcp-tools reference page and COMPATIBILITY.md is untouched (tool, not a gap API). Eval task in `bench/mcp/tasks.txt`: "determine whether you are connected correctly and print the fix".

Deliberately not built: `browser_setup` write tools (contradicts agents-settings.md (d); duplicates the connect-time consent gate), and a `lilo agent connect` CLI (second command surface for a 3-click UI path; revisit only with evidence users skip onboarding).

## Stream B — headless agent runs

Position: Lilo already has the "new headless" architecture (parking window, hidden engines, Debug-only headless app mode). What is missing is (1) proving the throttled-parked default is safe and measuring it, (2) a Release-grade background host mode, (3) consent that works without a window. B1 is already coded; B2–B4 make it shippable.

### B1. Land the throttle spike

Branch `spike/agent-tab-throttle`, commit 227aa283: `attach` no longer disables occlusion detection; `wake` ([Lilo/Agent/AgentFolders.swift:344](../Lilo/Agent/AgentFolders.swift)) disables it per tool call instead. `make check` green.

- Run the Swift tests in CI (`make ci-swift REF=spike/agent-tab-throttle` after pushing): `AgentFoldersTests` covers the new default; wake-before-screenshot path needs a test asserting `takeSnapshot` works on an occluded parked tab after `wake`.
- Measure: the `timer-ticks` fixture in `bench/mcp/fixtures.py` (parked tab, 60 s, count `setInterval` ticks) — PR evidence: ticks/sec parked before vs after, plus an energy read via the `docs/ENERGY.md` harness on a 5-minute idle agent session.
- Known risk to test explicitly: pages whose behavior depends on visibility (video, WebSocket keepalives, `document.visibilityState`-gated rendering). The eval suite decides if the default is safe; if a task class regresses, the fallback is throttle-on only after first tool call instead of never.

### B2. Release background-host mode

Promote the Debug headless seam ([Lilo/App/LiloApplication.swift:8](../Lilo/App/LiloApplication.swift), `AppDelegate.swift:74,114`, `MainWindowController.swift:15,664`) out of `#if DEBUG` behind a proper trigger: `lilo --background` (CLI arg, not env var) plus a "Run agent host in background" toggle in Settings > Agents. Activation policy `.accessory`, invisible windows, agent tabs never request foreground — all exists; the change is wiring + Release builds + localization for the new strings.

Out of scope: LaunchAgent/auto-start (a follow-up if the mode earns its keep).

### B3. Consent without a window (the hard blocker)

`askConsent` ([Lilo/Agent/AgentControl.swift:396](../Lilo/Agent/AgentControl.swift)) returns `.unavailable` without windows, so a background host cannot approve anything. Deliver the [AGENT-CONSENT-MODEL.md](AGENT-CONSENT-MODEL.md) four-case enum as a prerequisite: consent questions queue as **notifications** with deep links into a visible window; if the user is away, questions hold (session pauses, not auto-denies) — never a silent allow. The `agentClientPermissions` tiers (ask / chosen sites / everywhere) become the declarative path that lets approved clients run unattended *within the grant the user already made*.

Sequencing: enum first (small, already half-landed via `agent-consent-answer-enum`), notification-queued questions second — landed: `askConsent` holds a windowless question in a notification (`revealConsent` opens a window at its tap); `.unavailable` is the detached-control case — then B2 can ship enabled.

### B4. Resource posture by default

With B1 landed, parked agent tabs throttle whenever idle. Two small follow-ups: exclude agent sessions from App Nap only while a tool call is in flight (`beginActivityWithOptions` in `wake`/`sleep`, already stubbed in the sleep path), and a Settings readout (`browser_config` gains `idlePosture: full-rate | throttled | sleeping`) so harness docs can tell agents what to expect.

## Order and pairing

1. **A1** (docs-only, immediate) — do first, unblocks every harness author today.
2. **B1** (spike → PR) — CI green + tick/energy numbers decide landing.
3. **A2** (one tool + eval task) — after B1 so its eval runs on the final throttling default.
4. **B3** (consent enum → queued notifications).
5. **B2** (Release background mode) — last; ships only with B3.
6. **B4** — opportunistic, after B1/B2.

Each lands as its own PR against the fork with a `make change` release note; A1/A2 also go upstream (they are generic, no fork-specific deps). B2/B3 are fork-track first — upstream appetite for a background host mode should be probed with the A-series PRs before proposing them.
