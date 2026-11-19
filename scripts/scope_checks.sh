#!/bin/sh
# Print the make targets a diff needs: `full` (run make validate) or a list of check targets.
#   scripts/scope_checks.sh [BASE]     the diff of the work tree against merge-base(HEAD, BASE), BASE defaulting to origin/main
#   scripts/scope_checks.sh --files    the changed paths, one per line, on stdin
# The split between code and not code is CI's `changes` job (.github/workflows/build.yml), kept in step by
# scripts/scope_checks.test.sh: a change outside docs, release notes and the websites, or to COMPATIBILITY.md (a test
# input), is code and needs the Swift build, so `full`. Only a diff of lilo-ui/ alone is scoped further, as AGENTS.md says.
# Anything unexpected, an empty diff or a range git cannot read included, is `full`, as in CI.
set -eu

if [ "${1:-}" = --files ]; then
    files=$(cat)
else
    base=${1:-origin/main}
    mergebase=$(git merge-base HEAD "$base" 2> /dev/null) || { echo "scope_checks.sh: no merge base with $base, so full" >&2; echo full; exit 0; }
    files=$({ git diff --name-only "$mergebase"; git ls-files --others --exclude-standard; } | sort -u)
fi
[ -n "$files" ] || { echo full; exit 0; }

ui=; site=; docs=
while IFS= read -r file; do
    case $file in
        # The docs site's reference generator reads these (docs-site/README.md, build watch paths).
        lilo-ui/src/components/settings/settingsPanelModel.ts | lilo-ui/src/lib/i18n/locales/en.json | lilo-ui/src/lib/i18n/locales/fr.json) ui=1; docs=1 ;;
        lilo-ui/*) ui=1 ;;
        site/*) site=1 ;;
        docs-site/*) docs=1 ;;
        COMPATIBILITY.md) echo full; exit 0 ;;
        .changes/* | docs/* | *.md) ;;
        *) echo full; exit 0 ;;
    esac
done << EOL
$files
EOL

checks=${ui:+ui-lint ui-test }${site:+site-check site-test }${docs:+docs-check docs-test }
echo "${checks}release-status"
