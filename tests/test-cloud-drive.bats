#!/usr/bin/env bats
# Tests for firstboot.d/02cloud-drive and everyboot.d/02cloud-drive, which
# read the Proxmox cloud-init drive of a VM without cloud-init
# (bin/cloud-drive.py, tested in test_cloud_drive_cli.py), and for the
# marker that makes the boot run leave its questions to keel-init when an
# SSH key came from the drive (lib/console.sh, INITHOOKS_SSH_ANSWER).
#
# bin/cloud-drive.py and bin/fqdn.py are stubs here that record their
# arguments; hostname is a stub that keeps the name it is given. The
# files are scratch copies.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..

setup() {
    setup_stubs
    stub logger
    stub hostname "state='$BATS_TEST_TMPDIR/hostname.state'
if [[ \$# -eq 0 ]]; then
    cat \"\$state\" 2>/dev/null || echo vm100
else
    echo \"\$1\" > \"\$state\"
fi"
    export HOSTNAME_ROOT=$BATS_TEST_TMPDIR/root
    mkdir -p "$HOSTNAME_ROOT/etc"
    echo vm100 > "$HOSTNAME_ROOT/etc/hostname"
    export SSLCERT_PEM=$BATS_TEST_TMPDIR/no-cert.pem

    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH/bin"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
    export INITHOOKS_CONF=$BATS_TEST_TMPDIR/inithooks.conf
    export INITHOOKS_DEFAULT=$BATS_TEST_TMPDIR/default-inithooks
    {
        echo "INITHOOKS_PATH=$INITHOOKS_PATH"
        echo "INITHOOKS_CONF=$INITHOOKS_CONF"
        echo "SUDOADMIN=false"
    } > "$INITHOOKS_DEFAULT"
    export INITHOOKS_LOGFILE=$BATS_TEST_TMPDIR/inithooks.log
    export INITHOOKS_SSH_ANSWER=$BATS_TEST_TMPDIR/ssh-answer
    export INITHOOKS_DEFERRED=$BATS_TEST_TMPDIR/deferred
    export CLOUD_DRIVE_PASSWORD=$BATS_TEST_TMPDIR/root-password
    CALLS=$BATS_TEST_TMPDIR/calls
    unset _TURNKEY_INIT INITHOOKS_UNATTENDED
}

# bin_stub NAME [BODY]: bin/NAME records its arguments in CALLS, then
# runs BODY
bin_stub() {
    {
        echo '#!/bin/bash'
        echo "printf '%s %s\\n' '$1' \"\$*\" >> '$CALLS'"
        echo "${2:-exit 0}"
    } > "$INITHOOKS_PATH/bin/$1"
    chmod +x "$INITHOOKS_PATH/bin/$1"
}

@test "02cloud-drive at the first boot reads the drive with --firstboot" {
    bin_stub cloud-drive.py

    run "$REPO/firstboot.d/02cloud-drive"

    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = "cloud-drive.py --firstboot" ]
}

@test "02cloud-drive passes --sudoadmin when SUDOADMIN is on" {
    bin_stub cloud-drive.py
    echo "SUDOADMIN=True" >> "$INITHOOKS_DEFAULT"

    run "$REPO/firstboot.d/02cloud-drive"

    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = "cloud-drive.py --firstboot --sudoadmin" ]
}

@test "02cloud-drive does nothing under keel-init" {
    bin_stub cloud-drive.py
    export _TURNKEY_INIT=1

    run "$REPO/firstboot.d/02cloud-drive"

    [ "$status" -eq 0 ]
    [ ! -e "$CALLS" ]
}

@test "02cloud-drive fails when the drive cannot be read" {
    bin_stub cloud-drive.py "exit 1"

    run "$REPO/firstboot.d/02cloud-drive"

    [ "$status" -eq 1 ]
}

@test "everyboot 02cloud-drive does nothing when the id is applied" {
    bin_stub cloud-drive.py

    run "$REPO/everyboot.d/02cloud-drive"

    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = "cloud-drive.py --clone" ]
}

