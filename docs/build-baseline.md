# Build and dev-loop baseline

Dated sections, appended per change of the [development-experience plan](DEVELOPMENT-EXPERIENCE-PLAN.md).
This branch started the file without the Stage 0 baseline; when the two merge, keep Stage 0's text and append the section below.

## After: pnpm workspace for lilo-ui, site and docs-site (2026-11-18)

Change: one pnpm workspace and one `pnpm-lock.yaml` replace three `package-lock.json` files; `make` installs each project alone with `pnpm install --frozen-lockfile --ignore-scripts --filter ./<project>...`; CI drops its ten npm and `node_modules` caches for the one the bridge keeps.
Conditions: Apple M1 with 8 GB of RAM, load average high from other sessions, Node.js 22.23.4, npm 10.9.9 against pnpm 12.16.1, APFS.
Disk is the change in `df` of the data volume (store and cache growth included), not `du`, because pnpm clones files that `du` counts again.

| Measurement | npm, three projects | pnpm workspace |
|---|---|---|
| install of the three, warm package cache or store (a second worktree) | 10 s | 1 s |
| the same, disk added | 1.54 GB | 20 MB |
| install of the three, cold cache or store | 51 s | 20 s |
| the same, disk added (cache or store included) | 1.99 GB | 1.09 GB (the default store already held part of the packages) |
| `node_modules` by `du`, three projects | 1.57 GB | 1.1 GB (clones counted in full) |
| lockfiles | 3, 24814 lines | 1, 11805 lines |
| CI cache steps for npm packages and `node_modules` | 10 | 1 (the bridge's) |

Cold install of one project through the Makefile's filter, from an empty store and the registry, which is what a CI job without a cache pays: `lilo-ui` 3 s, `site` 10 s, `docs-site` 12 s.
A bare `pnpm install` from `docs-site/`, as Cloudflare's build command runs it, installs all three projects.

What the move changed besides size:

- The lockfile was resolved afresh: 94 of the 1078 package names differ from the three npm lockfiles in at least one resolved version (transitive patch and minor releases such as `@rolldown/binding-*` 1.2.x to 1.3.2). The three direct-dependency sets are the exact pins of the `package.json` files, unchanged.
- The `undici` override moved from `site/package.json` to `pnpm-workspace.yaml` and covers the three projects.
- Dependabot's `/` entry replaces the `/lilo-ui` and `/site` ones and also covers `docs-site`, which it did not.
- The release capture's source digest hashes `pnpm-lock.yaml` instead of `site/package-lock.json`, so archived captures read as stale once.

Verified here: `make ui-lint ui-test site-check site-test docs-check docs-test` (654 UI tests, 86 site tests, 47 docs tests), `make release-test release-media-test site-deploy-check docs-deploy-check ui-build` and `actionlint`, each from an empty `node_modules`.
Not measured: the CI jobs on GitHub-hosted runners (they need a push) and the Cloudflare build (the maintainer's dashboard change comes first).
