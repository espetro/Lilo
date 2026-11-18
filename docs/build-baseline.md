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

## 2026-11-18, Stage 2 PR 4: per-worktree test data

What changed: `make` exports `TEST_RUNNER_LILO_APP_SUPPORT_DIR=$(CURDIR)/.derived.noindex/test-data`, outside CI, so the test host reads `LILO_APP_SUPPORT_DIR` and its database, agent socket and downloads live in the worktree.
The plan wrote the override as a `TEST_CONFIG` argument; an `xcodebuild` argument of that form is a build setting and never reaches the host's environment, whereas `TEST_RUNNER_` variables do (the Makefile's bench targets already rely on this).

Not measured: the two concurrent `swift-test` lanes with `lsof` on the database and the socket.
`make swift-test` cannot run on this Mac (`xcodebuild` fails to load its CoreSimulator plug-in), so there was no test host to inspect.
Checked instead: with a throwaway makefile that includes the real one, a recipe sees the variable set to the worktree's folder, and sees nothing with `CI=1`.
`BuildIdentityTests` unsets and restores the override itself; its assertion on the default socket path is skipped when the process started with an override, because that URL is computed once per process.
