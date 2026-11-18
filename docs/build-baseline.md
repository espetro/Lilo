# Build and dev-loop baseline

Append-only "after" sections for the [development-experience plan](DEVELOPMENT-EXPERIENCE-PLAN.md).
This branch carries only its own sections: on merge with the Stage 0 branch, which creates this file with the "now" column, keep both and order the sections by date.

## After PR 7a: release-build off pull requests (2026-11-18)

Measured by reading the workflow, not by running it: a pull request now starts 3 `app` shards instead of 3 shards plus `release-build`, so it holds 3 of the 5 free macOS slots at most instead of 4.
The saved time per pull request is the `release-build` job itself, 10.8 min of macOS runner time in the baseline run `43823427506`; the makespan does not change, because that job ran beside the 5.9 to 9.5 min shards and only the `app` shards set it.
The cost is stated in the plan: a Release-only build break reaches main and surfaces there about 30 minutes after the merge instead of on the pull request.
Not measured: the real change in queueing, which needs the Stage 0 CI scrape (`make ci-metrics`) over runs made after this lands.
