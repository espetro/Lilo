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
