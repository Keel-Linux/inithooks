#!/usr/bin/env bats
# Tests for firstboot.d/31fqdn: the first boot asks the machine's fully
# qualified domain name, prefilled with the name the machine has, or takes
# a preseeded FQDN; what is answered renames the machine (lib/hostname.sh,
# as 09hostname does) and is recorded in /etc/hosts and the instance
# description by bin/fqdn.py --record.
#
# The description is recorded first, then the machine is renamed, then the
# /etc/hosts entry is written: a step that fails leaves the description
# saying what the machine should be, never a renamed machine with no
# record of it.
#
# Whatever the answer, and with none, the hook ends with the /etc/hosts
# entry for the name the machine has: the image ships no 127.0.1.1 line
# (common's seal-hostname), and `hostname -f` failed on a Web container
# whose first boot skipped the question (2026-10-03). Then the self-signed
# certificate is made again when it is not for that name: it said CN=core
# on a machine named web.
#
# In most tests bin/fqdn.py is a stub under INITHOOKS_PATH that records its
# arguments and answers what a test scripts; hostname is a stub too. The
# last tests run the real bin/fqdn.py against a scratch instance.yaml and a
# scratch hosts file, with FQDN preseeded or nobody to answer, so no screen
# is drawn. Somebody can answer the console unless a test says otherwise
# (INITHOOKS_UNATTENDED, lib/console.sh).

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..

setup() {
    setup_stubs
    stub hostname 'if [[ $# -eq 0 ]]; then echo blog; fi'

    export HOSTNAME_ROOT=$BATS_TEST_TMPDIR/root
    mkdir -p "$HOSTNAME_ROOT/etc"
    echo blog > "$HOSTNAME_ROOT/etc/hostname"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tblog\n' \
        > "$HOSTNAME_ROOT/etc/hosts"

    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH/bin"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
    # the stub prints ANSWER when asked and MACHINE for --machine, and
    # exits ASK_STATUS
    cat > "$INITHOOKS_PATH/bin/fqdn.py" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> '$STUBS/fqdn.py.calls'
case " \$* " in
    *" --record "*|*" --hosts "*) ;;
    *" --machine "*) printf '%s' "\${MACHINE-HOSTNAME=blog
FQDN=
}" ;;
    *) printf '%s' "\${ANSWER-}" ;;
esac
exit "\${ASK_STATUS:-0}"
EOF
    chmod +x "$INITHOOKS_PATH/bin/fqdn.py"

    export INITHOOKS_CONF=$BATS_TEST_TMPDIR/inithooks.conf
    export INITHOOKS_DEFAULT=$BATS_TEST_TMPDIR/default-inithooks
    {
        echo "INITHOOKS_PATH=$INITHOOKS_PATH"
        echo "INITHOOKS_CONF=$INITHOOKS_CONF"
    } > "$INITHOOKS_DEFAULT"
    export INITHOOKS_UNATTENDED=no
    export INITHOOKS_LOGFILE=$BATS_TEST_TMPDIR/inithooks.log
    export SSLCERT_PEM=$BATS_TEST_TMPDIR/ssl/cert.pem
    export SSLCERT_KEY=$BATS_TEST_TMPDIR/ssl/cert.key
    unset ANSWER ASK_STATUS FQDN MACHINE
}

@test "the screen is asked with the name the machine has" {
    export ANSWER=$'HOSTNAME=blog\nFQDN=blog.example.org\n'

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(calls fqdn.py | head -1)" = "--fqdn= --current=blog" ]
}

@test "the answer is recorded, renames the machine and gets its hosts entry" {
    export ANSWER=$'HOSTNAME=web\nFQDN=web.example.org\n'

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = web ]
    [ "$(calls hostname | tail -1)" = web ]
    [ "$(calls fqdn.py | sed -n 2p)" = "--record --hostname=web --fqdn=web.example.org" ]
    [ "$(calls fqdn.py | sed -n 3p)" = "--hosts --hostname=web --fqdn=web.example.org" ]
}

@test "the description first, then the rename, then the hosts entry" {
    # the description is what the machine is asked to be, so it is written
    # before anything is changed; the rename replaces the old name wherever
    # it stands, so the entry is written after it
    export ANSWER=$'HOSTNAME=web\nFQDN=web.example.org\n'
    stub hostname 'if [[ $# -eq 0 ]]; then echo blog; else
    echo renamed >> "'"$STUBS"'/order"; fi'
    cat > "$INITHOOKS_PATH/bin/fqdn.py" <<EOF
#!/bin/bash
case " \$* " in
    *" --record "*) echo recorded >> '$STUBS/order' ;;
    *" --hosts "*) echo hosts >> '$STUBS/order' ;;
    *) printf '%s' "\$ANSWER" ;;
esac
EOF

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(cat "$STUBS/order")" = "$(printf 'recorded\nrenamed\nhosts')" ]
}

