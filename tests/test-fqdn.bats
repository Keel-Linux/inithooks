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
# In most tests bin/fqdn.py is a stub under INITHOOKS_PATH that records its
# arguments and answers what a test scripts; hostname is a stub too. The
# last tests run the real bin/fqdn.py against a scratch instance.yaml and a
# scratch hosts file, with FQDN preseeded so no screen is drawn.

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
    # the stub prints ANSWER when asked, and exits ASK_STATUS
    cat > "$INITHOOKS_PATH/bin/fqdn.py" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> '$STUBS/fqdn.py.calls'
if [[ " \$* " != *" --record "* ]] && [[ " \$* " != *" --hosts "* ]]; then
    printf '%s' "\${ANSWER-}"
fi
exit "\${ASK_STATUS:-0}"
EOF
    chmod +x "$INITHOOKS_PATH/bin/fqdn.py"

    export INITHOOKS_CONF=$BATS_TEST_TMPDIR/inithooks.conf
    export INITHOOKS_DEFAULT=$BATS_TEST_TMPDIR/default-inithooks
    {
        echo "INITHOOKS_PATH=$INITHOOKS_PATH"
        echo "INITHOOKS_CONF=$INITHOOKS_CONF"
    } > "$INITHOOKS_DEFAULT"
    unset ANSWER ASK_STATUS FQDN
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

@test "an empty answer changes nothing" {
    export ANSWER=

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(calls hostname)" = "" ]
    [ "$(calls fqdn.py | wc -l)" -eq 1 ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = blog ]
}

@test "a preseeded FQDN reaches the screen, which asks nothing" {
    echo "export FQDN=blog.example.org" > "$INITHOOKS_CONF"
    export ANSWER=$'HOSTNAME=blog\nFQDN=blog.example.org\n'

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ "$(calls fqdn.py | head -1)" = "--fqdn=blog.example.org --current=blog" ]
}

@test "a preseeded SKIP asks nothing and changes nothing" {
    echo "export FQDN=skip" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/31fqdn"

    [ "$status" -eq 0 ]
    [ -z "$(calls fqdn.py)" ]
    [ -z "$(calls hostname)" ]
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
