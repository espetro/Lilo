#!/bin/sh
# Checks scripts/worktree_gc.sh's selection logic in a throwaway repository: a merged or closed
# PR makes a worktree removable while an open one, uncommitted changes, an unpushed HEAD, a
# detached HEAD or a process working inside it keep it. A stub `gh` answers the PR lookups; the
# git and lsof checks run for real. No network.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lilo-wt-gc-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
SLEEP_PID=
cleanup() { [ -z "$SLEEP_PID" ] || kill "$SLEEP_PID" 2> /dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

fail() { printf 'worktree_gc.test.sh: %s\n' "$*" >&2; exit 1; }

# A stub gh: `gh pr list --repo <r> --state closed --json headRefName --jq ...` prints the
# headRefName of each closed PR, one per line, from $WORK/closed-<repo>.txt.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" << 'EOF'
#!/bin/sh
repo=
prev=
for a in "$@"; do [ "$prev" = --repo ] && repo=$a; prev=$a; done
cat "$STUBDIR/closed-$(echo "$repo" | tr / _).txt" 2> /dev/null
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" STUBDIR="$WORK"
export LILO_GC_REPOS="fork/Repo up/Repo"
printf 'fix/merged\nfix/dirty\nfix/unpushed\nfix/inuse\n' > "$WORK/closed-fork_Repo.txt"
printf 'cool-fix\n' > "$WORK/closed-up_Repo.txt"

REPO="$WORK/repo"
git -c init.defaultBranch=main init -q "$REPO"
cd "$REPO"
git config user.name t; git config user.email t@example.invalid
echo a > a && git add a && git commit -qm base
git init -q --bare "$WORK/remote.git"
git remote add origin "$WORK/remote.git"
git push -q origin main

wt() { git worktree add "$WORK/$1" -b "$2" > /dev/null 2>&1; }
push_branch() { git -C "$WORK/$1" push -q origin "$2"; }

wt wt-merged fix/merged;       push_branch wt-merged fix/merged
wt wt-open fix/open;           push_branch wt-open fix/open
wt wt-dirty fix/dirty;         push_branch wt-dirty fix/dirty
wt wt-unpushed fix/unpushed
wt wt-inuse fix/inuse;         push_branch wt-inuse fix/inuse
wt wt-upstream upstream/cool-fix; push_branch wt-upstream upstream/cool-fix
wt wt-detached fix/detached;   push_branch wt-detached fix/detached
git -C "$WORK/wt-detached" checkout -q --detach HEAD

# Unpushed work: a local commit on top, so no remote-tracking branch contains HEAD.
echo u > "$WORK/wt-unpushed/u" && git -C "$WORK/wt-unpushed" add u && git -C "$WORK/wt-unpushed" commit -qm local
# Uncommitted work.
echo d > "$WORK/wt-dirty/dirty"
# A process holding its cwd inside the worktree.
(cd "$WORK/wt-inuse" && sleep 300) & SLEEP_PID=$!
sleep 1

"$ROOT/scripts/worktree_gc.sh" > "$WORK/dry" || fail "dry run failed"
cat "$WORK/dry"

row() { grep -w "$1" "$WORK/dry"; }
row wt-merged   | grep -q REMOVABLE || fail "merged PR worktree not removable"
row wt-open     | grep -q "no merged/closed PR" || fail "open PR worktree should be kept"
row wt-dirty    | grep -q "uncommitted changes" || fail "dirty worktree should be kept"
row wt-unpushed | grep -q "HEAD not on a remote" || fail "unpushed worktree should be kept"
row wt-inuse    | grep -q "cwd in use" || fail "in-use worktree should be kept"
row wt-upstream | grep -q REMOVABLE || fail "upstream/<slug> worktree not removable"
row wt-detached | grep -q "detached HEAD" || fail "detached worktree should be kept"
grep -qF "$REPO " "$WORK/dry" && fail "the main checkout must never be listed"
grep -q "dry run" "$WORK/dry" || fail "no dry-run summary"
[ -d "$WORK/wt-merged" ] || fail "dry run removed a worktree"

"$ROOT/scripts/worktree_gc.sh" --apply > "$WORK/applied" || fail "apply failed"
cat "$WORK/applied"
grep -F "$WORK/wt-merged" "$WORK/applied" | grep -q " removed" || fail "apply did not remove merged"
grep -F "$WORK/wt-upstream" "$WORK/applied" | grep -q " removed" || fail "apply did not remove upstream/*"
for kept in wt-open wt-dirty wt-unpushed wt-inuse wt-detached; do
    [ -d "$WORK/$kept" ] || fail "apply removed $kept"
done
git worktree list | grep -q "wt-merged" && fail "wt-merged still registered"

echo "worktree_gc.test.sh: ok"
