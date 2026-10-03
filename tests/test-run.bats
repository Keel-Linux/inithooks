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

# The silent gaps of a first boot (2026-10-02, a Web container on Proxmox
# VE: the console stayed on "Did you save the password?" after <Saved>
# until the next screen came). Before each hook from 30 on, run waited up
# to 10 s for a system still starting, without a word on the screen: 30 s
# before the Keel Cloud screen alone, more on a slow host.

@test "a starting system is waited for once, not before every hook" {
    stub systemctl 'echo starting'
    probe 30first
    probe 75second
    probe 80third

    run_runner

    [ "$status" -eq 0 ]
    [ "$(wc -l < "$SEEN")" -eq 3 ]
    # one second at a time (the 2 s before confconsole is not a wait)
    [ "$(calls sleep | grep -cx 1)" -eq 10 ]
}

@test "the wait ends as soon as the system is running" {
    # starting for the first two questions, running from the third on
    stub systemctl "n=\$(wc -l < '$STUBS/systemctl.calls')
if (( n <= 2 )); then echo starting; else echo running; fi"
    probe 30first
    probe 75second

    run_runner

    [ "$status" -eq 0 ]
    [ "$(calls sleep | grep -cx 1)" -eq 1 ]
    # the log line, then one question per second waited
    [ "$(calls systemctl | wc -l)" -le 4 ]
}

# run_on_terminal
# The runner with a terminal for its standard output, the way
# inithooks.service gives it tty1: a sized one, as a VT or an attached
# console is. script gives the pty no size when its own input is none.
run_on_terminal() {
    INITHOOKS_DEFAULT=$DEFAULT run script -qec \
        "stty rows 24 cols 80; $BATS_TEST_DIRNAME/../run" /dev/null < /dev/null
}

# run_on_unattended_terminal
# The runner on a terminal nobody is attached to: a pty with no size, as
# tty1 of an LXC container is until pct console or lxc-console attaches.
run_on_unattended_terminal() {
    INITHOOKS_DEFAULT=$DEFAULT run script -qec "$BATS_TEST_DIRNAME/../run" \
        /dev/null < /dev/null
}

# run_on_unread_terminal
# The runner on a sized terminal whose master nobody reads: what is written
# fills the pty's buffer and the next write blocks, which is what held the
# published core's first boot for good on 2026-10-03. The notices have one
# second to reach it.
run_on_unread_terminal() {
    INITHOOKS_DEFAULT=$DEFAULT NOTICE_TIMEOUT=1 \
        run timeout 60 python3 - "$BATS_TEST_DIRNAME/../run" <<'PY'
import fcntl, os, pty, struct, subprocess, sys, termios
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
# close_fds=False: the descriptor kcov traces on (tests/coverage.sh) must
# reach the runner
proc = subprocess.run([sys.argv[1]], stdin=subprocess.DEVNULL, stdout=slave,
                      stderr=sys.stderr, close_fds=False)
sys.exit(proc.returncode)
PY
}

@test "each first boot hook is named on the terminal while it runs" {
    stub dialog
    probe 15regen-sslcert
    probe 75keel-role

    run_on_terminal

    [ "$status" -eq 0 ]
    grep -q -- '--infobox Configuring regen-sslcert... please wait' \
        "$STUBS/dialog.calls"
    grep -q -- '--infobox Configuring keel-role... please wait' \
        "$STUBS/dialog.calls"
    grep -q -- '--backtitle Keel Linux - First boot configuration' \
        "$STUBS/dialog.calls"
}

@test "the wait for a starting system is shown on the terminal" {
    stub dialog
    stub systemctl 'echo starting'
    probe 30first

    run_on_terminal

    [ "$status" -eq 0 ]
    grep -q -- '--infobox Waiting for the system to finish starting' \
        "$STUBS/dialog.calls"
}

@test "nothing is drawn when the output is not a terminal" {
    stub dialog
    stub systemctl 'echo starting'
    probe 30first

    run_runner

    [ "$status" -eq 0 ]
    [ -z "$(calls dialog)" ]
    grep -q "first boot notices not drawn: the output is not a terminal" \
        "$ROOT/inithooks.log"
}

@test "nothing is drawn on a console nobody is attached to, and the log says so" {
    stub dialog
    probe 15first
    probe 30second

    run_on_unattended_terminal

    [ "$status" -eq 0 ]
    [ "$(wc -l < "$SEEN")" -eq 2 ]
    [ -z "$(calls dialog)" ]
    [ "$(grep -c "first boot notices not drawn" "$ROOT/inithooks.log")" -eq 1 ]
    grep -q "notices not drawn: the console has no size" "$ROOT/inithooks.log"
    grep -q "notices not drawn: the console has no size" "$STUBS/logger.calls"
}

