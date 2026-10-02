#!/usr/bin/env bats
# The first boot on a terminal: run, the real 30rootpass and setpass.py,
# the real dialog, on a pty that `script` gives them, the way
# inithooks.service gives them tty1.
#
# The keys are typed when the screen asks for them, not on a timer, and the
# whole run has TIMEOUT seconds: a run that stops answering fails here
# instead of leaving the console on its last screen. Each screen is looked
# for in what reached the pty, so a dialog drawn into a pipe (the bug of
# keel-mariadb's dbpass.py) is missing from it, and the test fails.
#
# Only chpasswd and passwd are stand-ins: chpasswd records the account it
# was given, never the password, and passwd -S answers the status the test
# sets. Needs dialog and python3-dialog; skipped without them, except in CI.

bats_require_minimum_version 1.5.0

load helpers

TIMEOUT=60
REAL_SLEEP=$(command -v sleep)

setup() {
    if ! command -v dialog > /dev/null \
            || ! /usr/bin/python3 -c 'import dialog' 2> /dev/null; then
        if [[ -n "${CI:-}" ]]; then
            echo "dialog and python3-dialog are required in CI" >&2
            return 1
        fi
        skip "needs dialog and python3-dialog"
    fi
    setup_stubs
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    ROOT=$BATS_TEST_TMPDIR
    LIB=$ROOT/lib
    SCREEN=$ROOT/typescript
    NEXT=$ROOT/next-hook-ran
    mkdir -p "$LIB/firstboot.d" "$LIB/bin"
    cp "$REPO/firstboot.d/30rootpass" "$LIB/firstboot.d/"
    ln -s "$REPO/bin/setpass.py" "$LIB/bin/setpass.py"
    # the screen after the password, drawn as the next hook draws its own
    cat > "$LIB/firstboot.d/80next" <<EOF
#!/bin/bash
dialog --backtitle 'Keel Linux - First boot configuration' \\
    --infobox 'NEXT-SCREEN-SHOWN' 5 40
touch '$NEXT'
EOF
    chmod +x "$LIB/firstboot.d/80next"

    stub logger
    stub systemctl 'echo running'
    stub confconsole
    stub sleep
    stub chpasswd "IFS=: read -r user _; echo \"\$user\" >> '$ROOT/chpasswd'"
    passwd_status L

    DEFAULT=$ROOT/default-inithooks
    cat > "$DEFAULT" <<EOF
INITHOOKS_CONF=$ROOT/inithooks.conf
INITHOOKS_PATH=$LIB
INITHOOKS_LOGFILE=$ROOT/inithooks.log
RUN_FIRSTBOOT=true
REDIRECT_OUTPUT=false
SUDOADMIN=false
EOF
    export INITHOOKS_DEFAULT=$DEFAULT
    export INITHOOKS_LOCK=$ROOT/inithooks.lock
    export INITHOOKS_COMPLETE=$ROOT/inithooks-complete
    export PYTHONPATH=$REPO${PYTHONPATH:+:$PYTHONPATH}
    export DIALOG_LOG=$ROOT/dialog.log
    export TERM=linux LINES=25 COLUMNS=80
    : > "$SCREEN"
}

# passwd_status STATUS
# passwd -S answers STATUS (P usable, L locked, NP empty) for any account.
passwd_status() {
    stub passwd "echo \"\${2:-root} $1 2026-10-02 0 99999 7 -1\""
}

teardown() {
    if [[ -s "${ROOT:-}/hung" ]]; then
        kill "$(cat "$ROOT/hung")" 2> /dev/null || true
    fi
}

# within FILE WORD
# Waits until WORD is in FILE, at most TIMEOUT seconds.
within() {
    local deadline=$((SECONDS + TIMEOUT))
    until grep -qa -- "$2" "$1" 2> /dev/null; do
        if (( SECONDS >= deadline )); then
            echo "never in $1: $2" >&2
            return 1
        fi
        "$REAL_SLEEP" 0.2
    done
}

