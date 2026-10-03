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
    # apt-get update exits UPDATE_STATUS; dist-upgrade prints a line and
    # exits UPGRADE_STATUS, so a failure has to cross the pipe into tee
    stub apt-get 'case "$*" in
update*) exit "${UPDATE_STATUS:-0}" ;;
*dist-upgrade*) echo "0 upgraded"; exit "${UPGRADE_STATUS:-0}" ;;
esac'
    # curl answers the reachability check: exit CURL_STATUS
    stub curl 'exit "${CURL_STATUS:-0}"'
    stub dpkg 'if [[ "$1" == --audit ]]; then echo "${DPKG_AUDIT-}"; fi'
    # the module and boot listing before and after the upgrade: the same
    # unless LS_CHANGES is set, when the second call differs; LS_STATUS is
    # its exit status (2 where /boot does not exist, as in a container)
    stub ls 'n=$(wc -l < "'"$STUBS"'/ls.calls")
if [[ -n "${LS_CHANGES-}" ]]; then echo "listing $n"; else echo listing; fi
exit "${LS_STATUS:-0}"'

    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH/bin" "$INITHOOKS_PATH/firstboot.d"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
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
    export SEC_UPDATES_SOURCES=$BATS_TEST_TMPDIR/security.sources
    printf 'Types: deb\nURIs: http://security.debian.org/debian-security\nSuites: trixie-security\nComponents: main\n' \
        > "$SEC_UPDATES_SOURCES"
    # somebody can answer the console (lib/console.sh), unless a test
    # says otherwise
    export INITHOOKS_UNATTENDED=no
    export INITHOOKS_LOGFILE=$BATS_TEST_TMPDIR/inithooks.log
    unset SEC_UPDATES DPKG_AUDIT LS_CHANGES LS_STATUS ASK_STATUS \
        UPDATE_STATUS UPGRADE_STATUS CURL_STATUS
}

# the value the dist-upgrade call passed for one apt option
apt_option() {
    calls apt-get | grep -o -- "-o $1=[^ ]*" | sed "s|^-o $1=||"
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

@test "nobody to answer: the updates are installed as FORCE installs them" {
    # what the preseed of a headless build says (README.rst)
    export INITHOOKS_UNATTENDED="the console has no size"
    export ASK_STATUS=99

    run --separate-stderr "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "force" ]
    [[ "$(calls apt-get)" == *"dist-upgrade -y"* ]]
    [ "$(cat "$INITHOOKS_LOGFILE")" = "INFO: [95secupdates] not asked, nobody can answer (the console has no size): security updates installed, as SEC_UPDATES=FORCE does" ]
}

@test "nobody to answer a preseeded SKIP: nothing is installed" {
    export INITHOOKS_UNATTENDED="the console has no size"
    echo "export SEC_UPDATES=SKIP" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "skip" ]
    [ -z "$(calls apt-get)" ]
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

# ------------------------------------------------- where the updates come from

@test "the upgrade reads the security source file and no other" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ "$(apt_option Dir::Etc::sourcelist)" = "$SEC_UPDATES_SOURCES" ]
    [ "$(apt_option Dir::Etc::sourceparts)" = /dev/null ]
}

@test "the default security source is security.sources, the file images ship" {
    # common's conf/bootstrap_apt writes it; it used to write
    # security.sources.sources, and cron-apt and this hook named that
    run grep -c 'SEC_UPDATES_SOURCES:-/etc/apt/sources.list.d/security.sources}' \
        "$REPO/firstboot.d/95secupdates"
    [ "$output" = 1 ]
    run ! grep -q 'security\.sources\.sources' "$REPO/firstboot.d/95secupdates"
}

