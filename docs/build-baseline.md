# Build and dev-loop baseline

The "now" column every later change of the [development-experience plan](DEVELOPMENT-EXPERIENCE-PLAN.md) is measured against.
Measured on 2026-11-18 at the commit this file lands in, with the tools of this repository: `make metrics-on` for the local numbers, `make ci-metrics` for CI.
A number marked "not measured" was not measured: the reason is given, and nothing is estimated in its place.

## Conditions

| | |
|---|---|
| Machine | Apple silicon Mac, 4 performance cores, 24 GB RAM, 1-minute load average 11 to 25 during the runs (other agent sessions were using it) |
| Xcode | 27.2, but its simulator plug-in cannot load (see "What this Mac could not measure") |
| Metal toolchain | not installed |
| Node.js | 22.23.4 through `mise exec` |
| Disk | more than 350 GB free |
| Heavy commands | each run under `scripts/lockf.py /tmp/tsc.lock`, one at a time |

The machine was never idle, so every duration below is a loaded-machine figure and is an upper bound for a quiet one.
Each record carries `loadavg1` so a later comparison can tell a slow run from a busy machine.

## What this Mac could not measure

Two things stop every `xcodebuild` here, which is why no Swift number appears in this file.

- `xcrun metal --version` fails: the Metal toolchain is not installed. `xcodebuild -downloadComponent MetalToolchain` is an Apple-ID download of several GB; it was not attempted.
- `xcodebuild` itself fails with `xcodebuild failed to load a required plug-in` (`CoreSimulator.framework` is missing under `/Library/Developer/PrivateFrameworks`). The fix is `sudo xcodebuild -runFirstLaunch`, and sudo needs a password.

So `make validate` stops at `test-build` (exit 70, about 1 to 2 s in) and this file reports the part of `make validate` that runs without Swift.
`make app`, `make swift-test` and the lock wait of a real test run are not measured.

## 1. Fresh clone to ready

| Step | Result |
|---|---|
| `git clone` of the public repository | 6.3 s, 157 MB on disk |
| `git worktree add` | 0.23 s, 56 MB on disk |
| `make bootstrap`, npm part (`lilo-ui` and the bridge) | 28 s, then it exits 1 at the missing Metal toolchain (the order bug Stage 1 fixes: it installed first, reported second) |
| `make vt-build` (prebuilt libghostty-vt, checksum-pinned) | 2 s |
| Cold `ui-build`, `ext-bridge-build` | 7.2 s, 8.3 s |
| Cold dependency installs the first `make validate` ran: `lilo-ui`, `site`, `docs-site` | 27 s, 12.7 s, 10.5 s |
| Cold `make app` (Debug) | not measured (Metal toolchain, Xcode plug-in) |

## 2. Warm `make validate`, without the Swift lane

Three runs in a row after the first run had installed everything, each under the lock, the machine at a load of 16 to 17.
Every run ended at `test-build` (exit 2 from make), so none is a green validate.

| Run | Wall time |
|---|---|
| 1 | 24 s |
| 2 | 26 s |
| 3 | 28 s |
| median | 26 s |

An earlier series of three runs, with the machine busier (load 14 to 20), took 30, 32 and 37 s.
The spread between the two series, 26 against 32 s, is the machine's load and not the code.
A green warm `make validate` includes Swift (a Debug build and the test run, behind the machine-wide test lock) and is not measured here.

Where the non-Swift wall time goes, median of the three runs of the second series (lanes run in parallel, so the rows do not add up):

| Target | Median seconds |
|---|---|
| `site-check` | 20.2 |
| `ui-lint` | 11.4 |
| `docs-build` | 8.8 |
| `ui-test` | 7.4 |
| `lockf-test` | 6.0 |
| `docs-check` | 5.5 |
| `hooks-test` | 4.4 |
| `site-generate` | 3.5 |
| `docs-test` | 3.4 |
| `ext-bridge-test` | 3.1 |
| `site-test` | 2.1 |
| `swiftlint` | 0.2 |
| `release-status` | 0.1 |

`hooks-install` shows failed runs in the summary (6 of 12): `hooks-test` runs it in throwaway repositories on purpose, to check it refuses to overwrite a hook.
They are expected exits, not failures of the build.

