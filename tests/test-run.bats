#!/usr/bin/env bats
# run: what the hooks are given
#
# The runner is the only thing between /etc/default/inithooks and a hook, so
# the contract under test is what a hook sees in its environment. A hook whose
# job is to create the conf file gets the path before the file is there; that
# is what an appliance first boot found missing.

bats_require_minimum_version 1.5.0

load helpers

# sleep is a stub in these tests; a daemon a hook leaves behind needs the
# real one
REAL_SLEEP=$(command -v sleep)

setup() {
    setup_stubs
    ROOT=$BATS_TEST_TMPDIR
    export INITHOOKS_LOCK=$ROOT/inithooks.lock
    export INITHOOKS_COMPLETE=$ROOT/inithooks-complete
    FIFO=$ROOT/release
    CONF=$ROOT/inithooks.conf
    LIB=$ROOT/lib
    SEEN=$ROOT/seen
    mkdir -p "$LIB/firstboot.d"

    stub logger
    stub systemctl 'echo running'
    stub confconsole
    stub sleep

    DEFAULT=$ROOT/default-inithooks
    cat > "$DEFAULT" <<EOF
INITHOOKS_CONF=$CONF
INITHOOKS_PATH=$LIB
INITHOOKS_LOGFILE=$ROOT/inithooks.log
RUN_FIRSTBOOT=true
REDIRECT_OUTPUT=false
EOF
}

# probe NAME [BODY]
# A firstboot hook that records what it was given, then runs BODY.
probe() {
    local name=$1 body=${2:-true}
    cat > "$LIB/firstboot.d/$name" <<EOF
#!/bin/bash
printf '%s\n' "\$INITHOOKS_CONF" >> '$SEEN'
$body
EOF
    chmod +x "$LIB/firstboot.d/$name"
}

teardown() {
    let_go "$FIFO"
}

run_runner() {
    INITHOOKS_DEFAULT=$DEFAULT run "$BATS_TEST_DIRNAME/../run"
}

@test "a hook is given the conf path when the conf file does not exist" {
    probe 01probe
    [ ! -e "$CONF" ]

    run_runner

    [ "$status" -eq 0 ]
    [ "$(cat "$SEEN")" = "$CONF" ]
}

@test "a hook is given the conf path when the conf file does exist" {
    echo 'export ROOT_PASS=preseeded' > "$CONF"
    probe 01probe

    run_runner

    [ "$(cat "$SEEN")" = "$CONF" ]
}

@test "the values of an existing conf file reach the hook" {
    echo 'export ROOT_PASS=preseeded' > "$CONF"
    cat > "$LIB/firstboot.d/01probe" <<EOF
#!/bin/bash
printf '%s\n' "\$ROOT_PASS" >> '$SEEN'
EOF
    chmod +x "$LIB/firstboot.d/01probe"

    run_runner

    [ "$(cat "$SEEN")" = "preseeded" ]
}

@test "a hook that creates the conf file hands it to the next hook" {
    probe 29creates "printf 'export ROOT_PASS=generated\n' > \"\$INITHOOKS_CONF\""
    cat > "$LIB/firstboot.d/30reads" <<EOF
#!/bin/bash
printf '%s\n' "\$ROOT_PASS" >> '$SEEN'
EOF
    chmod +x "$LIB/firstboot.d/30reads"

    run_runner

    [ "$(tail -1 "$SEEN")" = "generated" ]
}

@test "the preseed hook of the headless overlay writes the conf file" {
    local checkout=${BUILDTASKS:-$BATS_TEST_DIRNAME/../../buildtasks}
    local overlay=$checkout/patches/headless/overlay
    local hook=$overlay/usr/lib/inithooks/firstboot.d/29preseed
    if [ ! -x "$hook" ]; then
        skip "no buildtasks overlay at $checkout (set BUILDTASKS)"
    fi
    cp "$hook" "$LIB/firstboot.d/29preseed"

    run_runner

    [ "$status" -eq 0 ]
    grep -q '^export ROOT_PASS=' "$CONF"
    grep -q '^export AUTO_RUN=TRUE' "$CONF"
    run ! grep -qi 'ambiguous redirect' "$ROOT/inithooks.log"
}

@test "a failing hook is logged and the run carries on" {
    probe 01fails 'exit 1'
    probe 02runs

    run_runner

    [ "$status" -eq 0 ]
    [ "$(wc -l < "$SEEN")" -eq 2 ]
    grep -q '01fails\] failed - exit code 1' "$ROOT/inithooks.log"
}

