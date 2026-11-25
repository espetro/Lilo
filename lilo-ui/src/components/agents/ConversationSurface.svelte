<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import { cubicIn } from "svelte/easing";
  import { fade } from "svelte/transition";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { t } from "../../lib/i18n/state.svelte";
  import Icon from "../ui/Icon.svelte";
  import AgentTile from "./AgentTile.svelte";
  import ConversationView from "./ConversationView.svelte";
  import {
    dismissConversationSurface,
    type ConversationSurface,
  } from "../../stores/conversationSurfaces.svelte";

  interface Props {
    surface: ConversationSurface;
  }

  let { surface }: Props = $props();

  const FULL_FRAME = { x: 0, y: 0, width: 1, height: 1 };
  const FOCUSABLE =
    "button:not(:disabled), input:not(:disabled), textarea:not(:disabled), select:not(:disabled), [tabindex]:not([tabindex='-1'])";

  const isDialog = $derived(surface.placement === "dialog");
  const ready = $derived(!surface.pending && surface.tabId !== null && surface.error === null);
  const title = $derived(surface.agentName || t("agents.ask.agent"));

  let surfaceEl: HTMLElement | undefined = $state();

  function dismiss(): void {
    dismissConversationSurface(surface.surfaceRequestId);
  }

  function handleKeydown(event: KeyboardEvent): void {
    if (event.key === "Escape" && !event.defaultPrevented) {
      event.preventDefault();
      dismiss();
      return;
    }
    if (!isDialog || event.key !== "Tab" || !surfaceEl) return;
    const items = Array.from(surfaceEl.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
      (item) => item.offsetParent !== null || item === document.activeElement,
    );
    if (items.length === 0) return;
    const first = items[0];
    const last = items[items.length - 1];
    const active = document.activeElement as HTMLElement | null;
    if (event.shiftKey && (active === first || !surfaceEl.contains(active))) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && (active === last || !surfaceEl.contains(active))) {
      event.preventDefault();
      first.focus();
    }
  }

  // A failed start has no conversation to keep: the shell reports it, then clears itself.
  $effect(() => {
    if (!surface.error) return;
    const timer = setTimeout(dismiss, 2400);
    return () => clearTimeout(timer);
  });

  $effect(() => {
    if (!isDialog || ready || !surfaceEl) return;
    surfaceEl.focus({ preventScroll: true });
  });

  // A modal dialog gives focus back to whatever had it when the surface goes away.
  let returnFocus: HTMLElement | null = null;
  $effect(() => {
    if (!isDialog) return;
    returnFocus = document.activeElement as HTMLElement | null;
    return () => {
      if (returnFocus?.isConnected) returnFocus.focus({ preventScroll: true });
    };
  });

  // The card keeps the Ask Bar's return motion: a short sink and fade, never a new direction.
  function closeSurface(_node: Element) {
    const duration = prefersReducedMotion() ? 0 : 140;
    return {
      duration,
      easing: cubicIn,
      css: (t: number, u: number) =>
        `opacity:${t};transform:${isDialog ? `translate(-50%,-50%) translateY(${u * 6}px) scale(${1 - u * 0.02})` : `translateX(-50%) translateY(${u * 6}px) scale(${1 - u * 0.02})`}`,
    };
  }
</script>