## 3. Lock wait

The Swift test lock is `lockf -k $TMPDIR/lilo-swift-test.lock` (Makefile:83).
Isolation test of the lock alone, with a stand-in holder, because `make swift-test` cannot run here:

| Case | Result |
|---|---|
| Uncontended `lockf -k LOCK true`, 5 runs | 7 to 11 ms |
| Uncontended `scripts/lockf.py LOCK true`, 5 runs | 16 to 34 ms (a Python start) |
| Holder takes the lock for 10 s, a second caller starts at +2 s | the second caller waited 8.01 s, then ran |

So the wait is the holder's remaining time, with no polling overhead: a queue behind a real `swift-test` waits for what that run has left.
The wait inside `make swift-test` is not measured; with the metrics hook on it is part of the `swift-test` record's duration, and `concurrent` (recipes running in other worktrees when a record is written) says whether someone else held it.

## 4. Disk and memory footprint of one worktree

`df` deltas, because `du` lies on APFS clones.

| After | Free space change |
|---|---|
| `make bootstrap` (npm for `lilo-ui` and the bridge) and `make vt-build` | -0.4 GB |
| the first `make validate` (site and docs dependencies, UI and bridge builds, tool downloads) | -2.7 GB more |

`du` of the worktree afterwards: 1.8 GB (`docs-site/node_modules` 836 MB, `site/node_modules` 617 MB, `lilo-ui/node_modules` 136 MB, `build/` 50 MB, bridge `node_modules` 41 MB).
The Debug build products (about 2.3 GB per worktree by the plan's earlier measurement) are not in these figures.

One `make validate` run, measured with `/usr/bin/time -l`: 28.6 s wall, largest single process 1.2 GB resident (1.3 GB peak footprint).
That is the largest process, not the sum over the run.

## 5. CI, last 20 runs of the `CI` workflow on `main` (push)

`make ci-metrics`, public API, 2026-11-18, the 20 latest completed runs.

| Metric | Value |
|---|---|
| Runs | 20: 2 failed, 7 cancelled (a newer push replaced them), 0 re-run |
| Time to first signal | median 0.2 min, p95 1.6 min |
| Makespan, runs that finished | median 13.9 min, p95 21.2 min |
| Queue before a job starts | median 2 s, p95 150 s |
| macOS slot-minutes per run | median 35.7, p95 43.3 |
| Maximum concurrent macOS jobs | 4 of the 5 free slots |
| Skipped jobs | 2% of jobs |
| Failed jobs | across the 2 failed runs: each Swift shard 2, the release build 2, the UI job 2, release tooling 1; the failures are whole-run, not one flaky job |

Job durations (median, p95):

| Job | Median | p95 |
|---|---|---|
| Release Build (macOS) | 12.5 min | 17.9 min |
| App Validate + Swift Tests (macOS, 3/3) | 7.5 min | 9.2 min |
| App Validate + Swift Tests (macOS, 2/3) | 6.9 min | 8.8 min |
| App Validate + Swift Tests (macOS, 1/3) | 5.1 min | 8.0 min |
| UI end-to-end, 3 shards | 2.2 to 2.5 min | 2.6 to 3.1 min |
| Release tooling and website | 1.3 min | 1.8 min |
| UI (lint, test, build) | 0.7 min | 0.8 min |
| Extension Bridge Tests | 0.3 min | 0.4 min |
| Changed files | 0.1 min | 0.2 min |

Inside the Swift shards, the `make swift-test` step takes a median of 4.0, 5.2 and 4.7 min for shards 1 to 3, the UI build 0.7 to 0.8 min, and the cache restore 0.3 to 0.5 min.
`make swift-test-slow` (shard 3 only) adds 1.3 min; `make release-archive` is 10.1 min of the release build.
The API gives a step's duration but not the build against test split inside `make swift-test`, nor the lock wait; getting that needs a change in the recipe or the workflow, which this stage leaves for the stage that changes them.

Pull-request runs: not measured. The unauthenticated API allows 60 requests an hour, the first scrape and its development used them, and this Mac's `gh` login is invalid.

Cache hit rate: not measured. The restore and save steps' durations are in the scrape, but whether a restore hit is only in the step logs, which the API serves to signed-in users only.

## 6. Flake counts

Not measured. Counting tests that passed only on a retry means reading each run's log (`gh run view ID --log | grep -A5 "passed only on a retry"`), and logs need a signed-in `gh`, which this Mac does not have.
What the public API does give: 0 of the last 20 runs were re-run (attempt above 1), and 2 of 20 failed.
Re-run counts understate flakes, because `TEST_RETRY` retries a failed test inside the job.

## 7. Three-worktree concurrency trial

Not measured. The host rule runs heavy commands one at a time because they starve memory, the machine was already at a load of 11 to 25 from other sessions, and the lane that contends (the Swift tests) cannot run here.
A JavaScript-only trial would measure something the plan does not ask about.

## The check tiers and the rule that keeps or drops a check

The tiers are `make check` (in session, under 10 s), the pre-commit hook (under 15 s), the pre-push hook (`make validate-scope`, about 30 s warm) and CI ([CONTRIBUTING.md](../CONTRIBUTING.md#tests-and-validation)). Their first measurement, 2026-11-19, median of 3 runs, the machine at a load of 21 to 28:

| Diff | `make check` | pre-commit | pre-push (`validate-scope`, no lock wait) | Bytes printed by `make check` |
|---|---|---|---|---|
| docs only | 2.7 s | 0.7 s | 0.5 s | 67 |
| UI only, one file with a test | 5.1 s | 5.3 s | 21.4 s | 61 |
| Swift only, one file | 0.7 s | 0.7 s | not run: Swift is code, so the full `validate` | 70 |

No tier is judged by this table: it is a first reading on a loaded machine. The judgment waits for the baseline week.

**The baseline week.** Run `make metrics-on`, install the hooks with `make hooks-install`, work as usual for a week (or 30 runs of a check, whichever is longer), then read the records:

```
make metrics SINCE=7
# per tier: checks run, how many failed, and the median duration of a failing check (the time until that tier showed a problem)
jq -rs '[.[]|select(.phase=="check" and .tier)] | group_by(.tier)[] | {tier:.[0].tier, runs:length, failed:(map(select(.exit!=0))|length), first_signal_s:(map(select(.exit!=0).dur_s)|sort|.[length/2|floor])} | "\(.tier) checks=\(.runs) failed=\(.failed) median_failing_s=\(.first_signal_s)"' ~/.cache/lilo/metrics.jsonl
```

Group by `.target` too to read one check. A `rerun_of` field marks a check run again after a failure: the reruns per change.

**Keep or drop a check**, by its record over at least 30 runs or 4 weeks:

- Keep it if it catches at least 1 real failure per 50 runs that nothing earlier catches.
- Move it up a tier if it takes under 5 s.
- Demote it if it takes over 10 % of its tier's budget and under 2 % of its failures escape to the next tier.
- Drop it after 90 days with no catch and no overlap. Generated-file sync checks are excepted.

The numbers behind the rule: time to first signal, CI failures a local tier would have caught, check-output tokens per agent turn (the bytes printed), reruns per change and CI minutes per PR.

## The recorder

`make metrics-on` adds a block to the git-ignored `Makefile.local` that points `SHELL` at `scripts/metrics.py`; `make metrics-off` removes it, and `make metrics` summarizes.
Each recipe line then appends one JSON line to `~/.cache/lilo/metrics.jsonl` (`LILO_METRICS_FILE` moves it).
Nothing leaves the machine.

| Field | Meaning |
|---|---|
| `ts`, `dur_s` | start (epoch seconds) and wall duration of the recipe line |
| `target`, `level` | the make target, and how many `$(MAKE)` levels deep (a level-0 target contains the ones it runs through `$(MAKE)`) |
| `phase` | `recipe`, `orphaned` (killed outright, recorded by the next run) or `calibration` |
| `exit` | the exit status; 128 plus the signal for an interrupt (130, 143); `null` for an orphan |
| `worktree`, `branch`, `sha`, `dirty` | where it ran; `dirty` is whether tracked files differed from HEAD when the make run began |
| `cpus_perf`, `ram_gb` | performance cores and memory, read once per machine |
| `loadavg1`, `disk_free_gb` | machine load and free disk when the recipe ended |
| `concurrent` | recipes running in other worktrees when it ended |
| `agent`, `pid` | `LILO_AGENT`, or `claude-code` when `CLAUDECODE` is set; the wrapper's pid |
| `overhead_ms` | what building and writing this record cost |

Overhead: `python3 scripts/metrics.py calibrate` builds and writes 20 records and fails above 30 ms; here the median is 0.1 ms and the worst, the first record of a run, 13.7 ms.
Over the 66 records of one `make validate` run the median `overhead_ms` was 1.3 ms and the largest 14.6 ms.
The wrapper process as a whole, interpreter start included, costs about 27 ms per recipe line against 3 ms for plain `bash`; the first line of a make run pays one git process (about 15 ms) for `dirty`, the others read it from a file.

Limits: a recipe killed with SIGKILL cannot write its own line, so the next recorded run writes it as `orphaned` (with the time until then as its duration); only recipe lines are timed, so time make spends outside them (parsing, prerequisite checks) is not.

## Guardrails

- No timing metric gates CI or a merge.
- Read the numbers weekly, as a human; there is no dashboard and no per-agent ranking.
- A failure count is always read beside the timing it belongs to: a median over successes alone flatters.
- Every change that claims a speed-up ships a one-paragraph measurement verdict against this file.

## Reproduce

```
make metrics-on                          # then use make as usual
make metrics SINCE=7                     # summary of the last 7 days
python3 scripts/metrics.py calibrate     # the cost of a record
make ci-metrics RUNS=20                  # CI, the last 20 runs of build.yml on main
make metrics-off
```

## 2026-11-18, Stage 2 PR 2: shared compilation cache

What changed: make-driven `xcodebuild` runs and `scripts/build-app.sh` set `COMPILATION_CACHE_ENABLE_CACHING=YES`, `COMPILATION_CACHE_CAS_PATH=~/.cache/lilo/xcc`, `COMPILATION_CACHE_LIMIT_SIZE` and `COMPILER_INDEX_STORE_ENABLE=NO`.

Not measured on this Mac.
`xcodebuild` fails here before any build starts (`failed to load a required plug-in`: `CoreSimulator.framework` is missing, and `sudo xcodebuild -runFirstLaunch` needs a password), so the fresh-derived-data cold and warm builds could not run.
The figures that motivate the change come from the plan's earlier run on another Mac, not from this one: a fresh derived data path built in about 28 s with a cold cache and about 17 s with a warm shared cache (median of 4), and 43 s for the first worktree that populates it.
The A/B script is `/tmp`-only and trivial to redo: `rm -rf .derived.noindex/xcode; make xcode-build XCC_SETTINGS=` (no cache), then twice with `XCC_DIR=<empty dir>` (cold, warm).

Checked instead: the four settings exist in this Xcode's build service (`SWBCore`), and `SWIFT_ENABLE_EXPLICIT_MODULES=YES`, which compilation caching requires, is already set by the project.
Not verified: the unit of `COMPILATION_CACHE_LIMIT_SIZE`.
The Xcode specs do not document it; the Makefile passes bytes (10 GB).
If it were megabytes, the cap would simply never trigger, which fails safe, and `XCC_LIMIT` overrides it.

## 2026-11-18, Stage 2 PR 3: shared Swift package checkouts

What changed: make-driven `xcodebuild` runs and `scripts/build-app.sh` pass `-clonedSourcePackagesDirPath ~/.cache/lilo/spm-<sha256 of Package.resolved> -onlyUsePackageVersionsFromResolvedFile`.
CI is untouched: it keeps its cached `.derived.noindex/xcode/SourcePackages`.

Measured (the package resolution step, which does not need the broken `xcodebuild` plug-in): resolving the pinned GRDB.swift 7.11.1 and Sparkle 2.10.0 with `swift package --scratch-path <empty dir> resolve --only-use-versions-from-resolved-file`.

| | Result |
|---|---|
| Disk per fresh derived data path today | 481 MB (checkouts 178 MB, git repositories 277 MB, Sparkle binary artifact 27 MB) |
| Network clone and download per fresh derived data path | 44 s on this connection |
| After the change, first worktree on a given pin | the same 481 MB and 44 s, once |
| After the change, every other worktree on that pin | 0 MB and no clone |

The whole build with a fresh derived data path was not timed, for the reason in the section above.
The folder name carries the hash, so two worktrees on different pins can never read each other's checkouts.
Known limits: the Xcode IDE keeps its own copy; XcodeGen cannot express the flag, so it stays on the invocation lines; a pin change needs `Package.resolved` updated first, since the flag refuses to resolve anything else; `scripts/ext-smoke.mjs`, `scripts/ext-e2e-passwords.mjs` and the `bench_*` and `energy_*` scripts keep their own invocations and are not changed.

## 2026-11-18, Stage 2 PR 4: per-worktree test data

What changed: `make` exports `TEST_RUNNER_LILO_APP_SUPPORT_DIR=$(CURDIR)/.derived.noindex/test-data`, outside CI, so the test host reads `LILO_APP_SUPPORT_DIR` and its database, agent socket and downloads live in the worktree.
The plan wrote the override as a `TEST_CONFIG` argument; an `xcodebuild` argument of that form is a build setting and never reaches the host's environment, whereas `TEST_RUNNER_` variables do (the Makefile's bench targets already rely on this).

Not measured: the two concurrent `swift-test` lanes with `lsof` on the database and the socket.
`make swift-test` cannot run on this Mac (`xcodebuild` fails to load its CoreSimulator plug-in), so there was no test host to inspect.
Checked instead: with a throwaway makefile that includes the real one, a recipe sees the variable set to the worktree's folder, and sees nothing with `CI=1`.
`BuildIdentityTests` unsets and restores the override itself; its assertion on the default socket path is skipped when the process started with an override, because that URL is computed once per process.

## 2026-11-18, Stage 2 PR 5: test slot locks

What changed: the machine-global test lock is now `scripts/test_slot.sh`, which holds one of `TEST_SLOTS` locks (`lilo-swift-test.lock`, `lilo-swift-test-2.lock`, and so on).
`TEST_SLOTS` defaults to 1, where the script runs exactly `lockf -k lilo-swift-test.lock <command>` as before: same lock file, same waiting, same 4 workers on this Mac.
Only a `TEST_SLOTS := 2` in `Makefile.local` changes anything: two runs go at once, `TEST_WORKERS` halves, and `ext-smoke` and `ext-e2e-passwords` take every slot, so they still run alone.
`make slot-test` (also in `make validate`) checks it with stub commands in about 3 s: the exit code comes through, the first slot is the old lock file, three runs overlap two at a time at most, a command exiting 75 (lockf's "slot taken") is not mistaken for a taken slot, and `--all` and a lane exclude each other.

Not measured, and a prerequisite: the runningboardd A/B (`log stream --predicate 'sender == "runningboardd"'` during one solo run, then two slot-locked runs at `TEST_WORKERS=2`, plus the pre-retry failure rate staying flat).
It needs a test host, and `make swift-test` cannot run on this Mac (`xcodebuild` fails to load its CoreSimulator plug-in; the Metal toolchain is missing too).
The plan's expected throughput gain at two lanes (about 1.7x) is therefore unmeasured here and not promised: on 8 GB the lanes may be RAM-bound.
Nobody should raise `TEST_SLOTS`, and the change should not go upstream, before that A/B has been run on a Mac that can run the tests and its result is appended here.

## 2026-11-18, Stage 2 PR 6: scoped validation

What changed: `make validate-scope` runs `scripts/scope_checks.sh`, which maps the diff against `origin/main` (merge base, work tree and new files included) to check targets, then runs only those.
The code split is the one of CI's `changes` job; `make scope-test` (also in `make validate`) reads the regex out of `build.yml` and fails if the two disagree.
A diff of `lilo-ui/` alone runs `ui-lint ui-test`; of the website, `site-check site-test`; of `docs-site/`, `docs-check docs-test`; of `docs/`, other Markdown and release notes, `release-status` only.
A change to the docs reference generator's input paths in `lilo-ui/` (the settings model, the `en` and `fr` catalogs) adds `docs-check docs-test`.
Everything else, including `COMPATIBILITY.md`, an empty diff and a base git cannot read, is `make validate`, as in CI.
Because each check depends only on its own `node_modules`, a scoped run installs only those; `make validate` always installs all four.
Deviation from the plan: no `GROUPS` variable in the Makefile, since the script prints the targets and the existing prerequisites do the pruning.

Measured on a fresh worktree (nothing installed), wall time and `df` delta of the run from `npm ci` to the end, Node 22.23.4 through `mise exec`:

| Synthetic diff | Runs | Wall | Installed (`df` delta, `node_modules` alone) |
|---|---|---|---|
| UI only | `ui-lint ui-test` | 15 s | 287 MB (132 MB) |
| `docs-site/` only | `docs-check docs-test` | 19 s | 1083 MB (828 MB) |
| Website only | `site-check site-test` | 25 s | 1034 MB (584 MB) |
| Swift only | `make validate` | not measured | the four trees below, 1.58 GB |
| Today, any diff | `make validate` | not measured | 1.58 GB: `lilo-ui` 132 MB, bridge 40 MB, `site` 584 MB, `docs-site` 828 MB |

The bridge tests alone took 3 s and 92 MB (`df`).
The JS groups of `make validate` run one after another cold would take about 62 s (15 + 19 + 25 + 3); that sum leaves out the Swift lint, the app build and the Swift tests, which could not run here (`xcodebuild` fails to load its CoreSimulator plug-in), so the full validate wall time and the speed-up of a scoped run over it are not measured.
For a Swift-only diff the scope is `full` by design: no saving, and no risk.
Dry runs (`make -n validate-scope BASE=<commit>` in a throwaway clone with a synthetic commit) show the install lines each diff triggers: UI only, `npm --prefix lilo-ui ci` and nothing else; `docs-site/` only, `npm --prefix docs-site ci --ignore-scripts` and nothing else; Swift only, all four trees and `xcodebuild`.
Side finding: with the machine's default Node 26.13.1, `make ui-test` aborts (`Abort trap: 6`, no output) on an untouched tree; `mise exec -- make ...` uses the pinned 22.23.4 and passes (654/654).
Measured by reading the workflow, not by running it: a pull request now starts 3 `app` shards instead of 3 shards plus `release-build`, so it holds 3 of the 5 free macOS slots at most instead of 4.
The saved time per pull request is the `release-build` job itself, 10.8 min of macOS runner time in the baseline run `43823427506`; the makespan does not change, because that job ran beside the 5.9 to 9.5 min shards and only the `app` shards set it.
The cost is stated in the plan: a Release-only build break reaches main and surfaces there about 30 minutes after the merge instead of on the pull request.
Not measured: the real change in queueing, which needs the Stage 0 CI scrape (`make ci-metrics`) over runs made after this lands.

## After PR 7b: the gate job (2026-11-18)

No timing change: `gate` is one `ubuntu-latest` step of a few seconds that runs after every other job, so it adds seconds to the end of a run and no macOS minute.
Checked locally with actionlint and by running the gate's `case` on result lists: `success skipped` and `success success skipped` pass, `success failure` and `cancelled success` fail.
Not measured: the behaviour on a real failed run, which needs the first CI run of this branch.
The branch-protection change (require only `Gate` and Conventional Commits) is a maintainer action in the repository settings and is not part of this diff.

## After: pnpm workspace for lilo-ui, site and docs-site (2026-11-18)

Change: one pnpm workspace and one `pnpm-lock.yaml` replace three `package-lock.json` files; `make` installs each project alone with `pnpm install --frozen-lockfile --ignore-scripts --filter ./<project>...`; CI drops its ten npm and `node_modules` caches for the one the bridge keeps.
Conditions: Apple M1 with 8 GB of RAM, load average high from other sessions, Node.js 22.23.4, npm 10.9.9 against pnpm 12.16.1, APFS.
Disk is the change in `df` of the data volume (store and cache growth included), not `du`, because pnpm clones files that `du` counts again.

| Measurement | npm, three projects | pnpm workspace |
|---|---|---|
| install of the three, warm package cache or store (a second worktree) | 10 s | 1 s |
| the same, disk added | 1.54 GB | 20 MB |
| install of the three, cold cache or store | 51 s | 20 s |
| the same, disk added (cache or store included) | 1.99 GB | 1.09 GB (the default store already held part of the packages) |
| `node_modules` by `du`, three projects | 1.57 GB | 1.1 GB (clones counted in full) |
| lockfiles | 3, 24814 lines | 1, 11805 lines |
| CI cache steps for npm packages and `node_modules` | 10 | 1 (the bridge's) |

Cold install of one project through the Makefile's filter, from an empty store and the registry, which is what a CI job without a cache pays: `lilo-ui` 3 s, `site` 10 s, `docs-site` 12 s.
A bare `pnpm install` from `docs-site/`, as Cloudflare's build command runs it, installs all three projects.

What the move changed besides size:

- The lockfile was resolved afresh: 94 of the 1078 package names differ from the three npm lockfiles in at least one resolved version (transitive patch and minor releases such as `@rolldown/binding-*` 1.2.x to 1.3.2). The three direct-dependency sets are the exact pins of the `package.json` files, unchanged.
- The `undici` override moved from `site/package.json` to `pnpm-workspace.yaml` and covers the three projects.
- Dependabot's `/` entry replaces the `/lilo-ui` and `/site` ones and also covers `docs-site`, which it did not.
- The release capture's source digest hashes `pnpm-lock.yaml` instead of `site/package-lock.json`, so archived captures read as stale once.

Verified here: `make ui-lint ui-test site-check site-test docs-check docs-test` (654 UI tests, 86 site tests, 47 docs tests), `make release-test release-media-test site-deploy-check docs-deploy-check ui-build` and `actionlint`, each from an empty `node_modules`.
Not measured: the CI jobs on GitHub-hosted runners (they need a push) and the Cloudflare build (the maintainer's dashboard change comes first).

## After: Linux development flow (2026-11-18)

Change: `make swiftlint` downloads the Linux binary on Linux, `make linux-checks` runs everything `validate` runs except the Xcode build and the Swift tests, and CI's `release-tooling` job also runs `swiftlint`.
Conditions: Apple M1 with 8 GB of RAM, load average 11 to 13 from other sessions, each run under `scripts/lockf.py /tmp/tsc.lock`; the Linux checks on a Debian 13 box with 6 cores and 11 GB of RAM.
The per-target table is in [LINUX-AGENTS.md](LINUX-AGENTS.md#measurements).

| Measurement | Result |
|---|---|
| `make swiftlint` on macOS, empty `build/` (download, checksum, lint of 321 files) | 0 violations, about 9 s |
| `make swiftlint` on Debian 13, empty `build/` | 0 violations, about 9 s, static binary, two SourceKit rules skipped with a warning |
| dynamic Linux binary with no Swift toolchain | crashes (`Loading libsourcekitdInProc.so failed`), so the static binary is the default |
| unsupported platform (`linux` and `arm64`) | stops with `Unsupported SwiftLint platform: linux arm64` |
| `make linux-checks` on this Mac, warm dependencies | passes, 77 s in one run (49 s the targets one by one) |
| the 12 targets of `linux-checks` on Debian 13 | not measured: the spike recorded pass counts, not timings, and no new full Linux run was made |
| `make validate` on this Mac | not run: `make swift-test` cannot run here (CoreSimulator plug-in and Metal toolchain missing) |
| the CI `swiftlint` step on `ubuntu-latest` | not measured: it needs a push that triggers the workflow |
| worktree to macOS runner latency | not measured: no Mac was reachable |

## After PR 7c: failing-tests.md and the XCC cache entry (2026-11-18)

Size of what an agent reads, measured on a synthetic Playwright report with one failed test and one flaky test (the shape CI writes): `failing-tests.md` is under 400 bytes for those two tests, bounded at 300 characters of failure text per test, against the multi-megabyte xcodebuild log or `.xcresult` bundle it replaces.
The real size of an xcodebuild log and result bundle was not measured here, because `xcodebuild` cannot run on this Mac.
`make retried-tests-test` covers the Xcode and Playwright parsers (10 tests, under 10 ms); the `xcresulttool` JSON shape is mocked from the tree the existing retry parser already reads, so the first CI run with a failing Swift test is the real check.
The XCC cache entry is wired but inert until the Stage 2 change points `COMPILATION_CACHE_CAS_PATH` at `~/.cache/lilo/xcc`: the path stays empty and nothing is saved.
Not measured: the CI hit rate and the CAS correctness spot-check, which ride Stage 0 metric 6 once the Stage 2 change lands.
