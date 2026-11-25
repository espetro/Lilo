# Lilo companion extension (Linux, Chromium)

A standalone Chrome Web Store-style MV3 extension that exposes a browser's agent tool surface
(tabs, page snapshot, scripting) to the Lilo agent over Chrome native messaging. It targets
Chromium on Linux, where the Safari Web Extension bridge under `Lilo/Extensions/` does not apply.

## Status (this slice)

- Message schema and validation: `src/protocol.ts` (the shared contract cases in
  `src/protocol.fixtures.json` pin the TypeScript and the Swift mirror in `Lilo/Companion/` to
  the same accepts and rejects).
- Tool implementations over `chrome.tabs` / `chrome.scripting`: `src/tools.ts`.
- Native-messaging port plumbing with reconnect: `src/nativePort.ts`.
- The native-messaging **host**: on macOS the `lilo-companion` binary (`Lilo/Companion/`), on
  Linux the shim in `packaging/linux/lilo-companion-shim.py`. Neither answers anything itself:
  both are byte pipes into the unix socket the Lilo peer listens on (`LILO_COMPANION_SOCK`, or
  `~/Library/Application Support/Lilo/companion.sock` on macOS and `$XDG_RUNTIME_DIR/lilo/companion.sock`
  on Linux), so the schema is validated only where it is spoken. The peer that consumes the tool
  surface — the running app's agent surface, or the headless container — is the next slice.

## Linux install path

`packaging/linux/` carries what a `.deb`/`.rpm` ships: the shim, the native-messaging-host
manifest template (`com.getlilo.lilo.companion.json.in`), the opt-in force-install policy
(`lilo-companion-policy.json`, self-hosted update URL), and `postinst`/`postrm` which write
and remove exactly those files under `/etc/chromium`, `/etc/opt/chrome` and `/etc/edge`.
There is no policy path on macOS or Windows — those install through the browser's own store flow.

## Build and test

```
make companion-ext-build   # tsc + esbuild into dist/
make companion-ext-test    # node --test over src/*.test.ts
```

## Loading locally

`dist/` + `manifest.json` form an unpacked extension: load it in any Chromium via
"Load unpacked". Without a native-messaging host named `com.getlilo.lilo.companion` the worker
stays dormant and retries every 5 s.
