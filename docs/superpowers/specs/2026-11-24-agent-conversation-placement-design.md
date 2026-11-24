# Agent conversation placement

This spec records the approved design for choosing where a new agent conversation appears. It replaces the forced split-pane start added on `develop` with four explicit placements: mini conversation, dialog, split beside page, and full tab.

## Current architecture

The agent surfaces are already hybrid. The Ask Bar is Svelte chrome UI in `lilo-ui/src/components/agents/AskBar.svelte`, rendered over the page. The agent tab has a native tab and an empty native content host underneath, but the visible conversation is Svelte chrome UI in `lilo-ui/src/components/agents/ConversationView.svelte`. Native code owns tabs, folders, splits, focus, persistence and bridge delivery. Svelte owns the thread, composer, permissions, questions, plans, models and errors.

This split stays. Native code chooses where the conversation lands and tells chrome which surface to open. Svelte renders every conversation surface through the existing thread implementation rather than duplicating it in AppKit.

## Decisions

- The user-facing placement setting is `agentConversationPlacement`.
- Supported values are `mini`, `dialog`, `split` and `tab`.
- `mini` is the default because it preserves the page, follows the Ask Bar's location and is the least disruptive surface.
- `dialog` is the fallback when `split` is selected but no real split can be made.
- `tab` is explicit, never a silent fallback from a configured non-tab placement.
- Closing a mini or dialog surface dismisses only the surface. The conversation keeps running and remains available from its sidebar conversation and the Agents popover.
- Enlarging any non-tab surface activates the conversation's existing agent tab.
- Mini and dialog surfaces are bound to the source tab that the Ask Bar captured. They hide while another tab is active and return when the source tab becomes active again.
- There is one conversation surface per source tab at a time. Starting another conversation on that source replaces the open mini or dialog surface while the earlier conversation stays in the sidebar.
- `Cmd+Enter` keeps the existing background-start behavior and does not open a surface.

## Settings and Ask Bar

Settings → Agents → Agent Conversations gets a `Conversation placement` row backed by `agentConversationPlacement`.

The row offers:

- `Mini conversation`
- `Dialog`
- `Split beside page`
- `Full tab`

The Ask Bar gets a compact `Open as` picker beside the project, agent and model pickers. It edits `agentConversationPlacement`, so choosing in the bar changes the default for the next conversation too. The picker stays icon-forward and tooltip-based so it does not crowd the composer.

All new user-facing strings are added through the existing i18n catalogs for every locale.

## Native placement flow

The `startConversation` bridge payload gains:

- `placement`, one of the setting values
- `sourceTabId`, the active non-agent tab the Ask Bar captured
- `surfaceRequestId`, a client-generated identifier used to pair a delayed native start with its pending surface

`MainWindowController.startConversation` interprets the placement after it creates the conversation tab and folder:

- `tab` puts the agent tab in its conversation folder and activates it.
- `split` uses the existing real split machinery and keeps the 2:1 page-to-conversation ratio.
- `mini` and `dialog` leave the agent tab inactive inside its conversation folder and emit `conversationSurfaceRequested`.
- `background` skips activation and surface emission entirely.

`conversationSurfaceRequested` carries the conversation `tabId`, `sourceTabId`, `placement` and `surfaceRequestId`. The event is emitted after the conversation exists, which also covers delayed worktree setup. A failed start emits `conversationSurfaceFailed` with `surfaceRequestId` and a short failure message so the pending surface can close instead of waiting.

Split fallback is deterministic: if `split` cannot create a pane for the conversation, the window emits the same surface request with `dialog` instead of activating the tab. When no eligible source tab exists for `mini` or `dialog`, the conversation falls back to `tab` because there is no tab to bind the surface to.

## Chrome surface model

A small conversation-surface store owns pending and open surfaces in `lilo-ui`.

Each surface records:

- `surfaceRequestId`
- `sourceTabId`
- `placement`
- `tabId`, once native reports the conversation
- `pending`, while the native start or worktree setup is still running

`DeferredChrome` mounts a `ConversationSurface` wrapper for the surface bound to the active tab. `ConversationSurface` computes the overlay frame, scrim, role, dismiss behavior and presentation class, then renders `ConversationView` inside it.

`ConversationView` accepts a presentation prop so it can adapt header controls and root styling without copying the thread. Existing split and active-tab rendering remain supported presentations.

## Mini conversation

The mini surface is the Ask Bar expanded upward into a compact conversation card.

