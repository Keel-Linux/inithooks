#!/usr/bin/env bats
# Tests for firstboot.d/95secupdates: the first boot's security updates,
# preseeded (SEC_UPDATES) or asked (bin/secupdates-ask.py), and the line
# the hook leaves of the answer. Nothing else on the machine records it:
# the cron-apt install action every image ships looks the same after Skip
# and after Install, so keel inspect said force after Skip (the
# maintainer's screenshot 034).
#
# apt-get, dpkg, logger and ls are stubs; secupdates-ask.py is a stub
# under INITHOOKS_PATH that exits with the status a test sets.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..

setup() {
    setup_stubs
    stub logger
    stub apt-get
    stub dpkg 'if [[ "$1" == --audit ]]; then echo "${DPKG_AUDIT-}"; fi'
    # the module and boot listing before and after the upgrade: the same
    # unless LS_CHANGES is set, when the second call differs
    stub ls 'n=$(wc -l < "'"$STUBS"'/ls.calls")
if [[ -n "${LS_CHANGES-}" ]]; then echo "listing $n"; else echo listing; fi'

    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH/bin" "$INITHOOKS_PATH/firstboot.d"
    touch "$INITHOOKS_PATH/firstboot.d/99reboot"
    printf '#!/bin/bash\nexit "${ASK_STATUS:-0}"\n' \
        > "$INITHOOKS_PATH/bin/secupdates-ask.py"
    chmod +x "$INITHOOKS_PATH/bin/secupdates-ask.py"

    export INITHOOKS_CONF=$BATS_TEST_TMPDIR/inithooks.conf
    export INITHOOKS_DEFAULT=$BATS_TEST_TMPDIR/default-inithooks
    {
        echo "INITHOOKS_PATH=$INITHOOKS_PATH"
        echo "INITHOOKS_CONF=$INITHOOKS_CONF"
    } > "$INITHOOKS_DEFAULT"
    export SEC_UPDATES_RECORD=$BATS_TEST_TMPDIR/var/lib/inithooks/sec-updates
    export SEC_UPDATES_LOG=$BATS_TEST_TMPDIR/secupdates.log
    unset SEC_UPDATES DPKG_AUDIT LS_CHANGES ASK_STATUS
}

@test "a preseeded SKIP installs nothing and records skip" {
    echo "export SEC_UPDATES=SKIP" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "skip" ]
    [ -z "$(calls apt-get)" ]
}

@test "a preseeded FORCE records force and installs the updates" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "force" ]
    [[ "$(calls apt-get)" == *"dist-upgrade -y"* ]]
    [ ! -x "$INITHOOKS_PATH/firstboot.d/99reboot" ]
}

@test "Skip on the screen records skip" {
    export ASK_STATUS=99

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "skip" ]
    [ -z "$(calls apt-get)" ]
}

@test "Install on the screen records force and installs" {
    export ASK_STATUS=0

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "force" ]
    [[ "$(calls apt-get)" == *"dist-upgrade -y"* ]]
}

@test "a screen that fails records nothing and fails the hook" {
    export ASK_STATUS=3

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 3 ]
    [ ! -e "$SEC_UPDATES_RECORD" ]
}

@test "an invalid preseed records nothing and fails the hook" {
    echo "export SEC_UPDATES=maybe" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 1 ]
    [ ! -e "$SEC_UPDATES_RECORD" ]
    [[ "$(calls logger)" == *"invalid preseed value: maybe"* ]]
}

@test "a record that cannot be written is said and the boot goes on" {
    echo "export SEC_UPDATES=SKIP" > "$INITHOOKS_CONF"
    export SEC_UPDATES_RECORD=$BATS_TEST_TMPDIR/file/sec-updates
    touch "$BATS_TEST_TMPDIR/file"

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [[ "$(calls logger)" == *"could not record skip in $SEC_UPDATES_RECORD"* ]]
}

@test "dpkg in an inconsistent state is logged, and a new kernel arms 99reboot" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"
    export DPKG_AUDIT="libfoo is half configured"
    export LS_CHANGES=1

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [[ "$(cat "$SEC_UPDATES_LOG")" == *"dpkg in an inconsistent state"* ]]
    [[ "$(cat "$SEC_UPDATES_LOG")" == *"libfoo is half configured"* ]]
    [ -x "$INITHOOKS_PATH/firstboot.d/99reboot" ]
}

@test "without a conf file the screen is asked" {
    export ASK_STATUS=99

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "skip" ]
}
