# Agent entry next to the tab

Design note for [espetro/Lilo#44](https://github.com/espetro/Lilo/issues/44): where the user reaches their agents from, and how deep each surface goes. Lilo ships no AI of its own ([AI-AGENTS.md](../AI-AGENTS.md), ROADMAP non-goal); every surface here is UI for the external agents the user already runs over MCP and ACP. Nothing in this note adds a model, a key or a prompt path.

## Today

The Agents badge is the single chrome entry point. It sits in the sidebar's New Tab row next to New Terminal (`lilo-ui/src/components/sidebar/TabSection.svelte`) and in the tab strip's bottom bar (`lilo-ui/src/components/strip/TabStrip.svelte`). `AgentsBadge.svelte` shows the mascot, a spinning ring while any conversation works and an orange dot while one waits on an answer, with the count aggregated across every Space.

Its click has two outcomes. With nothing listed it calls `openAskBar()`; otherwise it opens `AgentsPopover.svelte`, the cross-Space list of conversations where a permission can be answered in place. `⇧⌘A` (`askAgent` in `Lilo/Conversations/MainWindowController+Conversations.swift`) opens the same Ask bar with the active page's selection, fetched through the agent input world.

`AskBar.svelte` is a floating bar over the page: it attaches the active tab and its selection as context chips, offers a project folder picker and an agent picker from the ACP registry, and on Enter calls `startConversation`. `ConversationBridgeHandler.swift` hands that to `MainWindowController.startConversation`, which creates a "New Conversation" folder and a `.agent` tab in the current Space and activates it unless the prompt asked for background (`⌘↩`). The conversation then draws over the tab's empty native view (`AgentChatHost`). The page the user was reading loses focus and leaves the screen entirely.

Lilo already has the docked-panel machinery this note builds on: `Lilo/Window/SidePanelController.swift` keeps one `chrome.sidePanel` panel per window, remembers a tab-specific panel per tab, follows the active tab in Chrome's order, and reserves a resizable strip right of the content. Today it only hosts extension pages; nothing agent-related uses it.

Tabs already have a hover affordance precedent: `StripTab.svelte` reveals a close button on hover, the same place a per-tab action would live.

## Problems

- The entry point is not next to the tab it is about. The badge lives in the New Tab row or the bottom bar, far from the page in use, and its popover lists every conversation in every Space, so "ask about this tab" is buried under global state.
- The Ask bar binds to whatever tab is active at the moment it opens. There is no way to point at a background tab and ask about it.
- Starting a conversation always mints a new agent tab and activates it. Even a one-line question about the page you are reading rips you out of that page; the only escape is remembering `⌘↩` for background.
- The binding between a conversation and its source page is implicit (an attachment chip), not structural. The agent tab sits in a collapsed folder and the page it was started from has no visible link back.
- Waiting-state information is global. The badge dot cannot say which tab or page an agent is working on or waiting for you about.

## Options

### A. Per-tab hover action and a docked panel bound to the tab

Hovering a tab reveals an agents affordance (next to the existing close button) that opens a docked panel bound to that tab, in the slot `SidePanelController` already manages. The panel hosts the light and middle tiers below: quick ask first, then the running thread beside the page. The full agent tab stays for work that needs its own pages. This is the BrowserOS sidebar pattern: the agent surface attaches to the tab it serves, the way `chrome.sidePanel` already does for extensions. An extension-style bar that floats over arbitrary pages is the anti-pattern, because it competes with the page for the same pixels the user is trying to read.

Cost: the panel content is chrome UI (Svelte), not an extension page, so `SidePanelController`'s entry model generalizes rather than being reused verbatim; the per-tab binding, layout and follow-the-active-tab behavior carry over.

### B. New Tab button as control panel

Turn the New Tab page into the agents hub: recent conversations, what waits on you, a prompt field, per-Space groups. Cheap to build on what exists and gives conversations a home that is not a tab. But it solves discovery, not context: the user still leaves the page they wanted to ask about, and the New Tab surface already carries shortcuts and favorites that would compete with agent state.

### C. Unchanged badge, better focus handling

Keep the badge as the only entry and fix the sharpest pain: make background the default for quick asks, return focus to the source page when a conversation finishes or is dismissed, and show which tab a conversation belongs to in the popover. Smallest diff, helps everyone today, and none of it blocks A later. It does not give agents a per-tab presence, so the "next to the tab" goal of the issue stays unmet.

## Tiers

Three depths, chosen by the weight of the task, all driving the same external agents:

1. **Light: the Ask bar.** One prompt, the page and selection attached, no persistent surface. Right for a question or a small edit. Today this exists; it stays the fastest path and the `⇧⌘A` target.
2. **Middle: the docked panel.** A panel bound to one tab that holds the Ask field and then the live thread, staying open beside the page while the agent works. Right for "work on this page with me watching": the user reads the page, answers a permission, sees the diff, all without losing the tab.
3. **Heavy: the agent tab.** A conversation with its own folder and the pages the agent opens, for multi-step work that leaves the source page behind. This exists today and stays the destination when the panel's "open in tab" is used or a task outgrows a sidebar.

Promotion is explicit, never automatic: the panel offers "Open in new tab" and the agent tab can collapse back to a panel on its source tab. Nothing migrates a conversation between tiers on its own.

## Recommendation

Ship C's focus fixes first because they are small and help the current flow, then build A as the middle tier, keeping the Ask bar as the light entry and the agent tab as the heavy one. Concretely: the per-tab hover action opens the docked panel for that tab (not the Ask bar directly), the panel starts as the Ask field bound to that tab and grows into the thread, and the badge keeps its global role (cross-Space list, waiting count) while gaining a per-tab indicator for tabs with an open panel or a bound conversation. Option B stays out: the New Tab page is not where context lives.

The slicing below orders the work so each PR stands alone and is verified before the next starts.

## Slicing into PRs

1. **Focus and binding fixes (option C).** Ask bar sends stay non-activating by default when started about the active page; closing or finishing a conversation returns focus to the tab it was about; the popover row names its source tab. Verification: `make ui-lint ui-test`, a `lilo-ui/e2e` spec through `fakeHost.ts` asserting focus return and the background flag, plus `make docs-check` for any copy change.
2. **Per-tab hover affordance.** The agents action appears on tab hover beside close (and in the tab's context menu for keyboard and non-hover access), enabled only when `agentsEnabled`. Clicking it posts a message naming the tab; the chrome opens the Ask bar pre-bound to that tab, fetching its selection the way `askAgent` does today. Verification: `make ui-lint ui-test`, fakeHost e2e covering hover reveal, context-menu path and binding to a background tab, `make docs-check` for new strings in every catalog.
3. **Docked agent panel.** Generalize the side-panel slot so a conversation panel can dock per tab beside extension panels (one panel at a time, Chrome's order), hosting the Ask field then the thread for the bound tab. The badge's per-tab indicator lands here. Verification: `make project-sync` after the Swift changes, `make validate` under the lock, Swift tests for panel follow/close semantics mirroring `SidePanelController`'s, fakeHost e2e for open/close/dismiss, `make docs-check`.
4. **Tier promotion.** "Open in new tab" from the panel reuses `startConversation` with the panel's context; the agent tab gains a way back to the panel on its source tab. Verification: `make validate`, e2e for both directions, release note via `make change`.