@test "a missing security source fails the hook instead of upgrading nothing" {
    # apt reads a missing sourcelist as an empty one: the dist-upgrade
    # succeeds, installs nothing and the boot says the updates were applied
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"
    rm "$SEC_UPDATES_SOURCES"

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 1 ]
    [[ "$(calls apt-get)" != *dist-upgrade* ]]
    [[ "$(calls logger)" == *"no security source at $SEC_UPDATES_SOURCES"* ]]
    [[ "$(cat "$SEC_UPDATES_LOG")" == *"no security source at $SEC_UPDATES_SOURCES"* ]]
}

# ------------------------------------------- offline, failures and the record

@test "the reachability check asks for the InRelease of the security source" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [[ "$(calls curl)" == *"http://security.debian.org/debian-security/dists/trixie-security/InRelease"* ]]
}

@test "offline, the boot goes on, says why, installs and records nothing" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"
    export CURL_STATUS=7

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ ! -e "$SEC_UPDATES_RECORD" ]
    [ -z "$(calls apt-get)" ]
    local said="cannot reach http://security.debian.org/debian-security"
    [[ "$(calls logger)" == *"$said"* ]]
    [[ "$(calls logger)" == *turnkey-install-security-updates* ]]
    [[ "$(cat "$SEC_UPDATES_LOG")" == *"$said"* ]]
}

@test "offline after Install on the screen, the boot goes on too" {
    export ASK_STATUS=0 CURL_STATUS=6

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ ! -e "$SEC_UPDATES_RECORD" ]
    [[ "$(calls apt-get)" != *dist-upgrade* ]]
}

@test "an apt-get update that fails is said, and the boot goes on" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"
    export UPDATE_STATUS=100

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ ! -e "$SEC_UPDATES_RECORD" ]
    [[ "$(calls apt-get)" != *dist-upgrade* ]]
    [[ "$(calls logger)" == *"apt-get update failed"* ]]
    [[ "$(cat "$SEC_UPDATES_LOG")" == *"apt-get update failed"* ]]
}

@test "a dist-upgrade that fails fails the hook through tee, and records nothing" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"
    export UPGRADE_STATUS=100

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -ne 0 ]
    [ ! -e "$SEC_UPDATES_RECORD" ]
    [[ "$(cat "$SEC_UPDATES_LOG")" == *"0 upgraded"* ]]
}

@test "a failed install after Install on the screen records nothing either" {
    export ASK_STATUS=0 UPGRADE_STATUS=100

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -ne 0 ]
    [ ! -e "$SEC_UPDATES_RECORD" ]
}

@test "force is recorded only after the upgrade ran" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"
    # the record must not exist yet when dist-upgrade runs
    stub apt-get 'case "$*" in
*dist-upgrade*) [ -e "'"$SEC_UPDATES_RECORD"'" ] && exit 42; exit 0 ;;
esac'

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "force" ]
}

@test "a machine without /boot, where ls fails, still installs the updates" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"
    export LS_STATUS=2

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "force" ]
    [[ "$(calls apt-get)" == *dist-upgrade* ]]
}

# journald down: logger exits 1 under bash -e (15regen-sslcert died of it
# on the published core booted headless, 2026-10-03)
@test "a preseeded SKIP is recorded when logger fails" {
    stub logger 'echo "logger: socket /dev/log: Connection refused" >&2; exit 1'
    echo "export SEC_UPDATES=SKIP" > "$INITHOOKS_CONF"

    run --separate-stderr "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "skip" ]
    [[ "$stderr" != *"Connection refused"* ]]
}

@test "a preseeded FORCE installs the updates when logger fails" {
    stub logger 'exit 1'
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "force" ]
    [[ "$(calls apt-get)" == *dist-upgrade* ]]
}

@test "a record that cannot be written is still said when logger fails" {
    stub logger 'exit 1'
    export SEC_UPDATES_RECORD=$BATS_TEST_TMPDIR/file/sec-updates
    touch "$BATS_TEST_TMPDIR/file"
    echo "export SEC_UPDATES=SKIP" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/95secupdates"

    [ "$status" -eq 0 ]
}