@test "a hostname without a domain is recorded with an empty FQDN" {
    export ANSWER=$'HOSTNAME=web\nFQDN=\n'

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(calls hostname | tail -1)" = web ]
    [ "$(calls fqdn.py | sed -n 2p)" = "--record --hostname=web --fqdn=" ]
}

@test "an empty answer keeps the name and writes its hosts entry" {
    export ANSWER=

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(calls hostname)" = "" ]
    [ "$(calls fqdn.py | sed 1d)" = "$(printf '%s\n' '--machine --current=blog' \
        '--hosts --hostname=blog --fqdn=')" ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = blog ]
}

@test "a preseeded FQDN reaches the screen, which asks nothing" {
    echo "export FQDN=blog.example.org" > "$INITHOOKS_CONF"
    export ANSWER=$'HOSTNAME=blog\nFQDN=blog.example.org\n'

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(calls fqdn.py | head -1)" = "--fqdn=blog.example.org --current=blog" ]
}

@test "a preseeded SKIP asks nothing, keeps the name and writes its hosts entry" {
    echo "export FQDN=skip" > "$INITHOOKS_CONF"
    export MACHINE=$'HOSTNAME=blog\nFQDN=blog.example.org\n'

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(calls fqdn.py)" = "$(printf '%s\n' '--machine --current=blog' \
        '--hosts --hostname=blog --fqdn=blog.example.org')" ]
    [ -z "$(calls hostname)" ]
}

@test "nobody to answer: the name is kept, recorded with its domain, and said" {
    export INITHOOKS_UNATTENDED="the console has no size"
    export MACHINE=$'HOSTNAME=blog\nFQDN=blog.example.org\n'

    run --separate-stderr "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(calls fqdn.py)" = "$(printf '%s\n' '--machine --current=blog' \
        '--record --hostname=blog --fqdn=blog.example.org' \
        '--hosts --hostname=blog --fqdn=blog.example.org')" ]
    [ -z "$(calls hostname)" ]
    [ "$(cat "$INITHOOKS_LOGFILE")" = "INFO: [31fqdn] not asked, nobody can answer (the console has no size): the machine keeps its name blog.example.org, recorded as instance.fqdn" ]
}

@test "nobody to answer: a name without a domain is kept, and not recorded" {
    export INITHOOKS_UNATTENDED="the console has no size"

    run --separate-stderr "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(calls fqdn.py)" = "$(printf '%s\n' '--machine --current=blog' \
        '--hosts --hostname=blog --fqdn=')" ]
    [[ "$stderr" == *"keeps its name blog, which has no domain: no instance.fqdn recorded"* ]]
}

@test "a preseeded FQDN is not asked even when somebody could answer" {
    # the preseed is the answer: the console is not looked at
    export INITHOOKS_UNATTENDED="the console has no size"
    echo "export FQDN=web.example.org" > "$INITHOOKS_CONF"
    export ANSWER=$'HOSTNAME=web\nFQDN=web.example.org\n'

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(calls fqdn.py | head -1)" = "--fqdn=web.example.org --current=blog" ]
    [ ! -e "$INITHOOKS_LOGFILE" ]
}

@test "a screen that fails is reported by its status, for run to log" {
    export ASK_STATUS=1

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 1 ]
    [ -z "$(calls hostname)" ]
}

@test "a record that fails stops the hook before the machine is renamed" {
    export ANSWER=$'HOSTNAME=web\nFQDN=web.example.org\n'
    cat > "$INITHOOKS_PATH/bin/fqdn.py" <<EOF
#!/bin/bash
if [[ " \$* " == *" --record "* ]]; then exit 1; fi
printf '%s' "\$ANSWER"
EOF

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 1 ]
    [ -z "$(calls hostname)" ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = blog ]
}

@test "a hosts entry that fails is reported by its status" {
    export ANSWER=$'HOSTNAME=web\nFQDN=web.example.org\n'
    cat > "$INITHOOKS_PATH/bin/fqdn.py" <<EOF
#!/bin/bash
if [[ " \$* " == *" --hosts "* ]]; then exit 1; fi
if [[ " \$* " != *" --record "* ]]; then printf '%s' "\$ANSWER"; fi
EOF

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 1 ]
    [ "$(calls hostname | tail -1)" = web ]
}

@test "an answer the screen did not shape is refused before anything is renamed" {
    export ANSWER=$'garbage\n'

    run --separate-stderr "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 1 ]
    [[ "$stderr" == *"unexpected answer"* ]]
    [ -z "$(calls hostname)" ]
}

@test "an answer without a hostname is refused before anything is renamed" {
    export ANSWER=$'FQDN=web.example.org\n'

    run --separate-stderr "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 1 ]
    [[ "$stderr" == *"without a hostname"* ]]
    [ -z "$(calls hostname)" ]
}

