#!/usr/bin/env bats
# Tests for firstboot.d/15regen-sslcert: the self-signed certificate made
# at first boot, and the services restarted for it.
#
# The published core 19.0-6 booted headless on BR2 (2026-10-03) left the
# hook at exit 1 before it did anything: under `bash -e` its log() called
# logger, which failed with "socket /dev/log: Connection refused" because
# journald was down, and the first info line killed the hook. The journal
# is a side effect of a hook whose job is the certificate, so a logger that
# fails may not stop it.
#
# The certificate is for the name the machine has, given to
# turnkey-make-ssl-cert: without names it took them from `hostname -A`, a
# reverse lookup of the machine's addresses, and a Web container named web
# served CN=core (2026-10-03).
#
# turnkey-make-ssl-cert, openssl, systemctl, update-ca-certificates, sleep,
# logger, hostname and bin/fqdn.py are stubs; `which` is the real one,
# finding the stubs on PATH.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..

setup() {
    setup_stubs
    stub logger
    stub turnkey-make-ssl-cert
    # the certificate and the key agree from the first look, unless a test
    # makes the first OPENSSL_DIFFER answers differ
    stub openssl 'n=$(wc -l < "'"$STUBS"'/openssl.calls")
if (( n <= ${OPENSSL_DIFFER:-0} )); then echo "md5 $n"; else echo "md5 same"; fi'
    stub systemctl 'if [[ "$1" == is-active ]]; then
    [[ " ${RUNNING-} " == *" $3 "* ]]
fi'
    stub update-ca-certificates
    stub sleep
    stub hostname 'if [[ $# -eq 0 ]]; then echo blog; else exit 1; fi'
    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH/bin"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
    # the name the machine has, as 31fqdn writes it into /etc/hosts
    cat > "$INITHOOKS_PATH/bin/fqdn.py" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> '$STUBS/fqdn.py.calls'
printf '%s' "\${MACHINE-HOSTNAME=blog
FQDN=blog.example.org
}"
EOF
    chmod +x "$INITHOOKS_PATH/bin/fqdn.py"
    export INITHOOKS_CONF=$BATS_TEST_TMPDIR/inithooks.conf
    export INITHOOKS_DEFAULT=$BATS_TEST_TMPDIR/default-inithooks
    {
        echo "INITHOOKS_PATH=$INITHOOKS_PATH"
        echo "INITHOOKS_CONF=$INITHOOKS_CONF"
    } > "$INITHOOKS_DEFAULT"
    unset _TURNKEY_INIT RUNNING OPENSSL_DIFFER MACHINE
}

@test "the certificate is made and the trust store updated" {
    run "$REPO/firstboot.d/15regen-sslcert"

    [ "$status" -eq 0 ]
    [ "$(calls turnkey-make-ssl-cert)" = "--default --force --ip blog.example.org blog" ]
    [ -e "$STUBS/update-ca-certificates.calls" ]
    [[ "$output" == *"Generating SSL/TLS cert & key"* ]]
}

@test "the certificate is for the name the machine has, not a reverse lookup" {
    run "$REPO/firstboot.d/15regen-sslcert"

    [ "$status" -eq 0 ]
    [ "$(calls fqdn.py)" = "--machine --current=blog" ]
    # hostname answered its name only: no -A, no -f
    [ -z "$(calls hostname)" ]
}

@test "a machine without a domain gets a certificate for its hostname" {
    export MACHINE=$'HOSTNAME=web\nFQDN=\n'

    run "$REPO/firstboot.d/15regen-sslcert"

    [ "$status" -eq 0 ]
    [ "$(calls turnkey-make-ssl-cert)" = "--default --force --ip web" ]
}

@test "a logger that fails does not stop the hook" {
    # journald down: logger exits 1 with "socket /dev/log: Connection
    # refused", under bash -e
    stub logger 'echo "logger: socket /dev/log: Connection refused" >&2; exit 1'

    run --separate-stderr "$REPO/firstboot.d/15regen-sslcert"

    [ "$status" -eq 0 ]
    [ "$(calls turnkey-make-ssl-cert)" = "--default --force --ip blog.example.org blog" ]
    [ -e "$STUBS/update-ca-certificates.calls" ]
    [[ "$output" == *"Restarting relevant services"* ]]
    [[ "$stderr" != *"Connection refused"* ]]
}

@test "the services that run are restarted, the others left alone" {
    export RUNNING="apache2.service webmin.service"

    run "$REPO/firstboot.d/15regen-sslcert"

    [ "$status" -eq 0 ]
    [ "$(grep '^restart' "$STUBS/systemctl.calls")" = "$(printf 'restart --quiet apache2\nrestart --quiet webmin')" ]
}

@test "a key still being written is waited for" {
    export OPENSSL_DIFFER=2

    run "$REPO/firstboot.d/15regen-sslcert"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Waiting for updated ssl cert & key"* ]]
    [[ "$output" == *"ready to restart services"* ]]
    [ "$(calls sleep | wc -l)" -eq 1 ]
}

@test "a key that never matches is reported after five looks" {
    export OPENSSL_DIFFER=100

    run "$REPO/firstboot.d/15regen-sslcert"

    [ "$status" -eq 0 ]
    [ "$(calls sleep | wc -l)" -eq 5 ]
    [[ "$output" == *"..."* ]]
}

@test "without turnkey-make-ssl-cert the hook fails and says so, logger or not" {
    rm "$STUBS/turnkey-make-ssl-cert"
    stub logger 'exit 1'

    run --separate-stderr "$REPO/firstboot.d/15regen-sslcert"

    [ "$status" -eq 1 ]
    [[ "$stderr" == *"FATAL"*"turnkey-make-ssl-cert executable not found"* ]]
}

@test "keel-init does not make a new certificate" {
    export _TURNKEY_INIT=1

    run "$REPO/firstboot.d/15regen-sslcert"

    [ "$status" -eq 0 ]
    [ -z "$(calls turnkey-make-ssl-cert)" ]
}

@test "the conf file is read when it is there" {
    echo "export SOMETHING=1" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/15regen-sslcert"

    [ "$status" -eq 0 ]
}
