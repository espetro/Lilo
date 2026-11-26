<!-- The conversations of every Space, what waits on you first. Answering happens in place; a row takes
     you to its conversation. Mounted on the body, so it may run past a narrow sidebar over the page. -->
<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import AgentTile from "./AgentTile.svelte";
  import PermissionButtons from "./PermissionButtons.svelte";
  import { dismissable } from "../../lib/actions/dismissable";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { portal } from "../../lib/actions/portal";
  import { spaceActions, terminalActions } from "../../lib/bridge/actions";
  import type { BridgeAgentClient, BridgeConversationSummary } from "../../lib/bridge/protocol";
  import { getFormatLocale, t } from "../../lib/i18n/state.svelte";
  import { popoverOut } from "../../lib/motion/restingTransitions";
  import { getAgentClients } from "../../stores/agents.svelte";
  import { openAskBar } from "../../stores/conversations.svelte";
  import { getAgentClientsSnapshot } from "../../stores/settings.svelte";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";
  import { getActiveSpaceId, getSpaceById } from "../../stores/spaces.svelte";

  let { anchor, summaries, onclose }: { anchor: HTMLElement; summaries: BridgeConversationSummary[]; onclose: () => void } = $props();

  const sections = $derived.by(() => {
    const needs: BridgeConversationSummary[] = [];
    const running: BridgeConversationSummary[] = [];
    const done: BridgeConversationSummary[] = [];
    for (const summary of summaries) {
      if (summary.permission) needs.push(summary);
      else if (summary.state === "busy" || summary.state === "starting") running.push(summary);
      else if (summary.unread || summary.state === "failed" || summary.title) done.push(summary);
    }
    return [
      { key: "needs", label: t("agents.badge.needsYou"), items: needs, start: 0 },
      { key: "running", label: t("agents.badge.running"), items: running, start: needs.length },
      { key: "done", label: t("agents.badge.done"), items: done, start: needs.length + running.length },
    ].filter((section) => section.items.length > 0);
  });
  const activeSpaceId = $derived(getActiveSpaceId());
  const askKeys = $derived(shortcutKeys("agents.ask"));

  // External MCP clients connected to lilo-mcp now: this list is per client name, honestly - a client
  // naming itself the same twice collapses into one row here, as the bridge already collapses it.
  const mcpClients = $derived(getAgentClients());
  const mcpNames = $derived(new Map(getAgentClientsSnapshot().allowed.map((agent) => [agent.name, agent])));
  const mcpClientIcons = $derived(new Map(getAgentClientsSnapshot().clients.map((client) => [client.id, client.icon])));
  const spaceListFormat = $derived(new Intl.ListFormat(getFormatLocale(), { type: "conjunction" }));

  function mcpDisplayName(name: string): string {
    return mcpNames.get(name)?.displayName || name;
  }

  function mcpIcon(name: string): string | null {
    const clientId = mcpNames.get(name)?.client;
    return (clientId && mcpClientIcons.get(clientId)) || null;
  }

  function mcpSpaceNames(client: BridgeAgentClient): string[] {
    return client.spaceIds.map((id) => getSpaceById(id)?.name).filter((name): name is string => !!name);
  }

  function mcpState(client: BridgeAgentClient): string {
    if (client.waitingForUser) return t("agents.status.waiting");
    if (client.busy) return t("agents.row.working");
    return t("agents.status.connected");
  }

  // The acting tab is the most relevant target; with none, its Agents space. Lilo exposes no stop
  // or pause for an external client here: there is no safe native action to call yet (see AGENTS.md).
  function revealMcpClient(client: BridgeAgentClient): void {
    const tabId = client.actingTabIds[0];
    if (tabId) {
      terminalActions.reveal(tabId);
    } else {
      const spaceId = client.spaceIds[0];
      if (!spaceId) return;
      spaceActions.switchTo(spaceId);
    }
    onclose();
  }

  const WIDTH = 320;
  const MARGIN = 8;
  // Right-aligned with the pill, toward the page whichever edge the pill sits on.
  const position = $derived.by(() => {
    const rect = anchor.getBoundingClientRect();
    const below = rect.top < window.innerHeight / 2;
    return {
      below,
      left: Math.min(Math.max(MARGIN, rect.right + 6 - WIDTH), window.innerWidth - WIDTH - MARGIN),
      vertical: below ? `top: ${rect.bottom + 6}px;` : `bottom: ${window.innerHeight - rect.top + 6}px;`,
    };
  });

  let popover: HTMLDivElement | undefined = $state();

  $effect(() => {
    popover?.querySelector<HTMLElement>(".float-row, .new")?.focus();
  });

  function line(summary: BridgeConversationSummary): string {
    if (summary.permission) return summary.permission.title;
    if (summary.state === "busy" || summary.state === "starting") return t("agents.row.working");
    if (summary.error) return summary.error;
    if (summary.state === "failed") return t("agents.row.failed");
    return summary.unread ? t("agents.badge.finished") : "";
  }

  const now = Date.now();
  const format = new Intl.RelativeTimeFormat(getFormatLocale(), { numeric: "auto", style: "narrow" });

  function age(at: number): string {
    const minutes = Math.round((at - now) / 60_000);
    if (Math.abs(minutes) < 60) return format.format(minutes, "minute");
    const hours = Math.round(minutes / 60);
    return Math.abs(hours) < 24 ? format.format(hours, "hour") : format.format(Math.round(hours / 24), "day");
  }

  function handleKeydown(event: KeyboardEvent): void {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const rows = Array.from(popover?.querySelectorAll<HTMLElement>(".float-row, .new") ?? []);
    if (rows.length === 0) return;
    event.preventDefault();
    const index = rows.indexOf(document.activeElement as HTMLElement);
    rows[(index + (event.key === "ArrowDown" ? 1 : -1) + rows.length) % rows.length]?.focus();
  }
