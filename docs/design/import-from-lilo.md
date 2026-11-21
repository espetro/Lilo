# Import from existing Lilo

An onboarding option, next to the browser imports, that reads the data of an installed Lilo (the release app) into the running build (Lilo Beta, Lilo Debug), read-only. Goal: full manual QA of the beta against a copy of the owner's production setup.

## Where a Lilo's data lives

Two builds differ only in the bundle id suffix and the folder name (`BuildIdentity.swift`):

| | Lilo | Lilo Beta |
|---|---|---|
| Bundle id | `fr.arouillard.lilo` | `fr.arouillard.lilo.beta` |
| App Support | `~/Library/Application Support/Lilo` | `.../Lilo-Beta` |
| WebKit data | `~/Library/WebKit/fr.arouillard.lilo` | `~/Library/WebKit/fr.arouillard.lilo.beta` |
| Preferences | `~/Library/Preferences/fr.arouillard.lilo.plist` | `.beta.plist` |
| Keychain items | own service names | own service names |

Neither build is sandboxed (`Lilo.entitlements` has no `app-sandbox` key), so the beta can read the release app's files directly, subject to TCC (Full Disk Access covers `~/Library/Application Support` of other apps on some setups; the existing `needsFullDiskAccess` path in `BrowserImportScanner` already handles this).

Per profile, under `<App Support>/Profiles/<profile-uuid>/`:

| Category | Location | Format |
|---|---|---|
| Bookmarks, tabs, Spaces state | `lilo.db`, table `spaceTabStates` (plus `spaces`, `profiles`) | GRDB/SQLite, WAL |
| History | `lilo.db`, tables `history` / `historyVisit` | SQLite |
| Settings (global) | `global.db`, table `settings`, key-value | SQLite |
| Site permissions, zoom, downloads, windows | `lilo.db` tables `sitePermissions`, `zoomLevels`, `downloads`, `windows` | SQLite |
| Favicons | `lilo.db`, table `favicons` | SQLite |
| Installed extensions + their settings | `lilo.db` tables `installed_extensions`, `extensionSettings`; files under the profile dir | SQLite + files |
| Cookies, site storage, caches | `~/Library/WebKit/<bundle id>`, one `WKWebsiteDataStore(forIdentifier: profileId)` per profile | WebKit-owned |
| HTTP auth + saved form credentials | Keychain (see `HTTPAuthKeychain`), keyed by profile id | Keychain |

Lilo keeps no password manager of its own (`Lilo keeps no passwords itself.`): the only credentials are HTTP auth keychain items and WebKit-saved HTTP credentials, both in the login keychain under beta-specific service names.

## What can be copied safely

- **Bookmarks, Spaces and their tab trees, history, settings, site permissions, zoom levels, downloads list, favicons**: everything lives in SQLite under `~/Library/Application Support/Lilo`. Read it with the SQLite backup API (`sqlite3_backup`), or copy the file together with `-wal` and `-shm` sidecars, into a temp dir, then read the copy. Never open the source in place and never read-write: the release app may hold the WAL. The existing readers (`ChromiumReader`, `SafariReader`) already read copies; `ImportFiles.withCopy()` is the established pattern.
- **Spaces and tabs**: `spaceTabStates` rows deserialize to `SpaceTabState`/`StoredSidebarTree`, which is exactly what the import sink writes. Feasible without going through the generic `ImportedBookmark` shape, but the generic shape is already there and works.
- **Extensions**: re-install by extension id through the existing `sink.installExtension(id, profileId)` path (same as Chromium today), rather than copying extension files.

## What cannot (or should not) be copied

- **Cookies and WebKit website data**: `WKWebsiteDataStore(forIdentifier:)` reads from `~/Library/WebKit/<bundle id>`, keyed by the running app's bundle id. Copying the release store's files into the beta's WebKit folder while it is closed would likely work (same WebKit, same schema), but it is undocumented, version-fragile and writes into WebKit's own territory. Recommend v1 skips website data; the practical impact is being logged out in the beta, which for QA is acceptable and honest. Revisit only if the owner wants cookie-level parity.
- **Keychain items**: created under the release app's identity, ACL'd to its signing identity. The beta reading them is what the existing Chromium path does (`ChromiumCookieDecryptor.keychainPassword`, a user-approved prompt), but Lilo's own HTTP-auth items are per profile id, not per browser; there is nothing well-defined to copy. Skip.
- **The agent socket and any live state**: the release app may be running. Read-only file access is safe with the WAL caveat; anything else (defaults domain, WebKit dir) is off-limits while it runs.

