#!/usr/bin/env bats
# Tests for lib/keel-firstboot.sh, firstboot.d/75keel-role and
# firstboot.d/80keel-cloud: the first boot asks this node's role
# (standalone, primary or replica) and an optional Keel Cloud API key,
# handbook decision 0020. The screens are confconsole's
# (keelfirstboot.py); these hooks only hand them the step and the
# preseeded values, and stay out of the way where confconsole is absent.
#
# python3 is a stub: it records the arguments and the HUB_APIKEY it was
# given, and answers with the status a test sets.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..

setup() {
    setup_stubs
    stub python3 'echo "HUB_APIKEY=${HUB_APIKEY-unset}" >> "'"$STUBS"'/python3.env"
if [[ -t 0 ]]; then echo terminal; else echo none; fi >> "'"$STUBS"'/python3.stdin"
exit "${PYTHON_STATUS:-0}"'

    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
    export INITHOOKS_CONF=$BATS_TEST_TMPDIR/inithooks.conf
    export INITHOOKS_DEFAULT=$BATS_TEST_TMPDIR/default-inithooks
    {
        echo "INITHOOKS_PATH=$INITHOOKS_PATH"
        echo "INITHOOKS_CONF=$INITHOOKS_CONF"
    } > "$INITHOOKS_DEFAULT"

    export KEEL_FIRSTBOOT=$BATS_TEST_TMPDIR/keelfirstboot.py
    touch "$KEEL_FIRSTBOOT"
    # somebody can answer the console (lib/console.sh), unless a test
    # says otherwise
    export INITHOOKS_UNATTENDED=no
    export INITHOOKS_LOGFILE=$BATS_TEST_TMPDIR/inithooks.log
    unset HUB_APIKEY
}

@test "75keel-role asks confconsole's first boot screen for the role" {
    run "$REPO/firstboot.d/75keel-role"

    [ "$status" -eq 0 ]
    [ "$(calls python3)" = "$KEEL_FIRSTBOOT role" ]
}

@test "nobody to answer: the screen is run without a terminal, and it is said" {
    # keelfirstboot.py still stores a preseeded key then, and draws
    # nothing (draw_on_terminal: no terminal on its standard input)
    export INITHOOKS_UNATTENDED="the console has no size"
    echo "export HUB_APIKEY=key-123" > "$INITHOOKS_CONF"

    run --separate-stderr script -qec "$REPO/firstboot.d/80keel-cloud" /dev/null

    [ "$status" -eq 0 ]
    [ "$(calls python3)" = "$KEEL_FIRSTBOOT cloud" ]
    [ "$(cat "$STUBS/python3.stdin")" = none ]
    [ "$(cat "$STUBS/python3.env")" = "HUB_APIKEY=key-123" ]
    [ "$(cat "$INITHOOKS_LOGFILE")" = "INFO: [80keel-cloud] not asked, nobody can answer (the console has no size): confconsole's cloud screen is run without a terminal and draws nothing" ]
}

@test "somebody to answer: the screen gets the terminal" {
    run script -qec "$REPO/firstboot.d/75keel-role" /dev/null < /dev/null

    [ "$status" -eq 0 ]
    [ "$(cat "$STUBS/python3.stdin")" = terminal ]
}

@test "80keel-cloud asks for the Keel Cloud key" {
    run "$REPO/firstboot.d/80keel-cloud"

    [ "$status" -eq 0 ]
    [ "$(calls python3)" = "$KEEL_FIRSTBOOT cloud" ]
}

@test "a preseeded HUB_APIKEY reaches the screen, which then asks nothing" {
    echo "export HUB_APIKEY=SKIP" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/80keel-cloud"

    [ "$status" -eq 0 ]
    [ "$(cat "$STUBS/python3.env")" = "HUB_APIKEY=SKIP" ]
}

@test "without a conf file the screen is asked with nothing preseeded" {
    run "$REPO/firstboot.d/80keel-cloud"

    [ "$status" -eq 0 ]
    [ "$(cat "$STUBS/python3.env")" = "HUB_APIKEY=unset" ]
}

@test "without confconsole's entry point nothing is asked and the boot goes on" {
    rm "$KEEL_FIRSTBOOT"

    run --separate-stderr "$REPO/firstboot.d/75keel-role"

    [ "$status" -eq 0 ]
    [ -z "$(calls python3)" ]
    [[ "$stderr" == *"$KEEL_FIRSTBOOT not found"*"stays standalone"* ]]
}

@test "a screen that fails is reported by its status, for run to log" {
    export PYTHON_STATUS=3

    run "$REPO/firstboot.d/75keel-role"

    [ "$status" -eq 3 ]
}

@test "the entry point defaults to confconsole's install path" {
    unset KEEL_FIRSTBOOT
    source "$REPO/lib/keel-firstboot.sh"

    [ "$KEEL_FIRSTBOOT" = /usr/lib/confconsole/keelfirstboot.py ]
}

@test "the TurnKey Hub screen is gone: no hook calls hubservices.py" {
    [ ! -e "$REPO/firstboot.d/80hub-services" ]
    [ ! -e "$REPO/bin/hubservices.py" ]
    run ! grep -rl hubservices "$REPO/firstboot.d"
}
