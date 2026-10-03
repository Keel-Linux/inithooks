#!/usr/bin/env bats
# Tests for lib/console.sh, whether anybody can answer a first boot screen,
# and for every hook that draws one: on a console nobody can answer, each
# hook asks nothing and finishes, as if no answer had been given, and says
# so in one line.
#
# The published Web 19.0-3 booted headless in an LXC container on
# 2026-10-03 stopped at 31fqdn: its screen was drawn on tty1, a pty whose
# master nobody read, and waited for an answer nobody could give. The
# consoles here are ptys whose master is never read, one with no size (an
# LXC tty nobody is attached to) and one with a size (a console that was
# sized and then left); the pty is the hook's terminal, standard input and
# output, as inithooks.service gives it tty1. Every screen a hook could
# draw is a stand-in that never returns, and the whole hook has DEADLINE
# seconds: a hook that asks fails here instead of hanging.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..
DEADLINE=30

setup() {
    setup_stubs
    stub logger
    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH/bin" "$INITHOOKS_PATH/firstboot.d"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
    export INITHOOKS_CONF=$BATS_TEST_TMPDIR/inithooks.conf
    export INITHOOKS_DEFAULT=$BATS_TEST_TMPDIR/default-inithooks
    {
        echo "INITHOOKS_PATH=$INITHOOKS_PATH"
        echo "INITHOOKS_CONF=$INITHOOKS_CONF"
    } > "$INITHOOKS_DEFAULT"
    export INITHOOKS_LOGFILE=$BATS_TEST_TMPDIR/inithooks.log
    export CONSOLE_TIMEOUT=1
    OUT=$BATS_TEST_TMPDIR/out
    write_decided
    unset INITHOOKS_UNATTENDED
}

# on_pty SIZED CMD...
# CMD with a new pty for its controlling terminal, standard input and
# output, whose master is never read; SIZED is sized (24x80) or unsized
# (0 0, what stty answers on an LXC tty nobody is attached to). Standard
# error is the test's. Fails when CMD has not finished in DEADLINE s.
on_pty() {
    timeout "$DEADLINE" python3 - "$@" <<'PY'
import fcntl, os, pty, struct, subprocess, sys, termios
sized, cmd = sys.argv[1], sys.argv[2:]
master, slave = pty.openpty()
if sized == "sized":
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
def controlling():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
# close_fds=False: the descriptor kcov traces on (tests/coverage.sh) must
# reach CMD
proc = subprocess.run(cmd, stdin=slave, stdout=slave, preexec_fn=controlling,
                      close_fds=False)
sys.exit(proc.returncode)
PY
}

# write_decided
# DECIDED, a script that asks console_unattended and writes its status
# and INITHOOKS_UNATTENDED, as a child process sees it, into OUT.
write_decided() {
    DECIDED=$BATS_TEST_TMPDIR/decided
    cat > "$DECIDED" <<EOF
source '$REPO/lib/console.sh'
status=0
console_unattended || status=\$?
bash -c 'echo "\$1 \$INITHOOKS_UNATTENDED"' - "\$status" > '$OUT'
EOF
}

# hangs NAME: the screen NAME under bin, which never returns
hangs() {
    printf '#!/bin/bash\nexec sleep 600\n' > "$INITHOOKS_PATH/bin/$1"
    chmod +x "$INITHOOKS_PATH/bin/$1"
}

# --- the rule -----------------------------------------------------------

@test "a decision already made is not made again" {
    export INITHOOKS_UNATTENDED=no
    run bash -c "source '$REPO/lib/console.sh'; console_unattended"
    [ "$status" -eq 1 ]

    export INITHOOKS_UNATTENDED="the console has no size"
    run bash -c "source '$REPO/lib/console.sh'; console_unattended"
    [ "$status" -eq 0 ]
}

@test "nobody answers a console with no size, and children inherit it" {
    run on_pty unsized bash "$DECIDED"

    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "0 the console has no size, nobody is attached to it" ]
}

