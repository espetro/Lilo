# Build and dev-loop baseline

Dated sections, appended per change of the [development-experience plan](DEVELOPMENT-EXPERIENCE-PLAN.md).
This branch started the file without the Stage 0 baseline; when the two merge, keep Stage 0's text and append the section below.

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
