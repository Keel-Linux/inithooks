#!/usr/bin/env bats
# Tests for lib/reboot-wait.sh, bin/reboot-when-idle and firstboot.d/99reboot:
# a reboot for a new kernel waits while an SSH session is open or keel-init
# runs (maintainer decision 2026-11-26). The updates are installed before;
# only the reboot waits. With nothing open, the reboot is at once, as
# before. While something is open, a transient unit (systemd-run) waits
# for it; after REBOOT_WAIT_MAX seconds an SSH session no longer holds the
# reboot, keel-init always does.
#
# pgrep, init, sleep, logger and systemd-run are stubs. pgrep answers from
# two files: ssh-open and keel-init-open, each holding how many more calls
# find the process open.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..

setup() {
    setup_stubs
    stub logger
    stub init
    stub sleep
    stub systemd-run
    OPEN=$BATS_TEST_TMPDIR
    echo 0 > "$OPEN/ssh-open"
    echo 0 > "$OPEN/keel-init-open"
    stub pgrep "case \"\$*\" in
    *sshd*) file='$OPEN/ssh-open' ;;
    *keel-init*) file='$OPEN/keel-init-open' ;;
    *) exit 2 ;;
esac
left=\$(cat \"\$file\")
if [[ \$left == forever ]]; then exit 0; fi
if (( left > 0 )); then echo \$((left - 1)) > \"\$file\"; exit 0; fi
exit 1"
    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH/bin" "$INITHOOKS_PATH/firstboot.d"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
    cp "$REPO/bin/reboot-when-idle" "$INITHOOKS_PATH/bin/"
    export INITHOOKS_CONF=$BATS_TEST_TMPDIR/inithooks.conf
    export INITHOOKS_DEFAULT=$BATS_TEST_TMPDIR/default-inithooks
    {
        echo "INITHOOKS_PATH=$INITHOOKS_PATH"
        echo "INITHOOKS_CONF=$INITHOOKS_CONF"
    } > "$INITHOOKS_DEFAULT"
    export INITHOOKS_LOGFILE=$BATS_TEST_TMPDIR/inithooks.log
    export REBOOT_WAIT_MAX=90 REBOOT_WAIT_STEP=30
}

@test "with nothing open the machine reboots at once" {
    source "$REPO/lib/reboot-wait.sh"

    reboot_when_idle

    [ "$(calls init)" = 6 ]
    [ -z "$(calls systemd-run)" ]
}

@test "an open SSH session puts the reboot off to a unit that waits" {
    echo forever > "$OPEN/ssh-open"
    source "$REPO/lib/reboot-wait.sh"

    run --separate-stderr reboot_when_idle

    [ "$status" -eq 0 ]
    [ -z "$(calls init)" ]
    [ "$(calls systemd-run)" = "--no-block --unit=inithooks-reboot-when-idle --description=Reboot for the new kernel once no SSH session and no keel-init remain $INITHOOKS_PATH/bin/reboot-when-idle" ]
    [[ "$stderr" == *"the reboot waits"*"at most 90 s"* ]]
}

@test "a keel-init that runs puts the reboot off" {
    echo forever > "$OPEN/keel-init-open"
    source "$REPO/lib/reboot-wait.sh"

    reboot_when_idle

    [ -z "$(calls init)" ]
    [ -n "$(calls systemd-run)" ]
}

@test "a unit that cannot start leaves the reboot to the operator" {
    echo forever > "$OPEN/ssh-open"
    stub systemd-run 'exit 1'
    source "$REPO/lib/reboot-wait.sh"

    run --separate-stderr reboot_when_idle

    [ "$status" -eq 0 ]
    [ -z "$(calls init)" ]
    [[ "$stderr" == *"reboot by hand"* ]]
}

@test "the unit reboots once the SSH session is closed" {
    echo 2 > "$OPEN/ssh-open"

    run --separate-stderr "$INITHOOKS_PATH/bin/reboot-when-idle"

    [ "$status" -eq 0 ]
    [ "$(calls init)" = 6 ]
    [ "$(calls sleep)" = "30
30" ]
    [[ "$stderr" == *"no SSH session and no keel-init remain"* ]]
}

@test "after the limit an SSH session no longer holds the reboot" {
    echo forever > "$OPEN/ssh-open"

    run --separate-stderr "$INITHOOKS_PATH/bin/reboot-when-idle"

    [ "$status" -eq 0 ]
    [ "$(calls init)" = 6 ]
    [ "$(calls sleep | wc -l)" -eq 3 ]
    [[ "$stderr" == *"90 s"*"SSH session is still open"* ]]
}

@test "keel-init holds the reboot until it ends, within the limit" {
    echo 2 > "$OPEN/keel-init-open"

    run "$INITHOOKS_PATH/bin/reboot-when-idle"

    [ "$status" -eq 0 ]
    [ "$(calls init)" = 6 ]
    [ "$(calls sleep | wc -l)" -eq 2 ]
}

@test "after the limit keel-init no longer holds the reboot either" {
    echo forever > "$OPEN/keel-init-open"

    run --separate-stderr "$INITHOOKS_PATH/bin/reboot-when-idle"

    [ "$status" -eq 0 ]
    [ "$(calls init)" = 6 ]
    [ "$(calls sleep | wc -l)" -eq 3 ]
    [[ "$stderr" == *"90 s"*"keel-init is still running"* ]]
}

@test "only root's sshd sessions and keel-init count" {
    source "$REPO/lib/reboot-wait.sh"

    reboot_ssh_open || true
    reboot_keel_init || true

    [ "$(calls pgrep)" = "-u root -f ^sshd(-session)?: [^/]
-u root -x keel-init|turnkey-init" ]
}

@test "99reboot with an SSH session open installs nothing more and waits" {
    echo forever > "$OPEN/ssh-open"
    cp "$REPO/firstboot.d/99reboot" "$INITHOOKS_PATH/firstboot.d/"
    export INITHOOKS_UNATTENDED="an SSH key came from the cloud-init drive"

    # 99reboot ships not executable: 95secupdates arms it
    run bash "$INITHOOKS_PATH/firstboot.d/99reboot"

    [ "$status" -eq 0 ]
    [ -z "$(calls init)" ]
    [ -n "$(calls systemd-run)" ]
}

@test "99reboot with nothing open reboots at once" {
    cp "$REPO/firstboot.d/99reboot" "$INITHOOKS_PATH/firstboot.d/"
    echo "SEC_UPDATES=FORCE" > "$INITHOOKS_CONF"

    # 99reboot ships not executable: 95secupdates arms it
    run bash "$INITHOOKS_PATH/firstboot.d/99reboot"

    [ "$status" -eq 0 ]
    [ "$(calls init)" = 6 ]
}
