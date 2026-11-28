# Staged plan: cross-platform ROI, Linux agent offload, and the Windows on-ramp

Plan, 2026-11-24. Written against the findings in [CROSS-PLATFORM.md](../CROSS-PLATFORM.md) and the audit in [cross-platform-roadmap-proof.md](cross-platform-roadmap-proof.md). Goals, in priority order:

1. **Highest ROI to the macOS product** — every stage must pay for itself on macOS alone.
2. **Maximize the non-macOS surface that Linux agents can carry** — grow the share of work done outside macOS, via `make linux-checks` and containers, without a GUI port.
3. **Keep performance and the first-party macOS feel** — no framework swap, no abstraction tax, AppKit stays.
4. **Leave the Windows port (~85–90% extension parity) as easy as possible to start** — by converging on the shell contract, not by building it now.

Non-goals preserved: no CEF, no Chromium abstraction, no Windows/Linux GUI port as a standing goal. Each stage lists the evidence obligations per [CONTRIBUTING.md](../../CONTRIBUTING.md#pr-evidence).

## Stage 0 — Extract the portable core (prerequisite; pays on macOS)

Move the ~8–9k lines of portable logic living inside AppKit files into a framework-free shared core, with no behavior change:

- Browser-state sync and command application from `MainWindowController.swift` (`sendTabUpdate`, `browserSnapshot`, `applyBrowserCommand`, ~342–573) into a `BrowserCore`-style module speaking only the bridge protocol.
- Split-pane layout math out of `MainWindowController+SplitView.swift` (1150 lines) into pure geometry types.
- Hit-classification *semantics* (zone store, gesture phases, drag-target classification behind `ChromeInteractionRouting.swift`/`ChromeEventRouter.swift`) separated from the NSEvent/DraggingInfo plumbing; `TabLayout.swift` is already clean — mirror it.
- Rule: new logic lands framework-free by default (models, protocol, filters already do; this extends the discipline to shell-adjacent logic).

**ROI on macOS:** the extracted core is unit-testable without windows (today `make swift-test` needs keyboard focus and CI shards); faster in-session checks; smaller AppKit diff surface.
**Linux offload:** the whole extracted core builds and tests on Linux under `make linux-checks` — every future feature written at this layer is agent-work off macOS.
**Windows on-ramp:** this *is* the shell contract's precondition.
**Definition of done:** no AppKit import in the shared core; CI runs its tests on both macOS and the Linux dev loop; `make validate` time unchanged or better.

## Stage 1 — Containerizable headless mode (Linux agents carry the agent surface)

Make `lilo run --mcp` (the `Lilo/Agent/` Unix-socket + CDP stack, 14/22 files already AppKit-free) runable in a Linux container driving WebKitGTK, with the same MCP tool surface:

- Split `Lilo/Agent/` along the same seam as Stage 0: protocol/consent/snapshot logic framework-free; a thin macOS driver over WKWebView behind it.
- A Linux driver over WebKitGTK implementing only what the tool surface consumes (tabs, snapshots, input, consent surface rendered in the Svelte chrome *inside the container's WebKitGTK view* — no native shell needed headless).
- Ship an OCI image + `make docker-mcp` target; document in [docs-site] alongside `manualSnippet`.
- Watch-paths note: the agent tool catalog feeds the docs-site reference generator — `make docs-check` required.

**ROI on macOS:** none directly, but it converts the agent-first moat (workflow (A)/(C) in [plans/agent-plugin-research.md](agent-plugin-research.md)) into a platform-neutral product — the moat stops being macOS-gated.
**Linux offload:** the driver, container plumbing, and e2e are all buildable/tested by Linux agents; macOS CI cost stays flat.
**Windows on-ramp:** the same driver interface is what a WebView2 driver implements later; consent/snapshot logic is reused verbatim.

## Stage 2 — Linux companion extension (full agent parity in the user's own Chromium)

Package Lilo's agent tool surface as a Web Store extension + native-messaging host for the user's own Chrome/Chromium/Brave/Edge on any OS (this is the honest Chromium-on-Linux play found in research):

- Extension: tabs/snapshot/scripting over `chrome.*`; the Lilo app (or container, headless) as the native-messaging peer.
- Linux install path: opt-in policy JSON (`ExtensionSettings` → `force_installed`, self-hosted update URL) + `/etc/chromium/native-messaging-hosts/` manifest, written by a .deb/.rpm postinst; clean uninstall removes both. No Windows/macOS policy path (enrollment-gated there) — those OSes use normal Store installs.
- This preserves the Chrome 136 constraint: no CDP-on-default-profile; the extension API route is the sanctioned one.

**ROI on macOS:** the same extension gives Lilo agent control *inside the user's Chrome on macOS* — a real feature for users who browse in Chrome but want Lilo's agent layer.
**Linux offload:** extension code is TS, built and tested by Linux agents (`make ext-bridge-build` toolchain is already Linux-clean).
**Windows on-ramp:** the CRX + `AddBrowserExtensionAsync` story reuses this packaging; the extension half of the 85–90% parity is written once.

## Stage 3 — Shell contract formalization (documents + codegen, no second shell yet)

Write the shell contract down and make the build emit per-host stubs, so a future port starts from codegen, not archaeology:

- `docs/SHELL-CONTRACT.md`: the four responsibilities (window lifecycle, input pump, composition overlay, system integration) with the extracted-core API each consumes.
- `make bridge-gen` additionally emits host-binding skeletons per target (Swift/macOS today; annotated Win32/GTK stubs kept out of the Xcode project).
- Track the two upstream dependencies that change the calculus: WebView2 #3259 (extension UI entry points) and WebKitGTK #52242 (`WebExtensionContext`). One line each in [CROSS-PLATFORM.md](../CROSS-PLATFORM.md) per release; no code.

**ROI on macOS:** the skeletons force the macOS side to stay honest about the seam; near-zero maintenance.
**Windows on-ramp:** this is the difference between "9–13 person-months starting from a survey" and the same months starting from generated stubs with the contract already enforced by CI.

## Stage 4 (trigger-gated) — Windows shell

Only on a trigger (demand, headcount). Scope fixed by prior research; not started before Stage 0–3 land:

- Win32 + DirectComposition + `ICoreWebView2CompositionController` (WinUI 3 is structurally unsuitable — composition hosting requires DComp visuals and host-owned input forwarding).
- Reuse: Svelte chrome unmodified, extracted core unmodified, agent driver from Stage 1, extension packaging from Stage 2, xterm.js + ConPTY for terminal (no Metal renderer port).
- Parity target ~85–90%; gaps (no Web Store in-app, partial `chrome.action`) documented in COMPATIBILITY.md per the Extension Gap rule.
- Effort: 9–13 person-months initial, ~0.5 FTE recurring; Evergreen runtime + bootstrapper, no engine shipped.

## Linux GUI — deliberately absent

A rendering-first GTK4+WebKitGTK port (16–24 p-m, no extensions, ~1 FTE recurring) is not scheduled at any stage. It becomes a candidate only if WebKitGTK #52242 merges and stabilizes (trigger 4 in the proof doc) *and* a demand trigger fires. Until then, Linux is served by Stages 1–2, which cover the agent-first moat — the part with a market — without a GUI.

## Sequencing and effort summary

| Stage | Effort | macOS ROI | Linux-agent offload | Windows on-ramp |
|---|---|---|---|---|
| 0 extraction | 2–4 p-m | testable core, faster checks | core tests on Linux | precondition |
| 1 container MCP | 1–2 p-m | moat becomes platform-neutral | driver + e2e | driver interface |
| 2 companion ext | 2–4 p-m | agent layer inside user's Chrome | all TS | extension packaging |
| 3 contract + codegen | weeks | seam honesty | stubs buildable on Linux | generated starting point |
| 4 Windows shell | 9–13 p-m, trigger-gated | — | — | — |

Stages 0–3 total ~6–10 person-months, every one justified by macOS ROI or agent-moat ROI alone, and they reduce — not add — the eventual Windows bill by front-loading everything portable.
