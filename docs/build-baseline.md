# Build and dev-loop baseline

Append-only "after" sections for the [development-experience plan](DEVELOPMENT-EXPERIENCE-PLAN.md).
This branch carries only its own sections: on merge with the Stage 0 branch, which creates this file with the "now" column, keep both and order the sections by date.

## After PR 7a: release-build off pull requests (2026-11-18)

Measured by reading the workflow, not by running it: a pull request now starts 3 `app` shards instead of 3 shards plus `release-build`, so it holds 3 of the 5 free macOS slots at most instead of 4.
The saved time per pull request is the `release-build` job itself, 10.8 min of macOS runner time in the baseline run `43823427506`; the makespan does not change, because that job ran beside the 5.9 to 9.5 min shards and only the `app` shards set it.
The cost is stated in the plan: a Release-only build break reaches main and surfaces there about 30 minutes after the merge instead of on the pull request.
Not measured: the real change in queueing, which needs the Stage 0 CI scrape (`make ci-metrics`) over runs made after this lands.

## After PR 7b: the gate job (2026-11-18)

No timing change: `gate` is one `ubuntu-latest` step of a few seconds that runs after every other job, so it adds seconds to the end of a run and no macOS minute.
Checked locally with actionlint and by running the gate's `case` on result lists: `success skipped` and `success success skipped` pass, `success failure` and `cancelled success` fail.
Not measured: the behaviour on a real failed run, which needs the first CI run of this branch.
The branch-protection change (require only `Gate` and Conventional Commits) is a maintainer action in the repository settings and is not part of this diff.

## After PR 7c: failing-tests.md and the XCC cache entry (2026-11-18)

Size of what an agent reads, measured on a synthetic Playwright report with one failed test and one flaky test (the shape CI writes): `failing-tests.md` is under 400 bytes for those two tests, bounded at 300 characters of failure text per test, against the multi-megabyte xcodebuild log or `.xcresult` bundle it replaces.
The real size of an xcodebuild log and result bundle was not measured here, because `xcodebuild` cannot run on this Mac.
`make retried-tests-test` covers the Xcode and Playwright parsers (10 tests, under 10 ms); the `xcresulttool` JSON shape is mocked from the tree the existing retry parser already reads, so the first CI run with a failing Swift test is the real check.
The XCC cache entry is wired but inert until the Stage 2 change points `COMPILATION_CACHE_CAS_PATH` at `~/.cache/lilo/xcc`: the path stays empty and nothing is saved.
Not measured: the CI hit rate and the CAS correctness spot-check, which ride Stage 0 metric 6 once the Stage 2 change lands.
