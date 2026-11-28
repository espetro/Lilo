# Handoff: Lilo dev-experience & build-architecture plan

For continuing the work from another device. Everything below is either committed to the fork, opened as an issue/discussion, or measured on the machine described in "Environment".

**Plan document**: `docs/DEVELOPMENT-EXPERIENCE-PLAN.md` (on the fork's `develop` branch, commit `37cae94e`).

---

## 1. Where everything lives

| Thing | Where |
|---|---|
| Plan document | `espetro/Lilo` @ `develop` → `docs/DEVELOPMENT-EXPERIENCE-PLAN.md` |
| Tracking issues (13) | `espetro/Lilo` issues #1-#13, one per PR |
| Upstream discussion, pnpm workspace | `Alexays/Lilo` issue #375 |
| Upstream discussion, Linux cloud agents | `Alexays/Lilo` issue #376 |
| Upstream repo | `Alexays/Lilo` (fork: `espetro/Lilo`) |
| Local remotes | `origin` = upstream, `fork` = espetro/Lilo |

**Branch model**: `develop` on the fork accumulates every stage (so its CI history shows cumulative gains); each upstream PR is a scoped subset with its own measurement table. Upstream is ROADMAP-gated (KISS, solo maintainer) so upstream PRs must stay minimal and each link its issue.

**Current state**: `main` = `c24fc63c` (unchanged from upstream), `develop` = head of the fork's `develop` (plan doc, this handoff, `mise.toml`+`mise.lock`+CONTRIBUTING pinning the host tools, and `scripts/lockf.py` — see §5). **No stage implementation has been written yet** — Stage 0 is next.

---

## 2. Environment (measured on the machine where the plan was made)

| | |
|---|---|
| macOS | 26.6.2 |
| Xcode | 27.2 (27B52), selected at `/Applications/Xcode.app` |
| Metal toolchain | **now installed** (`Apple metal version 32023.922`) — `make app` was failing before this; the 838 MB download unblocks it |
| Node / pnpm / bun | v24.22.2 / 12.16.1 / 1.3.14 (mise-installed) |
| Hardware | M1, **8 GB RAM, 4 P-cores** — the binding constraint on concurrent worktrees |
| Disk | ~7 GB free at handoff (cleaned `go-build`, `~/.npm/_npx`, Xcode DerivedData and the swiftpm cache) |
| `rtk` | 1.2.0, also pinned for the repo in `mise.toml` (see §5) |

**Remote hosts**: `ssh ovhcloud` (Debian 13, 6 cores, 11 GB RAM) — the Linux spike box. `quinos-mac-mini` on the tailnet **timed out** on connect during the session; check before relying on it as a self-hosted runner.

---

## 3. The measurements everything rests on (all measured, not estimated)

**Build speed with a shared Xcode compilation cache (XCC)** — the headline win. Method: fresh `-derivedDataPath` per run (= a new worktree), shared `COMPILATION_CACHE_CAS_PATH`:

| | times | median |
|---|---|---|
| Cold CAS, `COMPILER_INDEX_STORE_ENABLE=NO` | 31 / 26 / 25 / 31 s | **~28 s** |
| Warm shared CAS | 17 / 16 / 18 / 17 s | **~17 s** |
| First worktree (CAS populate) | 43 s | 43 s |

→ **~40% faster for every worktree after the first**, with two build-setting overrides and no new tool. Requires `SWIFT_ENABLE_EXPLICIT_MODULES=YES` (already on in this project).

**Per-worktree state**: node_modules 1.57 GB (4 npm trees) + `.derived.noindex` 667 MB (of which 482 MB is SPM SourcePackages) + Vendor 45 MB ≈ **2.3 GB per worktree**.

**Cross-project JS duplication** (the pnpm ROI): node_modules 1497 MB (npm) → **979 MB** (pnpm workspace) for lilo-ui + site + docs-site. Install ~20 s warm, one lockfile. An earlier figure of "~143 MB overlap" was **wrong** (a script bug missed `@scope/pkg` paths); the true duplication is ~787 MB.

**CI baseline** (from the Actions API, run `43823427506`): `app` shards 5.9 / 7.2 / 9.5 min, `release-build` 10.8 min, `ui` 0.9 min, `e2e` shards 2.2 / 2.4 / 3.2 min, `changes` 8 s. One PR uses **4 of the 5** free-plan macOS slots.

**Apple-framework coupling of the Swift code**: 195 of 323 app Swift files import AppKit or WebKit; 166 import Foundation. `LiloMCP/main.swift` imports `Darwin` (macOS-only by definition); `LiloPowerHelper` imports only Foundation but is a macOS tool target with `CREATE_INFOPLIST_SECTION_IN_BINARY`.

---

## 4. Stage-by-stage, with exact insertion points

Each stage = one fork branch = one upstream PR = one issue. **Start with Stage 0** — every later stage's before/after numbers come from it.

### Stage 0 — Observability (issue #1)
New: `scripts/metrics.py` (stdlib-only, house style of `scripts/perf_summary.py`), `scripts/ci_metrics.py`, `docs/build-baseline.md`. Makefile: add `metrics`/`metrics-off` targets.
- JSONL: `{ts, target, phase, dur_s, exit, worktree, sha, branch, dirty, loadavg1, concurrent, disk_free_gb, agent}` — written on success **and** failure **and** interrupt.
- Opt-in via the existing `Makefile.local` hook (Makefile:8) → zero Makefile diff to start.
- The CI API already gives job/step timings (verified: `gh api repos/Alexays/Lilo/actions/runs/<id>/jobs` returns `started_at`/`completed_at` per job) → the scraper needs no workflow change. One `GITHUB_STEP_SUMMARY` timing step around `make swift-test` for the number the API cannot see.
- 8 metrics with honest pairings + guardrails (no timing metric ever gates CI; weekly human read; no dashboards; every change ships a measurement verdict).

### Stage 1 — Setup correctness (issue #2)
`scripts/bootstrap.sh` + `Makefile` + `CONTRIBUTING.md`.
- **The bug**: bootstrap.sh:40 runs npm ci *before* the missing-prereq report at :42-48. Measured here: npm installed 1.5 GB, then the Metal check failed.
- Add: `DevToolsSecurity -status` (today only prose at CONTRIBUTING.md:51; it fails 40+ min into validate as `INTERNAL ERROR: childPID > 0`), disk-free check, engines scan across **all 5** package.json (today only 2 at bootstrap.sh:29), Metal-download caveat, Zig check, Linux routing, `--with-sites` flag (validate needs SITE_DEPS/DOCS_DEPS/CHANGIE that bootstrap never installs — Makefile:131 vs 136), `--json` output.

### Stage 2 — Local wins (issues #3-#7)

**PR 2 (issue #3) — XCC shared CAS.** Three invocation sites only: `Makefile:60` (`XCODEBUILD`), `Makefile:87` (`TEST_CONFIG`), `scripts/build-app.sh:117`. Add `COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH=$HOME/.cache/lilo/xcc COMPILATION_CACHE_LIMIT_SIZE=<cap> COMPILER_INDEX_STORE_ENABLE=NO`. **Command-line only, not xcconfig** — the IDE keeps its index.

**PR 3 (issue #4) — hash-keyed SPM dir.** Same three sites: `-clonedSourcePackagesDirPath $(SPM_PACKAGES_DIR)` where the dir is keyed on the sha256 of `Package.resolved`, plus `-onlyUsePackageVersionsFromResolvedFile`. −482 MB/worktree; hash keying makes cross-worktree pin drift impossible. Limits to state in the PR: the Xcode IDE keeps its own copy; XcodeGen cannot express this flag (it is an invocation flag, not a build setting).

**PR 4 (issue #5) — per-worktree test data.** `Makefile:87` `TEST_CONFIG` gains `LILO_APP_SUPPORT_DIR=$(CURDIR)/.derived.noindex/test-data`. The override exists (BuildIdentity.swift:17) and the bench scripts already use it (bench_startup.sh:62) — the test path never adopted it, so **every worktree's test host shares one GRDB DB and one agent socket**. This is the real reason the machine-global lock exists. Tradeoff: one WebCrypto keychain re-prompt per worktree under ad-hoc signing.

**PR 5 (issue #6) — test slot locks.** `scripts/test_slot.sh` (new, ~15 lines) + `Makefile:83`. **Blocked on the Stage 0 runningboardd A/B** (protocol: `log stream --predicate 'sender == "runningboardd"'` during 1 solo run vs 2 slot-locked runs at TEST_WORKERS=2). ext-smoke/ext-e2e keep the machine-global lock.

**PR 6 (issue #7) — scoped validate.** `Makefile` (GROUPS var + `validate-scope`) + `scripts/scope_checks.sh` (new, ~25 lines) + one AGENTS.md line. Mirror the CI changes-job regex (build.yml:39-40) as the source of truth. Today a UI-only scoped run still installs 1.4 GB of site/docs deps because `make validate` depends on all four node trees (Makefile:136).

### Stage 3 — CI signal (issues #8-#10)
- **PR 7a (issue #8)**: `release-build` on main pushes only → frees 1 of 5 macOS slots per PR. Accepted tradeoff: Release-only breaks surface on main ~30 min later.
- **PR 7b (issue #9)**: a terminal `gate` job (`needs:` all, `if: always()`, explicit fail) as the single required check. `if: always()` is mandatory — without it the gate is *skipped* when a dependency fails, and skipped counts as passing. Upstream branch protection then requires only `gate` + Conventional Commits.
- **PR 7c (issue #10)**: `failing-tests.md` artifact (extend `scripts/retried_tests.py`, which already truncates to 300 chars at :74) so agents stop reading multi-MB xcodebuild logs; plus an XCC CAS cache entry on CI.

### Stage 4 — Pin the package manager (issue #11)
`packageManager` fields in all 5 package.json + a repo-root package.json. Also the prerequisite for Stage 5, and what Cloudflare Workers Builds reads to pick the install tool.

### Stage 5 — pnpm workspace (issue #12, upstream discussion #375 FIRST)
**The blocker was overstated and is now resolved**: Cloudflare Workers Builds preinstalls pnpm and selects it via Corepack + the `packageManager` field, reading the **top-level** package.json even when the build root is a subdirectory (Cloudflare build-image docs). Verified locally: `pnpm install --frozen-lockfile` from inside `site/` resolves the workspace root above it; `--ignore-workspace` fails. So the build command becomes `pnpm install --frozen-lockfile --ignore-scripts` for both Workers — **a dashboard change the maintainer owns** (config lives outside git; docs-site/README.md:39-44 documents today's setup).
Sequencing: workspace on `develop` with full measurement → maintainer changes Cloudflare → then the upstream PR. release-media and bridge-src stay on npm unless the discussion says otherwise.

### Stage 6 — Linux cloud agents (issue #13, upstream discussion #376 FIRST)
The spike results are in §6 below. Expected shape: Linux agents run the JS/docs/site lane; the Swift layer stays on macOS. Frame it as development infrastructure, not a port — ROADMAP's "No Windows or Linux port" non-goal is about the product.

---

## 5. rtk and the other host tools — verdict (they are in the repo now, via `mise.toml`)

**This verdict changed on 2026-11-18.** The maintainer's answer was: include the host tools in the
repo, via `mise.toml`, and extend `mise.toml` to cover whatever else the host needs. That landed on
`develop` as `68040323 build: pin the host tools an agent needs in mise.toml`, refined by
`scripts/lockf.py` (see below).

**What the earlier assessment had established, and still holds:**

- **rtk** (1.1.0, host-level token-compressing CLI proxy) is genuinely effective for the *agent's* reading path (`git`, `gh`, `rg`, `read`, `grep`; 42% token savings measured on this machine) — **but it has no `make`, `xcodebuild`, `swift` or `swiftlint` filter** (those pass through with generic transforms only). The two heaviest streams in Lilo's own loop are **already compressed by the repo**: `make validate` runs 9 groups in parallel with per-group logs and prints only the failing one (Makefile:136-146); `scripts/retried_tests.py` truncates to 300 chars; `scripts/perf_summary.py` summarizes traces.
- The two lock families are **not interchangeable**: `lockf` locks a byte range, `flock` the file. The repo's `scripts/lockf.py` and the Makefile's `lockf` (Makefile:83) are one family; GNU `flock` and `discoteq/flock` are the other.

**What `mise.toml` now pins, and how each was verified on this machine:**

| Tool | Version | Why it is in the repo | Install path (verified) |
|---|---|---|---|
| `rtk` | 1.2.0 | summarizes `git`/`gh`/`rg` output for agents | mise registry entry; asset `rtk-aarch64-apple-darwin.tar.gz` |
| `jq` | 1.8.2 | `scripts/bench_extensions.sh` and `scripts/energy_idle_check.sh` read JSON with it | mise registry |
| `zig` | 0.16.0 | `make vt-build-source` needs Zig 0.16.x (Homebrew ships 0.17.1, which the check rejects) | mise registry |
| `shellcheck` | 0.11.0 | lints `scripts/*.sh` | mise registry |
| `node` | 22.23.4 | what `site/` and `docs-site/` require (`site/.nvmrc` pins the same) | mise registry |

`mise.lock` pins the per-platform sha256 of every download, and `[settings] lockfile = true` keeps
it that way. Verified end to end: `mise install` then `mise exec -- rtk --version` (1.2.0),
`jq --version` (1.8.2), `zig version` (0.16.0), `shellcheck --version` (0.11.0),
`node --version` (22.23.4).

### The lock: `scripts/lockf.py`, not flock

The host rule (`~/AGENTS.md`) says heavy compiles run under `flock /tmp/tsc.lock <cmd>`. GNU
`flock` is Homebrew-only, so the first attempt was `github:discoteq/flock` in `mise.toml`. **That
was the wrong call**, and the maintainer corrected it: prefer a small Python script over building
a C tool.

`scripts/lockf.py` does it with the standard library only (`fcntl.lockf`), so it needs no install
at all, runs identically on macOS and Linux, and lives in the repository so every machine uses the
same lock. It is modelled on [dspinellis's gist](https://gist.github.com/dspinellis/eb924c195206f57e896d026dbe14befa)
(Apache-2.0), **with the bug that gist has fixed**: Python opens descriptors close-on-exec (PEP
446), so the lock is released by the `execvp` that runs the command. Measured here: with the gist's
code a second process took the lock *while the command ran*; with `os.set_inheritable(descriptor,
True)` the lock is held for the command's whole life. Verified: mutual exclusion between two
waiters, `-n` fast-fail, `-w SECONDS` timeout, and the command's own exit code.

**The two lock families are not interchangeable**: `lockf` locks a byte range, `flock(2)` the file.
`scripts/lockf.py` is a `lockf` lock, so it interoperates with the Makefile's `lockf` test lock
(Makefile:83) and with Linux's `lockf`, but not with `flock(2)`. Keep the families on separate
lock files.

**One trap worth knowing:**

- **Node needs an explicit entry.** mise's `.nvmrc` autodetection does not override a *global*
  `node` pin, so a host with `node = "24"` in `~/.config/mise/config.toml` silently kept 24.
  Listing `node = "22.23.4"` in `[tools]` fixes it.

**No release note was added**: dev-infra commits in this repo (Makefile targets, CI changes) carry
none, per precedent (`2974a4f9`, `f72a0c98`).

---

## 6. Linux spike results (the Swift-on-Linux question)

The spike ran on `ssh ovhcloud` (Debian 13 trixie, 6 cores, 11 GB RAM) against `main` = `c24fc63`, with real command output. The load-bearing conclusions:

- **CI already runs most of the loop on Linux**: the `release-tooling`, `ui`, `e2e` (3 shards) and `bridge` jobs all run on `ubuntu-latest` (build.yml:44-151). Verified on Debian 13: `ui-lint` (svelte-check 0 errors), `ui-test` (654/654), `ext-bridge-test` (587/587), `site-check`/`site-test` (0 errors, 86/86), `docs-check`/`docs-test` (no broken links, 4,503 audits), `e2e` (714/715 — the one failure is a wall-clock perf guard on a shared box), `site-e2e` (114/115 — an iframe race that passes in isolation), `release-status`, `release-test`, `release-media-test`, `perf-summary-test`, `hooks-test`, `lint-commits`, `site-deploy-check`, `docs-deploy-check`, `bridge-gen`, `vt-build`, `ui-build` (both generated Swift files produced identically on Linux).
- **What genuinely needs macOS**: `make app`, `make install`, `make swift-test`, `make swift-test-slow`, `make release*`, `make dmg`, `make ext-smoke*`, every `*-bench`, `make agent-call`, `make project-sync`'s xcodegen step — AppKit and WebKit do not exist on Linux; 195 of 323 app files import them.
- **Two fixes make more of the lane work on Linux**, both small:
  - **`make swiftlint` fails on Linux only because the Makefile pins the macOS zip** (Makefile:24, 166-171 download `portable_swiftlint.zip`, a Mach-O universal). The Linux asset `swiftlint_linux_amd64.zip` runs and reports **0 violations on Lilo's 321 files**. The fix mirrors what `CHANGIE_OS`/`CHANGIE_ARCH` already do (Makefile:18-20): detect `uname -s`, download the Linux zip with its own pinned SHA256.
  - **`make project-sync` works up to the xcodegen step** — the UI bundle and `NativeStrings.swift` generate fine on Linux; only `xcodegen` (Mach-O only, no Linux asset) stops it.
- **A gotcha any agent must know**: `make chrome-surface` and `make public-suffix-list` are *network-fresh regenerators* — they rewrite the committed `.gen.*` files and `public-suffix-list.dat` from live data, dirtying the tree and making `ext-bridge-test` fail until `git checkout -- Lilo/Extensions …`. They are write targets, not test targets; never run them "to check".
- **No Mac on the tailnet is reachable**: `quinos-mac-mini` has been offline 56 days, `quinos-mac-mini-lan` times out, `kinosmac` offline, `kinosmac-legacy` refuses the connection. OVHcloud **does not sell Mac minis** (its catalog has no Apple plan; the EU provider that does is Scaleway). So a self-hosted Mac is a purchase (Scaleway Paris from €0.22/h, JUUZ €119/mo, MacStadium $149/mo, MacinCloud $164/mo) — and the spike found nothing worth buying while GitHub-hosted `xcode-27` is free, already wired and already correct.
- **The three iOS-oriented projects** (`xtool-org/xtool`, `MobAI-App/simslim`, `MobAI-App/mobai-dev`):
  - **xtool** is the interesting one: "Cross-platform Xcode replacement. Build and deploy iOS apps with SwiftPM on Linux, Windows, macOS" (MIT, 15.7k stars, actively pushed). Its `SDKBuilder.swift` **does** handle the `MacOSX` platform with `arm64-apple-macosx` and `x86_64-apple-macosx` triples. **But** its Linux install requires you to download **Xcode 27.1** from Apple's developer site yourself (it extracts the .xip to build a Swift SDK) — so it does not remove the Apple-SDK dependency, it relocates it, and it is a SwiftPM-based flow, not `xcodebuild`. Lilo's XcodeGen project, XPC services, asset catalogs, entitlements, Metal shaders and ad-hoc signing are all outside its model. The 2.0 beta (2026-11-16) adds a macOS triple but still cannot sign a Mac app, still lacks asset-catalog support, and cannot run or test anything.
  - **simslim** (Go, 4.3k stars) is "Run more iOS simulators on one Mac" — a Mac-only tool, irrelevant for a Linux box.
  - **mobai-dev** is "Everything a coding agent needs to build and run iOS apps from a Linux sandbox" — an agent harness around the iOS flow, same Apple-SDK dependency. Its *pattern* (snapshot → hosted macOS CI → artifact) is the template for Lilo's Linux lane.
- **Verdict for Stage 6**: the honest promise is a **split**, not a Swift-on-Linux miracle: Linux cloud agents carry the JS/docs/site/bridge lane (already CI-proven and now measured on Debian) and the Swift lane stays on a macOS runner. For Swift, the practical option is GitHub-hosted macOS runners (free and unlimited on a public repo; the binding constraint is the **5 concurrent job cap**, and Lilo's 3 test shards + release build already use 4 of them, so there is **one spare slot**), with a self-hosted Mac mini as the fallback when that cap actually queues a PR.
- **Darling** cannot run `xcodebuild` (its own README: "Xcode itself doesn't run yet"; issue #1414 closed as a duplicate of #488); **GNUstep** is not Apple's AppKit (WebKit/WKWebExtension/Metal/Sparkle XPC are all unavailable, so Lilo would not compile against it); the iOS-on-Linux toolchains (theos, swift-android) are for iOS targets, not macOS apps. The Apple SDK licence (§2.2.A, §2.5 of the Xcode and Apple SDKs Agreement) forbids running the Apple toolchain on non-Apple hardware, so the macOS SDK route is a licence violation, not just an engineering gap.
- **The closest thing to a Linux Apple builder** is `apple-cross-toolchain/rules_applecross` (Apache-2.0, Bazel): it builds macOS apps, extensions and frameworks on Linux, with clean-room `actool`/`ibtool`/`momc` reimplementations and even notarization from Linux. Its limits: **Metal has no Linux version** (relaxed compile only), `.xib` support is narrow, and — the killer — "it builds; it doesn't run … `bazel test` has nothing to run them on". It would also mean replacing the Makefile with Bazel. Watch-list only.


---

## 7. First actions on the new device

1. `git clone git@github.com:espetro/Lilo.git && cd Lilo && git checkout develop` — or reuse an existing clone and `git remote add fork git@github.com:espetro/Lilo.git`.
2. Verify the environment: `xcrun metal --version` (must print a version), `xcodebuild -version` (27.x), `node -v` (≥22.23.4 for site/docs), `df -h /` (≥10 GB free).
3. **Check the upstream discussions for replies** (#375, #376) — they gate Stages 5 and 6, and the maintainer's answer may change those scopes.
4. Run Stage 0's baseline checklist and commit `docs/build-baseline.md` **before** any other change. The checklist is in the metrics report: clone+bootstrap+app timing, 3× warm `make validate` median, lock-wait isolation (`lockf -k /tmp/lilo-swift-test.lock sleep 60` in one shell, `make swift-test` in another), a 3-worktree concurrency trial, a CI scrape of the last 20 runs, and flake counts from `gh run view <id> --log | grep -A5 "passed only on a retry"`.
5. Then Stage 0 → Stage 1 → Stage 2 (PRs 2-6) → Stage 3 → Stage 4 → Stage 5 (after the discussion) → Stage 6.

## 8. Watch-outs for whoever continues

- **`make validate` must stay parallel and must keep `swift-test` last** (it needs the UI and bridge bundles built first) — Makefile:138-145.
- **Never share DerivedData across worktrees**: xcodebuild's build.db gets corrupted (community-verified). Only the CAS and the SPM checkout dir are shareable.
- **The CAS cache key includes output paths**, so cross-worktree hits are partial (~40%, not ~90%).
- **APFS clones make `du` lie**: measure footprint with `df` deltas, not `du`, in the metrics.
- **`make project-sync` after adding/renaming any Swift file**, and commit the regenerated `Lilo.xcodeproj` — CI fails until it is in sync.
- **Generated files are build outputs**: `Lilo/Generated/*`, `Lilo/Extensions/Chrome*.js`, `*.gen.*`, docs-site `_generated/`.
- **The `flock`/`lockf` families do not interoperate** — keep them on separate lock files.
- **The maintainer is the only one who can change Cloudflare's build settings** (outside git) and the branch protection rules.