# operator WORD KEYS [WORD KEYS]...
# Types each KEYS (printf format) once its WORD has reached the pty, then
# keeps the pty's input open until the run has logged its end. A screen
# that never comes keeps the input open too, until the timeout ends the
# run: the end of the input would answer the dialog on the screen.
operator() {
    while (( $# )); do
        if ! within "$SCREEN" "$1"; then
            "$REAL_SLEEP" "$TIMEOUT"
            return 1
        fi
        "$REAL_SLEEP" 0.3
        # shellcheck disable=SC2059
        printf "$2"
        shift 2
    done
    within "$ROOT/inithooks.log" 'Inithooks run completed' || true
}

# first_boot WORD KEYS...
# The run on a pty under script, answered by operator, within TIMEOUT; it
# fails when a screen never came or the run did not end in time.
first_boot() {
    set -o pipefail
    operator "$@" | timeout "$TIMEOUT" script -qfec "$REPO/run" "$SCREEN" \
        > /dev/null 2>&1
}

# done_logged
# The run reached its end: script does not show what run logs.
done_logged() {
    grep -q 'Inithooks run completed' "$ROOT/inithooks.log"
}

assert_next_screen() {
    [ -e "$NEXT" ]
    grep -qa 'NEXT-SCREEN-SHOWN' "$SCREEN"
    done_logged
}

@test "Generate, then Saved, goes on to the next screen" {
    run first_boot 'Choose' '\r' 'manager.' '\r' 'discard' '\r' \
        'NEXT-SCREEN-SHOWN' ''

    [ "$status" -eq 0 ]
    assert_next_screen
    [ "$(cat "$ROOT/chpasswd")" = root ]
    # the confirmation reached the terminal, not a pipe
    grep -qa 'Saved' "$SCREEN"
    # and the step after it said what it was doing before drawing
    grep -qa 'Configuring next' "$SCREEN"
}

@test "New shows another password, then Saved goes on" {
    run first_boot 'Choose' '\r' 'manager.' '\r' 'discard' '\t\r' \
        'manager.' '\r' 'discard' '\r' 'NEXT-SCREEN-SHOWN' ''

    [ "$status" -eq 0 ]
    assert_next_screen
    [ "$(wc -l < "$ROOT/chpasswd")" -eq 1 ]
}

@test "Manual sets the typed password and goes on" {
    run first_boot 'Choose' 'M\r' 'Requirements' 'Abcdefg1\r' \
        'Confirm' 'Abcdefg1\r' 'NEXT-SCREEN-SHOWN' ''

    [ "$status" -eq 0 ]
    assert_next_screen
    [ "$(cat "$ROOT/chpasswd")" = root ]
}

@test "a password set at creation is kept with Enter and nothing replaces it" {
    passwd_status P

    run first_boot 'Choose' '\r' 'NEXT-SCREEN-SHOWN' ''

    [ "$status" -eq 0 ]
    assert_next_screen
    # Keep was offered, and only Keep is recommended when it is
    grep -qa '(recommended)' "$SCREEN"
    [ ! -e "$ROOT/chpasswd" ]
}

@test "Generate below Keep replaces the password set at creation" {
    passwd_status P

    run first_boot 'Choose' 'G\r' 'manager.' '\r' 'discard' '\r' \
        'NEXT-SCREEN-SHOWN' ''

    [ "$status" -eq 0 ]
    assert_next_screen
    [ "$(cat "$ROOT/chpasswd")" = root ]
}

@test "a preseeded password draws no password screen" {
    passwd_status P
    echo "export ROOT_PASS='Preseeded-123'" > "$ROOT/inithooks.conf"

    run first_boot 'NEXT-SCREEN-SHOWN' ''

    [ "$status" -eq 0 ]
    assert_next_screen
    run ! grep -qa 'Choose' "$SCREEN"
    [ "$(cat "$ROOT/chpasswd")" = root ]
}

@test "a screen drawn into a pipe never reaches the pty, and is caught" {
    # the guard itself: the dbpass.py bug, a hook reading a screen's
    # output through a pipe, leaves the screen out of the pty
    cat > "$LIB/firstboot.d/80next" <<EOF
#!/bin/bash
drawn=\$(dialog --backtitle 'Keel Linux - First boot configuration' \\
    --infobox 'NEXT-SCREEN-SHOWN' 5 40)
touch '$NEXT'
EOF
    TIMEOUT=10

    run first_boot 'Choose' '\r' 'manager.' '\r' 'discard' '\r' \
        'NEXT-SCREEN-SHOWN' ''

    [ "$status" -ne 0 ]
    [ -e "$NEXT" ]
    run ! grep -qa 'NEXT-SCREEN-SHOWN' "$SCREEN"
}

@test "a hook that stops answering fails the run within the timeout" {
    # the guard itself: a hook that hangs must fail this test file, not
    # hang it
    cat > "$LIB/firstboot.d/50hangs" <<EOF
#!/bin/bash
echo \$\$ > '$ROOT/hung'
exec '$REAL_SLEEP' 600
EOF
    chmod +x "$LIB/firstboot.d/50hangs"
    TIMEOUT=5

    run first_boot 'Choose' '\r' 'manager.' '\r' 'discard' '\r'

    [ "$status" -ne 0 ]
    [ ! -e "$NEXT" ]
}
