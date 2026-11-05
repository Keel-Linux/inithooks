#!/usr/bin/env bats
# Tests for lib/keel-firstboot.sh, firstboot.d/75keel-role and
# firstboot.d/80keel-cloud: the first boot asks the installation mode,
# then this node's role, then an optional Keel Cloud API key, handbook
# decisions 0020, 0028 and 0076. The screens are confconsole's
# (keelfirstboot.py); these hooks only hand them the step and the
# preseeded values, leave a question nobody can answer to keel-init, and
# stay out of the way where confconsole is absent.
#
# python3 is a stub: it records the arguments and the HUB_APIKEY it was
# given, and answers with the status a test sets: PYTHON_STATUS_<step>,
# else PYTHON_STATUS.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..

setup() {
    setup_stubs
    stub python3 'echo "HUB_APIKEY=${HUB_APIKEY-unset}" >> "'"$STUBS"'/python3.env"
if [[ -t 0 ]]; then echo terminal; else echo none; fi >> "'"$STUBS"'/python3.stdin"
step_status="PYTHON_STATUS_$2"
exit "${!step_status:-${PYTHON_STATUS:-0}}"'

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
    export INITHOOKS_DEFERRED=$BATS_TEST_TMPDIR/deferred
    unset HUB_APIKEY
}

@test "75keel-role asks the installation mode, then the role" {
    run "$REPO/firstboot.d/75keel-role"

    [ "$status" -eq 0 ]
    [ "$(calls python3)" = "$KEEL_FIRSTBOOT mode
$KEEL_FIRSTBOOT role" ]
    [ ! -e "$INITHOOKS_DEFERRED" ]
}

@test "nobody to answer the mode: keel-init asks it, and the role step still runs" {
    export INITHOOKS_UNATTENDED="the console has no size"
    export PYTHON_STATUS_mode=75

    run --separate-stderr "$REPO/firstboot.d/75keel-role"

    [ "$status" -eq 0 ]
    [ "$(calls python3)" = "$KEEL_FIRSTBOOT mode
$KEEL_FIRSTBOOT role" ]
    [ "$(cat "$INITHOOKS_DEFERRED")" = 75keel-role ]
    [ "$(head -1 "$INITHOOKS_LOGFILE")" = "INFO: [75keel-role] not asked, nobody can answer (the console has no size): confconsole's mode screen has a question: keel-init asks it" ]
}

@test "a cloud node's role left to keel-init is recorded once" {
    export INITHOOKS_UNATTENDED="the console has no size"
    export PYTHON_STATUS=75

    run "$REPO/firstboot.d/75keel-role"

    [ "$status" -eq 0 ]
    [ "$(cat "$INITHOOKS_DEFERRED")" = 75keel-role ]
}

@test "a preseeded mode: the step asks nothing and nothing is left to keel-init" {
    # keelfirstboot.py mode exits 0 when installation.mode is declared
    # (I2 of decision 0076; tests/test_first_boot.py in confconsole)
    export INITHOOKS_UNATTENDED="the console has no size"

    run "$REPO/firstboot.d/75keel-role"

    [ "$status" -eq 0 ]
    [ ! -e "$INITHOOKS_DEFERRED" ]
    [ "$(cat "$INITHOOKS_LOGFILE")" = "INFO: [75keel-role] not asked, nobody can answer (the console has no size): confconsole's mode screen is run without a terminal and draws nothing
INFO: [75keel-role] not asked, nobody can answer (the console has no size): confconsole's role screen is run without a terminal and draws nothing" ]
}

@test "a screen that found no terminal after all leaves its question to keel-init" {
    export PYTHON_STATUS_role=75

    run "$REPO/firstboot.d/75keel-role"

    [ "$status" -eq 0 ]
    [ "$(cat "$INITHOOKS_DEFERRED")" = 75keel-role ]
}

@test "a mode step that fails stops the hook before the role" {
    export PYTHON_STATUS_mode=3

    run "$REPO/firstboot.d/75keel-role"

    [ "$status" -eq 3 ]
    [ "$(calls python3)" = "$KEEL_FIRSTBOOT mode" ]
}

@test "a step that fails with nobody to answer is reported by its status" {
    export INITHOOKS_UNATTENDED="the console has no size"
    export PYTHON_STATUS_mode=3

    run "$REPO/firstboot.d/75keel-role"

    [ "$status" -eq 3 ]
    [ ! -e "$INITHOOKS_DEFERRED" ]
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
    [ "$(cat "$STUBS/python3.stdin")" = "terminal
terminal" ]
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
