# Test strategy: assessment and plan

Measured assessment of Lilo's test suite, plus a prioritized plan. Counts and wall times
were measured on this worktree (`develop` at 1febf836) and from CI run data
(`make ci-metrics RUNS=15` on Alexays/Lilo, fetched 2026-11-21). Where a number is a
median of CI it says so; local timings are wall times under `flock /tmp/tsc.lock` on an
M-series Mac shared with other agents.

## 1. Inventory

| Layer | Where | Count | Wall time | Needs |
|-------|-------|-------|-----------|-------|
| UI unit | `lilo-ui/src/**/*.test.ts`, `node --test` via tsx (`make ui-test`) | 95 files, 678 tests | 3.0 s warm local (tsx); `ui-lint` 7.4 s | Node only, no app, no display |
| UI e2e | `lilo-ui/e2e/*.spec.ts`, Playwright headless Chromium + fakeHost (`make e2e`) | 72 specs, 749 tests | 1.8–2.1 min/shard ×3 shards in CI; 3.3 min local | Node + Playwright shell; no app |
| Extension bridge | `Lilo/Extensions/bridge-src/**/*.test.ts`, `node --test` (`make ext-bridge-test`) | 64 files, 587 tests | 0.4 min CI job (median, whole job) | Node only |
| Swift unit | `LiloTests/**/*.swift`, XCTest in the app host (`make swift-test`) | 313 classes, ~3 000 `func test` in 320 files | 5.8 min/shard ×3 shards in CI (build cached); cold build ~10–30 min | macOS, Xcode, a display session, per-worktree app-support dir |
| Swift slow | 7 tests waiting out real clocks (`make swift-test-slow`, `SLOW_TESTS` in Makefile:89) | 7 tests | 1.3 min CI | same |
| Site | `site/tests`, `node --test` + unittest (`make site-test`) | 5 test files + demo specs, 86 tests | ~s inside a 1.5 min CI job | Node, Astro build |
| Site e2e | `site-e2e`, Playwright on the built site | small | not run in build.yml | Playwright |
| Docs site | `docs-site/tests`, `node --test` + `blume audit` (`make docs-test`) | 6 test files | inside the 1.5 min job | Node, Blume build |
| Hooks/tooling | `scripts/*.test.sh`, `*_test.py` (`hooks-test`, `perf-summary-test`, `retried-tests-test`, `metrics-test`, `ci-metrics-test`, `check-summary-test`, `lockf-test`, `tier-test`, `scope-test`, `slot-test`, `bootstrap-test`, `release-test`, `release-media-test`, `agent-eval-test`) | ~14 suites | inside the 1.5 min job | sh/python3 only; runs on Linux |
| Agent eval | `bench/mcp/` — deterministic fixture tasks graded in code, no judge model (`make agent-eval`; `agent-eval-test` tests the grader) | 100 tasks (bench/mcp/tasks.txt) | per-model run cost = agent tokens | Debug app + Claude Code |
| Extension compat | `ext-smoke` top-100 store extensions vs recorded Chrome behavior; `ext-nightly` top-500/1000; `ext-smoke-pr` sentinels; `ext-e2e-passwords` (Bitwarden + local Vaultwarden); `ChromeContractTests`/`chrome-contracts` recorded from Chrome for Testing; `TopManifestTests` | 100s of store extensions | nightly CI job; `ext-bench` idle-CPU budget | network, keychain, built app |
| Perf benches | `blocker-bench`, `blocker-coverage`, `script-bench`, `speedometer-bench` (Speedometer 3.1 in plain/bridged/full web view), `page-bench`, `preload-bench`, `port-bench`, `terminal-bench`, `startup-bench`, `ext-bench`, `e2e-energy`, `energy-sample/compare`, `energy-browsers` | 12 targets | `startup-bench` runs in CI (informational, 1.2 min); `ext-bench` + `e2e-energy` nightly | built app; some need network/sudo |
| `make validate` | the gate: all Linux-capable checks + `project-sync` + Debug build + `swift-test` | — | ~30 s warm locally per AGENTS.md (unverified here); CI equivalent = the whole build.yml makespan: **median 19.1 min, p95 20.3 min** | everything |
| `make check` | in-session tier, tests beside changed files | — | <10 s budget | — |

CI shape (build.yml): ubuntu jobs (release-tooling ~1.5 min, UI ~0.7 min, e2e ×3 ~2.1 min,
bridge ~0.4 min) plus 3 macOS shards (~8.2 / ~9.2 / ~12.1 min each incl. `swift-test-slow`)
and a Release build job (median 2.1 min cached, p95 18.6 min). **macOS slot-minutes per run:
median 47.7.** Failed Swift tests and Playwright tests retry once in CI; `retried_tests.py`
writes the retried list to the job summary and `failing-tests-*` artifacts.

