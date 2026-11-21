# macOS VM test isolation — decision record

Question: should Lilo's AppKit tests (`make swift-test`, which opens windows and
posts synthetic events on the developer's screen) move into a headless macOS VM
(Tart) so they stop disturbing the desktop?

Answer: **not now.** The cheap fixes already in the tree beat it, and this Mac
cannot afford the image today. Revisit only if code-level fixes and a second
login session leave real disturbance. Verdict reviewed against a Gemini chat
export (/tmp/macos-vm.md); its architecture was sound, its project list
accurate, and its one apparent hallucination (`openai/tart`) turned out
correct — `cirruslabs/tart` was transferred to the `openai` org and the old
name redirects.

## Measured facts (this machine, read-only)

- Host: MacBook Air M4, 10 cores (4P+6E), 24 GB, macOS 27.2.1, Xcode 27.2.
- Free disk: **12 GiB**. The needed guest image, `ghcr.io/cirruslabs/
  macos-tahoe-xcode:27.2`, is a **65.9 GiB download expanding to a 140 GB
  uncompressed disk** (OCI manifest annotation). The base image is 25.2 GiB /
  50 GB but lacks Xcode — and `xctest` lives only inside Xcode.app, so a
  test-running guest needs Xcode either way.
- Host test payload is small: `Products/Debug` = 177 MB (`Lilo.app` 108 MB
  incl. `LiloTests.xctest` 43 MB) plus a relocatable `.xctestrun` — so the
  right flow is host `build-for-testing` + guest `test-without-building`,
  never building inside the VM.
- Tart facts verified from source/docs: `--no-graphics` keeps a guest
  WindowServer without a host window; `--dir` shares host dirs over VirtioFS;
  `tart exec` needs the guest agent (bundled in Cirrus images); `clone
  --stacked` shares a read-only base disk (macOS 27+ hosts); default VM is
  2 CPU / 4 GB; max **2 concurrent macOS VMs** (VZ-enforced; the SLA clause
  allowing two virtualized instances explicitly names "testing during
  software development"); nested virtualization is Linux-guests-only on M3+.
- Sizing for this suite: 4 vCPU / **8 GB** is the lean point — `TEST_WORKERS`
  assumes ~4 parallel test hosts spawning WebContent processes; at the chat's
  <4 GB target the guest swaps and flakes.

## What wins before the VM

1. `NSWindow.orderFrontOffscreen` (LiloTests/Support/HiddenWindow.swift) —
   landed; removes window painting at ~30 call sites. Residual visible
   windows being driven down (HoldToQuit HUD fixed in flight).
2. Second login session (dedicated test user + fast user switching + SSH):
   a real WindowServer for tests, full fidelity, zero disk, no new tooling —
   try this before a 140 GB VM.
3. `TEST_PARALLEL=NO` / `TEST_WORKERS` / `TEST_SLOTS` knobs for quiet runs.
4. The `LiloCore` SwiftPM slice (issue #130) for the ~34% AppKit-free suite —
   the biggest offload, to Linux.
5. CI macOS runners already run everything off-laptop (queue median ~2 s).

## If the VM is ever adopted

- Blocker to clear first: ~150 GB free, or `TART_HOME` on an external APFS
  volume.
- Golden image = `macos-tahoe-xcode:<matching tag>`; clone per run, run
  `--no-graphics`, copy products off the `--dir` share into the guest disk,
  `xcodebuild -xctestrun … test-without-building`, delete the clone.
- Keep perf benches (`speedometer-bench`, `page-bench`, `e2e-energy`) on the
  host/CI — the guest GPU is paravirtualized and unrepresentative.
- Proposed surface, not implemented: `make vm-prepare` (image pull + golden
  checklist), `make swift-test-vm` (build-for-testing on host, ephemeral
  clone, `test-without-building` in guest, trap-deletes the clone). It stays
  opt-in, never part of `make validate`.