<div class="surface-root chrome-content-overlay-root">
  {#if isDialog}
    <button
      type="button"
      class="scrim"
      aria-label={t("common.close")}
      tabindex="-1"
      transition:fade={{ duration: prefersReducedMotion() ? 0 : 160 }}
      onclick={dismiss}
    ></button>
  {/if}
  <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
  <section
    bind:this={surfaceEl}
    class="surface float-surface"
    class:mini={!isDialog}
    class:dialog={isDialog}
    class:pending={!ready}
    role={isDialog ? "dialog" : "region"}
    aria-modal={isDialog ? "true" : undefined}
    aria-label={title}
    tabindex={ready ? undefined : -1}
    out:closeSurface
    use:reportInteractiveZone={{ id: `conversation-surface-${surface.surfaceRequestId}` }}
    onkeydown={handleKeydown}
  >
    {#if ready && surface.tabId}
      <ConversationView
        tabId={surface.tabId}
        frame={FULL_FRAME}
        presentation={surface.placement === "dialog" ? "surfaceDialog" : "surfaceMini"}
      />
    {:else}
      <header class="pending-header">
        <AgentTile agentId={surface.agentId} />
        <h1 class="pending-title">{title}</h1>
        <span class="spacer"></span>
        <button type="button" class="pending-close" aria-label={t("common.close")} onclick={dismiss}>
          <Icon name="close" size={13} />
        </button>
      </header>
      <div class="pending-body">
        {#if surface.error}
          <p class="pending-error">{t("placement.surfaceFailed")}</p>
          {#if surface.error}<p class="pending-detail">{surface.error}</p>{/if}
        {:else}
          <span class="pending-status">{t("agents.conversation.starting")}</span>
        {/if}
      </div>
    {/if}
  </section>
</div>

<style>
  .surface-root {
    pointer-events: none;
    z-index: 1000;
  }

  .scrim {
    position: absolute;
    inset: 0;
    padding: 0;
    border: 0;
    border-radius: var(--chrome-overlay-boundary-radius);
    background: var(--dialog-backdrop-tint);
    backdrop-filter: blur(var(--chrome-overlay-backdrop-blur));
    pointer-events: auto;
    cursor: default;
  }

  .surface {
    position: absolute;
    box-sizing: border-box;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    pointer-events: auto;
  }

  .surface.mini {
    left: 50%;
    bottom: var(--space-24);
    transform: translateX(-50%);
    width: min(700px, calc(100% - var(--space-32)));
    height: min(420px, calc(100% - 48px));
    border-radius: var(--radius-lg);
    animation: surface-mini-in var(--motion-duration-slow) var(--motion-ease-bounce) both;
  }

  .surface.dialog {
    left: 50%;
    top: 50%;
    transform: translate(-50%, -50%);
    width: min(840px, calc(100% - 48px));
    height: min(720px, calc(100% - 64px), 80vh);
    border-radius: var(--radius-lg);
    animation: surface-dialog-in var(--motion-duration-slow) var(--motion-ease-organic) both;
  }

  @keyframes surface-mini-in {
    from {
      opacity: 0;
      transform: translateX(-50%) translateY(10px) scale(0.98);
    }
  }

  @keyframes surface-dialog-in {
    from {
      opacity: 0;
      transform: translate(-50%, -50%) translateY(8px) scale(0.98);
    }
  }

  /* The shell lands first; the thread fades in once it has settled. */
  .surface :global(.conversation-root) {
    animation: surface-thread-in var(--motion-duration-slow) var(--motion-ease-standard) 140ms both;
  }

  @keyframes surface-thread-in {
    from {
      opacity: 0;
    }
  }

  .pending-header {
    flex: none;
    display: flex;
    align-items: center;
    gap: var(--space-8);
    height: 44px;
    padding: 0 var(--space-12) 0 var(--space-16);
    border-bottom: 1px solid var(--separator);
  }

  .pending-title {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  .spacer {
    flex: 1;
  }

  .pending-close {
    flex: none;
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-secondary);
    cursor: pointer;
  }

  .pending-close:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .pending-close:focus-visible {
    outline: var(--focus-outline);
  }

  .pending-body {
    flex: 1;
    display: grid;
    place-items: center;
    padding: var(--space-24);
    color: var(--text-secondary);
    font-size: var(--font-size-md);
    text-align: center;
  }

  .pending-error {
    margin: 0;
    color: var(--text-primary);
    font-weight: var(--font-weight-medium);
  }

  .pending-detail {
    margin: var(--space-6) 0 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .pending-status {
    color: var(--text-secondary);
  }

  @media (prefers-reduced-motion: reduce) {
    .surface.mini,
    .surface.dialog,
    .surface :global(.conversation-root) {
      animation: none;
    }
  }
</style>
