# Build and dev-loop baseline

Append-only, dated sections: each change of the [development-experience plan](DEVELOPMENT-EXPERIENCE-PLAN.md) records its before and after here.
The "now" column of Stage 0 lands with its own PR; this file holds the sections of the stages merged without it.

## After Stage 1: `make bootstrap` checks before it installs (2026-11-18)

Method: the same Mac in the same state before and after, a clone with no `node_modules`, run once each with `/usr/bin/time -p`.
The machine is a deliberately broken environment without trying: the Metal toolchain is not installed and Developer mode is disabled (`DevToolsSecurity -status`).
Before is the previous `scripts/bootstrap.sh` (npm ci for the interface and the bridge, then the missing-prerequisite report); after is this branch's `make bootstrap`.

| | before | after |
|---|---|---|
| Time to the first error | 3.06 s | 0.29 s |
| Bytes installed before that error | 167,836 KB (lilo-ui 127,176 + bridge 40,660 `node_modules`) | 0 |
| Problems reported | 1 (Metal) | 2 (Metal and Developer mode) |
| Exit code | 1, for every problem | 3: a person must act (2 would mean a missing tool) |

Caveats, so the table is not read as more than it is:

- The npm cache was warm, so the 3.06 s is a lower bound; on a cold cache and a slow network the old order pays the whole download first, and the new one still answers in well under a second.
- The old script never checked Developer mode: that failure surfaces tens of minutes into `make validate` as `INTERNAL ERROR: childPID > 0`. Its cost is not measured here, only that it is now reported at the start.
- `make bootstrap` with every check green, and the build steps after it (libghostty-vt, SwiftLint, XcodeGen), were not run on this Mac: the Metal toolchain is missing, so the Apple checks cannot pass here. The install path ran through the Linux route (`LILO_UNAME=Linux make bootstrap BOOTSTRAP_ARGS=--with-sites`): it installed the four dependency trees and Changie in 31 s on a warm cache, about 1.6 GB (`site` 602 MB, `docs-site` 846 MB, `lilo-ui` 128 MB, bridge 41 MB), which is the size `make validate` would otherwise install in the middle of its run.
- `make swift-test` cannot run on this Mac (CoreSimulator plug-in and Metal toolchain missing); nothing in this stage touches Swift.