</script>

<div
  bind:this={popover}
  class="popover float-surface float-popover"
  out:popoverOut|global
  class:above={!position.below}
  role="dialog"
  tabindex="-1"
  aria-label={t("agents.badge.title")}
  style="{position.vertical} left: {position.left}px; width: {WIDTH}px;"
  use:portal
  use:reportInteractiveZone={{ id: "agents-popover" }}
  onkeydown={handleKeydown}
  {@attach dismissable({ onDismiss: onclose, ignore: ".agents-button, .ui-split-menu", escape: true, returnFocus: anchor })}
>
  <div class="head">
    <span class="float-popover-title">{t("agents.badge.title")}</span>
    <button
      class="new"
      onclick={() => {
        onclose();
        openAskBar();
      }}
    >
      {t("agents.badge.new")}
      {#if askKeys}<span class="keys" aria-hidden="true">{askKeys}</span>{/if}
    </button>
  </div>

  <div class="list">
    {#each sections as section (section.key)}
      <div class="section" role="group" aria-label={section.label}>
        <div class="section-label" aria-hidden="true">{section.label}</div>
        {#each section.items as summary, index (summary.tabId)}
          {@const detail = line(summary)}
          {@const otherSpace = summary.spaceId !== activeSpaceId}
          <div class="item" class:waiting={!!summary.permission} style:--stagger={Math.min(section.start + index, 8)}>
            <button
              class="float-row"
              aria-label={[summary.title || t("agents.row.untitled"), detail, otherSpace ? summary.spaceName : "", section.key === "done" && summary.lastActivity ? age(summary.lastActivity) : ""].filter(Boolean).join(", ")}
              onclick={() => {
                terminalActions.reveal(summary.tabId);
                onclose();
              }}
            >
              <span class="icon">
                <AgentTile agentId={summary.agentId} />
                {#if summary.permission}<span class="dot" aria-hidden="true"></span>{/if}
              </span>
              <span class="text">
                <span class="name">{summary.title || t("agents.row.untitled")}</span>
                {#if detail}
                  <span
                    class="detail"
                    class:command={!!summary.permission && !summary.permission.question}
                    class:finished={!summary.permission && section.key === "done" && summary.unread}
                    class:error={summary.state === "failed"}
                  >{detail}</span>
                {/if}
              </span>
              {#if otherSpace}<span class="space" aria-hidden="true">{summary.spaceName}</span>{/if}
              {#if section.key === "done" && summary.lastActivity}<span class="age" aria-hidden="true">{age(summary.lastActivity)}</span>{/if}
              {#if section.key === "running"}
                <span class="spinner" aria-hidden="true"></span>
              {/if}
            </button>
            {#if summary.permission && !summary.permission.question}
              <div class="answers">
                {#if summary.permission.count > 1}
                  <span class="more">{t("agents.row.morePermissions", { count: summary.permission.count - 1 })}</span>
                {/if}
                <PermissionButtons tabId={summary.tabId} requestId={summary.permission.requestId} options={summary.permission.options} />
              </div>
            {/if}
          </div>
        {/each}
      </div>
    {/each}
    {#if mcpClients.length > 0}
      <div class="section" role="group" aria-label={t("agents.badge.mcp")}>
        <div class="section-label" aria-hidden="true">{t("agents.badge.mcp")}</div>
        {#each mcpClients as client, index (client.name)}
          {@const spaceNames = mcpSpaceNames(client)}
          {@const icon = mcpIcon(client.name)}
          {@const canReveal = client.actingTabIds.length > 0 || client.spaceIds.length > 0}
          {@const label = [mcpDisplayName(client.name), mcpState(client), spaceNames.length ? spaceListFormat.format(spaceNames) : ""].filter(Boolean).join(", ")}
          <div class="item" class:waiting={client.waitingForUser} style:--stagger={Math.min(sections.reduce((n, section) => n + section.items.length, 0) + index, 8)}>
            {#snippet mcpRow()}
              <span class="icon">
                {#if icon}<img class="mcp-logo" src={icon} alt="" />{:else}<span class="mcp-tile" aria-hidden="true">{mcpDisplayName(client.name).charAt(0).toUpperCase()}</span>{/if}
                {#if client.waitingForUser}<span class="dot" aria-hidden="true"></span>{/if}
              </span>
              <span class="text">
                <span class="name">{mcpDisplayName(client.name)}</span>
                <span class="detail" class:finished={client.waitingForUser}>{mcpState(client)}</span>
              </span>
              {#if spaceNames.length}<span class="space" aria-hidden="true">{spaceListFormat.format(spaceNames)}</span>{/if}
            {/snippet}
            {#if canReveal}
              <button class="float-row" aria-label={label} onclick={() => revealMcpClient(client)}>
                {@render mcpRow()}
              </button>
            {:else}
              <div class="float-row static" aria-label={label}>
                {@render mcpRow()}
              </div>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
    {#if sections.length === 0 && mcpClients.length === 0}
      <p class="empty">{t("agents.badge.empty")}</p>
    {/if}
  </div>
</div>

<style>
  .popover {
    position: fixed;
    z-index: var(--z-popover);
    padding: var(--space-8);
    transform-origin: calc(100% - 12px) 0;
  }

  .popover.above {
    transform-origin: calc(100% - 12px) 100%;
  }

  .head {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 4px 4px 0 8px;
  }

  .head .float-popover-title {
    flex: 1;
  }

  /* The panel's main action, a text button on the right of its title. */
  .new {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    height: var(--control-height-sm);
    padding: 0 var(--space-6);
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--accent-ink, var(--accent));
    font-family: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
    cursor: pointer;
  }

  .new:hover {
    background: var(--bg-hover);
  }

  .new:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .keys {
    color: var(--text-muted);
    font-weight: var(--font-weight-regular);
  }

  .list {
    display: flex;
    flex-direction: column;
    max-height: 420px;
    overflow-y: auto;
  }

  .section {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .section-label {
    padding: 14px 8px 4px;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--text-muted);
  }

  /* Rows follow the popover in, 20ms apart; the cap keeps a long list from trailing. */
  .item {
    border-radius: var(--radius-md);
    animation: agents-popover-row-in var(--motion-duration-normal) var(--motion-ease-organic) both;
    animation-delay: calc(40ms + var(--stagger) * 20ms);
  }

  @keyframes agents-popover-row-in {
    from {
      opacity: 0;
      transform: translateY(-4px);
    }
  }

  .item.waiting {
    background: color-mix(in srgb, var(--text-primary) 5%, transparent);
  }

  .item .float-row {
    align-items: flex-start;
    gap: 10px;
    padding-block: 8px;
    border-radius: var(--radius-md);
  }

  .icon {
    position: relative;
    flex: none;
    display: grid;
    margin-top: 1px;
  }

  .mcp-logo {
    width: 16px;
    height: 16px;
    border-radius: var(--radius-xs);
  }

  .mcp-tile {
    flex: none;
    width: 16px;
    height: 16px;
    box-sizing: border-box;
    border-radius: var(--radius-xs);
    display: grid;
    place-items: center;
    background: var(--terminal-tile-bg);
    box-shadow: inset 0 0 0 1px var(--terminal-tile-border);
    color: var(--terminal-tile-text);
    font-size: var(--font-size-3xs);
    font-weight: var(--font-weight-bold);
    line-height: 1;
  }

  /* A client with nothing to reveal yet (connected, no space or acting tab): information only. */
  .float-row.static {
    cursor: default;
  }

  .float-row.static:hover {
    background: transparent;
  }

  .dot {
    position: absolute;
    right: -3px;
    bottom: -3px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--attention);
    box-shadow: 0 0 0 2px var(--float-surface);
  }

  .text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .name {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .detail {
    font-size: var(--font-size-sm);
    color: var(--text-secondary);
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .detail.command {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
  }

  .detail.finished {
    color: var(--accent-ink, var(--accent));
  }

  .detail.error {
    color: var(--danger-text);
  }

  .space,
  .age {
    flex: none;
    max-width: 30%;
    margin-top: 1px;
    font-size: var(--font-size-sm);
    color: var(--text-muted);
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .age {
    font-variant-numeric: tabular-nums;
  }

  .answers {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: var(--space-8);
    padding: 0 8px 8px 34px;
  }

  .more {
    min-width: 0;
    margin-right: auto;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  /* About 30 s of turns, then a still arc: a turn left running must not keep the display link up. */
  .spinner {
    flex: none;
    width: 12px;
    height: 12px;
    margin-top: 3px;
    box-sizing: border-box;
    border-radius: 50%;
    border: 1.5px solid var(--text-primary-tint-12);
    border-top-color: var(--agents);
    border-right-color: var(--agents);
    animation: agents-popover-spin 0.9s linear 33 forwards;
  }

  @keyframes agents-popover-spin {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .spinner,
    .item {
      animation: none;
    }
  }

  /* The global rule shortens animations but not their delays, which would hold rows back. */
  :global(html.reduced-power) .item {
    animation: none;
  }

  .empty {
    margin: 0;
    padding: 12px 8px 8px;
    font-size: var(--font-size-md);
    color: var(--text-secondary);
  }
</style>
