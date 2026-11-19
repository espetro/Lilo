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
