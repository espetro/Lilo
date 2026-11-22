#!/usr/bin/env bash
# The Swift test verdict of a branch, from CI: `make ci-swift [REF=<branch>]`.
#
# Swift tests open windows and take the keyboard focus, so they run on GitHub's macOS runners, not on a person's
# machine. This finds the CI run of the branch's pushed head (the one a push or a pull request started) or
# dispatches one, waits for it with `gh run watch` (CI_SWIFT_TIMEOUT seconds at most, default 1800), then prints one
# line per macOS shard and the failing tests the jobs listed. Exit 0 when every shard passed.
set -uo pipefail

ref=${1:-$(git branch --show-current)}
timeout_s=${CI_SWIFT_TIMEOUT:-1800}
workflow=build.yml
# Two remotes (origin, upstream): the run is the fork's, whatever gh would pick.
GH_REPO=$(git remote get-url origin | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##'); export GH_REPO
[ -n "$ref" ] || { echo "ci-swift: no branch checked out: pass REF=<branch>" >&2; exit 2; }

sha=$(gh api "repos/$GH_REPO/commits/$ref" --jq .sha 2>/dev/null) \
  || { echo "ci-swift: $ref is not on the remote: push it first (git push -u origin $ref)" >&2; exit 2; }
[ "$(git rev-parse "$ref" 2>/dev/null || echo "$sha")" = "$sha" ] \
  || echo "ci-swift: the local $ref differs from the pushed $sha: testing the pushed commit" >&2

run_for_head() {
  gh run list --workflow "$workflow" --commit "$sha" --limit 1 --json databaseId --jq '.[0].databaseId // empty'
}

# A push or a pull request starts its run a few seconds late: give it that before dispatching another.
for _ in 1 2 3; do id=$(run_for_head); [ -n "$id" ] && break; sleep 4; done
if [ -z "$id" ]; then
  echo "ci-swift: no CI run for ${sha:0:8}: dispatching one on $ref" >&2
  gh workflow run "$workflow" --ref "$ref" -f ref="$sha" >&2 \
    || { echo "ci-swift: dispatch failed: $ref needs the workflow_dispatch trigger of $workflow" >&2; exit 2; }
  # The run shows up in the list a few seconds after the dispatch.
  for _ in 1 2 3 4 5 6 7 8; do sleep 3; id=$(gh run list --workflow "$workflow" --event workflow_dispatch --branch "$ref" --limit 1 --json databaseId,headSha --jq ".[] | select(.headSha == \"$sha\") | .databaseId"); [ -n "$id" ] && break; done
  [ -n "$id" ] || { echo "ci-swift: the dispatched run did not appear" >&2; exit 2; }
fi

echo "ci-swift: run $id for ${sha:0:8}: $(gh run view "$id" --json url --jq .url)"
if command -v timeout >/dev/null; then
  timeout "$timeout_s" gh run watch "$id" --interval 30 >/dev/null 2>&1
  [ $? -eq 124 ] && echo "ci-swift: still running after ${timeout_s}s: showing the state so far (rerun make ci-swift to keep waiting)" >&2
else
  gh run watch "$id" --interval 30 >/dev/null 2>&1
fi

summary=$(gh run view "$id" --json status,conclusion,jobs \
  --jq '.jobs[] | select(.name | startswith("App Validate")) | [.name, (if (.conclusion // "") == "" then .status else .conclusion end), (.startedAt // "-"), (.completedAt // "-")] | join("|")')
[ -n "$summary" ] || { echo "ci-swift: the run has no macOS Swift jobs (docs-only change?): nothing to report"; exit 0; }

status=0
while IFS='|' read -r name result started completed; do
  secs=""
  if [ "$completed" != "-" ] && [ "$completed" != "0001-01-01T00:00:00Z" ]; then
    secs=$(( $(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$completed" +%s 2>/dev/null || date -u -d "$completed" +%s) - $(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$started" +%s 2>/dev/null || date -u -d "$started" +%s) ))s
  fi
  printf '%-8s %s %s\n' "$result" "$name" "$secs"
  [ "$result" = success ] || status=1
  [ "$result" = failure ] && failed=1
done <<< "$summary"

if [ "${failed:-0}" -eq 1 ]; then
  dir=$(mktemp -d)
  # failing-tests-app-N.md: each failed test with its first failure line (uploaded by the job on a failure).
  if gh run download "$id" --pattern 'failing-tests-app-*' --dir "$dir" >/dev/null 2>&1; then
    echo; echo "Failing tests:"; cat "$dir"/*/failing-tests.md
  else
    echo "ci-swift: no failing-tests artifact: read the log with: gh run view $id --log-failed" >&2
  fi
  /bin/rm -rf "$dir"
fi
exit $status
