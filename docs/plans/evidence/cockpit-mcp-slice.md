# Cockpit MVP, first slice: external MCP clients in the Agents popover

Date: 2026-11-26. Stage 5 artifact for [multi-agent-roadmap.md](../multi-agent-roadmap.md). Covers the first visible piece of the cockpit, not the full workspace system the roadmap describes.

## What this slice is

The Agents popover (`lilo-ui/src/components/agents/AgentsPopover.svelte`) already lists in-browser conversations. This slice adds a second, clearly separated section listing the external clients connected over `lilo-mcp` right now: their name, whether they are acting, waiting for an approval, or merely connected, the Agents space(s) they work in, and one reveal action for the most relevant tab or space.

The data comes from the existing `agentActivity` bridge event (`Lilo/Agent/AgentControl.swift`, `publishActivity`). One addition was needed: `waitingForUser`, a per-client boolean taken from `AgentSession.waitingForUser`, so the popover can show "Waiting for you" instead of only "Working" or "Connected". No other native or protocol change was needed; `AgentControl` already collapses sessions by client name into one entry per name (`Set(authorized.map(\.clientName))`).

## Honest limits

- **Per client name, not per tenant or per run.** The payload has always been grouped by the name a client gives at handshake. Two processes of the same tool connecting under the same name collapse into one row here, as they already did in the mascot's mood and in Settings > Agents. This slice does not claim per-run isolation; that is stage 3's tenant/run identity work, not this one. If a client needs to be told apart from another of the same name, it has to pick a different name, since there is no product-level identity below that today.
- **No stop or pause control.** The bridge exposes no safe way to stop or pause one external session from the chrome: `stopCalls`/`stopAll` end every tool call of a conversation tab or of the whole agent socket, not one client's session, and nothing narrower exists. Revoking a client (`settingsActions.revokeAgentClient`) is a durable permission change, not a live-session control, and reconnecting it needs the user's consent again, so using it as a "stop" button would surprise a user who only meant to pause one run. Rather than invent a new native action for this slice, the row has no stop control at all. A real stop/pause needs a native, per-session action first; that is future native work, not a UI omission to silently work around.

## What was not touched

Conversations keep their existing sections, rows and behavior; nothing about them changed. The badge's numeric "waiting" count and spinner ring still come only from conversations, as before. The new section only changes whether the popover opens at all when no conversation is listed but an MCP client is connected (`AgentsBadge.svelte`'s `listed` check), since otherwise the click would start a new conversation instead of showing the client that is already there.

## Evidence

- `lilo-ui/src/stores/agents.test.ts`: `waitingForUser` passes through the store unchanged, same as the other per-client fields.
- `lilo-ui/e2e/agentsPopover.spec.ts`: the three states a connected client can be in (acting, waiting, idle-but-connected) render with the right label and reveal behavior, and the idle client with no space or acting tab yet has no clickable action, as there is nothing yet to reveal.
- `lilo-ui/captures/scenarios.ts`: `agents-popover-mcp-{light,dark}` capture the section for PR review.

## What this does not decide

This does not settle workspace language, run grouping, or any shared-tenant semantics; those stay stage 3/6 questions. It does not add a stop action; a future native change to let one session's calls be cancelled from the chrome is a prerequisite, tracked here rather than in the roadmap body since it is an implementation detail of this slice, not a new roadmap stage.
