# Lilo dev-experience & build-architecture plan

Multi-stage PR series making Lilo lean for agent-first, multi-worktree development (3-5 agents in worktrees on one Mac, pushing PRs to CI), with observability at every step.

**Working context**

- Author: espetro (fork: `github.com/espetro/Lilo`), upstream: `github.com/Alexays/Lilo` (solo maintainer Alexays, ROADMAP-gated, KISS rules in AGENTS.md).
- Two-track flow: everything lands on the fork's `develop` branch first (accumulative, fully measured), curated minimal PRs go upstream, one logical change each.
- Machine: M1, 8 GB RAM, 4 P-cores, ~7 GB free disk after cleanup (the S0 baseline wants ≥10 GB).
- Measured baseline facts this plan builds on: cold `make app` 6m58s with the Metal toolchain installed; fresh-worktree Debug build 28s cold CAS / 17s with shared XCC CAS (measured A/B); per-worktree state ~2.3 GB; machine-global Swift test lock (Makefile:83); CI: 4 of 5 free macOS slots per PR.
- Host tools (`rtk`, `flock`, `jq`, `zig`, `shellcheck`, the websites' Node.js) are pinned in `mise.toml` with `mise.lock` (commit 68040323): the maintainer asked for the repo to carry them. They stay outside the required toolchain — no `make` target depends on mise.

**Guidelines honored per stage**

1. Every PR: one logical change, linked to one GitHub issue, and to a reproducible measurement (commands + before/after table).
2. ROADMAP alignment: the only item that challenges a rule is the pnpm workspace (KISS / "Makefile is the only command surface" tension) and it ships with an upstream discussion carrying the ROI counterargument first. The Linux work explicitly does NOT touch the "No Windows or Linux port" non-goal (that is a product statement; this is development infrastructure).
3. `develop` on the fork accumulates all stages; upstream PRs are cherry-picked subsets, so upstream reviews see scoped diffs while `develop`'s CI shows cumulative gains.

---

## Stage 0 — Observability + frozen baseline (PR 0, upstream issue #1: "Add build/dev-loop metrics")

Files: `scripts/metrics.py` (new, stdlib-only, house style of `scripts/perf_summary.py`), `scripts/ci_metrics.py` (new, Actions API scraper), `Makefile` (`metrics`, `metrics-watch` targets; opt-in wrapper), `docs/build-baseline.md` (new, committed).

- JSONL schema: `{ts, target, phase, dur_s, exit, worktree, sha, branch, dirty, cpus_perf, ram_gb, loadavg1, concurrent, disk_free_gb, agent, pid}` — written on success AND failure AND interrupt (survivorship bias is the failure mode).
- Local writer: opt-in via `Makefile.local` (`SHELL` override) so zero Makefile change is needed to start; `make metrics` summarizes; `make metrics-off` restores. Overhead budget < 30 ms/record, asserted by a self-calibration record.
- CI writer: `scripts/ci_metrics.py` scrapes the Actions API (job/step `started_at`/`completed_at` for the last N runs — free, no workflow change) + one `GITHUB_STEP_SUMMARY` timing step around `make swift-test` (the one number the API cannot see) + `cache-hit` outputs per cache aggregated.
- 8-metric minimum set (each with its honest pairing in the same report):
  1. cold-start-to-first-green-validate (pair: warm loop latency)
  2. peak concurrent footprint via `df` delta + peak RSS (pair: corruption/incident count) — `du` lies on APFS clones
  3. lock-wait time + concurrent test-host count (pair: concurrency-induced failure delta)
  4. CI time-to-first-signal + skip rate (pair: coverage counter)
  5. CI makespan + macOS slot-minutes + max concurrent slots
  6. cache hit rate + cache-correctness spot-check (weekly no-cache verification build)
  7. pre-retry test failure rate (pair: tests-removed counter; `TEST_RETRY` only masks in CI)
  8. env-vs-code validate failure split + half-configured-tree incidents (pair: CI sync-check outcomes)
- Guardrails (in the docs): no timing metric ever gates CI; weekly human read, never a dashboard, never per-agent leaderboards; every change ships a one-paragraph measurement verdict.
- Baseline checklist output committed as `docs/build-baseline.md` (the "now" column): clone+bootstrap+app timing, 3× warm validate median, lock-wait isolation test, 3-worktree concurrency trial, CI scrape of last 20 runs, flake counts.
- Machine prep first: free disk to ≥ 10 GB (npm cache 379 MB, Xcode caches, old DerivedData), Metal toolchain download (~2-4 GB) so `make app` actually completes.
- Measurement: this stage IS the measurement.
- Note: `Makefile.local` hook already exists (Makefile:8) — the wrapper rides it, so upstream diff stays tiny.

## Stage 1 — Setup correctness: `make setup` (PR 1, issue: "bootstrap checks before installs")

Files: `scripts/bootstrap.sh`, `Makefile` (bootstrap target args), `CONTRIBUTING.md`.

- Reorder: ALL checks first (currently npm ci runs at bootstrap.sh:40 before missing-prereq report at :42-48 — measured on this machine: npm installed then Metal failed).
- Add checks: `DevToolsSecurity -status` (today only prose at CONTRIBUTING.md:51; fails 40+ min into validate with `INTERNAL ERROR: childPID > 0`), disk free vs a declared need, engines scan across all 5 package.json files (today only 2 at bootstrap.sh:29), Metal-download caveat text (needs Apple-ID-authenticated download, ~10 min), Zig presence if the vt prebuilt is unreachable, Linux routing message (list what works on Linux, from Stage 6 findings).
- Add `--with-sites` flag installing SITE_DEPS/DOCS_DEPS + CHANGIE so `make validate` doesn't surprise-install 1.4 GB mid-gate (bootstrap installs only UI+BRIDGE today, Makefile:131, but its success banner recommends validate which needs Makefile:136 deps).
- `--json` output for agents; exit codes distinguish "missing tool" from "action requires human".
- Measurement: time-to-first-error and bytes-installed on a deliberately broken env (missing Metal), before vs after.

## Stage 2 — Measured local wins (PRs 2-6, one issue each)

**PR 2 — XCC compilation cache shared across worktrees** (issue: "Share the Xcode compilation cache across worktrees")
- Files: `Makefile` (XCODEBUILD line 60, TEST_CONFIG line 87), `scripts/build-app.sh` (line 117).
- Change: `COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH=$(HOME)/.cache/lilo/xcc COMPILATION_CACHE_LIMIT_SIZE=<cap>` + `COMPILER_INDEX_STORE_ENABLE=NO` on make-driven xcodebuild invocations only (NOT xcconfig — the IDE keeps its index).
- Measured on this repo: fresh-derived-data build 28s cold → 17s warm CAS (median of 4 A/B runs); first worktree pays the populate. Explicit modules already on (`SWIFT_ENABLE_EXPLICIT_MODULES=YES` — XCC requires it).
- Risks documented in the PR: CAS grows across runs (limit set); cache key includes output paths so coverage is partial; per-DD `CompilationCache.noindex` stays as fallback.

**PR 3 — hash-keyed shared SPM package dir** (issue: "Stop cloning GRDB per derived-data path")
- Files: same three sites as PR 2, plus a `SPM_PACKAGES_DIR ?= $(HOME)/.cache/lilo/spm-$(shell shasum -a 256 Lilo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved | cut -d' ' -f1)` variable.
- Change: `-clonedSourcePackagesDirPath $(SPM_PACKAGES_DIR) -onlyUsePackageVersionsFromResolvedFile`.
- Saves ~482 MB/worktree; hash keying makes pin drift between worktrees physically impossible (different pins → different dir).
- Known limits (stated in PR): does not affect the Xcode IDE's own copy; XcodeGen cannot express this flag so it must stay on invocation lines; CI already caches SPM correctly (build.yml:193) so CI is untouched.

**PR 4 — per-worktree test data isolation** (issue: "Tests write to one shared Lilo-Debug dir")
- Files: `Makefile` (TEST_CONFIG, line 87), `CONTRIBUTING.md`.
- Change: `LILO_APP_SUPPORT_DIR=$(CURDIR)/.derived.noindex/test-data` in TEST_CONFIG. The override already exists (BuildIdentity.swift:17) and bench scripts already use it (bench_startup.sh:62) — tests currently do NOT, so two worktrees' test hosts share one GRDB DB and agent socket. This is what actually makes concurrent lanes safe, beyond the CPU argument.
- Tradeoff documented: one WebCrypto keychain re-prompt per worktree (ad-hoc signing), or a team ID in Makefile.local to avoid it.
- Measurement: two concurrent swift-test lanes, each with its own support dir — assert no DB contention (`lsof` on the DB), no cross-lane socket connects.

**PR 5 — test slot locks (2 lanes)** (issue: "Replace the machine-global test lock with N slots")
- Files: `scripts/test_slot.sh` (new, ~15 lines), `Makefile` (TEST_LOCK consumers: 88, 407, 421), `Makefile.local.example`.
- Prerequisite: the runningboardd A/B from Stage 0's baseline (log stream during 1 vs 2 lanes at TEST_WORKERS=2). Do not merge without it.
- Change: N slot locks (`lockf -t 0` on `/tmp/lilo-test-slot-{1..N}.lock`), auto-halve `TEST_WORKERS` when 2 lanes run; ext-smoke/ext-e2e keep the machine-global lock (they use network + keychain + Store).
- Expected: ~1.7× aggregate test throughput at 2 lanes (RAM-bounded on 8 GB — stated, not promised).
- Measurement: Stage 0 metric 3 (lock wait + concurrent hosts) and metric 7 (pre-retry failure rate must stay flat).

**PR 6 — scoped validation** (issue: "Make AGENTS.md's scoping rule executable")
- Files: `Makefile` (GROUPS variable + `validate-scope` target), `scripts/scope_checks.sh` (new, ~25 lines), `AGENTS.md` (one line).
- Change: `make validate-scope` maps the git diff against origin/main to check groups, mirroring the CI changes-job regex (build.yml:39) as source of truth; prunes SITE_DEPS/DOCS_DEPS prereqs when scoped out (today a UI-only run still installs 1.4 GB of site/docs deps via Makefile:136).
- Measurement: full validate vs scoped validate wall time + bytes installed for a synthetic UI-only, docs-only, and Swift-only diff.

## Stage 3 — CI signal for agent pushes (PRs 7a-7c, issues each)

**PR 7a — release-build off PRs** (issue: "Free a macOS slot per PR")
- Files: `build.yml` (job condition ~line 253).
- Change: run release-build on push-main/merge_group only. Frees 1 of 5 slots per PR; Release-only breaks surface on main ~30 min later (accepted, stated). Release cache saves already assume main (build.yml:298-304).

**PR 7b — gate job as the single required check** (issue: "One required check to rule them all")
- Files: `build.yml` (new terminal job), upstream branch-protection change (maintainer action, listed as such).
- Change: `gate` job, `needs: [all]`, `if: always()`, fails explicitly on any dependency failure/cancel. Upstream sets branch protection to require only `gate` + Conventional Commits. Kills the skipped-required-check class forever, makes future job changes protection-safe.

**PR 7c — failing-tests.md artifact + CI cache for XCC CAS** (issue: "Agent-readable CI failures")
- Files: `build.yml`, `scripts/retried_tests.py` (extend to failed tests), optional new cache entry.
- Change: per-shard artifact listing failed/retried test names + shard + first failure line (≤300 chars) — agents stop reading multi-MB xcodebuild logs; plus cache `$(HOME)/.cache/lilo/xcc` on CI with a Package.resolved-hash key so CI and local CAS shapes converge (correctness spot-check rides Stage 0 metric 6).

## Stage 4 — toolchain pinning (PR 8, issue: "Pin the package manager")

- Files: all 5 package.json + repo-root package.json (new, for corepack/CF), `.github/workflows/*` node-version alignment, `CONTRIBUTING.md`.
- Change: `packageManager` fields (exact npm version). Cloudflare Workers Builds reads the top-level package.json when root dir is a subdirectory (verified in CF docs) — this PR is also the prerequisite for Stage 5.
- Risk called out: corepack enforcement may surprise contributors with off-version npm; message from bootstrap covers it.

## Stage 5 — pnpm workspace (PR 9 + upstream discussion BEFORE the PR, per ROADMAP guidance)

**First: upstream discussion** "Adopt a pnpm workspace for the JS projects?" with the counterargument package:
- ROI (measured on this machine): node_modules 1497 MB → 979 MB across the 3 web projects (~520 MB), install 20 s warm for all three, one lockfile instead of 3, pnpm store dedups with the maintainer's other projects.
- The KISS challenge answered honestly: adds pnpm-workspace.yaml + root package.json + one tool; removes 2 lockfiles, ~8 CI cache keys collapse; Workers Builds support verified (preinstalled pnpm 9.10, Corepack, packageManager field; `pnpm install` from inside `site/` resolves the workspace root above it — verified locally; `--ignore-workspace` fails, so CF's build command must become `pnpm install --frozen-lockfile --ignore-scripts`).
- What the maintainer must own: Cloudflare dashboard change for both Workers (build command + verify first deploy), since CF config lives outside git (docs-site/README.md:39-44 documents today's config).
- Rollback story: the sites deploy independently of code merges; a failed CF build reverts by restoring the old build command; app/bridge are untouched by this stage.
- Sequencing inside the stage: (a) workspace + lockfile + Makefile + CI on the fork (`develop`) with full measurement; (b) maintainer does the CF change on a CF preview; (c) only then the upstream PR. release-media and bridge-src stay npm (separate concerns, tiny trees) unless the discussion says otherwise.

## Stage 6 — Linux development flow (PRs 10+; spike done, upstream issue #376 open)

Frame (stated in every artifact): development infrastructure, not a port — ROADMAP's "No Windows or Linux port" non-goal is about the product. Per ROADMAP process, open a discussion first (upstream issue #376).

Content:
- `docs/LINUX-AGENTS.md`: verified partition of make targets into Linux-capable / macOS-only (CI already runs release-tooling, ui, e2e, bridge on ubuntu-latest — the docs formalize what contributors' Linux agents can run).
- `make linux-checks` (or scoped equivalents) exercised in CI on ubuntu.
- **Swift-on-Linux verdict (researched, not guessed).** No toolchain compiles, links, runs and tests an AppKit/WebKit macOS app on Linux as of 2026-11. 195 of 323 app files import AppKit or WebKit; WebKit, Metal, NSXPC and IOKit do not exist on Linux; `swift build` fails on the first `import AppKit` (and `LiloMCP/main.swift` imports the Linux-nonexistent `Darwin`). Darling cannot run `xcodebuild` (open issues since 2019) and lacks the current Swift framework surface; GNUstep is not Apple's AppKit (no WebKit port, per its own docs). The two credible Apple-side builders — `xtool` 2.0 beta and `rules_applecross` — compile and bundle but **cannot execute or test**, lack Icon Composer and Metal parity, and still require an Xcode `.xip` the user licensed on a Mac. So the promise is a **split**, not a Swift-on-Linux miracle: Linux agents carry the JS/docs/site/bridge lane, the Swift lane stays on macOS.
- macOS remote story: the tailnet `quinos-mac-mini` as a self-hosted Actions runner (was unreachable at plan time), GitHub-hosted macOS runners stay primary (free/unlimited on the public repo, the 5-slot concurrency cap is the constraint, not money). `-derivedDataPath` and `-clonedSourcePackagesDirPath` are remote-side paths, so plain SSH `xcodebuild` works unchanged over a synced worktree.
- Measurement: which of `make ui-lint ui-test e2e site-check site-test docs-check docs-test ext-bridge-test` pass on Debian 13, with timings and disk; the Swift-remote latency for a worktree→macOS-runner loop.
- Watch list: `rules_applecross` — the closest existing project to building a macOS app on Linux; revisit if it gains byte-identical Metal and a run story.

## Branch & review mechanics

- Fork: `develop` = main + Stage branches merged in order; every merge runs the fork's CI (build.yml works on forks; release.yml needs secrets and simply doesn't run — fine).
- Upstream: curated PRs per stage (the ones marked "upstream" above), each linking its issue + measurement table; the discussion posts for Stage 5 and Stage 6 go up before their PRs.
- `develop` CI history is the cumulative-gains evidence; per-PR fork CI runs the same metrics so scoped gains are visible per PR.
- Every merged stage updates `docs/build-baseline.md`'s "after" column (append-only, dated sections).

## Sequencing & dependencies

```
machine cleanup + Metal toolchain   (local, no PR)
S0 metrics + baseline  ──► everything else depends on its numbers
S1 setup fixes          (independent)
S2 PR2 CAS ─► PR3 SPM dir ─► PR4 app-support-dir ─► PR5 slots (needs S0 A/B) ─► PR6 scope
S3 CI trio              (independent of S2, needs S0 CI scrape for before/after)
S4 packageManager       (independent; prerequisite for S5)
S5 pnpm workspace       (needs S4 + discussion + maintainer CF change)
S6 Linux flow           (needs the maintainer's answer on #376; independent otherwise)
```

## What is deliberately NOT in this plan

Bazel/Tuist/rules_xcodeproj (Xcode 27 unsupported; project specifics unbuilt), sccache (cannot cache Swift; disables module caching), bun migration (same Cloudflare coupling as pnpm, smaller ecosystem win), sharing DerivedData across worktrees (build.db corruption, verified by community reports), replacing GRDB's vendored SQLite (runtime behavior change), merge queue (only after S3 frees slots and >3 merges/hour is real), self-hosted macOS runner fleet (free hosted macOS on public repos; concurrency cap is the constraint), and anything that makes a `make` target depend on mise (the host tools live in `mise.toml` precisely so the required toolchain stays what the Makefile checks for; landed as 68040323 after the maintainer asked for the repo to carry them).

## Open items

1. Maintainer buy-in: upstream issues #375 (pnpm) and #376 (Linux agents) are open with no reply — they gate S5 and S6; S2-S3 PRs are safe to send without one (pure build hygiene, no ROADMAP tension).
2. This machine's disk: ~7 GB free after cleanup; still short of the ≥10 GB the S0 baseline wants (flock/rtk installs freed nothing more of size; the remaining big consumers are the repo's own builds).