Requirements recap: `swift-test*` and everything under `test-build` need macOS + Xcode + a
window server session; e2e needs only a browser; `ext-*` need network and the keychain;
`agent-eval` needs a model; `energy-browsers` needs sudo (powermetrics) and ~5 h.

### Flaky / retried tests

CI retries once and reports the retried set; local runs fail on the first flake by design
(CONTRIBUTING.md). Known flaky set, from maintainer notes and observation:

- `AgentCaptureTests.testToolsAreListed` (LiloTests/Agent/AgentCaptureTests.swift:342)
- `IdleBridgeHandlerTests` (LiloTests/Extensions/IdleBridgeHandlerTests.swift)
- cooperative-freeze media tests (`LiloTests/Engine/EngineFreezerTests.swift`,
  `PiPControllerTests` — real media pipelines through WebKit)
- port worker tests (`LiloTests/Extensions/LocalPortTests.swift`,
  `ProfileExtensionRegistryTests` — worker idle/schedule timing)
- `largeSidebar.spec.ts` wall-clock guard: `longestTask < 1000 ms`
  (lilo-ui/e2e/largeSidebar.spec.ts:155) — failed once on a loaded Debian box at
  1381 ms (docs/LINUX-AGENTS.md measurements). A perf assertion inside a functional
  suite: it flakes under load and its budget is not adjustable.
- Local `make e2e` on a loaded Mac: 749 passed, 4 failed (agentPicker row height,
  dnd favorites-grid columns, pinnedDivider command-bar scope, sidebarTree arrow
  keys) — timing-sensitive specs on a contended machine; see the flaky ledger
  proposal below for why this set should be measured, not guessed.
- 104 `Task.sleep`/`Thread.sleep` call sites across 42 Swift test files (heaviest:
  RealExtensionSmokeTests 10, ProfileExtensionRegistryTests 6, TerminalSessionTests 4).

### Duplication / low-value scan

- The same 3-line hide-a-window incantation (`alphaValue = 0`, `orderFrontRegardless`,
  `setFrame(x: -20000, y: -20000, …)`) was repeated in 13 setUp blocks; now
  `NSWindow.orderFrontOffscreen` in LiloTests/Support/HiddenWindow.swift (this change).
