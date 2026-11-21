## What and why

<!-- What this changes, and the problem it solves. Link the issue or discussion: "Fixes #123". -->

## Why and measured impact

<!-- Before and after numbers with the command that produced each (time, bytes, tokens, calls, disk, failure rate, interactions). Never invent a number. For a design or taste call say so and name who decides. -->

## How to test

<!-- Steps to see the change working, and the tests that cover it. -->

## Screenshots

<!-- For a UI change (Svelte, CSS, native chrome): before and after, in light and dark mode; a gif or short video for motion. `make ui-capture` for the chrome UI, `make window-capture` for the native window; never screencapture. Delete this section otherwise. -->

## Checklist

- [ ] The title follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) (`fix(sidebar): ...`)
- [ ] `make validate` passes locally
- [ ] Tests added or updated for the change
- [ ] A UI change has before and after captures (stills, plus a gif or video for motion)
- [ ] A user-visible change has a release-note fragment (`make change`)
- [ ] New user-facing strings are in every catalog under `lilo-ui/src/lib/i18n/locales/`
- [ ] `COMPATIBILITY.md` updated if extension behavior changed
- [ ] No unrelated changes