# --- the real bin/fqdn.py, with FQDN preseeded ------------------------------

real_fqdn_py() {
    rm "$INITHOOKS_PATH/bin/fqdn.py"
    ln -s "$REPO/bin/fqdn.py" "$INITHOOKS_PATH/bin/fqdn.py"
    export PYTHONPATH=$REPO${PYTHONPATH:+:$PYTHONPATH}
    export INITHOOKS_DECL=$BATS_TEST_TMPDIR/instance.yaml
    export INITHOOKS_HOSTS=$HOSTNAME_ROOT/etc/hosts
    export DIALOG_LOG=$BATS_TEST_TMPDIR/dialog.log
    # keel is not on this PATH: the description is written unvalidated
    export PATH=$STUBS:/usr/bin:/bin
}

@test "a preseeded FQDN is recorded in hosts and a new instance.yaml" {
    real_fqdn_py
    echo "export FQDN=web.example.org" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = web ]
    [ "$(calls hostname | tail -1)" = web ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hosts")" = "$(printf '127.0.0.1\tlocalhost\n127.0.1.1 web.example.org web')" ]
    [ "$(cat "$INITHOOKS_DECL")" = "$(printf 'version: 1\ninstance:\n  hostname: web\n  fqdn: web.example.org\ntls:\n  acme:\n    domains:\n    - web.example.org')" ]
}

@test "a preseeded FQDN is recorded into the instance.yaml that is there" {
    real_fqdn_py
    printf 'version: 1\napp:\n  email: admin@example.org\ntls:\n  acme:\n    enabled: true\n    domains:\n    - www.example.org\n' \
        > "$INITHOOKS_DECL"
    echo "export FQDN=web.example.org" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(cat "$INITHOOKS_DECL")" = "$(printf 'version: 1\napp:\n  email: admin@example.org\ntls:\n  acme:\n    enabled: true\n    domains:\n    - www.example.org\ninstance:\n  hostname: web\n  fqdn: web.example.org')" ]
}

@test "a preseeded FQDN the description already declares writes it nowhere" {
    real_fqdn_py
    printf '# the operator wrote this\nversion: 1\ninstance:\n  hostname: wp\n  fqdn: web.example.org\ntls:\n  acme:\n    domains: [web.example.org]\n' \
        > "$INITHOOKS_DECL"
    echo "export FQDN=web.example.org" > "$INITHOOKS_CONF"

    run --separate-stderr "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [[ "$stderr" == *"already declares the name"* ]]
    [ "$(head -1 "$INITHOOKS_DECL")" = "# the operator wrote this" ]
    # the declared hostname, which 09hostname set, is the one kept
    [ "$(calls hostname | tail -1)" = wp ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hosts")" = "$(printf '127.0.0.1\tlocalhost\n127.0.1.1 web.example.org wp')" ]
}

@test "a preseeded FQDN that is not a domain name fails the hook and changes nothing" {
    real_fqdn_py
    echo "export FQDN=web_1.example.org" > "$INITHOOKS_CONF"

    run --separate-stderr "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 1 ]
    [[ "$stderr" == *"web_1.example.org"* ]]
    [ -z "$(calls hostname)" ]
    [ ! -e "$INITHOOKS_DECL" ]
}

# --- the hosts entry the image no longer ships -------------------------------

# without_hosts_entry: /etc/hosts as the image ships it since common#35,
# without a 127.0.1.1 line
without_hosts_entry() {
    printf '127.0.0.1\tlocalhost\n::1\tlocalhost ip6-localhost\n' \
        > "$HOSTNAME_ROOT/etc/hosts"
}

@test "a preseeded SKIP writes the hosts entry the image does not ship" {
    real_fqdn_py
    without_hosts_entry
    echo "export FQDN=SKIP" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hosts")" = "$(printf '127.0.0.1\tlocalhost\n::1\tlocalhost ip6-localhost\n127.0.1.1 blog')" ]
    [ ! -e "$INITHOOKS_DECL" ]
}

@test "nobody to answer: the hosts entry is written for the name without a domain" {
    real_fqdn_py
    without_hosts_entry
    export INITHOOKS_UNATTENDED="the console has no size"

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(tail -1 "$HOSTNAME_ROOT/etc/hosts")" = "127.0.1.1 blog" ]
    [ ! -e "$INITHOOKS_DECL" ]
    [ "$(grep -c '\[31fqdn\]' "$INITHOOKS_LOGFILE")" -eq 1 ]
}

