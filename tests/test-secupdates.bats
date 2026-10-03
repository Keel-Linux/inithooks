#!/usr/bin/env bats
# Tests for firstboot.d/95secupdates: the first boot's security updates,
# preseeded (SEC_UPDATES) or asked (bin/secupdates-ask.py), and the line
# the hook leaves of the answer. Nothing else on the machine records it:
# the cron-apt install action every image ships looks the same after Skip
# and after Install, so keel inspect said force after Skip (the
# maintainer's screenshot 034).
#
# apt-get, dpkg, logger and ls are stubs; secupdates-ask.py is a stub
# under INITHOOKS_PATH that exits with the status a test sets. An apt-get
# that hangs sleeps for good: the hook must stop it within its limits, and
# the tests that use one run under an outer timeout so that a hook that
# does not stop it fails instead of hanging the suite.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..
# the real sleep, for an apt-get that hangs where sleep is a stub
REAL_SLEEP=$(command -v sleep)

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
    # the daily job that installs what the first boot did not: cron-apt's
    # install action (common's conf/turnkey.d/cronapt)
    export SEC_UPDATES_CRONAPT=$BATS_TEST_TMPDIR/cron-apt/5-install
    mkdir -p "$(dirname "$SEC_UPDATES_CRONAPT")"
    touch "$SEC_UPDATES_CRONAPT"
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
        UPDATE_STATUS UPGRADE_STATUS CURL_STATUS \
        SEC_UPDATES_TIMEOUT SEC_UPDATES_UPDATE_TIMEOUT
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
    [[ "$(calls logger)" == *"cron-apt installs them"* ]]
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

# ------------------------------------------- the update never holds the boot
#
# The maintainer's decision (2026-10-03): an unattended first boot installs
# the security updates, and they never hold it. apt-get update and the
# upgrade are bounded, a run stopped or failed leaves dpkg configured, and
# the boot goes on with one line in the inithooks log naming the daily job
# that installs them instead.

# hang WHEN: apt-get sleeps for good on the call matching WHEN, and
# answers every other one as the default stub does
hang() {
    stub apt-get 'case "$*" in
'"$1"') echo "apt-get $1 started"; "'"$REAL_SLEEP"'" 300 ;;
*dist-upgrade*) echo "0 upgraded"; exit "${UPGRADE_STATUS:-0}" ;;
esac'
}

# run_bounded: the hook, under an outer limit far above its own, timed
run_bounded() {
    local started=$SECONDS
    run timeout 60 "$REPO/firstboot.d/95secupdates"
    took=$((SECONDS - started))
}

# the lines the hook left in the inithooks log
said() {
    grep -F '[95secupdates]' "$INITHOOKS_LOGFILE" 2>/dev/null || true
}

@test "the limits default to 15 minutes for the run and 2 for apt-get update" {
    run grep -c 'SEC_UPDATES_TIMEOUT:-900}' "$REPO/firstboot.d/95secupdates"
    [ "$output" = 1 ]
    run grep -c 'SEC_UPDATES_UPDATE_TIMEOUT:-120}' "$REPO/firstboot.d/95secupdates"
    [ "$output" = 1 ]
}

@test "an apt-get update that hangs is stopped at its limit, and the boot goes on" {
    {
        echo "export SEC_UPDATES=FORCE"
        echo "SEC_UPDATES_UPDATE_TIMEOUT=1"
    } > "$INITHOOKS_CONF"
    hang 'update*'

    run_bounded

    [ "$status" -eq 0 ]
    (( took < 10 ))
    [[ "$(calls apt-get)" != *dist-upgrade* ]]
    [ ! -e "$SEC_UPDATES_RECORD" ]
    [ "$(said | wc -l)" -eq 1 ]
    [[ "$(said)" == *"apt-get update did not finish in 1 s"*cron-apt* ]]
}

@test "an upgrade that hangs is stopped at the run's limit, and dpkg is configured" {
    {
        echo "export SEC_UPDATES=FORCE"
        echo "SEC_UPDATES_TIMEOUT=2"
    } > "$INITHOOKS_CONF"
    hang '*dist-upgrade*'
    # what a dpkg killed while unpacking leaves
    export DPKG_AUDIT="libfoo is half configured"

    run_bounded

    [ "$status" -eq 1 ]
    (( took < 10 ))
    [ ! -e "$SEC_UPDATES_RECORD" ]
    # once before the update, and once after the upgrade was stopped
    [ "$(calls dpkg | grep -c -- '--configure -a')" -eq 2 ]
    [ "$(said | wc -l)" -eq 1 ]
    [[ "$(said)" == *"the upgrade did not finish in 2 s"*cron-apt* ]]
    [ ! -x "$INITHOOKS_PATH/firstboot.d/99reboot" ]
}

