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
# Build and dev-loop baseline

Dated measurements of the [development-experience plan](DEVELOPMENT-EXPERIENCE-PLAN.md), appended section by section.
A number marked "not measured" was not measured: the reason is given, and nothing is estimated in its place.

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