## Read-only and locking rules

1. Locate the source by bundle id (`BrowserImportScanner.appURL(bundleId:)` already resolves sibling bundle ids including `.beta`/`.debug` suffixes) and derive `~/Library/Application Support/Lilo` from it. Never write there.
2. Read every SQLite file through `sqlite3_backup` to a temp copy (or `cp` file + `-wal` + `-shm` when the source is quiescent), read the copy, delete it. This is atomic from the reader's view even while prod runs.
3. Check `isDenied()` (already in `BrowserImportScanner`) and surface the Full Disk Access card like other browsers do.
4. Never set the release app's defaults, never touch its WebKit directory, never delete anything.

## Where it plugs in

The pipeline is source-agnostic: `ImportSource`/`ImportProfile` + `ImportKind`, read into an `ImportBundle` by a family, written by `BrowserImporter` through the `Sink`. A Lilo source is:

- a new family `.lilo` (or reuse `.chromium`-style dispatch) with a `LiloReader` that produces `ImportBundle` from the backed-up `lilo.db`/`global.db`: bookmarks/tabs/spaces from `spaceTabStates` and `spaces`, history from `historyVisit`, extensions from `installed_extensions`.
- `BrowserImportScanner.scan` gains one entry: if another Lilo's support folder exists and this build is not the release app (`BuildIdentity.appIdentifier != "fr.arouillard.lilo"`), offer source `("lilo", "Lilo", ...)`. Its `ImportProfile`s come from the `profiles` table. Show `needsFullDiskAccess` when `isDenied`.
- Settings: today import lives only in onboarding (`OnboardingImport.svelte` over `scanImportSources`/`runImport`); a Lilo source appears there automatically with no UI change beyond the source card, which comes from the scan. If a Settings surface is wanted later, it reuses the same components.

## UX

- Onboarding import step: a "Lilo" card appears only when the scan finds another Lilo install (data folder exists and bundle id differs). Same card grid, same kind toggles (Bookmarks, Tabs, History, Extensions; no cookies/password rows for this source).
- During import: no Keychain prompt (no cookie decryption), so the keychain note does not apply.
- Settings > Import: not present today in Settings; if added, the same scan feeds it.

## Recommendation and slicing

Ship it as the generic pipeline extension above, in small PRs:

1. **PR 1 - spike landed here**: `LiloSiblingLocator` - find a sibling Lilo install's App Support directory by bundle id, pure-path function, unit-tested against a temp fixture. No writes to real user dirs.
2. **PR 2 - `LiloReader`**: open a *copy* of a source `lilo.db`/`global.db` and produce an `ImportBundle`. Tests with fixture databases built by the test itself (create schema via GRDB in a temp dir), never a real user's data.
3. **PR 3 - scanner entry + onboarding card**: `scan()` offers "Lilo" when a sibling exists and this build is not the release app; locale keys for all catalogs.
4. **PR 4 (optional)**: settings copy across (a curated allowlist of keys, not blind copy), extension re-install ordering/pins.

Tests stay in `LiloTests/Import/`, mirroring source paths, using temp fixtures only.

## Open questions for the owner

1. Should settings carry over wholesale, or only a curated set (theme, search engines, link rules)? Blind copy risks importing flags the beta does not know.
2. Are cookies worth the risk (copying the WebKit store while prod is closed), or is being logged out in the beta acceptable for QA?
3. Should the release Lilo also offer this import (import from beta), or stay one-way (beta reads prod)?
4. Is History wanted in full (it can be hundreds of thousands of visits), or capped to a recent window?
5. Multiple profiles in prod: import all, or pick one at scan time (the pipeline supports profiles already)?
6. Re-import behavior: the dedup in `BrowserImporter` handles re-runs; is "reset beta data and re-import" wanted as an explicit action?