- `BrowserStateStoreTests.swift` is 4 466 lines/155 tests — high value surface (state
  store is the app's core), but the per-test setup is copy-heavy; a shared fixture would
  shrink it.
- No measured low-value suites: every layer maps to a distinct risk. The cheapest signal
  loss today is the wall-clock e2e guard above, which costs retries without isolating
  regressions — a dedicated perf spec or budget mechanism would carry it better.

## 2. Screen audit: tests that show a window

The test host already runs with `setActivationPolicy(.prohibited)`
(Lilo/App/AppDelegate.swift:72) and `TestRunCleanup` keeps every test window out of
Mission Control via `.transient`/`.ignoresCycle` collection behavior
(LiloTests/Support/TestRunCleanup.swift:31). But `.prohibited` does not stop a window
from *drawing*: any `orderFront`/`makeKeyAndOrderFront` still renders on the user's
display during a local `make swift-test`.

Sites found ordering a window on screen (before this change):

| File | Call | Was hidden? |
|------|------|-------------|
| LiloTests/Engine/EngineFreezerTests.swift:43 | `orderFront(nil)` on a titled 400×300 window at 0,0 | no |
| LiloTests/Engine/PiPControllerTests.swift:62,204 | `orderFront(nil)`, same | no |
| LiloTests/Engine/WKWebViewTabPrintTests.swift:38 | `orderFront(nil)`, 600×400 | no |
| LiloTests/Engine/WKWebViewTabTeardownTests.swift:188 | `makeKeyAndOrderFront(nil)` | no |
| LiloTests/Engine/WKWebViewTabWindowFrameTests.swift:20 | `orderFront(nil)`, 1200×800 | no |
| LiloTests/LittleWindow/LittleWindowTests.swift:249 | `makeKeyAndOrderFront(nil)` | no |
| LiloTests/Extensions/ExtensionPageTabTests.swift:476,622 | `window.window?.orderFront(nil)` | no |
| LiloTests/Extensions/ProfileExtensionRegistryTests.swift:560 | `orderFrontRegardless()` | no |
| LiloTests/Extensions/PasswordManagerE2ETests.swift:81 | `orderFront(nil)` — e2e, skipped in `swift-test` | no (excluded) |
| LiloTests/Extensions/RealExtensionSmokeTests.swift (5 sites) | `orderFront*` — skipped in `swift-test`, takes all test slots | no (excluded) |
| LiloTests/Support/TestRunCleanupTests.swift:11 | `orderFront(nil)` | deliberately visible: tests the cleanup |
| LiloTests/Support/ReleaseMediaCapture.swift:82-86 | `makeKeyAndOrderFront` + `NSApp.activate` | deliberately visible: release media capture needs real pixels |
| 4 benchmark classes (Speedometer, PageLoad, InjectedScripts, TopHitPreload) | `orderFrontRegardless()` | env-gated (`XCTSkip` unless `make *-bench`); left alone: alpha=0 could change WebKit's rendering throttle and skew the numbers they exist to measure |

Already hidden (the convention this codifies): AgentToolTestCase, AgentApprovalTests,
AgentInputTests, MenuIconTests, WKWebViewTabDialogTests, CaptureBridgeHandlerTests,
DebuggerGapAPITests, PageCaptureGapAPITests, ChromeGlobalEventRoutingTests ×2,
PagePopupTests, PageSnapshotServiceRegionSelectionTests, WKWebViewTabNavigationPolicyTests,
GestureForwardingPanelTests — `alphaValue = 0` + `orderFrontRegardless` + frame at
(−20 000, −20 000). The panel test is the exception: it stays in place because its
synthesized scroll event is addressed by screen coordinates.

Options considered:

1. **Per-test hidden ordering** (adopted): `orderFrontOffscreen` = alpha 0 + order in +
   origin (−20 000, −20 000). `isVisible` stays true, so WebKit occlusion, popovers,
   `window.outerWidth` and event routing keep working. Verified below.
2. Global offscreen move in `TestRunCleanup`'s `NSApplication.didUpdateNotification`
   observer: catches future sites for free, but silently relocates every window —
   breaks tests that assert on `window.screen` (an offscreen window's `screen` can be
   nil) and hides regressions in the very behavior being tested. Rejected.
3. `LILO_HEADLESS=1` for the test host (`TEST_RUNNER_LILO_HEADLESS`): exists for
   `make agent-app` (Lilo/App/LiloApplication.swift). It makes MainWindowController's
   windows transparent/clickless but does not move them offscreen, and it makes
   `canBecomeKey`/`canBecomeMain` false — which would break tests exercising key-window
   paths (ChromeGlobalEventRoutingTests calls `makeKey` on purpose). Rejected as a
   blanket setting; the per-window helper is more precise.
4. Separate session/VM: works (CI effectively does this — nobody watches the runner's
   display) but solves nothing for the local `make swift-test` the complaint is about.
5. `WKWebView.takeSnapshot` / in-process rendering: already used where pixels matter
   (screenshot tests); not a windowing fix.

Verification (`make swift-test` on the touched classes, this worktree): every
converted site passed — including the riskier ones: PiPControllerTests (real
media through WebKit offscreen), ExtensionPageTabTests (the "a popover shows
only from a window on screen" comment — ordering in offscreen satisfies it),
WKWebViewTabWindowFrameTests (`outerWidth` unaffected), LittleWindowTests
(`makeKey` on an offscreen window), WKWebViewTabPrintTests, EngineFreezerTests,
WKWebViewTabTeardownTests, WKWebViewTabDialogTests, MenuIconTests,
TestRunCleanupTests. **One site reverted**: GestureForwardingPanelTests feeds a
synthesized scroll CGEvent at global coordinates, which only lands on the panel
at its real frame — it keeps `alphaValue = 0` + `orderFrontRegardless` in place
(invisible, un-moved).

## 3. Debian offload

Today (docs/LINUX-AGENTS.md, measured on Debian 13): `make linux-checks` covers
ui-lint, ui-test, ext-bridge-test, site-check/test, docs-check/test, hooks-test, the
~10 python/sh tooling suites, release-status and swiftlint (static build; two
SourceKit rules skipped). `e2e`, `site-e2e`, `release-test`, `bridge-gen`, `ui-build`,
`vt-build` also pass on Linux but are excluded for weight/network. Everything under
`test-build` needs xcodebuild → macOS. `Package.swift` exists (executable + testTarget)
but `swift test` is macOS-only today because the `Lilo` target's sources import AppKit.

What could move to Linux, ranked by effort:

- **A `LiloCore` SwiftPM library of AppKit-free sources.** 132 of the 320 test files
  import neither AppKit, WebKit nor SwiftUI and hold **~1 019 `func test` (~34%)**
  — Localization (12 files), Tabs value types (SplitLayout, SidebarNodeIndex,
  SpaceTabState, KeepLoaded, lifecycle policy), Bridge handlers (TabBridgeHandler,
  SearchBridgeHandler, StateSyncBridgeHandler, BridgeEventCoalescer), Power policy,
  Changes/GitDiff, Terminal session/theme pieces, FaviconService, parts of
  Storage/Import. Effort: medium-large — the sources under test must be moved or
  made AppKit-free too (the tests are `@testable import Lilo`; a library target makes
  them `import LiloCore` with internal APIs becoming public). XCTest works on Linux
  via corelibs-xctest; GRDB has a Linux build. The payoff is a real signal for a
  third of the suite in a Linux container or the ubuntu CI jobs — the single largest
  offload available. First slice suggestion: the pure value-type tests under
  `LiloTests/Tabs` + `LiloTests/App/*LocalizationTests`, which need no dependency
  injection; ~160 tests in 12 AppKit-free Tabs files plus ~50 localization tests
  (~210 as the first slice).
- **Playwright WebKit project for e2e.** `make ui-capture` already runs under both
  `webkit` and `chromium` shells on Debian; e2e runs Chromium only
  (lilo-ui/playwright.config.ts projects). Adding a `webkit` project exercises the
  engine Lilo actually ships — cheap in config, costs ~2× e2e runtime; run it
  nightly or on a label rather than per-PR.
- **Remote macOS capacity.** GitHub-hosted `xcode-27` runners are the current path
  (5 concurrent macOS jobs on the free plan; 47.7 macOS-min per push). Self-hosted
  Tart/Anka VMs or a Mac mini runner would cut queue time and give warmer caches but
  add a machine to maintain — only worth it once PR volume makes queueing the
  bottleneck; today queue-before-start median is 2 s.
- **Containerized runs** (Debian container for `linux-checks`): trivial — it is
  exactly what the ubuntu jobs are. A `linux-checks` container image definition
  would help local Debian dev parity; low value since `make linux-checks` is
  already self-contained.

What cannot move: everything under `test-build` (xcodebuild, WebKit on macOS,
runningboardd), ext-smoke/ext-e2e (the built app), terminal rendering
(libghostty-vt + Metal), benchmarks, agent-eval, energy tooling, Sparkle/DMG
release steps.

## 4. How comparable projects test

| Project | Approach | Source |
|---------|----------|--------|
| Zen Browser (Firefox fork) | PR CI is lint + bootstrap + build only (`npm run lint`, `npm run bootstrap`); behavioral testing is inherited from Firefox's infrastructure, not re-done | zen-browser/desktop `.github/workflows/pr-test.yml` |
| Floorp | Same shape: patch-on-Firefox fork, build CI, upstream test suite | Floorp-Projects/Floorp |
| Firefox | mochitest (in-chrome harness), Marionette (WebDriver-ish), web-platform-tests imported and run per-push on mozilla-central; tiered `mach test`/`mach try` chooser; pernosco/rr record-and-replay for intermittents | mozilla-central `testing/mochitest`, `testing/marionette`, `testing/web-platform`, `tools/tryselect` |
| Chromium | `browser_tests`/`content_shell`/`unit_tests` per component, Telemetry perf harness, clusterfuzz continuous fuzzing, web_tests (= WPT + local) with baselines per platform | chromium `testing/`, `tools/telemetry`, `third_party/blink/web_tests` |
| WebKit | Layout tests (`run-webkit-tests`, tens of thousands, expected-result baselines), `TestWebKitAPI` gtest C++ API tests, `run-javascriptcore-tests` incl. test262, `webkitpy` harness; EWS bots per platform | WebKit `Tools/Scripts`, `Tools/TestWebKitAPI`, `LayoutTests/` |
| Ladybird | `Tests/LibWeb` Layout/Ref/Screenshot/Text tests + Crash tests; WPT imported under `Tests/LibWeb/Ref/wpt`; libjs-test262 workflow diffs per-file results against recorded baselines (`per_file_result_diff.py`); `macos-accessibility-tests.yml` for the platform a11y bridge | LadybirdBrowser/ladybird `.github/workflows/libjs-test262.yml`, `Tests/LibWeb/` |
| Servo | WPT as the primary suite + `mach test-wpt`; unit tests per crate; speedometer runs on CI | servo/servo `.github/workflows/main.yml`, `tests/wpt` |
| Ghostty | `zig build test` + `test-lib-vt`, lib-vt ABI/schema conformance jobs, fuzz target (`test-fuzz-libghostty`), `test-debian-13`, valgrind, simd matrix — all on self-hosted Namespace runners incl. macOS; the SwiftUI app layer is covered by build+lint, not a GUI test suite | ghostty-org/ghostty `.github/workflows/test.yml` (jobs: test, test-macos, test-lib-vt, test-fuzz-libghostty, test-debian-13, valgrind) |
| WezTerm | Rust unit tests in crates + `cargo test` in CI; minimal GUI automation | wezterm/wezterm `.github/workflows` |
| Zed | `run_tests.yml` path-gated jobs on Namespace runners: cargo nextest/clippy/fmt, licenses, typos, collab tests; sccache for Rust caching; gpui components tested headlessly in-crate | zed-industries/zed `.github/workflows/run_tests.yml` |
| Ice Cubes (SwiftUI app) | `IceCubesTests` XCTest for model/network layers; the app UI is not instrumented | Dimillian/Ice-Cubes |
| BrowserOS | `bos-build-tests.yml` = Python unittests of the build tooling + ruff + CLI smoke; the agent (neo) has a Playwright *conformance* suite run in docker-compose (`neo-playwright-conformance.yml`, opt-in until green) — agent behavior is tested as API conformance, not LLM-in-the-loop | browseros-ai/BrowserOS `.github/workflows/` |
| Agentic browsing evals | WebArena / WorkArena / OSWorld / WebVoyager-style benchmarks: live site clones or sandboxes, LLM agent drives a browser, success graded by URL/state predicates. browser-use runs its own eval matrix per model. Common pattern: fixture server + code grading = exactly what `bench/mcp/` already implements | web-arena-x/webarena, ServiceNow/WorkArena, xlang-ai/OSWorld, browser-use/browser-use `eval/` |
| Playwright MCP | Driver conformance tests in repo (`tests/`); LLM evals left to consumers | microsoft/playwright-mcp |

Takeaways for Lilo: (1) browsers that fork an engine do *not* re-test the engine —
they test their own chrome and compat surface (Zen, Floorp); Lilo matches this with
ext-smoke + ChromeContractTests. (2) Engine owners test engines (WebKit layout tests,
Ladybird WPT) — out of scope for a WKWebView consumer except the small injected-surface
risk `PageWorldTests` already guards. (3) Terminal/graphics apps test the headless
core exhaustively (ghostty lib-vt) and the GUI shell thinly — matches Lilo's split
between XCTest logic and no GUI automation. (4) Agent behavior is best graded in
code against fixture servers (bench/mcp model, BrowserOS conformance) — already
adopted; the gap is running it in CI/nightly rather than by hand.

## 5. Benchmarks and compat suites to adopt

| Suite | Value | Cost | Where | First step |
|-------|-------|------|-------|------------|
| Speedometer 3.1 | Already adopted (`speedometer-bench`) in plain/bridged/full injection | done | local/nightly | — |
| JetStream | Overlaps Speedometer for JS perf; Lilo doesn't ship a JS engine | low value | — | skip |
| MotionMark | Rendering benchmark; Lilo renders via WebKit, which it does not own | low value | — | skip |
| **web-platform-tests subsets** | The real gap: WPT subsets for the areas Lilo's bridges touch — `webdriver` no, but `content-security-policy`, `navigation-api`, `service-workers` only matter to WebKit. **Worth it only for the PageWorld/injection surface** (prototype patches, message passing): a small subset run inside a Lilo tab would catch WebKit-vs-injection drift | medium: needs a wpt runner wrapper driving the app | macOS CI/nightly | pick 2–3 directories under `wpt/` matching injected APIs, run through `agent-call` |
| test262 | JS engine conformance — WebKit owns it | none | — | skip |
| Acid/CSS | Superseded by WPT; covered by WebKit | none | — | skip |
| **WebExtension compat** | Already the deepest: top-100/500/1000 store smoke vs recorded Chrome behavior, `ChromeContractTests`, `TopManifestTests`, `ChromeSurfaceTests` | done; the marginal step is an MV3 **conformance** corpus: a fixture extension exercising every `chrome.*` surface with recorded-Chrome expected outputs — `test-extensions/extension-contracts` + `chrome-contracts` is already exactly this | done | keep `chrome-contracts` recordings fresh (re-record on WebKit upgrades) |
| **Terminal conformance** (vttest/esctest) | The terminal tab is libghostty-vt, tested upstream (ghostty `test-lib-vt`); Lilo-side risk is the *glue* — resize, scrollback, colors. A small esctest/vttest pass through a terminal tab would catch glue bugs | medium: needs driving a real terminal tab with the VT harness | macOS nightly | wrap `vttest`/`esctest` runs via `agent-call` or a test-only entry point |
| **Accessibility audits** | Ladybird runs `macos-accessibility-tests.yml`; Lilo has `a11yLabels.spec.ts` + `liveRegions.spec.ts` e2e coverage of chrome only — the AppKit side has none | medium: AX calls against a debug build via agent tools or a small XCTest using `AXUIElement` | macOS CI | an XCTest asserting AX names/roles on sidebar, toolbar, settings — cheap because AppKit AX is queryable in-process |
| Chrome Web Store top extensions | Adopted: `ext-nightly` top-1000 | done | nightly | — |
| PerfDog-style energy tests | `energy-sample`/`e2e-energy`/`energy-browsers` exist; `e2e-energy` fails on idle git/worker/snapshot work | done locally; could gate nightly | nightly macOS | run `e2e-energy` in extensions-nightly workflow |

## 6. Strategies and levels

| Strategy | Exists today | Would pay off | Avoid/notes |
|----------|--------------|---------------|-------------|
| Table-driven | widespread (`func test` + loops; localization tests are per-language files) | — | — |
| Property-based | none | fast-check for `lilo-ui` parsers (`fuzzySearch`, commandBar ranking, dnd engine, bridge message decoding); SwiftCheck or swift-testing parameterization for `SplitLayout`, sidebar index, URL normalization | keep to pure functions; property tests of AppKit objects flake |
| **Fuzzing** | none | highest value on **decoding boundaries**: bridge message decode (bridge-schema types), omnibox/URL parsing, PSL rules (`public-suffix-list.dat` consumers), filter-list converter, import parsers (bookmarks/passwords HTML+CSV), extension manifest parsing — all parse hostile external data | use structure-aware seeds not raw bytes; a libFuzzer-style loop in Swift (swift-fuzzer/SwiftCheck generators) or fast-check for the TS sides |
| Snapshot/golden | e2e traces + `ui-capture` scenarios; generated-file sync tests (codegen.test.ts) | cheap: golden the bridge protocol against the schema already done; extend `ui-capture` scenarios rather than adding a snapshot framework | pixel snapshots of AppKit = platform/font fragile, skip |
| Mutation testing | none | Stryker on `lilo-ui` hot paths (fuzzySearch, ranking, stores) would grade assertion quality | cost: minutes-to-tens-of-minutes — nightly, never per-PR; cap to 2–3 modules first |
| Contract tests | generated-file sync (codegen.test.ts), `PrivateDelegateSelectorTests`, `PageWorldTests`, `ChromeSurfaceTests`, `ChromeContractTests` | the Swift/TS bridge: a schema-driven contract test that feeds invalid/unexpected messages to both sides (already have the schema in bridge-schema/tab.json — property-based generation from it) | — |
| Differential | ext-smoke vs recorded Chrome behavior | the strongest differential pattern in the suite; re-recording cadence is the risk | — |
| Spec-driven | `chrome.*` surface tests vs chrome-types | WebExtension API coverage is the spec target; continue | — |
| LLM rubrics | `agent-eval` fixtures graded in code, no judge | add tasks for new agent tools as they land; consider a small judge-graded suite for open-ended tasks only if code grading can't express success | judge models are flaky + costly; keep the no-judge invariant |
| Test impact analysis | `make check`/`check-staged` runs tests beside changed files; `validate-scope` picks check groups by diff | extend to e2e: map spec files to touched lilo-ui areas (cheap heuristic); a full per-test coverage map (vitest/istanbul) is heavy for 5.8-min savings | — |

## 7. Speed and shape

Current state (measured): `make check` <10 s tier → pre-commit <15 s → pre-push
`validate-scope` under tsc.lock → CI build.yml makespan median 19.1 min with 47.7
macOS slot-min. `swift-test` shards ×3 at ~5.8 min/shard with a warmed derived-data
cache; `parallel-testing-enabled YES` with one worker per performance core; test-slot
locks (`scripts/test_slot.sh`) cap concurrent runs; `TEST_SLOTS=2` exists for
big Macs. e2e shards ×3 at ~2 min each, `fullyParallel`, CI workers=100%.

Where the time goes and what to do:

- **swift-test is the long pole** (5.8 min/shard after a cached build; ~60% of app-job
  time). Options, ranked: (a) shard 4–5 ways on macOS (job wall time falls; slot-minutes
  don't — it's the same CPU sum), (b) `SWIFT_TEST_FILTER` impact analysis — skip classes
  untouched by the diff (risky for AppKit coupling; a conservative mapping like
  validate-scope's is feasible: UI-only diffs already skip the whole app job via
  `changes.outputs.code`), (c) split the suite into logic-only vs WebContent-heavy
  classes and run WebContent-heavy ones on fewer parallel workers — they bottleneck on
  WebKit processes, not CPU, (d) keep 3 shards. Recommendation: (a) is free wall-clock
  if the 5-job cap allows; (c) is the real fix for slot-minutes.
- **Release build p95 18.6 min** vs median 2.1 — cache misses dominate; the
  derived-data + xcc CAS caches in build.yml already address this; the gap is the
  restore-keys granularity.
- **e2e ~6 min total** (3×~2) is fine; the flake lever is the wall-clock
  `longestTask` guard, not speed.
- **No test impact analysis beyond file-adjacent unit tests.** A conservative
  mapping (spec → area) could skip ~half the e2e on focused diffs; medium effort,
  real PR-loop savings — but CI e2e is already only ~2 min/shard, so the payoff is
  small. Skip.
- **Cache:** pnpm store + Playwright + SPM + derived-data + xcc CAS all cached in
  build.yml. Nothing more to add; cold e2e cost is browser install (~30 s).
- **Merge/remove tests:** no duplicates found worth deleting; the cost is parallel
  workers and CI minutes, not test count.

Before/after estimates: adopting 4 macOS shards cuts the makespan ~2–3 min where the
queue allows; a WebContent-light split could cut slot-minutes 15–25%; neither is free
(flakes follow timing). `make validate` warm stays ~30 s; nothing proposed here slows
the local loop.

## 8. Adversarial passes

### (a) The maintainer who pays the CPU and attention cost

47.7 macOS slot-minutes per push is the bill. On the free plan's 5 concurrent macOS
jobs, a burst of PRs serializes; self-hosted runners trade money for maintenance.
The suite has no dead weight to cut — the biggest single cost is the Release archive
(8.6 min) which is a build, not a test. The honest lever is macOS-independent checks
(section 3) and not widening the macOS matrix casually. Also: every new env-gated
bench adds a secret path CI doesn't run — benches that never run in CI rot
(`ext-nightly` is the good counterexample: it runs and fails loudly).

### (b) The flake hunter

CI's single-retry policy reports retried passes — the instrumentation already exists
(`scripts/retried_tests.py`, `failing-tests-*` artifacts, `ci-metrics`). Gaps: there is
no flake *ledger* — retried-test data lives in per-run summaries, not a dashboard;
a nightly `retried_tests.py --failing` rollup across runs would name the top offenders
with data instead of the anecdotal known-flaky list. The wall-clock e2e guard
(`longestTask < 1000 ms`) is a flake machine by construction. 104 explicit sleeps in
Swift tests are the main flake surface; `pollUntil` is the established antidote.

### (c) The security and privacy reviewer

Strengths: `TemporaryBrowserContext` + `TestProfileIds` isolate data; `TestRunCleanup`
removes per-host WebKit stores, prefs, temp dirs, and kills orphaned WebKit processes;
private-mode isolation has its own tests; no real user data in fixtures (checked —
fixtures use example.com hosts). Gaps: extension smoke tests install real third-party
extensions from the store — sandboxed by the test host's own keychain/permissions, but
a supply-chain incident in a top-100 extension executes in the test host (mitigate:
nightly-only, no user keychain — already true). Fuzz targets (recommended above)
*are* the security program for the parsing boundaries.

### (d) A new contributor on Debian or a cheap Mac

`make linux-checks` is genuinely good — lint, all JS tests, docs, hooks, release
checks run on a stock Debian box (plus `unzip`). The wall: zero Swift signal. The
`LiloCore` library slice (section 3) is the fix; until then, a Debian contributor
editing `Lilo/` flies blind on 100% of the app layer. On a cheap Mac, `swift-test`
takes the test slot and floods the machine (TEST_SLOTS=1 default, WebContent
processes saturate cores) — documented, but the first-time experience is a
30-minute cold build nobody warns about before `make validate`.

### (e) The release manager who must trust green

Green today means: every layer ran once, retried passes are listed in the summary,
`swift-test-slow` runs on shard 3, ext-smoke sentinels run on extension-touching PRs
(`extensions-pr.yml`), `ext-nightly` watches the top-1000. What green does *not*
cover: e2e on WebKit (chromium only), the app UI itself (no AppKit-level UI test —
no AX-driven test of the real window), release-path tests beyond `release-test`
script tests, and the WebKit fork drift (`webkit-fork` is optional; CI builds against
system WebKit). A nightly job running `make e2e` under Playwright WebKit + one AX
smoke test would close the two that matter.

### (f) An agent author who needs a fast tight loop

`make check` <10 s, `make check-staged` pre-commit, `check BASE=origin/develop`
works in a worktree, `LILO_CHECK_TRIGGER=agent` is already a first-class concept,
metrics record per-tier timings. The real friction: an agent that touches Swift has
no sub-minute signal — `swift-test` needs the full app build. A
`make swift-test-filter` fast path exists (`SWIFT_TEST_FILTER`) but requires knowing
class names; a `make swift-test-changed` that maps changed source files to mirror
test classes (the `X.swift → XTests.swift` convention makes this mechanical) would
be the cheap win. Estimated: a changed `SplitLayout.swift` → `SplitLayoutTests` run
in seconds instead of a 5.8-min shard.

## 9. Ranked list

### Do now (cheap, high value)

1. **Shared offscreen-window helper** — `LiloTests/Support/HiddenWindow.swift`,
   applied to 22 sites (this change). Effort: done. Payoff: local `swift-test` stops
   painting windows on the user's display; one convention instead of 13 copies.
2. **Flake ledger** — a `make flake-report` that aggregates `retried_tests.py`
   output over N recent CI runs into a ranked table; run it in a weekly job or
   alongside `ci-metrics`. Effort: small (the parser exists). Payoff: the flaky set
   becomes a measured queue, not folklore.
3. **`make swift-test-changed`** — map changed `Lilo/**/*.swift` to `LiloTests/**/XTests.swift`
   classes and run just those after `test-build`. Effort: small (naming convention is
   already strict). Payoff: a sub-minute Swift signal for most diffs; the missing
   tight loop for agent authors.
4. **Move the e2e `longestTask` wall-clock guard** into a dedicated perf spec
   (own file, retried or nightly) so `largeSidebar.spec.ts` stops flaking functional
   runs. Effort: trivial. Payoff: removes the known-flake in the e2e suite.
5. **Playwright WebKit e2e job (nightly).** `ui-capture` proves the shell runs on
   Debian; `pnpm playwright install webkit` + `--project=webkit` is a small config
   change. Effort: small. Payoff: e2e runs on the engine Lilo ships; catches
   Chromium-only green.

### Do next (real work, real payoff)

6. **`LiloCore` SwiftPM slice for Linux** — move the ~130 AppKit-free test files'
   subjects into a library target, starting with `LiloTests/Tabs` value types +
   `*LocalizationTests` (~200–300 tests as the first slice). Effort: medium-large.
   Payoff: a third of the Swift suite on Debian/CI-ubuntu; the single biggest
   offload.
7. **Fuzz the parsing boundaries** — fast-check (or a small generator harness) on
   bridge message decode, URL/omnibox parsing, PSL, filter-list converter, import
   parsers, manifest parsing. Effort: medium. Payoff: security-review-grade
   coverage of every hostile-input boundary.
8. **AppKit accessibility smoke test** — XCTest asserting AX labels/roles/keyboard
   order on the main window and settings (in-process `AXUIElement` or unit-level
   `accessibilityLabel` checks). Effort: medium. Payoff: the release-manager gap —
   the native chrome is the only untested UI layer.
9. **Nightly `e2e-energy`/`ext-bench` gating** — they exist and are already run in
   the nightly workflow partially; make regressions open an issue automatically.
   Effort: small-medium. Payoff: perf regressions caught in days not releases.
10. **WebContent-heavy test split** — tag or shard tests that spawn WebContent
    processes separately from pure-logic tests; run the heavy set with fewer
    parallel workers. Effort: medium (needs a class list audit). Payoff: lower
    peak load, fewer timing flakes, better slot utilization.

### Do not do (cost > value, or anti-goal)

- **WPT/layout-test adoption at scale** — Lilo does not own the engine; WebKit's own
  suite covers it. Keep only a narrow PageWorld/injection subset if ever needed.
- **test262, JetStream, MotionMark** — engine benchmarks for an engine Lilo doesn't ship.
- **Pixel snapshot testing of AppKit chrome** — font/display fragile; `ui-capture`
  scenarios already cover the review-media need.
- **A judge-model grading suite** — the bench/mcp no-judge invariant is a feature;
  a judge would buy flakiness.
- **SwiftCheck-style property tests of AppKit/WebKit objects** — nondeterministic
  fixtures of a nondeterministic substrate.
- **Self-hosted macOS runners today** — queue median is 2 s; the cost is real,
  the benefit isn't yet.
- **Removing the CI retry** — it is the flake-ledger data source; keep it, but
  never let `make validate` retry locally (already true).
