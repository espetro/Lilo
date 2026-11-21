# Swift tests that disturb the Mac they run on

The complaint: while agents run `make swift-test` or `make validate` on the owner's own laptop, in the owner's own login session, windows appear, input is disturbed and the Mac is sluggish. This document says what was measured, what blocks, what was fixed and what the alternatives would cost. [test-strategy.md](test-strategy.md) section 2 holds the earlier window audit.

Everything below was measured on one machine: MacBook Air (M4: 4 performance + 6 efficiency cores, 24 GB), macOS 27.2, a 2560x1664 display, `make swift-test` with the default 4 workers, other agents building and testing on the same Mac at the same time (system load average 10 to 70). Numbers move by 20 to 30 % between identical runs for that reason: read orders of magnitude, not decimals.

## How it is measured

`make test-disturbance` (sources: `scripts/disturbance_sampler.swift`, built with `swiftc`, no grants) wraps `xcodebuild` inside the test slot lock and samples every 200 ms:

| Signal | How | Needs |
|--------|-----|-------|
| Focus taken | `NSWorkspace` activation notifications of a `.tests` host, plus the frontmost app per sample | nothing |
| Dock icons | `didLaunchApplication` of a host with `.regular` policy | nothing |
| Windows shown | `CGWindowListCopyWindowInfo` owner, bounds, alpha, on-screen flag (never titles) of host windows: visible = alpha above 0 and on a display | nothing |
| Transparent windows on screen | the same list, alpha 0 | nothing |
| Do they take clicks | `NSWindow.windowNumber(at:)` at each transparent window's centre | nothing |
| Cursor | `CGEvent(source: nil).location` jumps above 40 px | nothing |
| Synthetic HID input | idle time of the HID system state vs the combined session state: events posted at the HID tap count only in the session | nothing |
| CPU | `host_processor_info` busy share; hosts and their responsible WebKit processes via `proc_pid_rusage` | nothing |
| Sluggishness | how late a 200 ms timer fires, and how long a fixed 0.5 ms spin takes, on the sampler's own thread (a runnable interactive thread waiting for a core) | nothing |

`scripts/disturbance_by_class.py` joins the samples with a serial run's `Test Suite ... started at` lines (`TEST_PARALLEL=NO`) and prints one row per test class.

## What blocks, ranked by how much it disturbs

Baseline: the 41 test classes that create windows (743 tests), commit `0afba4e2`, before any change here.

1. **Test windows with pixels.** 36 distinct host windows were on screen at some sample of a serial pass, 25.6 s of its 203 s; in the parallel pass 26.8 s of 103 s. The worst, from the per-class table: `PiPControllerTests` (the PiP panel stays up 17.6 s), `PagePopupTests` (16 popup windows, 2.8 s), `LittleWindowTests` (7), `MenuIconTests`, `WKWebViewTabDialogTests`, `WKWebViewTabNavigationPolicyTests`. And one nobody had found: `HoldToQuitTests` shows the real "Hold Cmd Q to Quit" HUD (216 x 59) in the middle of the main display, because its key events have no window. The earlier audit only looked for explicit `orderFront` calls in tests: these windows are shown by the code under test. Sampled in the wild during another agent's full run: three of those HUD windows for 10 s of 90. 2. **CPU saturation by the parallel workers.** 4 workers plus about 40 WebContent processes put the system above 90 % busy for 25 to 39 s of a 100 s parallel pass (p95 98 to 100 %), and the sampler's own interactive thread, which needs 0.6 ms to do its work, needed 20.6 ms at p95 and 87 ms at worst; timers fired 32 ms late at p95. That is the sluggishness. A serial pass of the same classes: p95 1.9 ms. 3. **About 150 transparent windows left on screen** (`alphaValue = 0` at the default frame: 100 of them 1000 x 700 at the top left). The window server does not give them clicks (0 of them topmost at their centre in every run), so they do not steal input; they cost window-server work and Mission Control state, which `TestRunCleanup` already limits. 4. **Nothing else.** In every run: 0 focus activations of a test host, 0 Dock icons, 0 synthetic HID events. The host runs `.prohibited` (AppDelegate), and a grep finds no `CGEvent.post`, `cghidEventTap`, `CGWarpMouseCursorPosition` or `NSApp.activate` in `LiloTests` (the `CGEvent`s tests build are delivered with `sendEvent`, never posted). The cursor jumps the sampler counts (15 to 175 per run) are the owner's own mouse, confirmed by the synthetic detector staying at 0. 5. **`taskpolicy -b make swift-test` would not have helped.** The test hosts and their WebContent processes are children of launchd (`ps -o ppid` is 1), not of xcodebuild: a priority set on the make command never reaches them.

## What changed

| Change | Where | Why |
|--------|-------|-----|
| Hold-to-quit tests use an offscreen window; they wait for the quit instead of a fixed 100 ms | `LiloTests/App/HoldToQuitTests.swift` | the HUD; the fixed wait failed under saturation |
| Quiet host: every turn of the main run loop, before Core Animation commits, visible windows get alpha 0 and `ignoresMouseEvents`, and animations are turned off | `TestRunCleanup`, env `LILO_TEST_QUIET=1` | catches windows the code under test shows by itself, which no per-test helper can; a timer or dispatch turn posts no `didUpdate` |
| Demoted host (opt-in, `TEST_NICE=1`): the host and every process it is responsible for go to `PRIO_DARWIN_BG` (efficiency cores only), re-applied every 2 s for new WebKit processes | `TestRunCleanup`, env `LILO_TEST_DEMOTE=1` | CPU saturation, at a price: see below |
| `TEST_QUIET` (default 1 off CI) turns the quiet host on for `swift-test` and `swift-test-slow` only and halves the workers (half the performance cores); benchmarks and media capture never run quiet | `Makefile` | |
| `make test-disturbance` and the sampler; `TEST_PARALLEL=NO` and a `TEST_WRAP` seam in `swift-test` | `Makefile`, `scripts/` | measure before and after |

