# Linux agents

Lilo is a macOS app and stays one: [ROADMAP.md](../ROADMAP.md) rules out a Windows or Linux port.
This page is about something else, the development loop.
A coding agent running in a Linux sandbox or cloud box can do most of the work on Lilo's web side (the UI, the extension bridge, the websites, the documentation, the release tooling) and cannot do the Swift side.
It describes what the agent can run, how to run several side by side, and where the Swift work goes.

The partition below was measured on Debian 13 (6 cores, 11 GB) against `develop` at `51eaadfe`, with the per-target table under [Measurements](#measurements) recorded on the same host; an earlier spike ran against `main` at `c24fc63c`.
Timings marked "this Mac" come from an Apple M1 with 8 GB of RAM under load from other work, so read them as an order of magnitude.

## What runs on Linux

`make linux-checks` runs every check that needs no Xcode, in the order `make validate` runs them: it is `validate` without the app build and the Swift tests.
CI runs the same targets on `ubuntu-latest` already (the `release-tooling`, `ui`, `e2e` and `bridge` jobs), so what passes there passes in a Linux sandbox.

| Target | Checks | Result on Debian 13 |
|--------|--------|---------------------|
| `ui-lint` | svelte-check and lint of `lilo-ui` | 0 errors |
| `ui-test` | `lilo-ui` unit tests | 654 of 654 |
| `ext-bridge-test` | the extension bridge unit tests | 587 of 587 |
| `site-check`, `site-test` | getlilo.app type check and tests | 0 errors, 86 of 86 |
| `docs-check`, `docs-test` | docs.getlilo.app build, link and audit checks | no broken links, 4,503 audits |
| `hooks-test`, `perf-summary-test`, `lockf-test` | the commit hooks, the perf summary and the lock wrapper | pass |
| `release-status` | pending release notes and the version files agree | pass |
| `swiftlint` | Swift lint, no Xcode needed | 0 violations in 321 files |
| Target | Makefile | Checks | Result on Debian 13 |
|--------|----------|--------|---------------------|
| `ui-lint` | `Makefile:381` | svelte-check and lint of `lilo-ui` | pass |
| `ui-test` | `Makefile:386` | `lilo-ui` unit tests | 661 of 661 |
| `ext-bridge-test` | `Makefile:488` | the extension bridge unit tests | 587 of 587 |
| `site-check` | `Makefile:841` | getlilo.app type check | pass |
| `site-test` | `Makefile:849` | site tests | 86 of 86 |
| `docs-check` | `Makefile:911` | docs.getlilo.app link and audit checks | pass, no broken links |
| `docs-test` | `Makefile:915` | docs build and tests | pass (red on `develop` until the tool-count fix in this change) |
| `hooks-test` | `Makefile:163` | the commit hooks | pass |
| `perf-summary-test`, `retried-tests-test`, `metrics-test`, `ci-metrics-test`, `check-summary-test`, `lockf-test` | `Makefile:753`, `:757`, `:777`, `:785`, `:793`, `:761` | the perf summary, the failed test report, the timing recorders and the lock wrapper | pass (Python only) |
| `scope-test`, `tier-test` | `Makefile:801`, `:789` | the diff scoping and the check tiers | pass |
| `release-status` | `Makefile:298` | pending release notes and the version files agree | pass |
| `swiftlint` | `Makefile:243` | Swift lint, no Xcode needed | 0 violations in 323 files |

`make linux-checks` itself (`Makefile:240`) is `validate` minus the Xcode build and the Swift tests, so it also runs on macOS; on Linux it is the full pre-push pass.
Two host prerequisites the spike surfaced: the Makefile extracts archives with `unzip` (`Makefile:255`, `:263`, `:683`), which a stock Debian install lacks (`apt install unzip`, or any `unzip` on `PATH`), and the static SwiftLint writes its cache to `/var/tmp/SwiftLint`, which on a shared box can belong to another user — the lint itself passes and only the cache write fails; `--no-cache` avoids it.

These pass on Linux too, and sit outside `linux-checks` because they are heavier or need a browser or a network download:

| Target | Makefile | Notes |
|--------|----------|-------|
| `e2e` | `Makefile:390` | Playwright against the vite dev server, no app needed: 714 of 715 on this host, the one failure a wall-clock guard (`longestTask` 1381 ms against a 1000 ms bound) on a box at load 5; it stays out of `linux-checks` because it is the heavy browser suite CI already runs sharded three ways. Needs `pnpm --dir lilo-ui exec playwright install --only-shell chromium` first (CI does the same). |
| `site-e2e` | `Makefile:853` | Playwright against the built site. |
| `release-test`, `release-media-test` | `Makefile:315`, `:333` | release tooling tests. |
| `site-deploy-check`, `docs-deploy-check` | `Makefile:895`, `:923` | what the Cloudflare builds run. |
| `bridge-gen`, `ui-build`, `vt-build` | `Makefile:664`, `:319`, `:670` | The generated sources come out identical to macOS (`ui-build` writes both generated Swift files; `vt-build` fetches the prebuilt libghostty-vt). |
| `lint-commits` | `Makefile:159` | Conventional Commits check of a range. |

`make swiftlint` on Linux downloads the static `swiftlint_linux_amd64.zip` (its own pinned checksum, in the Makefile beside the macOS one) and runs the same rules as macOS with two exceptions: `statement_position` and `vertical_whitespace_closing_braces` need SourceKit, which the static binary does not have, so it prints a warning and skips them.
The macOS job in CI runs all of them, so a violation only those two rules find shows up there and not on Linux.
The Linux download is amd64 only; on arm64 the target stops with `Unsupported SwiftLint platform`.
The dynamic binary in the same zip covers the two rules, but it needs a Swift toolchain to load SourceKit (it crashes without one), so it is not the default.

## What needs macOS

| Target | Makefile | Why |
|--------|----------|-----|
| `app`, `install`, `install-debug`, `xcode-build*`, `run-ui-dev` | `Makefile:555`, `:559`, `:563`, `:567`, `:572`, `:577` | `xcodebuild`, AppKit, WebKit and Metal exist only on macOS. |
| `swift-test`, `swift-test-slow` | `Makefile:413`, `:419` | the tests run in the app host. |
| `test-build` and everything under it (`*-bench`, `blocker-*`, `script-bench`, `speedometer-bench`, `page-bench`, `preload-bench`, `port-bench`, `terminal-bench`, `startup-bench`) | `Makefile:399` | they build the app or its test bundle with `xcodebuild`. |
| `release*`, `dmg*` | `Makefile:634`, `:638`, `:644`, `:649`, `:660` | signing, notarization and Sparkle. |
| `ext-smoke*`, `ext-nightly`, `ext-e2e*`, `agent-call`, `agent-app*`, `energy-*` | `Makefile:492`, `:496`, `:500`, `:504`, `:511`, `:586`, `:612`, `:738`, `:742` | they drive the built app. |
| `project-sync` | `Makefile:247` | it generates the UI bundle and the native strings, then stops: XcodeGen has no Linux build. |
| `validate` | `Makefile:179` | it ends in `swift-test`, so on Linux run `linux-checks`. |
| `webkit-fork` | `Makefile:686` | extracts with `ditto`, which exists only on macOS. |

`vt-build-source` (`Makefile:698`) is unverified: it needs only Zig, which runs on Linux, but it emits an `.xcframework`, an Apple bundle format, so it probably wants a macOS SDK; not tried on the spike box.

Two targets write to the tree from live data and must never run speculatively:
`make chrome-surface` and `make public-suffix-list` rewrite committed generated files from the network, which dirties the tree and makes `ext-bridge-test` fail until the files are checked out again.
They are regenerators, not checks.

## Several agents on one box

Give each agent its own git worktree, outside the repository, and install its dependencies there:

```bash
git worktree add ~/.worktrees/<ticket>/<keywords> -b <branch> origin/main
cd ~/.worktrees/<ticket>/<keywords>
make linux-checks        # npm ci runs on the first target that needs each tree
```

- **One `npm ci` per worktree.** Never share a `node_modules` between worktrees, and never run two `npm ci` in the same tree: the second one corrupts the first.
- **Disk.** The four npm trees measure about 1.6 GB on macOS (`lilo-ui` 132 MB, `site` 574 MB, `docs-site` 819 MB, the bridge 40 MB) and about 2.3 GB installed on the spike box; budget 4 GB free per worktree.
  Each target installs only the trees it needs, so a UI-only change pays for `lilo-ui` alone.
- **Memory and CPU.** Builds and `site-test`, `docs-test` are the heavy ones. On an 8 GB box run them one at a time through `scripts/lockf.py /tmp/tsc.lock make <target>` (see [Locking across machines](../CONTRIBUTING.md#locking-across-machines)).
- **Scope the run** to what the diff touches, as [AGENTS.md](../AGENTS.md) says: a change in `lilo-ui/` needs `make ui-lint ui-test`, one in `docs-site/` needs `make docs-check docs-test`.
  `make linux-checks` is the full pass before a push.
- Keep the Swift side out of the worktree's way: edits to `.swift` files can be written on Linux, linted with `make swiftlint`, and are then built and tested by CI (below).

## Swift on Linux: no

No toolchain compiles, links, runs and tests an AppKit and WebKit macOS app on Linux, as of November 2026.
This was researched rather than assumed:

- 195 of the app's 323 Swift files import AppKit or WebKit (269 and 208 files repo-wide). WebKit, Metal, NSXPC and IOKit do not exist on Linux.
- `swift build` stops at the GhosttyVt binary target, which has no Linux slice, and `LiloMCP/main.swift` imports `Darwin`, which does not exist there.
- Darling cannot run `xcodebuild` (its README says "Xcode itself doesn't run yet"). GNUstep is not Apple's AppKit and has no WebKit port.
- The Xcode and Apple SDKs Agreement (sections 2.2.A and 2.5) does not allow the Apple toolchain on non-Apple hardware.
- `xtool` 2.0 beta and `rules_applecross` are the closest tools: they compile and bundle for Apple platforms from Linux, but cannot run or test the result, lack Metal parity and Icon Composer, and still need an Xcode download the user licensed on a Mac. `rules_applecross` would also replace the Makefile with Bazel.
  Watch `rules_applecross`; revisit if it gains byte-identical Metal and a way to run what it builds.

So the split is the whole promise: Linux agents carry the web, docs, bridge and release lane, the Swift lane stays on macOS.

## Where the Swift work runs

GitHub-hosted `xcode-27` runners stay the primary builder: they are free and unlimited on a public repository.
The constraint is the five macOS jobs GitHub runs at once on a free plan, and one pull request already uses four of them (three test shards and the release build), so one slot is spare.
A Linux agent's loop for a Swift change is then: edit, `make swiftlint`, push the branch, read the macOS job's result from CI.

A self-hosted Mac is a purchase to make only if that cap really queues pull requests: the tailnet `quinos-mac-mini` is the candidate already on the network (unreachable from the spike box, so its warm Xcode + Metal toolchain is unverified), and the rental options are Scaleway (Paris, from about €0.22 an hour, runner preinstalled), JUUZ (about €119 a month) or MacStadium (about $149 a month). OVHcloud sells no Mac minis.
With a Mac on the network, `xcodebuild` over SSH needs no change: `-derivedDataPath` and `-clonedSourcePackagesDirPath` are paths on the Mac, so sync the worktree and run `make` there.
The latency of that worktree-to-Mac loop is not measured, since no Mac was reachable from the Linux box.

## Measurements

Wall time per target on Debian 13 (6 cores, 11 GB, other sessions loading the box), dependencies installed, each target run alone after a full `make linux-checks` pass:

| Target | Result | Seconds |
|--------|--------|---------|
| `ui-lint` | pass | 41 |
| `ui-test` | 661 of 661 | 19 |
| `site-check` | pass | 71 |
| `site-test` | 86 of 86 | 29 |
| `docs-check` | pass | 119 |
| `docs-test` | pass | 140 |
| `hooks-test` | pass | 2 |
| `perf-summary-test` | pass | 0 |
| `retried-tests-test` | pass | 1 |
| `scope-test` | pass | 0 |
| `tier-test` | pass | 3 |
| `metrics-test` | pass | 4 |
| `ci-metrics-test` | pass | 0 |
| `check-summary-test` | pass | 2 |
| `lockf-test` | pass | 6 |
| `ext-bridge-test` | 587 of 587 | 10 |
| `release-status` | pass | 0 |
| `swiftlint` | 0 violations in 323 files | 5 (`--no-cache`; the cache write needs a writable `/var/tmp/SwiftLint`) |

`make linux-checks` end to end took 6 min 25 s warm on the same loaded box (it stops at `swiftlint` there only because of the `/var/tmp` cache ownership above; every member passes).
`make e2e` needs `pnpm --dir lilo-ui exec playwright install --only-shell chromium` once (a 120 MB download), then runs the 715 Playwright tests against the vite dev server: 714 passed in 12.1 min with `--workers=4`, the one failure the `longestTask` guard above under load.

Wall time per target on this Mac (M1, 8 GB, other sessions running), after the dependencies were installed:

| Target | Seconds |
|--------|---------|
| `ui-lint` | 5.4 |
| `ui-test` | 2.7 |
| `site-check` | 10.9 |
| `site-test` | 5.8 |
| `docs-check` | 4.5 |
| `docs-test` | 7.1 |
| `hooks-test` | 2.5 |
| `perf-summary-test` | 0.1 |
| `lockf-test` | 6.1 |
| `ext-bridge-test` | 2.4 |
| `swiftlint` | 0.5 (SwiftLint's cache was warm; 9 s cold) |
| `release-status` | 1.2 |
| the targets run one by one | 49 |
| `make linux-checks`, one run | 77 |

`linux-checks` runs its targets one after another, where `make validate` runs its groups in parallel, so on a quiet multi-core box `validate`'s approach finishes sooner.
The two totals differ by 28 s; the load average was 11 to 13 throughout, so I did not attribute the gap to anything but noise. Treat both as one sample, not a benchmark.

Not measured: the dependency install time on a cold Linux box (the spike box's pnpm store was warm), `site-e2e` on this host, and the worktree-to-Mac latency.
Measured on Debian 13 for this change: `make swiftlint` from an empty `build/` (download, checksum, unzip, lint of 321 files) took about 9 s; the same download and lint of 323 files took about 7 s here once `unzip` was on `PATH`.
