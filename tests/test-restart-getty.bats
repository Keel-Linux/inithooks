#!/usr/bin/env bats
# Tests for bin/restart-getty: the login prompt comes back on the tty the
# first boot wizard used, once inithooks.service is over.
#
# In a container there is no /dev/tty0, so getty@tty1.service is skipped by
# its ConditionPathExists and the console was left dead after the wizard's
# last screen (plain LXC, Proxmox). The script then runs agetty on the
# wizard's tty itself, in a transient unit.
#
# systemctl and systemd-run are stubs that answer from a scratch state
# directory; the ttys are scratch files and links, resolved by the real
# readlink, the way /dev/tty1 -> lxc/tty1 is in an LXC container.
#
# Refutations are written "run ! cmd", never a bare "! cmd": bash does not
# apply errexit to a negated command, so a bare one asserts nothing.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..
SCRIPT=$REPO/bin/restart-getty

setup() {
    setup_stubs
    STATE=$BATS_TEST_TMPDIR/state
    mkdir -p "$STATE/active" "$STATE/startable" "$STATE/ttypath" "$STATE/fail-start"
    stub sleep

    # systemctl: is-active, show -P TTYPath, start and reset-failed, from
    # $STATE. inithooks.service stays active for as many checks as
    # $STATE/inithooks-active says.
    stub systemctl "state='$STATE'
unit=\${*: -1}
case \$1 in
    is-active)
        if [[ \$unit == inithooks.service ]]; then
            n=\$(cat \"\$state/inithooks-active\" 2>/dev/null || echo 0)
            if (( n > 0 )); then
                echo \$((n - 1)) > \"\$state/inithooks-active\"
                exit 0
            fi
            exit 3
        fi
        [[ -e \"\$state/active/\$unit\" ]] && exit 0
        exit 3 ;;
    show)
        cat \"\$state/ttypath/\$unit\" 2>/dev/null
        exit 0 ;;
    start)
        [[ -e \"\$state/fail-start/\$unit\" ]] && exit 1
        [[ -e \"\$state/startable/\$unit\" ]] && touch \"\$state/active/\$unit\"
        exit 0 ;;
esac
exit 0"

    # systemd-run: the unit it names becomes active, unless the test said
    # it fails ($STATE/run-fails) or dies at once ($STATE/run-dies)
    stub systemd-run "state='$STATE'
[[ -e \"\$state/run-fails\" ]] && exit 1
for arg; do
    [[ \$arg == --unit=* ]] && unit=\${arg#--unit=}
done
[[ -e \"\$state/run-dies\" ]] || touch \"\$state/active/\$unit\"
exit 0"

    DEV=$BATS_TEST_TMPDIR/dev
    mkdir -p "$DEV/lxc" "$DEV/pts"
    touch "$DEV/lxc/tty1" "$DEV/pts/1" "$DEV/tty1.vt"
    UNITS=$BATS_TEST_TMPDIR/units
    mkdir -p "$UNITS"
    touch "$UNITS/getty@.service" "$UNITS/container-getty@.service"

    export _STARTED_BY_SYSTEMD=yes
    export GETTY_WANTS=$BATS_TEST_TMPDIR/getty.target.wants
    mkdir -p "$GETTY_WANTS"
}

# container: /dev/tty1 is a link to lxc/tty1, and the wizard ran on it
container() {
    ln -s lxc/tty1 "$DEV/tty1"
    tty_of inithooks.service "$DEV/tty1"
}

# vm: /dev/tty1 is the virtual console itself
vm() {
    ln -s tty1.vt "$DEV/tty1"
    tty_of inithooks.service "$DEV/tty1"
}

# enable UNIT TEMPLATE: the link systemctl enable leaves in getty.target.wants
enable() {
    ln -s "$UNITS/$2" "$GETTY_WANTS/$1"
}

# tty_of UNIT PATH: what systemctl show -P TTYPath UNIT answers
tty_of() {
    echo "$2" > "$STATE/ttypath/$1"
}

startable() {
    touch "$STATE/startable/$1"
}

active() {
    touch "$STATE/active/$1"
}

@test "does nothing when not started by systemd" {
    unset _STARTED_BY_SYSTEMD

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"not started by systemd"* ]]
    [ -z "$(calls systemctl)" ]
    [ -z "$(calls systemd-run)" ]
}

@test "on a VM, getty@tty1 is started on the wizard's tty" {
    vm
    enable getty@tty1.service getty@.service
    tty_of getty@tty1.service "$DEV/tty1"
    startable getty@tty1.service

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'start getty@tty1.service' <<< "$(calls systemctl)"
    [[ "$output" == *"getty@tty1.service started"* ]]
    [ -z "$(calls systemd-run)" ]
}

@test "a getty already running is left alone" {
    vm
    enable getty@tty1.service getty@.service
    tty_of getty@tty1.service "$DEV/tty1"
    active getty@tty1.service

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"getty@tty1.service already running"* ]]
    run ! grep -q '^start' <<< "$(calls systemctl)"
    [ -z "$(calls systemd-run)" ]
}

@test "in plain LXC, agetty runs on lxc/tty1 when getty@tty1 is skipped" {
    container
    enable getty@tty1.service getty@.service
    tty_of getty@tty1.service "$DEV/tty1"
    # no /dev/tty0: the unit's condition fails, start exits 0, nothing runs

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'start getty@tty1.service' <<< "$(calls systemctl)"
    [[ "$output" == *"getty@tty1.service did not start"* ]]
    run -0 calls systemd-run
    [[ "$output" == *"--unit=inithooks-getty-tty1.service"* ]]
    [[ "$output" == *"--property=TTYPath=$DEV/lxc/tty1"* ]]
    [[ "$output" == *"--property=StandardInput=tty"* ]]
    [[ "$output" == *"--property=Restart=always"* ]]
    [[ "$output" == *"agetty -o -- \\u --noreset --noclear - linux" ]]
    [ -e "$STATE/active/inithooks-getty-tty1.service" ]
}

@test "on Proxmox, container-getty@1 on lxc/tty1 is started, no agetty of ours" {
    container
    enable container-getty@1.service container-getty@.service
    tty_of container-getty@1.service "$DEV/lxc/tty1"
    startable container-getty@1.service

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'start container-getty@1.service' <<< "$(calls systemctl)"
    [ -z "$(calls systemd-run)" ]
}

@test "a getty unit on another tty is not started, agetty runs on the wizard's" {
    container
    enable container-getty@1.service container-getty@.service
    tty_of container-getty@1.service "$DEV/pts/1"
    startable container-getty@1.service

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"container-getty@1.service is on $DEV/pts/1, not $DEV/lxc/tty1"* ]]
    run ! grep -q '^start' <<< "$(calls systemctl)"
    grep -q -- "--property=TTYPath=$DEV/lxc/tty1" <<< "$(calls systemd-run)"
}

@test "with no getty unit enabled, agetty runs on the wizard's tty" {
    container
    # a dangling link is not an enabled unit
    ln -s "$UNITS/gone@.service" "$GETTY_WANTS/getty@tty1.service"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"No getty unit enabled"* ]]
    grep -q -- "--property=TTYPath=$DEV/lxc/tty1" <<< "$(calls systemd-run)"
}

@test "a getty unit that fails to start falls back to agetty" {
    vm
    enable getty@tty1.service getty@.service
    tty_of getty@tty1.service "$DEV/tty1"
    touch "$STATE/fail-start/getty@tty1.service"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"getty@tty1.service did not start"* ]]
    grep -q -- "--property=TTYPath=$DEV/tty1.vt" <<< "$(calls systemd-run)"
}