@test "the run's limit holds for apt-get update too" {
    # the run may be shorter than the update's own limit
    {
        echo "export SEC_UPDATES=FORCE"
        echo "SEC_UPDATES_TIMEOUT=1"
    } > "$INITHOOKS_CONF"
    hang 'update*'

    run_bounded

    [ "$status" -eq 0 ]
    (( took < 10 ))
    [[ "$(said)" == *"apt-get update did not finish in 1 s"* ]]
}

@test "an upgrade that fails is said in one line naming the daily job" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"
    export UPGRADE_STATUS=100

    run_bounded

    [ "$status" -eq 1 ]
    [ ! -e "$SEC_UPDATES_RECORD" ]
    # dpkg was consistent: nothing to configure after the failure
    [ "$(calls dpkg | grep -c -- '--configure -a')" -eq 1 ]
    [ "$(said | wc -l)" -eq 1 ]
    [[ "$(said)" == *"the upgrade failed (exit 100"*cron-apt* ]]
    [[ "$(calls logger)" == *"the upgrade failed (exit 100"* ]]
}

@test "an upgrade that succeeds leaves no warning in the inithooks log" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"

    run_bounded

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "force" ]
    [ -z "$(said)" ]
}

@test "offline, the one line names the daily job too" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"
    export CURL_STATUS=7

    run_bounded

    [ "$status" -eq 0 ]
    [ "$(said | wc -l)" -eq 1 ]
    [[ "$(said)" == *"cannot reach"*cron-apt* ]]
}

@test "without cron-apt's install action the line says how to install them" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"
    export UPGRADE_STATUS=100
    rm "$SEC_UPDATES_CRONAPT"

    run_bounded

    [ "$status" -eq 1 ]
    [[ "$(said)" != *cron-apt* ]]
    [[ "$(said)" == *"no daily job installs them"*turnkey-install-security-updates* ]]
}

@test "a limit that is not a number of seconds is said, and the default used" {
    {
        echo "export SEC_UPDATES=FORCE"
        echo "SEC_UPDATES_TIMEOUT=15m"
    } > "$INITHOOKS_CONF"

    run_bounded

    [ "$status" -eq 0 ]
    [ "$(cat "$SEC_UPDATES_RECORD")" = "force" ]
    [[ "$(calls logger)" == *"SEC_UPDATES_TIMEOUT=15m is not a number of seconds, 900 used"* ]]
}

# ------------------------------------------------ the hooks after it still run

# run_firstboot: the real run over 95secupdates and a hook after it
run_firstboot() {
    ln -s "$REPO/firstboot.d/95secupdates" "$INITHOOKS_PATH/firstboot.d/95secupdates"
    printf '#!/bin/bash\necho ran > %q\n' "$BATS_TEST_TMPDIR/next" \
        > "$INITHOOKS_PATH/firstboot.d/96next"
    chmod +x "$INITHOOKS_PATH/firstboot.d/96next"
    stub systemctl 'echo running'
    stub confconsole
    stub sleep
    export INITHOOKS_LOCK=$BATS_TEST_TMPDIR/inithooks.lock
    export INITHOOKS_COMPLETE=$BATS_TEST_TMPDIR/inithooks-complete
    {
        echo "INITHOOKS_LOGFILE=$INITHOOKS_LOGFILE"
        echo "RUN_FIRSTBOOT=true"
        echo "REDIRECT_OUTPUT=false"
    } >> "$INITHOOKS_DEFAULT"
    local started=$SECONDS
    run timeout 60 "$REPO/run"
    took=$((SECONDS - started))
}

@test "an upgrade that hangs does not stop the hooks after it" {
    export INITHOOKS_UNATTENDED="the console has no size"
    echo "SEC_UPDATES_TIMEOUT=2" > "$INITHOOKS_CONF"
    hang '*dist-upgrade*'

    run_firstboot

    [ "$status" -eq 0 ]
    (( took < 15 ))
    [ "$(cat "$BATS_TEST_TMPDIR/next")" = ran ]
    grep -qF '[95secupdates] failed - exit code 1' "$INITHOOKS_LOGFILE"
    grep -qF '[96next] successfully completed' "$INITHOOKS_LOGFILE"
}

@test "an upgrade that fails does not stop the hooks after it" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"
    export UPGRADE_STATUS=100

    run_firstboot

    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/next")" = ran ]
    grep -qF '[96next] successfully completed' "$INITHOOKS_LOGFILE"
}

@test "offline, the hook succeeds and the hooks after it run" {
    echo "export SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"
    export CURL_STATUS=7

    run_firstboot

    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/next")" = ran ]
    grep -qF '[95secupdates] successfully completed' "$INITHOOKS_LOGFILE"
}
