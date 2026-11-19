# Fork beta

A rolling beta of the espetro/Lilo fork, built from its `develop` branch so that its changes can be used before upstream reviews them.
It exists only on the fork and is never sent upstream: nothing in it, the `fork:` commits included, belongs in a pull request to Alexays/Lilo.

## What it is

[`.github/workflows/beta.yml`](../.github/workflows/beta.yml) runs on every push to `develop`, and by hand from the Actions tab (workflow_dispatch), and only in espetro/Lilo.
It builds the Release configuration with `LILO_BETA=1`, packages it with `make dmg` (a zip of the app if dmgbuild fails), and replaces the GitHub prerelease tagged `beta`.
The release notes carry the commit SHA and the build date.
The tag is `beta`, never `v*`, so the upstream release workflow, which also checks the repository, can never fire on it.

Download `Lilo-Beta.dmg` (or `Lilo-Beta.zip`) from the [`beta` release](https://github.com/espetro/Lilo/releases/tag/beta).

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

It never updates itself: the build has no Sparkle public key, so no update check starts and the upstream appcast is never read.
Update by downloading the latest `beta` release.

## How it is built

`scripts/build-app.sh` builds the beta when `LILO_BETA=1` is set (the workflow sets it).
That sets the `.beta` bundle id suffix, the name `Lilo Beta`, an empty `SPARKLE_PUBLIC_ED_KEY`, the `BETA` Swift condition `BuildIdentity` reads, and no hardened runtime, whose library validation rejects the ad-hoc signed Sparkle framework.
A step of the workflow checks those results in the built app and fails the run before anything is published.

To try it locally (this builds, it does not install or launch anything):

```
LILO_BETA=1 make release-archive
```

`workflow_dispatch` is only listed by GitHub once the workflow file is on the default branch; until then the push to `develop` is the trigger.