@test "everyboot 02cloud-drive renames a clone as 31fqdn does, then records the id" {
    bin_stub cloud-drive.py 'if [[ $1 == --clone ]]; then
    printf "HOSTNAME=db\nFQDN=db.example.org\nINSTANCE_ID=9f1e\nNAME=db.example.org\n"
fi'
    bin_stub fqdn.py
    echo "SUDOADMIN=true" >> "$INITHOOKS_DEFAULT"

    run "$REPO/everyboot.d/02cloud-drive"

    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = "cloud-drive.py --clone --sudoadmin
fqdn.py --record --hostname=db --fqdn=db.example.org
fqdn.py --forget-tls
fqdn.py --hosts --hostname=db --fqdn=db.example.org
cloud-drive.py --record-id=9f1e --name=db.example.org" ]
    [ "$(hostname)" = db ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = db ]
}

@test "everyboot 02cloud-drive records a name without a domain as such" {
    bin_stub cloud-drive.py 'if [[ $1 == --clone ]]; then
    printf "HOSTNAME=db\nFQDN=\nINSTANCE_ID=9f1e\nNAME=db\n"
fi'
    bin_stub fqdn.py

    run "$REPO/everyboot.d/02cloud-drive"

    [ "$status" -eq 0 ]
    # --record with no fqdn removes the instance.fqdn of the original
    [ "$(sed -n 2p "$CALLS")" = "fqdn.py --record --hostname=db --fqdn=" ]
    [ "$(sed -n 3p "$CALLS")" = "fqdn.py --forget-tls" ]
    [ "$(sed -n 4p "$CALLS")" = "fqdn.py --hosts --hostname=db --fqdn=" ]
    [ "$(hostname)" = db ]
}

@test "everyboot 02cloud-drive that keeps the name only records the id" {
    bin_stub cloud-drive.py 'if [[ $1 == --clone ]]; then
    printf "HOSTNAME=\nFQDN=\nINSTANCE_ID=9f1e\nNAME=blog\n"
fi'

    run "$REPO/everyboot.d/02cloud-drive"

    [ "$status" -eq 0 ]
    [ "$(sed -n 2p "$CALLS")" = "cloud-drive.py --record-id=9f1e --name=blog" ]
    [ "$(hostname)" = vm100 ]
}

@test "everyboot 02cloud-drive refuses an answer it does not know" {
    bin_stub cloud-drive.py 'echo "EVIL=1"'

    run --separate-stderr "$REPO/everyboot.d/02cloud-drive"

    [ "$status" -eq 1 ]
    [[ "$stderr" == *"unexpected answer from cloud-drive.py: EVIL"* ]]
}

@test "everyboot 02cloud-drive fails and records nothing when the drive cannot be read" {
    bin_stub cloud-drive.py "exit 1"

    run "$REPO/everyboot.d/02cloud-drive"

    [ "$status" -eq 1 ]
    [ "$(cat "$CALLS")" = "cloud-drive.py --clone" ]
}

@test "a key from the drive turns an attended console into one nobody answers" {
    echo reason > "$INITHOOKS_SSH_ANSWER"
    export INITHOOKS_UNATTENDED=no

    run bash -c "source '$REPO/lib/console.sh'
console_unattended && bash -c 'echo \"\$INITHOOKS_UNATTENDED\"'"

    [ "$status" -eq 0 ]
    [ "$output" = "an SSH key came from the cloud-init drive, keel-init asks at the first login" ]
}

@test "the marker keeps a reason the console already has" {
    echo reason > "$INITHOOKS_SSH_ANSWER"
    export INITHOOKS_UNATTENDED="the console has no size"

    run bash -c "source '$REPO/lib/console.sh'
console_unattended && echo \"\$INITHOOKS_UNATTENDED\""

    [ "$output" = "the console has no size" ]
}

@test "keel-init asks on its own terminal whatever the marker says" {
    echo reason > "$INITHOOKS_SSH_ANSWER"
    export INITHOOKS_UNATTENDED=no _TURNKEY_INIT=1

    run bash -c "source '$REPO/lib/console.sh'; console_unattended"

    [ "$status" -eq 1 ]
}