@test "the wizard's tty defaults to /dev/tty1" {
    enable getty@tty1.service getty@.service
    echo /dev/tty1 > "$STATE/ttypath/getty@tty1.service"
    startable getty@tty1.service
    # inithooks.service answers no TTYPath

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'start getty@tty1.service' <<< "$(calls systemctl)"
}

@test "an agetty of ours already running is left alone" {
    container
    active inithooks-getty-tty1.service

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks-getty-tty1.service already running"* ]]
    [ -z "$(calls systemd-run)" ]
}

@test "a failed agetty unit of an earlier run is reset before the new one" {
    container

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'reset-failed inithooks-getty-tty1.service' <<< "$(calls systemctl)"
}

@test "systemd-run failing is fatal, and says where to report it" {
    container
    touch "$STATE/run-fails"

    run "$SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to start agetty on $DEV/lxc/tty1"* ]]
    [[ "$output" == *"Please report to https://github.com/Keel-Linux/inithooks/issues"* ]]
    run ! grep -qi turnkeylinux <<< "$output"
}

@test "an agetty unit that does not stay up is fatal" {
    container
    touch "$STATE/run-dies"

    run "$SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"inithooks-getty-tty1.service failed"* ]]
}

@test "waits for inithooks.service to stop before starting the getty" {
    vm
    enable getty@tty1.service getty@.service
    tty_of getty@tty1.service "$DEV/tty1"
    startable getty@tty1.service
    echo 3 > "$STATE/inithooks-active"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"waiting 10 more seconds"* ]]
    [ "$(calls sleep | wc -l)" -eq 3 ]
    grep -qx 'start getty@tty1.service' <<< "$(calls systemctl)"
}

@test "gives up when inithooks.service does not stop in 10 seconds" {
    vm
    enable getty@tty1.service getty@.service
    echo 100 > "$STATE/inithooks-active"

    run "$SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"inithooks.service did not stop"* ]]
    [ "$(calls sleep | wc -l)" -eq 10 ]
    run ! grep -q '^start' <<< "$(calls systemctl)"
    [ -z "$(calls systemd-run)" ]
}