@test "nobody to answer: the domain pct gave the container is kept and recorded" {
    real_fqdn_py
    stub hostname 'if [[ $# -eq 0 ]]; then echo keel-web1; fi'
    printf '127.0.0.1 localhost\n127.0.1.1 keel-web1.pop.coop keel-web1\n' \
        > "$HOSTNAME_ROOT/etc/hosts"
    export INITHOOKS_UNATTENDED="the console has no size"

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hosts")" = "$(printf '127.0.0.1 localhost\n127.0.1.1 keel-web1.pop.coop keel-web1')" ]
    [ "$(sed -n '2,4p' "$INITHOOKS_DECL")" = "$(printf 'instance:\n  hostname: keel-web1\n  fqdn: keel-web1.pop.coop')" ]
    [ -z "$(calls hostname)" ]
}

@test "the hosts entry has the form keel apply --system writes" {
    # keel.system.hosts: `127.0.1.1 <fqdn> <hostname>`, in place of the
    # short line; the two writers must agree, or apply rewrites it
    real_fqdn_py
    without_hosts_entry
    echo "export FQDN=blog.example.org" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(grep -c '^127\.0\.1\.1 ' "$HOSTNAME_ROOT/etc/hosts")" -eq 1 ]
    grep -qx '127.0.1.1 blog.example.org blog' "$HOSTNAME_ROOT/etc/hosts"
}

# --- the certificate follows the name ------------------------------------------

# real_certificate CN
# The self-signed certificate the machine has, for CN, and a
# turnkey-make-ssl-cert that makes one for the first name it is given, as
# the real one does, in the scratch SSLCERT_PEM. hostname answers the name
# it was last given.
real_certificate() {
    mkdir -p "$(dirname "$SSLCERT_PEM")"
    stub turnkey-make-ssl-cert 'names=()
for arg; do [[ "$arg" == -* ]] || names+=("$arg"); done
san=$(printf "DNS:%s," "${names[@]}")
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=${names[0]}" \
    -addext "subjectAltName=${san%,}" -keyout "$SSLCERT_KEY" \
    -out "$SSLCERT_PEM.crt" 2>/dev/null
cat "$SSLCERT_PEM.crt" "$SSLCERT_KEY" > "$SSLCERT_PEM"'
    stub systemctl 'exit 3'
    stub update-ca-certificates
    stub sleep
    turnkey-make-ssl-cert --default --force "$1"
    rm "$STUBS/turnkey-make-ssl-cert.calls"
    echo blog > "$BATS_TEST_TMPDIR/name"
    stub hostname 'name='"$BATS_TEST_TMPDIR"'/name
if [[ $# -eq 0 ]]; then cat "$name"; else echo "$1" > "$name"; fi'
}

cn() {
    openssl x509 -in "$SSLCERT_PEM" -noout -subject -nameopt RFC2253 \
        | sed 's/^subject=CN=//'
}

@test "after a rename the certificate is made for the new name" {
    real_fqdn_py
    real_certificate core
    echo "export FQDN=web.example.org" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(calls turnkey-make-ssl-cert)" = "--default --force --ip web.example.org web" ]
    [ "$(cn)" = web.example.org ]
    openssl x509 -in "$SSLCERT_PEM" -noout -ext subjectAltName \
        | grep -q 'DNS:web.example.org, DNS:web'
}

@test "nobody to answer: the certificate is made for the name the machine keeps" {
    real_fqdn_py
    real_certificate core
    export INITHOOKS_UNATTENDED="the console has no size"

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(cn)" = blog ]
}

@test "a certificate already for the name is not made again" {
    real_fqdn_py
    real_certificate web.example.org
    echo "export FQDN=web.example.org" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ -z "$(calls turnkey-make-ssl-cert)" ]
}

@test "a certificate an authority signed is kept" {
    # confconsole's Let's Encrypt writes the same files
    real_fqdn_py
    real_certificate core
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=Authority \
        -keyout "$BATS_TEST_TMPDIR/ca.key" -out "$BATS_TEST_TMPDIR/ca.crt" \
        2>/dev/null
    openssl req -new -key "$SSLCERT_KEY" -subj /CN=blog.example.org \
        2>/dev/null | openssl x509 -req -days 1 -CA "$BATS_TEST_TMPDIR/ca.crt" \
        -CAkey "$BATS_TEST_TMPDIR/ca.key" -out "$SSLCERT_PEM" 2>/dev/null
    echo "export FQDN=web.example.org" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ -z "$(calls turnkey-make-ssl-cert)" ]
    [ "$(cn)" = blog.example.org ]
    [[ "$output" == *"is signed by an authority; kept"* ]]
}

@test "a certificate that cannot be read is kept, and said" {
    real_fqdn_py
    mkdir -p "$(dirname "$SSLCERT_PEM")"
    echo garbage > "$SSLCERT_PEM"
    stub turnkey-make-ssl-cert
    echo "export FQDN=web.example.org" > "$INITHOOKS_CONF"

    run --separate-stderr "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ -z "$(calls turnkey-make-ssl-cert)" ]
    [[ "$stderr" == *"cannot be read as a certificate; kept"* ]]
}
