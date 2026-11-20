# Fork beta

A beta of the espetro/Lilo fork, built from its `develop` branch so that its changes can be used before upstream reviews them.
It exists only on the fork and is never sent upstream: nothing in it, the `fork:` commits included, belongs in a pull request to Alexays/Lilo.

## What it is

[`.github/workflows/beta.yml`](../.github/workflows/beta.yml) runs on every push to `develop`, and by hand from the Actions tab (workflow_dispatch), and only in espetro/Lilo.
It builds the Release configuration with `LILO_BETA=1`, packages it with `make dmg` (a zip of the app if dmgbuild fails), and publishes a new GitHub prerelease tagged `beta-N`, where N is the workflow run number: it only grows, so every build stays addressable and none is overwritten. The newest 10 are kept.
The release notes carry the commit SHA and the build date.
The tag is `beta-N`, never `v*`, so the upstream release workflow, which also checks the repository, can never fire on it.

Download `Lilo-Beta.dmg` (or `Lilo-Beta.zip`) from the newest [`beta-N` release](https://github.com/espetro/Lilo/releases) (the list is ordered by date).

## Unsigned

The build is ad-hoc signed: no Developer ID, no notarization, no secret.
macOS refuses it on first launch.
Either right-click `Lilo Beta.app` and choose Open (on macOS 15 and later, then Open Anyway in System Settings, Privacy & Security), or remove the quarantine flag:

```
xattr -dr com.apple.quarantine "/Applications/Lilo Beta.app"
```

Because the signature is ad-hoc, macOS may ask again for camera, microphone and keychain access after each update.

## Its own identity

The beta never shares anything with an installed Lilo:

| | Lilo | Lilo Beta |
|---|---|---|
| App | `Lilo.app` | `Lilo Beta.app` |
| Bundle id | `fr.arouillard.lilo` | `fr.arouillard.lilo.beta` |
| Data folder | `~/Library/Application Support/Lilo` | `~/Library/Application Support/Lilo-Beta` |
| Power helper daemon | `fr.arouillard.lilo.power` | `fr.arouillard.lilo.beta.power` |

The agent socket, the keychain items and the preferences follow the same identity (`BuildIdentity.swift`).
Both can run side by side, and `Lilo Beta.app` can sit next to `Lilo.app` in `/Applications`.
Both still offer to be the default browser: pick one.

It cannot update itself through Sparkle: the build has no Sparkle public key, so no update check starts and no appcast is read.
Instead, `BetaUpdateChecker` reads the fork's GitHub releases list once on launch (the URL lives in `LILOBetaUpdateFeedURL`, set by `scripts/build-app.sh` only when `LILO_BETA=1`) and compares the newest `beta-N` tag with the one the workflow stamped into this build (`LILOBetaTag`; an unstamped local build keeps the tag its first check saw).
When a newer one exists, Settings > Advanced shows a row that opens its release page; the download and install stay manual.
To find which build has a bug, try the previous N.

## How it is built

`scripts/build-app.sh` builds the beta when `LILO_BETA=1` is set (the workflow sets it).
That sets the `.beta` bundle id suffix, the name `Lilo Beta`, an empty `SPARKLE_PUBLIC_ED_KEY`, the `BETA` Swift condition `BuildIdentity` reads, and no hardened runtime, whose library validation rejects the ad-hoc signed Sparkle framework.
A step of the workflow checks those results in the built app and fails the run before anything is published.

To try it locally (this builds, it does not install or launch anything):

```
LILO_BETA=1 make release-archive
```

`workflow_dispatch` is only listed by GitHub once the workflow file is on the default branch; until then the push to `develop` is the trigger.