Its geometry follows the Ask Bar:

- bottom-centered in the content area
- width remains `min(700px, content width - 32px)`
- height is `min(420px, calc(100% - 48px))`
- no scrim, so the page remains interactive
- the card uses the existing `float-surface` treatment and large radius

The surface contains the same header, thread and composer as the full conversation, with compact spacing. Header controls are:

- enlarge, using the existing diagonal expand affordance
- close, which dismisses only the surface

Focus moves to the mini composer when the surface appears. The user can still click and type in the page because the mini is non-modal.

While the native start is pending, the expanded Ask Bar becomes a pending mini shell with the agent name and a quiet starting state. When `conversationSurfaceRequested` arrives with the matching `surfaceRequestId`, the pending shell swaps in the conversation.

## Dialog conversation

The dialog follows the Notion reference: a centered card over a dimmed page.

Its geometry and chrome are:

- centered horizontally in the content area
- width is `min(840px, calc(100% - 48px))`
- height is `min(720px, calc(100% - 64px), 80vh)`
- a dimmed content scrim with the existing overlay tint and blur treatment
- large radius and floating-surface shadow
- `role="dialog"` with modal focus behavior

The dialog contains the full `ConversationView` thread and composer. The empty or starting state uses the existing centered agent hero, which matches the Notion card's quiet focused composition.

Header controls are:

- close at the leading corner, mirroring the reference
- enlarge at the trailing corner

Esc, a scrim click and the close control dismiss the dialog. The conversation remains alive and can be reopened from the sidebar conversation or enlarged into its tab.

## Split and full tab

`split` keeps the current native split behavior: the source page retains two thirds of the content width and the conversation pane takes one third. Existing split controls and resize behavior remain unchanged.

`tab` keeps the legacy solo agent-tab behavior. It is available from Settings and the Ask Bar picker, and every mini or dialog surface can enlarge into it.

## Motion and microinteractions

Motion is calm, GPU-safe and consistent with existing chrome transitions:

- Ask Bar to mini uses a short transform-and-opacity expansion in place. The shell moves first and the thread fades in after it settles.
- Dialog opens with a small rise and scale-in over a scrim fade. Exit is shorter and sinks slightly.
- Mini and dialog dismissals use the Ask Bar's existing short return motion rather than a new direction.
- New thread rows keep the existing `restingFly` animation.
- Permission and question cards keep their existing spring emphasis.
- No animation changes `top`, `left`, `width` or `height` during interaction.
- `prefers-reduced-motion` removes transitions and shows state changes immediately.

## Accessibility

- The dialog is modal and traps focus until dismissed.
- The mini surface is non-modal and does not trap page focus.
- Enlarge and close controls have translated accessible names and keyboard focus.
- Surface appearance and conversation completion keep the existing announcements.
- Escape dismisses the active surface when no permission or question consumes it first.
- All controls preserve the current focus-outline styling.

## Error and lifecycle behavior

- A failed `startConversation` emits `conversationSurfaceFailed`; the pending shell shows a clear error briefly, then closes.
- If the source tab closes, its bound surface dismisses and the conversation remains in the sidebar.
- If the Space changes, the bound surface hides with its source tab.
- If the window restores conversations, no mini or dialog surface reopens automatically. Sidebar conversations remain the restore path.
- If a conversation tab closes, its bound surface closes too.
- Hidden surfaces do not subscribe to `conversationOpened`; `ConversationView` already owns show and hide on mount and unmount.

## Testing

Focused coverage includes:

- protocol tests for the new `startConversation` fields and `conversationSurfaceRequested`
- chrome store tests for pending surfaces, request matching, dismissal, replacement and promotion
- UI tests for the Ask Bar placement picker and Settings select
- component coverage for mini and dialog geometry, controls, dismiss behavior and reduced-motion paths
- Swift tests for `tab`, `split`, `mini`, `dialog`, background and fallback placement decisions
- a fakeHost end-to-end path for Ask Bar → mini → enlarge and Ask Bar → dialog → dismiss
- `make check` after each scoped edit, `make ui-lint ui-test` for UI-only slices and `make validate` before the full change is claimed

## Non-goals

- No separate native floating window or NSPanel.
- No draggable mini surface.
- No multiple mini conversations on one source tab.
- No automatic promotion based on task length or output type.
- No second side-panel column for agents.
- No change to conversation folders, `conversationTabId`, agent-opened page routing, permissions, models or ACP session behavior.
