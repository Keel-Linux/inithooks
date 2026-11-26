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
    mkdir -p "$STATE/active" "$STATE/startable" "$STATE/ttypath" "$STATE/fail-start" \
        "$STATE/activestate"
    stub sleep

    # systemctl: is-active, show -P TTYPath and ActiveState, list-jobs,
    # start and reset-failed, from $STATE. Each check of inithooks.service
    # (is-active or ActiveState) takes the next line of
    # $STATE/inithooks-states, and the last line stays (default inactive);
    # list-jobs inithooks.service prints $STATE/inithooks-jobs.
    stub systemctl "state='$STATE'
unit=\${*: -1}
inithooks_state() {
    local f=\"\$state/inithooks-states\"
    [[ -s \"\$f\" ]] || { echo inactive; return; }
    head -n 1 \"\$f\"
    if (( \$(wc -l < \"\$f\") > 1 )); then
        sed -i 1d \"\$f\"
    fi
}
case \$1 in
    is-active)
        if [[ \$unit == inithooks.service ]]; then
            [[ \$(inithooks_state) == active ]] && exit 0
            exit 3
        fi
        [[ -e \"\$state/active/\$unit\" ]] && exit 0
        exit 3 ;;
    show)
        if [[ \$3 == ActiveState && \$unit == inithooks.service ]]; then
            inithooks_state
        elif [[ \$3 == ActiveState ]]; then
            if [[ -e \"\$state/activestate/\$unit\" ]]; then
                cat \"\$state/activestate/\$unit\"
            elif [[ -e \"\$state/active/\$unit\" ]]; then
                echo active
            else
                echo inactive
            fi
        else
            cat \"\$state/ttypath/\$unit\" 2>/dev/null
        fi
        exit 0 ;;
    list-jobs)
        [[ \$unit == inithooks.service ]] && cat \"\$state/inithooks-jobs\" 2>/dev/null
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

@test "an agetty of ours between restarts is left alone" {
    container
    # Restart=always: ActiveState is activating while SubState is auto-restart
    echo activating > "$STATE/activestate/inithooks-getty-tty1.service"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks-getty-tty1.service already running (activating)"* ]]
    [ -z "$(calls systemd-run)" ]
}

@test "a failed agetty unit of an earlier run is reset before the new one" {
    container
    echo failed > "$STATE/activestate/inithooks-getty-tty1.service"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'reset-failed inithooks-getty-tty1.service' <<< "$(calls systemctl)"
    [ -n "$(calls systemd-run)" ]
}

@test "the agetty unit conflicts with inithooks.service" {
    # so a second start of inithooks.service stops it, and the wizard does
    # not share the tty with a login prompt
    container

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -q -- "--property=Conflicts=inithooks.service" <<< "$(calls systemd-run)"
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

# inithooks_states STATE...: the states of inithooks.service, one per check
inithooks_states() {
    printf '%s\n' "$@" > "$STATE/inithooks-states"
}

@test "inithooks.service deactivating is over: the getty starts at once" {
    # ExecStopPost runs while the unit is deactivating; there is no wait
    vm
    enable getty@tty1.service getty@.service
    tty_of getty@tty1.service "$DEV/tty1"
    startable getty@tty1.service
    inithooks_states deactivating

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks.service is not running"* ]]
    [ -z "$(calls sleep)" ]
    grep -qx 'start getty@tty1.service' <<< "$(calls systemctl)"
}

@test "inithooks.service failed is over: the getty starts" {
    # OnFailure starts the script after a failed run
    vm
    enable getty@tty1.service getty@.service
    tty_of getty@tty1.service "$DEV/tty1"
    startable getty@tty1.service
    inithooks_states failed

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'start getty@tty1.service' <<< "$(calls systemctl)"
}

# inithooks#73: the postinst of an upgrade restarts inithooks.service. The
# stop of the restart starts this script (ExecStopPost), and the start of
# the restart puts the console screen on tty1 again. The script must not
# start a getty (it conflicts with inithooks.service and stops the new run)
# and must not fail (the node is then degraded until a reboot). The next
# stop of inithooks.service starts the script again.

@test "inithooks.service restarted: a restart job is queued, no getty, no failure" {
    container
    enable container-getty@1.service container-getty@.service
    tty_of container-getty@1.service "$DEV/lxc/tty1"
    startable container-getty@1.service
    inithooks_states deactivating
    echo '9640 inithooks.service restart running' > "$STATE/inithooks-jobs"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks.service starts again"* ]]
    run ! grep -q '^start' <<< "$(calls systemctl)"
    [ -z "$(calls systemd-run)" ]
    [ -z "$(calls sleep)" ]
}

@test "inithooks.service restarted: a start job is queued, no getty, no failure" {
    container
    enable container-getty@1.service container-getty@.service
    tty_of container-getty@1.service "$DEV/lxc/tty1"
    startable container-getty@1.service
    inithooks_states inactive
    echo '9641 inithooks.service start waiting' > "$STATE/inithooks-jobs"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks.service starts again"* ]]
    run ! grep -q '^start' <<< "$(calls systemctl)"
    [ -z "$(calls systemd-run)" ]
}

@test "inithooks.service restarted: it runs again with the console screen, no getty, no failure" {
    # the race of inithooks#73: the new run is active before the first check
    container
    enable container-getty@1.service container-getty@.service
    tty_of container-getty@1.service "$DEV/lxc/tty1"
    startable container-getty@1.service
    inithooks_states active

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks.service starts again"* ]]
    run ! grep -q '^start' <<< "$(calls systemctl)"
    [ -z "$(calls systemd-run)" ]
    [ -z "$(calls sleep)" ]
}

@test "inithooks.service restarted: it is activating, no getty, no failure" {
    container
    enable container-getty@1.service container-getty@.service
    tty_of container-getty@1.service "$DEV/lxc/tty1"
    startable container-getty@1.service
    inithooks_states activating

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks.service starts again"* ]]
    run ! grep -q '^start' <<< "$(calls systemctl)"
    [ -z "$(calls systemd-run)" ]
}

@test "inithooks.service restarted: it is reloading, no getty, no failure" {
    container
    enable container-getty@1.service container-getty@.service
    tty_of container-getty@1.service "$DEV/lxc/tty1"
    inithooks_states reloading

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks.service starts again"* ]]
    run ! grep -q '^start' <<< "$(calls systemctl)"
}

@test "the jobs are read before the state" {
    # a start job that ends between the reads leaves the unit active
    container
    inithooks_states active

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    run -0 grep -n -e '^list-jobs' -e '^show -P ActiveState inithooks' <<< "$(calls systemctl)"
    [[ "${lines[0]}" == *list-jobs* ]]
}

@test "a stop job of inithooks.service is not a new run: the getty starts" {
    vm
    enable getty@tty1.service getty@.service
    tty_of getty@tty1.service "$DEV/tty1"
    startable getty@tty1.service
    inithooks_states inactive
    echo '9642 inithooks.service stop running' > "$STATE/inithooks-jobs"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'start getty@tty1.service' <<< "$(calls systemctl)"
}
