#!/usr/bin/env bats
# Tests for lib/init-lock.sh, the first boot lock as run takes it
# (Keel-Linux/inithooks#24).
#
# The lock is the real flock(2) on a scratch file; what holds it on the other
# side is the util-linux flock command or a second shell, never a stub, so a
# refusal here is the kernel's. keel-init's side of the same lock is
# tests/test_init_lock.py.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..
LIBRARY=$REPO/lib/init-lock.sh

setup() {
    LOCK=$BATS_TEST_TMPDIR/inithooks.lock
    FIFO=$BATS_TEST_TMPDIR/release
    mkfifo "$FIFO"
    # shellcheck source=../lib/init-lock.sh
    source "$LIBRARY"
}

teardown() {
    let_go "$FIFO"
}

# is_free: succeeds when another process could take the lock now
is_free() {
    flock -n "$LOCK" true
}

is_held() {
    ! is_free
}

# hold_until_released PID_TEXT
# Another process writes PID_TEXT into the file, holds the lock until the
# fifo is written, and is waited for until it does hold it.
hold_until_released() {
    printf '%s\n' "$1" > "$LOCK"
    flock "$LOCK" -c "read -r _ < '$FIFO'" &
    HOLDER=$!
    eventually is_held
}

@test "the lock path defaults to /run/inithooks.lock" {
    run bash -c "unset INITHOOKS_LOCK; source '$LIBRARY'; echo \$INITHOOKS_LOCK"

    [ "$output" = /run/inithooks.lock ]
}

@test "the lock path is taken from INITHOOKS_LOCK" {
    run bash -c "INITHOOKS_LOCK=/elsewhere; source '$LIBRARY'; echo \$INITHOOKS_LOCK"

    [ "$output" = /elsewhere ]
}

@test "take holds the lock and writes the pid of the shell" {
    init_lock_take "$LOCK"

    [ -n "$INIT_LOCK_FD" ]
    [ "$(cat "$LOCK")" = "$$" ]
    run ! is_free
}

@test "release lets another process take the lock" {
    init_lock_take "$LOCK"

    init_lock_release

    [ -z "$INIT_LOCK_FD" ]
    is_free
}

@test "release without the lock does nothing" {
    unset INIT_LOCK_FD

    run init_lock_release

    [ "$status" -eq 0 ]
}

@test "take waits for the run holding the lock and names it" {
    hold_until_released 4242
    init_lock_take "$LOCK" 2> "$BATS_TEST_TMPDIR/err" &
    local taker=$!
    # the taker is waiting, not finished and not refused
    eventually grep -q waiting "$BATS_TEST_TMPDIR/err"
    kill -0 "$taker"

    echo go > "$FIFO"
    wait "$taker"

    grep -q "another first boot run holds $LOCK (pid 4242), waiting" \
        "$BATS_TEST_TMPDIR/err"
}

@test "a holder that is killed does not keep the lock" {
    bash -c "source '$LIBRARY'; init_lock_take '$LOCK'; read -r _ < '$FIFO'" &
    HOLDER=$!
    eventually is_held

    kill -9 "$HOLDER"
    wait "$HOLDER" || true

    is_free
}

@test "take fails with a message when the lock cannot be opened" {
    run init_lock_take "$BATS_TEST_TMPDIR/no/such/dir/lock"

    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot open the first boot lock $BATS_TEST_TMPDIR/no/such/dir/lock"* ]]
}

@test "take fails with a message, and closes the file, when flock fails" {
    setup_stubs
    stub flock 'exit 1'

    run init_lock_take "$LOCK"

    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot lock $LOCK"* ]]
    # both attempts were made, the one that waits last
    [ "$(calls flock | wc -l)" -eq 2 ]
    [[ "$(calls flock | tail -1)" != -n* ]]
}

@test "take leaves no descriptor behind when flock fails" {
    setup_stubs
    stub flock 'exit 1'

    init_lock_take "$LOCK" 2>/dev/null || true

    [ -z "$INIT_LOCK_FD" ]
    run ! bash -c "ls -l /proc/$BASHPID/fd | grep -q '$LOCK'"
}