@test "nobody answers a sized console whose master is never read" {
    run on_pty sized bash "$DECIDED"

    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "0 the console did not take a write in 1 s, nobody is reading it" ]
}

@test "somebody answers a sized console that is read" {
    run script -qec "stty rows 24 cols 80; bash $DECIDED" /dev/null < /dev/null

    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "1 no" ]
}

@test "the controlling terminal is asked when the output is not one" {
    # dialog draws on the controlling terminal then (dialog_wrapper.py)
    run script -qec "stty rows 24 cols 80; bash $DECIDED > /dev/null" \
        /dev/null < /dev/null

    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "1 no" ]
}

@test "nobody answers where there is no terminal at all" {
    run setsid -w bash "$DECIDED" < /dev/null > /dev/null

    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "0 there is no terminal" ]
}

@test "a hook that does not ask says why in one line, on stderr and in the log" {
    export INITHOOKS_UNATTENDED="the console has no size"

    run --separate-stderr bash -c "source '$REPO/lib/console.sh'
console_skipped 31fqdn 'the machine keeps its name web'"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = "[31fqdn] not asked, nobody can answer (the console has no size): the machine keeps its name web" ]
    [ "$(cat "$INITHOOKS_LOGFILE")" = "INFO: $stderr" ]
}

@test "a log that cannot be written does not stop the hook" {
    export INITHOOKS_UNATTENDED="the console has no size"
    export INITHOOKS_LOGFILE=$BATS_TEST_TMPDIR/no/such/dir/log

    run --separate-stderr bash -c "set -e; source '$REPO/lib/console.sh'
console_skipped 85secalerts 'no alert email'; echo went-on"

    [ "$status" -eq 0 ]
    [ "$output" = went-on ]
    [[ "$stderr" == "[85secalerts] not asked"* ]]
}

# --- the hooks ------------------------------------------------------------

# hook_finishes SIZED HOOK
# Runs HOOK, a copy under INITHOOKS_PATH, on the console; it must end with
# status 0 and leave its one line in the log.
hook_finishes() {
    # 99reboot is armed by 95secupdates, and ships not executable
    install -m 755 "$REPO/firstboot.d/$2" "$INITHOOKS_PATH/firstboot.d/$2"
    run --separate-stderr on_pty "$1" "$INITHOOKS_PATH/firstboot.d/$2"
    echo "$stderr" >&2
    [ "$status" -eq 0 ]
    [ "$(grep -c "^INFO: \[$2\] not asked, nobody can answer" "$INITHOOKS_LOGFILE")" -eq 1 ]
}

setup_rootpass() {
    hangs setpass.py
}

setup_fqdn() {
    # the real screen: it asks on the terminal, and never gets an answer
    ln -s "$REPO/bin/fqdn.py" "$INITHOOKS_PATH/bin/fqdn.py"
    export PYTHONPATH=$REPO${PYTHONPATH:+:$PYTHONPATH}
    export INITHOOKS_HOSTS=$BATS_TEST_TMPDIR/hosts
    export INITHOOKS_DECL=$BATS_TEST_TMPDIR/instance.yaml
    export HOSTNAME_ROOT=$BATS_TEST_TMPDIR/root
    export SSLCERT_PEM=$BATS_TEST_TMPDIR/cert.pem
    mkdir -p "$HOSTNAME_ROOT/etc"
    printf '127.0.0.1 localhost\n' > "$INITHOOKS_HOSTS"
    stub hostname 'if [[ $# -eq 0 ]]; then echo web; fi'
}

setup_keel() {
    # confconsole's screen, drawn whenever it has a terminal
    export KEEL_FIRSTBOOT=$BATS_TEST_TMPDIR/keelfirstboot.py
    printf 'import os, time\nif os.isatty(0):\n    time.sleep(600)\n' \
        > "$KEEL_FIRSTBOOT"
}

