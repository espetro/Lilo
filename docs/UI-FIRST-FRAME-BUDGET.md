# The chrome's first-frame budget

`scripts/embed_chrome_ui.py` fails `make ui-build` when the part of the chrome UI that loads before its first frame grows past `max_first_frame_bytes`.
This note says what that number protects, where today's bytes are, whether Lighthouse or web vitals would be a better gate, and the smallest change that gives an honest signal.
Everything here was measured on 2026-11-19 on `develop` (`01ef9915`) with the bundle `make ui-build` produces.

## What the budget protects

The chrome is a Svelte app served from `lilo-chrome://ui/` out of text compiled into the binary ([ARCHITECTURE.md](ARCHITECTURE.md#overlay-hud-design), [WEB-CHROME.md](WEB-CHROME.md)).
There is no network, no cache and no transfer size: the cost of a byte is the parse and evaluation of it in the chrome's WebContent process on every launch, before the first paint.
So the budget counts raw UTF-8 bytes, not gzip bytes, and Lighthouse's transfer-size and TTFB audits have nothing to say about it.

The first frame is `index.html` plus what it references: `index.js`, the `initial` chunk and its stylesheet (`vite.config.ts` puts the whole first frame in that one chunk on purpose).
Two budgets exist: the whole embedded bundle (`max_embedded_bytes`, 4,552,500 with 15 catalogs) and the first frame (`max_first_frame_bytes`, `604_704 + 128` per catalog beyond six, 605,856 today).

| Part | Bytes | Share of the bundle |
|------|------:|--------------------:|
| Emoji catalogs, 14 locales (lazy) | 1,412,456 | 32.7 % |
| Message catalogs, 14 locales (lazy) | 1,187,466 | 27.5 % |
| Other lazy chunks (139 files) | 614,736 | 14.2 % |
| First frame (`index.html`, `index.js`, `initial` js 484,912 and css 119,751) | 605,853 | 14.0 % |
| `DeferredChrome` (command bar, onboarding, overlays) | 198,253 | 4.6 % |
| Agent conversation chunks | 150,344 | 3.5 % |
| `Settings*` chunks (`SettingsShell` is 100,317 js and 33,634 css) | 148,139 | 3.4 % |
| Total | 4,317,247 | |

The first frame sits 3 bytes under its limit.

### Precedent

The file arrived on 2026-11-07 with a limit of 603,520 (`0272883e`).
Four raises followed, each a one-line commit for the feature that tripped it:

| Date | Commit | Raise | Reason |
|------|--------|------:|--------|
| 2026-11-10 | `73dd74ef` | +320 | meeting card |
| 2026-11-12 | `a6fac581` | +128 | command bar IME guard |
| 2026-11-19 | `06239339` | +640 | custom agent settings page |
| 2026-11-19 | `01ef9915` | +96 | develop was already 93 bytes over |

That is +1,184 bytes (0.2 %) in 12 days, every one forced by a feature, none by a mistake.
The limit has acted as a ratchet that costs a commit per feature, not as a guard against a regression.

### Why the settings page tripped it

The custom agent settings page is already lazy.
`SettingsShell` is a dynamic import in `DeferredChrome.svelte`, and `SettingsCustomAgent`, `SettingsAgentPrompt` and `SettingsAgentRows` are statically imported inside that chunk, so none of their code is in the first frame (`SettingsCustomAgent` appears only in `SettingsShell-*.js`).
Other settings surfaces are lazy too: `SettingsPanel` loads with `SidebarPanels`, `SettingsBrowsingData` has its own import, and every other `Settings*.svelte` is reached only through those.
Lazy-loading more of the page would save nothing.

The 640 bytes came from the 13 new keys the commit added to `en.json` (`1c2feca0`).
English is the source catalog and is imported statically by `translate.ts`, so every English string is in the first frame unless the build strips it.
The build already strips three sections (`native`, `whatsNew`, `agents`; see `stripNativeStringsPlugin` in `vite.config.ts` and `agentsCatalog.ts`).
The `settings` section is not stripped.

| English section in the first frame | Bytes (minified JSON) |
|-----------------------------------|----------------------:|
| `settings` | 25,828 |
| `commandBar` | 6,882 |
| `onboarding` | 4,470 |
| `extensions` | 2,773 |
| `spaceEditor` | 2,744 |
| `permissionPrompt` | 2,313 |
| all of `en` in the first frame | 63,095 |

Measured by building with the section removed from `en.json` (build only, the app would show raw keys):

| Build | `initial` js and css | First frame | Change |
|-------|---------------------:|------------:|-------:|
| Today | 604,663 | 605,853 | |
| Without `settings` | 578,805 | 579,995 | -25,858 (-4.3 %) |
| Without `settings`, `onboarding`, `extensions`, `spaceEditor`, `diagnostics`, `processManager`, `historyPage`, `downloadsPanel`, `screenshot` | 563,995 | 565,185 | -40,668 (-6.7 %) |

Every new setting adds English copy, so the budget trips on every settings feature.
That is a structural reason for the churn above.

Other large first-frame modules, as rendered sizes before minification (so only their ratios mean anything): the Svelte runtime and other `node_modules` 183 KB, `components/sidebar` 239 KB, `components/urlbar` 87 KB, `lib/dndEngine` 37 KB, `stores/commandBarSearch` 30 KB.
Not tried: whether the drag engine or the command bar's search store could load on first use.

## What Lilo already measures

- **Launch marks.** `StartupMetrics` (`Lilo/App/StartupMetrics.swift`) records process-relative marks, among them `windowShown`, `chromeServed:index.js`, `chromeInitialStateReceived`, `chromeVisualReady` (the chrome's first `requestAnimationFrame` after mount, sent over the bridge as `markVisualReady`), `onboardingVisible` and `firstContentPainted`.
- **`make startup-bench`** (`scripts/bench_startup.sh`) builds a Release app and launches it N times (default 10) on a throwaway profile, onboarding pending and then completed, and prints the median and range of each mark.
  `--variant NAME:app=PATH` runs several builds interleaved so machine noise hits each alike.
  CI runs it on pushes to `main` and uploads the result as an artifact; it never fails the run ([CONTRIBUTING.md](../CONTRIBUTING.md)).
- **Reference numbers** ([WEB-CHROME.md](WEB-CHROME.md)), 10 launches with 3 tabs on 2026-11-03: window shown 195 ms (193 to 219), chrome first paint 370 ms (347 to 406), page content 463 ms (439 to 499).
- **Performance recordings** (Help > Diagnostics > Record, `scripts/perf_summary.py`): main-thread intervals, hangs and dropped frames, summarized or compared between two recordings.
- **Build timing** (`make metrics`, [DEVELOPMENT-EXPERIENCE-PLAN.md](DEVELOPMENT-EXPERIENCE-PLAN.md)) with the rule that no timing metric gates CI.

The 640-byte raise is 0.1 % of the first frame.
The chrome's launch-to-first-paint spread alone is 59 ms across 10 launches.
No timer can see a 0.1 % change in parse cost, so the byte count is the only instrument fine enough for the creep and the wrong one for judging whether it matters.

## The options, argued against

**(a) Raw first-frame bytes (today).**
For: deterministic to the byte, costs nothing, runs in `make ui-build`, and tracks the real cost (parse and evaluation scale with source size and nothing else varies).
Against: it is a proxy with no threshold derived from a user-visible effect; at 3 bytes of headroom it forces a commit for 100 bytes of copy; it cannot tell a 600-byte string from a 60 KB accidental static import, so both get the same response (raise the number).
Verdict: right instrument, wrong granularity.

**(b) Lighthouse.**
Against, with evidence:
- The `lighthouse_audit` tool of the chrome-devtools MCP says it covers accessibility, SEO, best practices and agentic browsing, and excludes performance.
  Performance comes from `performance_start_trace`.
- On this machine that MCP could not attach at all: `Could not find DevToolsActivePort for chrome`, because no Chrome runs with remote debugging.
  Lighthouse needs a Chromium it drives itself.
- The only page it could load is the UI on the Vite dev server (`make ui-preview`) or the Playwright fakeHost path, never `lilo-chrome://`, so it would audit 250 unbundled module requests, not the 4 files the app serves, with Chromium's engine, not WebKit's.
- Its performance model is network-shaped (TTFB, transfer size, render-blocking requests, throttling presets), and none of that exists for an embedded scheme.
- Its accessibility audits are useful and already have a better home: the Playwright specs `a11yLabels` and `contrast` in `lilo-ui/e2e`.
Verdict: not worth building for this question.

**(c) Web vitals inside WebKit (`PerformanceObserver`).**
- LCP and INP are defined for navigations of pages users wait on and interact with.
  The chrome is one document that never navigates and paints a mostly static frame; its first content is also its largest, so LCP equals first paint.
  CLS is a layout-stability measure and the house rules already forbid layout jumps; a probe on the fakeHost path (below) read 0.00018 on all 7 runs.
  INP needs real pointer or key input at volume, which a bench launch does not produce.
- `chromeVisualReady` is already the first-paint mark, taken in the chrome and stamped against process start, so an LCP or FCP entry would repeat it with a different clock origin.
- Whether the installed WebKit exposes LCP and Event Timing to `PerformanceObserver` was not verified here; it would be the first thing to check (`PerformanceObserver.supportedEntryTypes` inside the chrome's web view) before any of this was built.
- Cost: new UI code that runs on every launch to report numbers nobody gates on, which conflicts with "nothing at idle".
Verdict: not worth building. One cheap variant is worth knowing about: `event` entries with long durations in a `make startup-bench` run would give an INP-like signal for the first click, if a real problem there is ever suspected.

**(d) A compound metric tracked per commit.**
A noise-aware compound (median of N launches of launch to `chromeVisualReady`, launch to first input, plus bytes) is what `startup-bench` already produces, minus the tracking.
Against making it a gate:
- Timing on a shared Mac is noisy.
  The probe below swung from 316 to 836 ms warm on one page, with other sessions building in parallel.
  [DEVELOPMENT-EXPERIENCE-PLAN.md](DEVELOPMENT-EXPERIENCE-PLAN.md) already decided that no timing metric gates CI.
- A Release build plus 2 x 10 launches takes minutes and a free, unlocked screen (the script exits on a locked one).
- A per-commit series needs a runner that stays the same; the fork's CI runs only for PRs to `main`.
For: it measures the thing the budget stands in for, and `--variant` already gives a paired comparison of two builds, which cancels most drift.
Verdict: worth using as the judge, not as the tripwire.

### Probe: web vitals on the fakeHost path

A throwaway Playwright spec (headless Chromium 1248 from the Playwright cache, not committed) loaded the chrome from `vite dev` with the e2e `initialWorld` and read `paint` and `largest-contentful-paint` entries, 7 runs on a machine busy with other builds:

| Run | 1 (cold compile) | 2 | 3 | 4 | 5 | 6 | 7 |
|-----|-----:|--:|--:|--:|--:|--:|--:|
| FCP = LCP (ms) | 9,116 | 836 | 596 | 552 | 316 | 368 | 328 |

CLS 0.00018 on every run, TTFB 4 to 8 ms, 250 resource requests.
The warm median is 552 ms with a 2.6x spread, from the same bytes.
This is Chromium and an unbundled dev server: it says what the numbers would look like, not what Lilo's launch costs.

## Recommendation

Keep the byte budget and keep it a build failure.
It is cheap, exact and the right unit.
Change what happens around it, in this order:

1. **Take the settings copy out of the first frame** (follow-up below).
   It removes 25.8 KB (4.3 %), turns the next ~40 settings strings into non-events and fixes the cause of most raises.
   After it lands, lower the limit to the new size plus the headroom below, otherwise the freed room guards nothing.
2. **Set the limit with headroom, not to the byte.**
   When the budget is raised or lowered, set it to the measured size rounded up by 2 KB (about 0.3 %).
   The budget exists to catch an accidental static import (10 to 100 KB), not 100 bytes of copy, and a 2 KB step still catches every such mistake.
   This is a number in a comment, not a mechanism.
3. **Make a measured launch time the judge when the budget moves a lot.**
   When a change raises the limit by more than 2 KB, the PR runs `make startup-bench RUNS=10` with the base build and the head build as two `--variant`s and quotes the median `chromeVisualReady` of each.
   A regression blocks the merge when the head median is more than 25 ms slower than the base, about 7 % of the 370 ms mark and under half of the 59 ms spread of ten launches, and a second paired run of 10 confirms it.
   Below that, bytes alone decide, as today.
   The 25 ms figure is a starting point from the one recorded spread; the first few paired runs should replace it with their own.
4. **Do not build** Lighthouse runs, an in-app web-vitals reporter or a per-commit dashboard.

Cost: item 2 is a comment; item 3 is about 4 minutes of an unlocked Mac per large raise, and large raises should be rare once item 1 lands; items 1 and 4 add no code that runs at launch.

What was not measured: the actual launch-time effect of 25 KB less in the first frame (no Release build or bench run was done for this note), the WebKit support for `largest-contentful-paint` and `event` entries, and whether the strings left in the first frame by the open follow-up are used by something the grep did not find (keys built at runtime, such as ``t(`settings.tabPosition.${value}`)``).

## Follow-up: a deferred English `settings` section

Not done here.
It is the same mechanism as the agents' copy, but it is not a few lines: unlike `agents`, the `settings` keys are also read from outside `components/settings/`, so each of those readers has to load the section or lose it.

Files:

- `lilo-ui/vite.config.ts`: in `stripNativeStringsPlugin`, add `settings` to what the `?raw` load returns and delete it from the English catalog in `transform`, as is done for `agents`.
- `lilo-ui/src/lib/i18n/settingsCatalog.ts` (new), modeled on `agentsCatalog.ts`: `catalogs.en = { ...catalogs.en, settings: JSON.parse(deferredCatalog).settings }`.
  Both modules share the one `en.json?raw` string, so the chunk holds it once.
- `import "../../lib/i18n/settingsCatalog"` in the lazy readers: `components/settings/SettingsShell.svelte`, `SettingsPanel.svelte`, `SettingsBrowsingData.svelte` (and any other `settings/*.svelte` that is imported outside `SettingsShell`), plus the lazy readers outside that folder: `onboarding/OnboardingAgents.svelte`, `onboarding/OnboardingYourLilo.svelte`, `urlbar/SiteDrawer.svelte`.
- `urlbar/DefaultBrowserDrawer.svelte` (5 keys) and `urlbar/PermissionRequestDrawer.svelte` (1 key) are in the first frame, so importing the catalog from them would pull it back in.
  Move those 6 keys to the `urlBar` section in all 15 catalogs, or make the drawers lazy.
- `lilo-ui/src/lib/i18n/translate.test.ts` or a new test: the English `settings.items.*` keys resolve after the catalog module is imported and not before, and the parity check still passes (it reads the JSON files, which do not change).
- Then lower `max_first_frame_bytes` in `scripts/embed_chrome_ui.py` by the measured amount plus the headroom.

Check with `make ui-lint ui-test`, then `make ui-build` to read the new first-frame size, and the settings and onboarding e2e specs through the fakeHost path (no screen capture).

The order of the work and the risks: a missed reader shows a raw key such as `settings.items.foo.title` instead of text, so grep every `settings.` key (static and templated) against the files above before and after, and open each affected surface in the preview.
