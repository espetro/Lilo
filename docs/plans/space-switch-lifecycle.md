# Space-switch tab lifecycle

Investigation and fix design for "switching Spaces puts the tabs of the Space I left to sleep and loses their state", written against `develop` at 452f84d5. Deliverable 1 traces the code paths, deliverable 2 compares what other browsers do from primary sources, deliverable 3 is the implemented fix.

## 1. What a Space switch does today

### The switch

`MainWindowController.switchToSpace` (`Lilo/Spaces/MainWindowController+Spaces.swift:410`) parks the current runtime and restores the target Space's. `leaveSpace` (`MainWindowController+Spaces.swift:338`) calls `parkCurrentSpaceRuntimeForSwitch` (`Lilo/Tabs/TabManager+StateTransfer.swift:88`), which removes the web views from the window, snapshots the engines into a `TabRuntimeSnapshot`, and hands it to `BrowserStateStore.cacheInactiveSpaceRuntime` (`Lilo/State/BrowserStateStore.swift:683`). No engine is torn down at this point; the tab content processes stay alive, parked.

Immediately after, `leaveSpace` calls `context.hiddenSpaceLifecycle.scheduleTrim(excluding: nextSpaceId)` (`MainWindowController+Spaces.swift:393`). That schedules `HiddenSpaceLifecycleController`'s trim closure (`Lilo/Tabs/HiddenSpaceLifecycleController.swift:145`), which runs `trimInactiveEngines` (`BrowserStateStore.swift:811`) after the trim delay, plus `trimActiveSpaceEngines` on every window for the now-visible Space.

### What the trim did before this change

`trimInactiveEngines` asked `TabLifecycleCoordinator` (`Lilo/Tabs/TabLifecycleCoordinator.swift`) for two things:

- `hiddenSpacesToEvict`: more than `maxHiddenSpacesWithNormalRetainedEngines` (2 on Balanced) hidden Spaces hold engines -> the least recently accessed Spaces lose **every unprotected engine outright** (a discard).
- `retainedEngineIds`: each surviving hidden Space keeps at most `maxNormalRetainedEnginesPerHiddenSpace` (6 on Balanced, or all engines in the foreground policy? no - the budget, then protected and MRU tabs); engines beyond the budget were **discarded**.

So a Space switch did not merely freeze what it left: the second you left a Space, every engine of that Space beyond the six-engine budget, and every engine of a third hidden Space, was discarded (reload on return, page state lost), unless the tab was in `discardProtectedEngineIds`: agent-controlled, PiP, Keep Loaded, audio within its grace, capture devices, restoring grace, and unsaved form data (discard only), plus inspected and displayed engines.

The active Space was trimmed the same way: `trimActiveSpaceEngines` (`TabManager+StateTransfer.swift:126`) discarded the active Space's over-budget engines.

### Frozen vs discarded vs profile switch

- **Frozen**: `freezeIdleEngines` (`BrowserStateStore.swift:747`) freezes hidden and active-space background engines idle longer than `freezeThreshold` (300 s Balanced), and the window-occluded path freezes everything after `hiddenFreezeDelay`. `WKWebViewTab.freeze` cooperates with the page through `PageWorld` and calls the private `_suspendPage:`. A frozen engine resumes in place without reload: DOM, JS heap, scroll, websockets stay. A frozen page still loses wall-clock behavior (timers, reconnect loops run only on resume) but not state. `hasUnsavedFormData` did **not** protect a tab from freezing, so a form could be suspended mid-edit.
- **Discarded on Space switch**: the `trimInactiveEngines` and `trimActiveSpaceEngines` calls above. The engine is torn down after `discardRuntimeState` stashes interaction state (scroll, history, form field values where WebKit keeps them); returning to the tab reloads the page. In-flight uploads/downloads, pending navigations, open editors, JS-only flow state and `beforeunload` prompts are lost.
- **Profile/private switch**: `parkCurrentSpaceRuntimeForSwitch` parks engines the same way; per-Profile `WKWebsiteDataStore`s and per-tab ephemeral stores for private Spaces are keyed on the engine, so parking is what isolates them. Private Spaces may additionally tear engines down by design; that is intentional and unchanged.
- **Idle timestamps**: `lastActiveAt` is stamped on tab activation (`noteTabActivated`, `BrowserStateStore.swift:672`, via `TabManager.activateTabRuntime` at `Lilo/Tabs/TabManager.swift:262`) and for the left Space's active tab at park time (`cacheInactiveSpaceRuntime`). Split-pane siblings of the active tab were **not** stamped: their idle clock kept running through the time they were visible.

### States not protected before this change

- Freezing a tab with `hasUnsavedFormData`: `shouldRetainFromDiscard` vetoed only the discard (`TabLifecycleCoordinator.swift:278`).
- A tab `isLoading` (pending navigation, pending POST, first load): protected from nothing.
- In-progress uploads inside a loaded page have no cheap isolated-world signal; they ride the generic protections (form dirty, Keep Loaded) or nothing. Same for an open `beforeunload` prompt, which WebKit reports only as a pending navigation to the delegate.
- WebRTC: capture-active tabs are protected; a peer connection with no local capture tracks only `callControls.hasPeerConnection`, which blocks the idle sweep's freeze via a page-world probe but not a discard.

## 2. What other browsers do

