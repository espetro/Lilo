# Agent harness plan

Where Lilo's browser harness for agents goes next, from the research of 2026-11-18 (Lilo's `Lilo/Agent` and `Lilo/Conversations` against Zephium, BrowserOS neo, Strawberry, Claude in Chrome, Playwright and Chrome DevTools MCP, DeepSeek Harness and T3 Code). Every stage is measured with the fixture tasks (`make agent-eval`, [bench/mcp/README.md](../bench/mcp/README.md#fixture-tasks)) before and after.

## Position

Keep: no AI built into Lilo, any harness drives it (MCP and ACP), native WebKit with trusted native input and reading the page cannot see, an isolated Agents Space the user watches. Close: Zephium's safety design and its measured results, BrowserOS's replay and token economy, Strawberry's reusable skills. The vision is Arc's Boosts: a site's behavior the user owns, here written and run by the user's own agents.

## Stage 1: measure (done: fixture tasks)

- `bench/mcp/fixtures.py`: 16 local tasks graded in code, so no judge model. Sonnet runs every task; Haiku shows harness quality differences more sharply at a tenth of the price.
- BU Bench judge: Online-Mind2Web's WebJudge study shows smaller judges lose agreement with humans (GPT-5.4 Mini 56 %, GPT-5.5 75 %). Keep Opus for release runs; for weekly runs measure Sonnet's agreement with Opus on 20 fixed tasks first, and switch only above 90 %.
- Next fixtures: the approval gate in every UI language, icon-only buttons, cross-origin frames, a sign-in wall handoff.

## Stage 2: tool surface

33 tools, about 7,000 tokens of schemas (`computer` 3.3k characters, `emulate` 3.2k, `network_mock` 3.0k). BrowserOS neo serves 17, with one `act` tool for every input. Overlaps to fold, each change measured on the fixtures:

- `find`, `read_page` and `get_page_text` into one `read` with a mode.
- `list_connected_browsers`, `select_browser` and `switch_browser`: Claude in Chrome shims with nothing to choose in Lilo.
- `browser_batch` into `run`: `run` already calls any tool in a loop.
- `devtools_command`, `devtools_events`, `network_mock`, `network_response`, `emulate`, `performance` and `cookies` behind one `devtools` tool, or reachable only from `run`.

Code mode is already there: `run` executes a program in a blank web view that calls the tools. The Cloudflare and OpenCode approach goes further: list a small core of tools, and describe the rest as a typed API inside `run`'s description, so the long schemas cost tokens only in the programs that use them.

Observation: `read_page` returns up to 50,000 characters each time. Add a diff since the last read (BrowserOS's `diff`), and a one-line summary of what changed after each action. Fence page text as untrusted with a per-call nonce (BrowserOS's `wrapUntrusted`); the `injection` fixture measures it.

## Stage 3: approval gate

- Scope: today `askConsent` sends the question to every window's URL bar drawer, in one queue with site and extension permission prompts, with no tab: one waiting question holds the others in every window. Show it on the agent's own tab and conversation row (which already turn amber for ACP permissions), and keep the rest of the browser free.
- Language: the gate is a regex of English and French words (`AgentPage.js`), while the UI ships 15 languages, and it misses "Confirm", "Place", "Book" and icon-only buttons. Make it language independent first: a form submit with a password, card or one-time code field, a POST or a navigation leaving the origin after the click, a button of type submit in a form with payment fields, `autocomplete` tokens (`cc-*`, `one-time-code`). Keep the word list as a fallback, extended to every catalog.
- Tiers: read (never asked), reversible write (asked once per site), commit (send, pay, delete, publish: asked each time unless always allowed), irreversible with the user's profile cookies (always asked). `javascript_tool`, `run` and `devtools_command` stay outside, as documented.

## Stage 4: replay and durable runs

- Timeline: each tool call appends one JSONL line (time, tool, arguments without secrets, result summary, `possibleCommit`, a screenshot reference) under the conversation's folder. The conversation row opens it as a scrubbable timeline. This is BrowserOS's replay without recording video, and the possibleCommit marks show where a retry would be unsafe.
- Durable `run`: a program waiting for an approval or killed with the app loses its place. [dquickts](https://github.com/stencil-hq/dquickts) can snapshot a whole QuickJS heap in the middle of a loop and resume it in another process, with host calls that park until answered: that maps onto `run` waiting for the user, and onto a replay that resumes from a step. It is a C dependency against WebKit's JavaScriptCore, which `run` uses today: spike it outside the app first, measuring snapshot size and resume time on the fixture programs.

## Stage 5: CDP endpoint

`InspectorCDP.js` already speaks much of the Chrome DevTools Protocol over WebKit's inspector for `chrome.debugger` (DOM, Runtime, Page, Network, Emulation, `Input.insertText`), and `AgentInput` sends `Input.dispatchMouseEvent` as native events. Missing for Puppeteer, Playwright `connectOverCDP`, Stagehand and browser-use: a loopback WebSocket listener (`/json/version`, `/json/list`, `/devtools/page/<id>`), the browser level (`Browser.getVersion`, `Target.setAutoAttach` with flattened sessions, `Target.createTarget`, `attachToTarget`), `Fetch` interception and `Accessibility.getFullAXTree`.

- Pages are the agent's tabs in its Agents Space only, with the same client approval as MCP (a token file the client reads).
- Order: Puppeteer `connect` first (the shim already accepts its startup commands), then browser-use, then Playwright, each with a fixture run through its own MCP server.
- Off by default, opt-in in Settings > Agents. An upstream proposal needs Alexays's agreement first, as it widens what an extension-only layer serves.

## Stage 6: ACP

T3 Code's ACP support shows what Lilo's lacks: a local ACP command (any executable with arguments, such as `dsh --profile acp`) next to the registry, environment overrides per agent, several instances of one agent, custom model IDs, listing and importing an agent's existing sessions, and the `terminal` client capability (Lilo sends `terminal: false` and `fs: false`). The first two make any custom harness usable in Lilo; add them first.

## Stage 7: skills (Boosts)

Strawberry saves a successful run as a skill to replay. In Lilo: a conversation's timeline (stage 4) becomes a skill file the user owns (`SKILL.md` and the `run` program) that the user's agent loads through ACP, attached to a site like a Boost, and replayed without a model when its steps still match the page. Lilo stores and runs nothing on its own: the agent does, so the no-AI rule holds.

## Visualization

Already there: the violet arrow and mascot follow the agent's pointer (`AgentCursorView`) and an agent's tab gets a violet frame and badge. Missing: an outline of the element a ref names when the agent acts on it without moving the pointer (`form_input`, `javascript_tool`), and a short caption of the action. Both stay native views, out of agent screenshots.

## Notes on earlier claims

- "BrowserOS ships a 0.54B click model (ScreenSpot-V2 79.1)": nothing in BrowserOS's public repositories matches it; its changelog only says "overhauled agent grounding". BrowserOS neo's MCP grounds by refs from an accessibility snapshot, like Lilo. Treat the claim as unverified.

## Delivery plan

Two tracks, as in the development-experience plan: every change lands on the fork's `develop` first (the rolling beta build from `develop` is the app to install and try), and a curated subset goes to upstream as one issue and one PR each. Sizes come from what the maintainer merged quickly (small fixes with an issue behind them, 20 to 500 lines) and what stalled (large outside features without a discussion, and build tooling: #380 to #384 have had no review).

### Architecture verdict

Four adversarial reads (vertical slices, ports and adapters, the maintainer's review load, backpressure tooling) agree: no reorganization.

- Vertical slices: Lilo already is one on the Swift side (`Lilo/Agent` 5.1k lines in 17 files, `Lilo/Conversations` 2.4k, tests mirroring sources). Recent agent commits touch 3 to 6 files. The toolchain forces the UI, bridge, locales and tests into separate roots, so slices would break `project.yml`, the generators and the parity checks. Only add a placement-rule line: a feature folder over about 500 lines gets subfolders (`Lilo/Agent/Approval`), with tests mirroring them.
- Ports and adapters: the tool list and `AgentTools.call` are already the inbound port, and approval already has one choke point (`askConsent`). Outbound ports (engine, consent UI, replay store) would have one implementation each, which `AGENTS.md` forbids. One extraction is justified once a second adapter exists: `AgentControl.execute(name, args, session)`, owning the activity, deadline, overlap warning and `possibleCommit` handling now in `AgentMCP.handle` (about 110 lines), with `AgentSession` freed of its connection. CDP is a different vocabulary and extends `InspectorCDP.js`, not this port; ACP goes through the MCP socket.
- Do the extraction in the CDP spike's first PR, not before.

### Pairs of issue and PR

Each row is one issue and one PR, in merge order. "Fork" means it stays on the fork's `develop` until the maintainer answers.

| # | Issue and PR (one each) | Size | Track | Measured by |
|---|---|---|---|---|
| 1 | Native drag starts no HTML5 drag session: `computer left_click_drag` only selects text | under 100 lines | upstream, bug with repro | `drag-reorder` without the JS fallback |
| 2 | Approval gate misreads pages in 15 languages and misses icon-only buttons ("Save order" asks as a purchase): detect by structure first (password, card and one-time-code fields, submit in a payment form, cross-origin navigation after the click), word list as fallback | about 400 lines | upstream, bug | new gate fixtures in several languages |
| 3 | ACP: run a local command with arguments and per-agent environment overrides | about 250 lines | upstream, small issue | a fixture run through a custom command |
| 4 | Debug harness runs: `agent-app` enables agent control, `LILO_AGENT_ALLOW_ALL` also skips click prompts | under 60 lines | upstream with 5 | `make agent-eval` runs unattended |
| 5 | Deterministic agent fixture tasks graded in code (`make agent-eval`) | about 300 lines, bench only, never in `validate` beyond its self-test | upstream after 2, so it can measure it | the suite itself |
| 6 | Outline the element an agent acts on (`form_input`, `javascript_tool`), native view, out of screenshots, Reduce motion respected | about 200 lines | upstream | manual plus a screenshot test |
| 7 | Fold the Claude-in-Chrome shims (`list_connected_browsers`, `select_browser`, `switch_browser`) | about 200 lines | upstream after an issue: client tool names change | `agent-eval` pass rate and schema tokens, before and after |
| 8 | Approval gate on the agent's own tab and conversation row, tiers (read, reversible, commit, irreversible) | split in two PRs, each about 400 lines | upstream after 2 and an issue on the tier model | gate fixtures plus two windows open |
| 9 | Per-call action log (JSONL under the conversation's folder, no screenshots by default) | about 150 lines | upstream after an issue | log lines match the calls in a fixture run |
| 10 | Merge `read`, `find`, `get_page_text` into one `read`; devtools tools behind one tool or `run` only | after 7 shows the cost and gain | upstream after discussion | pass rate and tokens per task |
| 11 | CDP endpoint: discussion first; a spike on the fork (loopback, off by default, token file, Puppeteer first) including the `execute` extraction | spike only | fork, discussion upstream | a Puppeteer fixture run |
| 12 | dquickts spike: snapshot and resume a `run` program, outside the app | a doc and a script | fork | snapshot size, resume time |
| 13 | Replay view from the log, and skills as site Boosts | later | hold: the maintainer's non-goal on single-use plugin frameworks needs an answer first | not started |

Ordering follows review load: 1, 2, 3 and 4 with 5, then 6, 7, 8, 9, and the larger items only after a maintainer answer. Do not send more build-tooling PRs upstream until #380 to #383 land or close, and drop #384.

### Backpressure

Stay on Make and stdlib Python: a Bun or TypeScript `validate.ts` would add a runtime against the Makefile-only rule and duplicate `scope_checks.sh` and `metrics.py`. Much of it exists: the parallel `validate` with logs shown only on failure, `validate-scope`, `scripts/metrics.py`, `ci_metrics.py` and the baseline in `docs/build-baseline.md`. Missing, and the fork-only series that fills it:

| Tier | Budget | Contents |
|---|---|---|
| in session | under 10 s | `make check`: lint and the relevant test only, no builds, chosen from the changed files |
| pre-commit | under 15 s | staged lint, commit message, generated files in sync |
| pre-push | about 30 s warm | `validate-scope` under `flock /tmp/tsc.lock` |
| CI | full | `validate`, `e2e`, `swift-test-slow`, Release build |

Steps, each its own fork PR: (b1) `QUIET=1` prints one line per check and the log only for a failed one, `JSON=1` for agents; (b2) the pre-commit and pre-push hooks plus a Swift-only scope; (b3) the metrics record gains `tier`, `scope`, `trigger` and `rerun_of`; (b4) a baseline week with `make metrics-on` before anything is judged.

Keep or drop a check by its measured record over at least 30 runs or 4 weeks: keep it if it catches at least 1 real failure per 50 runs that nothing earlier catches; move it up a tier if it takes under 5 s; demote it if it takes over 10 % of its tier's budget and under 2 % of its failures escape to the next tier; drop it after 90 days with no catch and no overlap (generated-file sync checks excepted). The numbers behind it: time to first signal, CI failures a local tier would have caught, check-output tokens per agent turn, reruns per change and CI minutes per PR.