@test "with no marker an attended console stays attended" {
    export INITHOOKS_UNATTENDED=no

    run bash -c "source '$REPO/lib/console.sh'; console_unattended"

    [ "$status" -eq 1 ]
}

@test "30rootpass with a key from the drive and no password leaves it to keel-init" {
    echo reason > "$INITHOOKS_SSH_ANSWER"
    export INITHOOKS_UNATTENDED=no
    bin_stub setpass.py

    run --separate-stderr "$REPO/firstboot.d/30rootpass"

    [ "$status" -eq 0 ]
    [ ! -e "$CALLS" ]
    [ "$(cat "$INITHOOKS_DEFERRED")" = 30rootpass ]
    [[ "$stderr" == *"an SSH key came from the cloud-init drive"* ]]
}

@test "30rootpass with the drive's password keeps it without a screen" {
    echo reason > "$INITHOOKS_SSH_ANSWER"
    export INITHOOKS_UNATTENDED=no
    echo "export ROOT_PASS=KEEP" > "$INITHOOKS_CONF"
    bin_stub setpass.py

    run "$REPO/firstboot.d/30rootpass"

    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = "setpass.py root --pass=KEEP" ]
}

@test "75keel-role with a key from the drive leaves both questions to keel-init on a console somebody reads" {
    echo reason > "$INITHOOKS_SSH_ANSWER"
    export INITHOOKS_UNATTENDED=no
    export KEEL_FIRSTBOOT=$BATS_TEST_TMPDIR/keelfirstboot.py
    # confconsole's step: no terminal on standard input is DEFERRED (75)
    cat > "$KEEL_FIRSTBOOT" <<EOF
import os, sys
with open("$CALLS", "a") as fob:
    fob.write(sys.argv[1] + (" tty" if os.isatty(0) else " notty") + "\n")
sys.exit(0 if os.isatty(0) else 75)
EOF

    run script -qec "stty rows 24 cols 80; '$REPO/firstboot.d/75keel-role'" /dev/null < /dev/null

    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = "mode notty
role notty" ]
    [ "$(cat "$INITHOOKS_DEFERRED")" = 75keel-role ]
}

@test "75keel-role without the marker asks on a console somebody reads" {
    export INITHOOKS_UNATTENDED=no
    export KEEL_FIRSTBOOT=$BATS_TEST_TMPDIR/keelfirstboot.py
    cat > "$KEEL_FIRSTBOOT" <<EOF
import os, sys
with open("$CALLS", "a") as fob:
    fob.write(sys.argv[1] + (" tty" if os.isatty(0) else " notty") + "\n")
EOF

    run script -qec "stty rows 24 cols 80; '$REPO/firstboot.d/75keel-role'" /dev/null < /dev/null

    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = "mode tty
role tty" ]
}

@test "30rootpass asks nothing when the cloud-init drive set the root password" {
    echo "set from the cloud-init drive" > "$CLOUD_DRIVE_PASSWORD"
    export INITHOOKS_UNATTENDED=no
    bin_stub setpass.py

    run --separate-stderr "$REPO/firstboot.d/30rootpass"

    [ "$status" -eq 0 ]
    [ ! -e "$CALLS" ]
    [ ! -e "$INITHOOKS_DEFERRED" ]
    [[ "$stderr" == *"the root password was set from the cloud-init drive"* ]]
}

@test "keel-init does not ask the root password the cloud-init drive set" {
    echo "set from the cloud-init drive" > "$CLOUD_DRIVE_PASSWORD"
    export INITHOOKS_UNATTENDED=no _TURNKEY_INIT=1
    bin_stub setpass.py

    run "$REPO/firstboot.d/30rootpass"

    [ "$status" -eq 0 ]
    [ ! -e "$CALLS" ]
}

@test "the drive's root password does not spare the admin password" {
    echo "set from the cloud-init drive" > "$CLOUD_DRIVE_PASSWORD"
    echo "SUDOADMIN=true" >> "$INITHOOKS_DEFAULT"
    export INITHOOKS_UNATTENDED=no _TURNKEY_INIT=1
    bin_stub setpass.py

    run "$REPO/firstboot.d/30rootpass"

    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = "setpass.py admin --pass=" ]
}
