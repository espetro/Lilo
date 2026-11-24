# Lilo companion extension (Linux, Chromium)

A standalone Chrome Web Store-style MV3 extension that exposes a browser's agent tool surface
(tabs, page snapshot, scripting) to the Lilo agent over Chrome native messaging. It targets
Chromium on Linux, where the Safari Web Extension bridge under `Lilo/Extensions/` does not apply.

## Status (this slice)

- Message schema and validation: `src/protocol.ts`
- Tool implementations over `chrome.tabs` / `chrome.scripting`: `src/tools.ts`
- Native-messaging port plumbing with reconnect: `src/nativePort.ts`

The native-messaging **host** (the Lilo app or headless container side) and the **Linux install
path** (policy JSON, `.deb`/`.rpm` postinst, `native-messaging-hosts` manifests) are later slices.

## Build and test

```
make companion-ext-build   # tsc + esbuild into dist/
make companion-ext-test    # node --test over src/*.test.ts
```

## Loading locally

`dist/` + `manifest.json` form an unpacked extension: load it in any Chromium via
"Load unpacked". Without a native-messaging host named `com.getlilo.lilo.companion` the worker
stays dormant and retries every 5 s.
