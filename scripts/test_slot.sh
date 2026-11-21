#!/bin/sh
# Run a command holding one of N test slot locks, or with --all every one of them.
#   test_slot.sh SLOTS COMMAND [ARGS...]
#   test_slot.sh --all SLOTS COMMAND [ARGS...]
# Slot 1 is lilo-swift-test.lock, the lock every checkout has always used, so a worktree on an older Makefile and
# this one still exclude each other; slot K is lilo-swift-test-K.lock. With one slot this is exactly
# `lockf -k lilo-swift-test.lock COMMAND`: it waits its turn. With more it takes the first free slot and, when all
# are taken, retries every 2 s. --all (ext-smoke, ext-e2e: network, keychain, one Store) takes the slots in order,
# so it waits for every lane to drain and, taking none out of order, cannot deadlock with a lane that takes one.
set -eu
dir=${LILO_TEST_LOCK_DIR:-${TMPDIR:-/tmp/}}
all=
[ "${1:-}" = --all ] && { all=1; shift; }
[ "$#" -ge 2 ] || { echo "usage: test_slot.sh [--all] SLOTS COMMAND [ARGS...]" >&2; exit 2; }
slots=$1; shift
case $slots in '' | *[!0-9]* | 0) echo "test_slot.sh: SLOTS must be a positive number, not '$slots'" >&2; exit 2 ;; esac

slot_file() { if [ "$1" -eq 1 ]; then echo "${dir%/}/lilo-swift-test.lock"; else echo "${dir%/}/lilo-swift-test-$1.lock"; fi; }

if [ -n "$all" ]; then
    n=$slots
    while [ "$n" -ge 1 ]; do set -- lockf -k "$(slot_file "$n")" "$@"; n=$((n - 1)); done
    exec "$@"
fi
[ "$slots" -eq 1 ] && exec lockf -k "$(slot_file 1)" "$@"

# lockf -t 0 gives up with 75 when the slot is taken, which the command could also exit with: the marker file
# tells a command that ran from a slot that did not open.
marker=$(mktemp "${TMPDIR:-/tmp/}lilo-slot.XXXXXX")
trap 'rm -f "$marker"' EXIT
while :; do
    n=1
    while [ "$n" -le "$slots" ]; do
        rm -f "$marker"
        status=0
        # shellcheck disable=SC2016 # the inner shell expands them
        lockf -s -k -t 0 "$(slot_file "$n")" sh -c 'touch "$0"; exec "$@"' "$marker" "$@" || status=$?
        [ -e "$marker" ] && exit "$status"
        [ "$status" -eq 75 ] || exit "$status"
        n=$((n + 1))
    done
    sleep "${LILO_TEST_SLOT_RETRY:-2}"
done
