#!/usr/bin/env bats
# run: what the hooks are given
#
# The runner is the only thing between /etc/default/inithooks and a hook, so
# the contract under test is what a hook sees in its environment. A hook whose
# job is to create the conf file gets the path before the file is there; that
# is what an appliance first boot found missing.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    setup_stubs
    ROOT=$BATS_TEST_TMPDIR
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