@test "a sized console nobody reads is found before any notice" {
    # dialog here writes more than the pty holds, so its write would block
    # the way the real one did; the console's probe (lib/console.sh) finds
    # it first, and nothing is drawn
    stub dialog 'printf "%0131072d" 0'
    probe 15first
    probe 30second
    probe 31third

    run_on_unread_terminal

    [ "$status" -eq 0 ]
    [ "$(wc -l < "$SEEN")" -eq 3 ]
    [ -z "$(calls dialog)" ]
    grep -q "notices not drawn: the console did not take a write in 1 s" \
        "$ROOT/inithooks.log"
}

@test "a console that stops taking notices does not hold the boot" {
    # the probe passes, the notice after it does not reach the console;
    # the runner gives it NOTICE_TIMEOUT and goes on without notices, and
    # the hooks after it are told nobody can answer
    stub dialog 'printf "%0131072d" 0'
    probe 15first
    probe 30second 'echo "$INITHOOKS_UNATTENDED" > '"'$ROOT/told'"
    export CONSOLE_PROBE_BYTES=1

    run_on_unread_terminal

    [ "$status" -eq 0 ]
    [ "$(wc -l < "$SEEN")" -eq 2 ]
    [ "$(calls dialog | wc -l)" -eq 1 ]
    grep -q "notices not drawn: the console did not take a notice in 1 s" \
        "$ROOT/inithooks.log"
    [ "$(cat "$ROOT/told")" = "the console did not take a notice in 1 s, nobody is reading it" ]
}

@test "nobody to answer: the hooks are told, and what they print goes to the log" {
    # tty1 of a container nobody is attached to holds what is written to
    # it until its buffer is full, and then blocks the writer for good:
    # 95secupdates prints the whole upgrade
    stub dialog
    probe 15first 'echo "$INITHOOKS_UNATTENDED" > '"'$ROOT/told'"'; echo HOOK-PRINTED'

    run_on_unattended_terminal

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT/told")" = "the console has no size, nobody is attached to it" ]
    grep -qx HOOK-PRINTED "$ROOT/inithooks.log"
    [[ "$output" != *HOOK-PRINTED* ]]
}

@test "nobody to answer: confconsole still gets the console" {
    # for whoever attaches to it later
    stub confconsole '[[ -t 1 ]] && echo terminal > '"'$ROOT/confconsole'"
    probe 15first

    run_on_unattended_terminal

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT/confconsole")" = terminal ]
}

@test "somebody to answer: the hooks are told, and print on the console" {
    stub dialog
    probe 15first 'echo "$INITHOOKS_UNATTENDED" > '"'$ROOT/told'"'; echo HOOK-PRINTED'

    run_on_terminal

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT/told")" = no ]
    [[ "$output" == *HOOK-PRINTED* ]]
    run ! grep -q HOOK-PRINTED "$ROOT/inithooks.log"
}

@test "a run whose output goes to the log draws nothing either" {
    sed -i 's/REDIRECT_OUTPUT=false/REDIRECT_OUTPUT=true/' "$DEFAULT"
    # the xen marker: the log is sent to the console by another service,
    # so this run starts no tail of its own
    mkdir -p "$ROOT/turnkey-info"
    touch "$ROOT/turnkey-info/xen"
    echo "TKLINFO=$ROOT/turnkey-info" >> "$DEFAULT"
    stub dialog
    probe 30first

    run_on_terminal

    [ "$status" -eq 0 ]
    [ -z "$(calls dialog)" ]
}

@test "everyboot hooks are not announced" {
    stub dialog
    mkdir -p "$LIB/everyboot.d"
    cat > "$LIB/everyboot.d/01quiet" <<PROBE
#!/bin/bash
true
PROBE
    chmod +x "$LIB/everyboot.d/01quiet"

    run_on_terminal

    [ "$status" -eq 0 ]
    [ -z "$(calls dialog)" ]
}

@test "a notice dialog cannot draw does not stop the run" {
    stub dialog 'echo "Error opening terminal: unknown." >&2; exit 255'
    probe 15first
    probe 30second

    run_on_terminal

    [ "$status" -eq 0 ]
    [ "$(wc -l < "$SEEN")" -eq 2 ]
    [[ "$output" != *"Error opening terminal"* ]]
}