setup_secalerts() {
    hangs secalerts.py
    printf '#!/bin/bash\necho admin@example.com\n' \
        > "$INITHOOKS_PATH/bin/inithooks_cache.py"
    chmod +x "$INITHOOKS_PATH/bin/inithooks_cache.py"
}

setup_secupdates() {
    hangs secupdates-ask.py
    # installed as SEC_UPDATES=FORCE installs, here without a network
    stub curl 'exit 7'
    export SEC_UPDATES_RECORD=$BATS_TEST_TMPDIR/sec-updates
    export SEC_UPDATES_LOG=$BATS_TEST_TMPDIR/secupdates.log
    export SEC_UPDATES_SOURCES=$BATS_TEST_TMPDIR/security.sources
    printf 'URIs: http://security.debian.org/debian-security\nSuites: trixie-security\n' \
        > "$SEC_UPDATES_SOURCES"
}

setup_reboot() {
    hangs reboot-ask.py
    stub init
}

@test "30rootpass on a console with no size keeps the password" {
    setup_rootpass
    hook_finishes unsized 30rootpass
}

@test "30rootpass on a sized console nobody reads keeps the password" {
    setup_rootpass
    hook_finishes sized 30rootpass
}

@test "30rootpass with a preseeded password sets it without asking" {
    stub chpasswd
    setup_rootpass
    echo "export ROOT_PASS=Preseeded-123" > "$INITHOOKS_CONF"
    printf '#!/bin/bash\necho "$*" > %q\n' "$BATS_TEST_TMPDIR/setpass" \
        > "$INITHOOKS_PATH/bin/setpass.py"
    chmod +x "$INITHOOKS_PATH/bin/setpass.py"
    cp "$REPO/firstboot.d/30rootpass" "$INITHOOKS_PATH/firstboot.d/"

    run on_pty unsized "$INITHOOKS_PATH/firstboot.d/30rootpass"

    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/setpass")" = "root --pass=Preseeded-123" ]
}

@test "31fqdn on a console with no size keeps the name" {
    setup_fqdn
    hook_finishes unsized 31fqdn
    [ "$(cat "$INITHOOKS_HOSTS")" = "$(printf '127.0.0.1 localhost\n127.0.1.1 web')" ]
}

@test "31fqdn on a sized console nobody reads keeps the name" {
    setup_fqdn
    hook_finishes sized 31fqdn
    [ "$(cat "$INITHOOKS_HOSTS")" = "$(printf '127.0.0.1 localhost\n127.0.1.1 web')" ]
}

@test "75keel-role on a console with no size asks nothing" {
    setup_keel
    hook_finishes unsized 75keel-role
}

@test "75keel-role on a sized console nobody reads asks nothing" {
    setup_keel
    hook_finishes sized 75keel-role
}

@test "80keel-cloud on a console with no size asks nothing" {
    setup_keel
    hook_finishes unsized 80keel-cloud
}

@test "80keel-cloud on a sized console nobody reads asks nothing" {
    setup_keel
    hook_finishes sized 80keel-cloud
}

@test "85secalerts on a console with no size sets no alert email" {
    setup_secalerts
    hook_finishes unsized 85secalerts
}

@test "85secalerts on a sized console nobody reads sets no alert email" {
    setup_secalerts
    hook_finishes sized 85secalerts
}

@test "95secupdates on a console with no size installs as FORCE does" {
    setup_secupdates
    hook_finishes unsized 95secupdates
    grep -q "cannot reach" "$SEC_UPDATES_LOG"
}

@test "95secupdates on a sized console nobody reads installs as FORCE does" {
    setup_secupdates
    hook_finishes sized 95secupdates
    grep -q "cannot reach" "$SEC_UPDATES_LOG"
}

@test "99reboot on a console with no size reboots as FORCE does" {
    setup_reboot
    hook_finishes unsized 99reboot
    [ "$(calls init)" = 6 ]
}

@test "99reboot on a sized console nobody reads reboots as FORCE does" {
    setup_reboot
    hook_finishes sized 99reboot
    [ "$(calls init)" = 6 ]
}
