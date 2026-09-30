#!/usr/bin/env bats
# Tests for update-motd.d/06-keel-init, the login message while the first
# boot is not finished (Keel-Linux/inithooks#24). The words are keel-init's
# (keel-init --status, tests/test_init_lock.py); this is about the fragment
# passing them on and never failing a login.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..
FRAGMENT=$REPO/update-motd.d/06-keel-init

setup() {
    setup_stubs
    export KEEL_INIT=$STUBS/keel-init
}

@test "the fragment asks keel-init for the status and prints its words" {
    stub keel-init "echo '    the first-boot wizard is running on the console'"

    run "$FRAGMENT"

    [ "$status" -eq 0 ]
    [ "$output" = '    the first-boot wizard is running on the console' ]
    [ "$(calls keel-init)" = --status ]
}

@test "a run in progress does not fail the login" {
    stub keel-init 'echo busy; exit 75'

    run "$FRAGMENT"

    [ "$status" -eq 0 ]
    [ "$output" = busy ]
}

@test "without keel-init the fragment prints nothing" {
    export KEEL_INIT=$BATS_TEST_TMPDIR/absent

    run "$FRAGMENT"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the fragment asks the installed keel-init by default" {
    run grep -q '^KEEL_INIT=${KEEL_INIT:-/usr/sbin/keel-init}$' "$FRAGMENT"

    [ "$status" -eq 0 ]
}