| Browser | Sleep trigger | Protected | Shown as | User control |
|---|---|---|---|---|
| Chrome Memory Saver | Inactivity (configurable by mode; Moderate/Balanced/Maximum) | audio/video, calls, screen share, notifications, downloads, partially filled forms, pinned tabs, connected devices, DevTools; non-visible <10 min protected from urgent discard (chromium resource_coordinator `tab_manager`) | dimmed favicon + "inactive" ring, "Memory Saver" chip on return | per-site "always keep active" allowlist; Memory Saver on/off and mode |
| Chromium internals | proactive discard targets a measured reclaim amount; eligibility = disallowed vs protected | as above; 10-min non-visible protection, 1-min audio grace | n/a | n/a |
| Edge Sleeping Tabs | `SleepingTabsTimeout` (default 900 s, 30 s - 12 h), Energy Saver shortens to 5/30 min, 15 min under 6 GB RAM | same Chromium set + sleeping-tabs URL blocklist | faded tab in tab strip, "sleeping" tooltip | settings + group policies (timeout, blocklist, enable/disable) |
| Zen Browser | explicit workspace unload (`unloadWorkspace`, `unloadAllOtherWorkspaces`) | `zenModeActive` tabs, empty, essential, pending | dimmed tab | per-workspace unload commands |
| Firefox | `browser.tabs.unloadOnLowMemory` (memory pressure only, off by default on most platforms) | pinned, audio, video calls, DevTools | reloaded-on-click | about:config pref |
| Safari/WebKit | no user-facing tab sleep; WebKit suspends hidden/occluded web content and throttles timers; iOS jetsams under pressure | n/a | n/a | none |
| Arc | auto-**archive** (close + recover from archive), configurable period (default ~30 days), not a sleep | pinned tabs | tab moves to archive | per-Space auto-archive toggle + period |
| Vivaldi | "Tab Hibernation" (hibernate all or background tabs on demand) | active tab | hibernated tab muted/dimmed | commands + settings |
| Brave | inherits Chromium Memory Saver (`brave://settings/system`) | Chromium set | same | same + allowlist |
| BrowserOS | Chromium fork: inherits Memory Saver | Chromium set | same | same |

Sources: Chrome help `support.google.com/chrome/answer/12929150`; Chromium `chrome/browser/resource_coordinator` discard policy (10-min non-visible protection, 1-min audio protection, measured reclaim targets, footprint split across frames per process); Edge `SleepingTabsTimeout` policy docs; zen-browser/desktop `TabUnloader.sys.mjs` patch and workspace `unloadWorkspace`/`unloadAllOtherWorkspaces`; Firefox `browser.tabs.unloadOnLowMemory` pref (source fetch 404'd, pref documented via search results - honest limitation); Vivaldi Tab Hibernation marketing page (help 404s); Arc help 403 (behaviour from documented settings). Arc's page is Cloudflare-blocked and Firefox/Zen/Vivaldi details beyond the cited source could not be verified further.

Two lessons transfer: **form data and loading/pending tabs are first-class protections everywhere that has them**, and **discard is a memory-pressure response, not an inactivity response** - every engine that offers both keeps sleeping tabs resident until the system needs the memory.

## 3. The fix (implemented)

The smallest effective change: routine trims freeze instead of discarding, and the two protection gaps close.

- `trimInactiveEngines` gains `freezesExcessEngines` (`BrowserStateStore.swift:805`): under it, the budgets count **live** engines only and evict/freeze rather than discard; discard-protected engines (now including loading tabs) stay live. `HiddenSpaceLifecycleController` sets it for every routine trim - space switch, idle sweep, post-activation trim - whenever the memory-pressure plan is `.foreground` with no warning/critical pressure (`HiddenSpaceLifecycleController.swift:126`). Warning/critical pressure, constrained power, `forceTrim`, the footprint ceiling and the window-hidden path still discard.
- `trimActiveSpaceEngines`/`trimActiveSpace` take the same flag; the visible Space freezes over-budget background tabs instead of discarding them (`TabManager+StateTransfer.swift:126`, `MainWindowController+Lifecycle.swift:35`).
- `hasUnsavedFormData` moves into `shouldRetainProtected`, vetoing freeze too: a frozen page cannot autosave and sees `visibilitychange hidden` mid-edit (`TabLifecycleCoordinator.swift:299`). Detection stays exactly where it is - `FormDirtyBridge` in `PageWorld.bridgeWorld`, event-driven, no globals, no polling.
- `isLoading` joins `shouldRetainFromDiscard`: a pending navigation/POST is never torn down mid-flight.
- `cacheInactiveSpaceRuntime` stamps `lastActiveAt` on the left Space's active tab **and its split-pane siblings** (`BrowserStateStore.swift:683`), so idle time is measured from when each tab was last visible, not from the switch nor from an older in-space activation.

Cost at idle: zero. The checks run only inside a trim that already ran; `freezesExcessEngines` is a parameter, the protection lookups are the same `Tab` flags the coordinator already read.

### What is deliberately unchanged

- A per-Space setting: the existing global preset + per-tab Keep Loaded + host allowlist already cover the ask cheaply; a per-Space knob duplicates them.
- In-progress uploads and `beforeunload`: no cheap isolated-world signal exists (uploads are in-process `fetch`/XHR state; `beforeunload` is delegate-side). The generic protections that do exist cover most real cases (a filled form is dirty).
- Private Spaces tearing engines down: intentional isolation, kept.

### Tests (CI only, per task contract)

`TabLifecycleCoordinatorTests.testProtectionMatrixAcrossFreezeDiscardAndIdleDiscard` - table of tab state x trigger x policy; `BrowserStateStoreTests` gains freeze-mode trim tests (excess frozen not discarded, unsaved-form engine stays live, reclaim mode still discards). The flipped assertion in `testUnsavedFormInputSurvivesHiddenSpaceBudgetAndBackgroundPolicy` documents the new freeze veto.
