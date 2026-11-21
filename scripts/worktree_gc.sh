#!/bin/sh
# Lists the linked worktrees that are safe to remove, and removes them with --apply:
# their pull request on every repo in $LILO_GC_REPOS is merged or closed, the checkout is
# clean, HEAD sits on a remote-tracking branch and no process has its working directory
# inside. `git worktree remove` (never --force) does the deletion, so a dirty worktree is
# refused even if the checks raced. The main checkout is never a candidate.
set -eu

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
GH=${LILO_GH:-gh}
REPOS=${LILO_GC_REPOS:-"espetro/Lilo Alexays/Lilo"}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lilo-worktree-gc.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
command -v lsof > /dev/null || { echo "worktree-gc: lsof is required for the in-use check" >&2; exit 1; }

# The head-branch names of every merged or closed PR (`--state closed` includes merged).
: > "$WORK/done"
for repo in $REPOS; do
    "$GH" pr list --repo "$repo" --state closed --limit 400 \
        --json headRefName --jq '.[].headRefName' >> "$WORK/done" || \
        { echo "worktree-gc: listing closed PRs of $repo failed" >&2; exit 1; }
done
sort -u "$WORK/done" -o "$WORK/done"

# Every process's working directory, in one lsof call.
lsof -n -F n -d cwd 2> /dev/null | sed -n 's/^n//p' > "$WORK/cwds"

pr_done() {
    grep -qx "$1" "$WORK/done" && return 0
    # A worktree named after an upstream PR it reviews: upstream/<slug> maps to head <slug>.
    case $1 in upstream/*) grep -qx "${1#upstream/}" "$WORK/done" ;; *) return 1 ;; esac
}

in_use() {
    while IFS= read -r cwd; do
        case $cwd in "$1" | "$1"/*) return 0 ;; esac
    done < "$WORK/cwds"
    return 1
}

printf '%-72s %-42s %8s  %s\n' WORKTREE BRANCH MIB STATUS
total=0
removed=0
git worktree list --porcelain > "$WORK/wts"
exec 3< "$WORK/wts"
path= head= branch=
while IFS= read -r line <&3 || [ -n "$path" ]; do
    case $line in
        "worktree "*) path=${line#worktree } ;;
        "HEAD "*) head=${line#HEAD } ;;
        "branch refs/heads/"*) branch=${line#branch refs/heads/} ;;
        detached) branch= ;;
        "") [ -n "$path" ] || continue
            # Only linked worktrees count: the main checkout's git dir is <path>/.git.
            case $(git -C "$path" rev-parse --git-dir 2> /dev/null) in
                */worktrees/*) ;; *) path= head= branch=; continue ;;
            esac
            reason=
            if [ -z "$branch" ]; then reason="detached HEAD, skipped"
            elif ! pr_done "$branch"; then reason="no merged/closed PR"
            elif [ -n "$(git -C "$path" status --porcelain)" ]; then reason="uncommitted changes"
            elif ! git branch -r --contains "$head" | grep -q .; then reason="HEAD not on a remote"
            elif in_use "$path"; then reason="cwd in use"
            fi
            if [ -n "$reason" ]; then
                printf '%-72s %-42s %8s  %s\n' "$path" "$branch" - "$reason"
            else
                mib=$(du -sm "$path" 2> /dev/null | cut -f1)
                total=$((total + mib))
                if [ "$APPLY" = 1 ]; then
                    if git worktree remove "$path" 2> "$WORK/err"; then
                        removed=$((removed + 1))
                        printf '%-72s %-42s %8s  removed\n' "$path" "$branch" "$mib"
                    else
                        printf '%-72s %-42s %8s  %s\n' "$path" "$branch" "$mib" "refused: $(cat "$WORK/err")"
                    fi
                else
                    printf '%-72s %-42s %8s  %s\n' "$path" "$branch" "$mib" REMOVABLE
                fi
            fi
            path= head= branch= ;;
    esac
done
exec 3<&-
if [ "$APPLY" = 1 ]; then
    echo "worktree-gc: removed $removed worktrees, reclaimed $total MiB (du; APFS clones count fully)"
else
    echo "worktree-gc: $total MiB removable (dry run; APPLY=1 removes)"
fi
