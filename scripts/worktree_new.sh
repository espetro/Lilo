#!/bin/sh
# Creates a git worktree under $LILO_WORKTREE_ROOT (default ~/.worktrees/<NAME>) and seeds the
# heavy regenerable directories from a warm checkout with APFS clonefile copies, so a new
# worktree costs seconds and near-zero disk instead of a fresh bootstrap. node_modules are
# not cloned: pnpm install already clonefiles from the shared store in about a second and
# respects this worktree's own lockfile. See CONTRIBUTING.md "Worktrees".
set -eu

die() { printf 'worktree-new: %s\n' "$*" >&2; exit 2; }

NAME=${1:?"usage: worktree_new.sh NAME [BASE]"}
BASE=${2:-origin/develop}
ROOT=${LILO_WORKTREE_ROOT:-"$HOME/.worktrees"}
BRANCH=${LILO_WORKTREE_BRANCH:-$NAME}
MAX=${LILO_WORKTREE_MAX:-10}
FORCE=${LILO_WORKTREE_FORCE:-0}
DERIVED=${LILO_WORKTREE_DERIVED:-0}
SITES=${LILO_WORKTREE_SITES:-0}
BRIDGE=${LILO_WORKTREE_BRIDGE:-1}

case $NAME in .. | */../* | ../* | */.. | /* | "") die "bad NAME '$NAME'" ;; esac

# The main checkout is the first entry of `git worktree list`; it is the default seed.
MAIN=$(git worktree list --porcelain | sed -n 's/^worktree //p' | head -1)
SEED=${LILO_WORKTREE_SEED:-$MAIN}

COUNT=$(git worktree list | wc -l | tr -d ' ')
[ "$COUNT" -lt "$MAX" ] || [ "$FORCE" = 1 ] || \
    die "$COUNT worktrees already exist (cap $MAX); run make worktree-gc or LILO_WORKTREE_FORCE=1"

DIR=$ROOT/$NAME
[ ! -e "$DIR" ] || die "$DIR already exists"
mkdir -p "$(dirname "$DIR")"
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git worktree add "$DIR" "$BRANCH"
else
    git worktree add "$DIR" -b "$BRANCH" "$BASE"
fi

# Clonefile copies: instant on APFS and they share storage with the seed until either side
# writes. cp -R is the fallback for filesystems without clonefile.
seed_copy() {
    [ -d "$SEED/$1" ] || return 0
    mkdir -p "$DIR/$1"
    cp -Rcf "$SEED/$1/." "$DIR/$1/" 2> /dev/null || cp -Rf "$SEED/$1/." "$DIR/$1/"
}
seed_copy Vendor
# Lilo/Generated also holds the tracked TabBridgeSchema.gen.swift: only the git-ignored
# outputs are seeded, never over a checkout's tracked files.
for f in ChromeUIAssets.swift NativeStrings.swift; do
    [ -f "$SEED/Lilo/Generated/$f" ] || continue
    mkdir -p "$DIR/Lilo/Generated"
    cp -cf "$SEED/Lilo/Generated/$f" "$DIR/Lilo/Generated/$f" 2> /dev/null || cp -f "$SEED/Lilo/Generated/$f" "$DIR/Lilo/Generated/$f"
done
for tool in "$SEED"/build/changie-* "$SEED"/build/swiftlint-* "$SEED"/build/xcodegen-*; do
    [ -d "$tool" ] || continue
    mkdir -p "$DIR/build"
    cp -Rcf "$tool" "$DIR/build/" 2> /dev/null || cp -Rf "$tool" "$DIR/build/"
done
[ "$DERIVED" = 1 ] && seed_copy .derived.noindex

DEPS="lilo-ui/node_modules/.installed"
[ "$BRIDGE" = 1 ] && DEPS="$DEPS Lilo/Extensions/bridge-src/node_modules/.package-lock.json"
[ "$SITES" = 1 ] && DEPS="$DEPS site/node_modules/.installed docs-site/node_modules/.installed"
# Installs come from the shared pnpm store (clonefile) and the npm cache: seconds, ~0 new disk.
make --no-print-directory -C "$DIR" $DEPS

printf 'worktree-new: %s [%s] seeded from %s\n' "$DIR" "$BRANCH" "$SEED"