## Measured impact

Whole suite, `make test-disturbance LABEL=x [TEST_QUIET=0|TEST_NICE=1]` on the same build, one run each, load average 57 to 70 from other agents in all three (so the stalls include their work):

| | before: `TEST_QUIET=0` | default (quiet, half the workers) | quiet, 4 workers, `TEST_NICE=1` |
|---|---|---|---|
| Wall time | 261 s | 361 s (+38 %) | 576 s (+121 %) |
| Host windows on screen at some sample | 68 | 32 | 12 |
| Seconds with a host window on screen | 40.4 | 8.4 | 3.8 |
| Seconds the Mac was above 90 % busy | 114 | 49 | 11 |
| Interactive thread: stall p95 / max (0.6 ms of work) | 27.0 / 230 ms | 3.8 / 50 ms | 5.2 / 372 ms |
| Timer lateness p95 | 77 ms | 4.9 ms | 30 ms |
| Failing tests | 1 (`EngineFreezerTests`, known flake) | the same 1 | 8: `AgentNetworkToolsTests` x4, `AgentFetchRunTests`, `DebuggerGapAPITests`, `HistoryImportTests`, the known one |

Why `TEST_NICE` is not the default: at background priority the hosts' timers are coalesced and the suite takes twice as long, and the timing-sensitive tests flake. On the 42 window classes alone with 2 workers it removed every stall (p95 1.1 ms, 0 s above 90 %, 133 s against 106 s without it), so it is the opt-in for a Mac someone is working on right now.

Five classes that show windows, serial, `TEST_PARALLEL=NO` (`AgentFoldersTests AgentApprovalTests PagePopupTests HoldToQuitTests PiPControllerTests`): 24 windows on screen for 21.4 s before, 20 windows for 3.2 s after.

What is left: `PagePopupTests` still draws 16 to 19 popup windows for about 3 s in total (a window server animation that alpha 0 and `animationBehavior = .none` do not stop; the next step is a test seam in `PagePopupController`), `PiPControllerTests` one panel, the alpha-0 windows (they take no clicks). Focus, Dock and HID input were never a problem.

## Alternatives

| Option | Verdict |
|--------|---------|
| (a) Fix in code: tests never activate, accessory policy, `postToPid`, offscreen windows | Done where it measures: there is nothing to fix for activation, policy and HID events (already clean, see above), windows are fixed generically by the quiet host rather than per site. Snapshots do not need a visible window and are already in-process. |
| (b) Lower priority, fewer workers | `taskpolicy` on make does not reach the hosts; demoting from inside the host does. Fewer workers help less than demotion (below). Chosen: demote, keep the worker count. |
| (c) A second macOS login session (`launchctl asuser`) | Not tried: needs an administrator. Steps: `sudo sysadminctl -addUser lilotests -password -`, log that user in once with Fast User Switching so its Aqua session exists, then `sudo launchctl asuser $(id -u lilotests) sudo -u lilotests -H make swift-test`, with Xcode licensed for that user and its own checkout. It removes every window and focus effect but not CPU, and an inactive session has no console display, which WebKit's occlusion and display-link tests may notice: unverified. |
| (d) A macOS VM (Tart, Anka; Apple Virtualization) | Not feasible here today: tart is not installed (not in the core Homebrew tap; `cirruslabs/cli/tart`), the Mac has 12 GiB of 460 GiB free (98 % used) and a macOS plus Xcode guest image is tens of GB, the guest needs 8 GB of the 24 GB for a cold Lilo build. Apple Silicon hosts run at most two macOS guests. Upside: windows, focus and input are fully isolated and the vCPU count caps the load; downside: the same 10 to 30 min cold build per VM image, and PiP, media and GPU tests may differ in a paravirtual GPU. Not measured. |
| (e) Remote Mac or CI | The fork's `build.yml` already runs three macOS shards (`xcode-27`) on pull requests to `main`: about 8 to 12 min each, 47.7 macOS minutes per run. An agent triggers it by pushing a branch and opening a draft PR to `main` (or by adding `workflow_dispatch` to `build.yml`, which it lacks) and reads `gh run view --log-failed` and the `failing-tests-*` artifacts. Public repository: no minutes billed, 5 concurrent macOS jobs. A self-hosted Mac mini would cut the queue and keep caches warm, and is only worth it when queueing is the bottleneck (median queue today: 2 s). The loop is 10 to 20 min per try instead of 2 to 10 min locally: for a final gate, not for the edit loop. |
| (f) Platform-independent SwiftPM slice for Linux | 125 of 305 test files import none of AppKit, WebKit, SwiftUI, Cocoa, AVFoundation or QuartzCore: 1 059 of 3 049 tests (35 %). They are the ones that never show a window, so this does not fix the complaint (the 41 offending classes hold 743 tests and need AppKit) but it moves a third of the suite off the laptop entirely. It needs the `LiloCore` library split from test-strategy.md section 3 (the subjects live in the AppKit-linked `Lilo` target), medium to large. |