@test "firstboot hooks do not run when RUN_FIRSTBOOT is not true" {
    sed -i 's/RUN_FIRSTBOOT=true/RUN_FIRSTBOOT=false/' "$DEFAULT"
    probe 01probe

    run_runner

    [ "$status" -eq 0 ]
    [ ! -e "$SEEN" ]
}

# The first boot lock (Keel-Linux/inithooks#24): lib/init-lock.sh has the
# functions, these tests what run does with them.

@test "the lock is held while a hook runs" {
    probe 01probe "flock -n '$INITHOOKS_LOCK' true || echo held >> '$SEEN'"

    run_runner

    [ "$status" -eq 0 ]
    [ "$(tail -1 "$SEEN")" = held ]
}

@test "a hook is not given the lock's descriptor" {
    probe 01probe "ls -l /proc/\$\$/fd > '$ROOT/fds'"

    run_runner

    [ "$status" -eq 0 ]
    [ -s "$ROOT/fds" ]
    run ! grep -q "$INITHOOKS_LOCK" "$ROOT/fds"
}

@test "the lock is released before confconsole starts" {
    stub confconsole "flock -n '$INITHOOKS_LOCK' true && echo free >> '$SEEN'"

    run_runner

    [ "$status" -eq 0 ]
    [ "$(cat "$SEEN")" = free ]
}

@test "a daemon a hook leaves behind does not keep the lock" {
    probe 01daemon "'$REAL_SLEEP' 30 > /dev/null 2>&1 &
echo \$! > '$ROOT/daemon'"

    run_runner
    local daemon
    daemon=$(cat "$ROOT/daemon")

    [ "$status" -eq 0 ]
    kill -0 "$daemon"
    flock -n "$INITHOOKS_LOCK" true
    kill "$daemon"
}

@test "run waits for a run in progress and reads the RUN_FIRSTBOOT it left" {
    probe 01probe
    mkfifo "$FIFO"
    # a keel-init that finishes the first boot: 98finalize sets the flag
    flock "$INITHOOKS_LOCK" -c "read -r _ < '$FIFO'
sed -i 's/RUN_FIRSTBOOT=true/RUN_FIRSTBOOT=false/' '$DEFAULT'" &
    local holder=$!
    eventually bash -c "! flock -n '$INITHOOKS_LOCK' true"
    INITHOOKS_DEFAULT=$DEFAULT "$BATS_TEST_DIRNAME/../run" \
        > "$ROOT/out" 2> "$ROOT/err" &
    local runner=$!
    # waiting and not finished: a run that did not wait would be done, or
    # would never print this
    eventually grep -q waiting "$ROOT/err"
    kill -0 "$runner"

    echo go > "$FIFO"
    wait "$holder"
    wait "$runner"

    # the firstboot hook did not run a second time; the runner did finish
    [ ! -e "$SEEN" ]
    grep -q 'Inithooks run completed' "$ROOT/inithooks.log"
}

@test "run fails, running nothing, when the lock cannot be opened" {
    probe 01probe
    export INITHOOKS_LOCK=$ROOT/no/such/dir/lock

    run_runner

    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot open the first boot lock"* ]]
    [ ! -e "$SEEN" ]
}

@test "a firstboot hook finds the run described in the lock" {
    probe 30probe "cp '$INITHOOKS_LOCK' '$ROOT/described'"

    run_runner

    [ "$status" -eq 0 ]
    grep -qx 'kind=run' "$ROOT/described"
    grep -qx 'phase=firstboot' "$ROOT/described"
    grep -qx 'hook=30probe' "$ROOT/described"
    grep -qx 'preseeded=' "$ROOT/described"
}

@test "a preseeded first boot says so in the lock" {
    echo 'export AUTO_RUN=TRUE' > "$CONF"
    probe 95probe "cp '$INITHOOKS_LOCK' '$ROOT/described'"

    run_runner

    grep -qx 'preseeded=yes' "$ROOT/described"
}

@test "an everyboot hook finds the everyboot phase in the lock" {
    mkdir -p "$LIB/everyboot.d"
    cat > "$LIB/everyboot.d/01probe" <<PROBE
#!/bin/bash
cp '$INITHOOKS_LOCK' '$ROOT/described'
PROBE
    chmod +x "$LIB/everyboot.d/01probe"

    run_runner

    grep -qx 'phase=everyboot' "$ROOT/described"
    grep -qx 'hook=01probe' "$ROOT/described"
}

@test "run marks the boot run of this boot complete" {
    [ ! -e "$INITHOOKS_COMPLETE" ]

    run_runner

    [ "$status" -eq 0 ]
    [ -e "$INITHOOKS_COMPLETE" ]
}
