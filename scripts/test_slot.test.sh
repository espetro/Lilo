#!/bin/sh
# Checks scripts/test_slot.sh with stub commands (no xcodebuild): about 3 s.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SLOT="$ROOT/scripts/test_slot.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lilo-slot-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export LILO_TEST_LOCK_DIR="$WORK/locks" LILO_TEST_SLOT_RETRY=0.1
mkdir "$LILO_TEST_LOCK_DIR" "$WORK/running"

fail() { printf 'test_slot.test.sh: %s\n' "$*" >&2; exit 1; }

# A stub test run: records how many runs overlap it, takes $1 seconds, ends with the exit code $2.
cat > "$WORK/stub.sh" <<'STUB'
#!/bin/sh
dir=$1
mkdir "$dir/running/$$"
ls "$dir/running" | wc -l | tr -d ' ' >> "$dir/overlaps"
sleep "$2"
rmdir "$dir/running/$$"
echo run >> "$dir/runs"
exit "${3:-0}"
STUB
chmod +x "$WORK/stub.sh"
stub() { "$SLOT" "$@"; }

# One slot: the command's exit code comes through, and it takes the lock every checkout has always used.
status=0; stub 1 sh -c 'exit 7' || status=$?
[ "$status" -eq 7 ] || fail "one slot: expected the command's exit 7, got $status"
# shellcheck disable=SC2016 # the inner shell expands $0
stub 1 sh -c 'lockf -s -t 0 "$0" true && exit 1 || exit 0' "$LILO_TEST_LOCK_DIR/lilo-swift-test.lock" \
    || fail "one slot: lilo-swift-test.lock was not held while the command ran"

# Bad slot counts are refused before anything runs.
for bad in 0 x -1 ""; do
    status=0; "$SLOT" "$bad" true 2> /dev/null || status=$?
    [ "$status" -eq 2 ] || fail "slots '$bad': expected exit 2, got $status"
done

# Two slots: three runs of 0.5 s overlap two at a time, never three.
rm -f "$WORK/overlaps"
for _ in 1 2 3; do stub 2 "$WORK/stub.sh" "$WORK" 0.5 & done
wait
[ "$(wc -l < "$WORK/runs" | tr -d ' ')" -eq 3 ] || fail "two slots: expected 3 runs"
[ "$(sort -n "$WORK/overlaps" | tail -1)" -eq 2 ] || fail "two slots: expected two runs at once, got overlaps: $(tr '\n' ' ' < "$WORK/overlaps")"

# A command that itself exits 75 (lockf's "slot taken") ran once and is not retried in another slot.
rm -f "$WORK/runs"
status=0; stub 2 "$WORK/stub.sh" "$WORK" 0 75 || status=$?
[ "$status" -eq 75 ] || fail "exit 75: expected 75, got $status"
[ "$(wc -l < "$WORK/runs" | tr -d ' ')" -eq 1 ] || fail "exit 75: the command ran more than once"

# --all waits for the running lane, and a lane that starts while it holds every slot waits for it too.
rm -f "$WORK/runs" "$WORK/overlaps"
stub 2 "$WORK/stub.sh" "$WORK" 0.6 &
sleep 0.1
"$SLOT" --all 2 "$WORK/stub.sh" "$WORK" 0.6 &
sleep 0.8
stub 2 "$WORK/stub.sh" "$WORK" 0 &
wait
[ "$(tr '\n' ' ' < "$WORK/overlaps")" = "1 1 1 " ] || fail "--all: runs overlapped: $(tr '\n' ' ' < "$WORK/overlaps")"

echo "test_slot.test.sh: ok"
