#!/usr/bin/env bats
# Tests for lib/hostname.sh and firstboot.d/09hostname: renaming the
# machine. The hook has always replaced the old name with the new one in
# the files that carry it and set the kernel's name; the rename is now a
# function in lib/hostname.sh, so that firstboot.d/31fqdn renames the
# machine the same way instead of carrying a copy.
#
# hostname is a stub: it answers the name the machine has and records the
# name it is given. The files are scratch copies under HOSTNAME_ROOT.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..

setup() {
    setup_stubs
    stub hostname 'if [[ $# -eq 0 ]]; then echo blog; fi'

    export HOSTNAME_ROOT=$BATS_TEST_TMPDIR/root
    mkdir -p "$HOSTNAME_ROOT/etc/postfix"
    echo blog > "$HOSTNAME_ROOT/etc/hostname"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tblog\n' \
        > "$HOSTNAME_ROOT/etc/hosts"
    echo blog > "$HOSTNAME_ROOT/etc/mailname"
    printf 'myhostname = blog\nmydestination = blog, localhost\n' \
        > "$HOSTNAME_ROOT/etc/postfix/main.cf"

    export INITHOOKS_CONF=$BATS_TEST_TMPDIR/inithooks.conf
    export INITHOOKS_DEFAULT=$BATS_TEST_TMPDIR/default-inithooks
    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
    {
        echo "INITHOOKS_PATH=$INITHOOKS_PATH"
        echo "INITHOOKS_CONF=$INITHOOKS_CONF"
    } > "$INITHOOKS_DEFAULT"
}

@test "hostname_set replaces the old name in every file that carries it" {
    source "$REPO/lib/hostname.sh"

    hostname_set web

    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = web ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hosts")" = "$(printf '127.0.0.1\tlocalhost\n127.0.1.1\tweb')" ]
    [ "$(cat "$HOSTNAME_ROOT/etc/mailname")" = web ]
    [ "$(cat "$HOSTNAME_ROOT/etc/postfix/main.cf")" = "$(printf 'myhostname = web\nmydestination = web, localhost')" ]
}

@test "the name is replaced only as a whole name or a first label" {
    # 09hostname's sed took the name as a pattern and matched it inside
    # any word: a machine called web rewrote every SSH key comment,
    # postfix setting and name that contained it
    source "$REPO/lib/hostname.sh"
    stub hostname 'if [[ $# -eq 0 ]]; then echo web; fi'
    printf 'web\n' > "$HOSTNAME_ROOT/etc/hostname"
    printf '127.0.1.1 web.example.org web\n2001:db8::10 webmail backup-web www.web web-2\nssh-ed25519 AAAA root@web\n' \
        > "$HOSTNAME_ROOT/etc/hosts"
    printf 'myhostname = web\nmydestination = web, webmail, localhost\n' \
        > "$HOSTNAME_ROOT/etc/postfix/main.cf"

    hostname_set blog

    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = blog ]
    [ "$(sed -n 1p "$HOSTNAME_ROOT/etc/hosts")" = "127.0.1.1 blog.example.org blog" ]
    [ "$(sed -n 2p "$HOSTNAME_ROOT/etc/hosts")" = "2001:db8::10 webmail backup-web www.web web-2" ]
    [ "$(sed -n 3p "$HOSTNAME_ROOT/etc/hosts")" = "ssh-ed25519 AAAA root@blog" ]
    [ "$(cat "$HOSTNAME_ROOT/etc/postfix/main.cf")" = "$(printf 'myhostname = blog\nmydestination = blog, webmail, localhost')" ]
}

@test "two names on one line are both replaced" {
    source "$REPO/lib/hostname.sh"
    printf '127.0.1.1 blog blog\n' > "$HOSTNAME_ROOT/etc/hosts"

    hostname_set web

    [ "$(cat "$HOSTNAME_ROOT/etc/hosts")" = "127.0.1.1 web web" ]
}

@test "the name is matched literally, a colon or a dot included" {
    source "$REPO/lib/hostname.sh"
    stub hostname 'if [[ $# -eq 0 ]]; then echo "a:b.example.org"; fi'
    printf 'a:b.example.org axb.example.org\n' > "$HOSTNAME_ROOT/etc/hosts"

    hostname_set web

    [ "$(cat "$HOSTNAME_ROOT/etc/hosts")" = "web axb.example.org" ]
}

@test "a dotted name is replaced whole, as pct create --hostname set it" {
    source "$REPO/lib/hostname.sh"
    stub hostname 'if [[ $# -eq 0 ]]; then echo blog.example.org; fi'
    printf 'blog.example.org\n' > "$HOSTNAME_ROOT/etc/hostname"
    printf '127.0.1.1 blog.example.org blog\n' > "$HOSTNAME_ROOT/etc/hosts"

    hostname_set blog

    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = blog ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hosts")" = "127.0.1.1 blog blog" ]
}

@test "the same name again touches no file" {
    source "$REPO/lib/hostname.sh"
    touch -d '2020-01-01' "$HOSTNAME_ROOT/etc/hosts"

    hostname_set blog

    [ "$(calls hostname | tail -1)" = blog ]
    [ "$(stat -c %Y "$HOSTNAME_ROOT/etc/hosts")" = "$(date -d '2020-01-01' +%s)" ]
}

@test "hostname_set sets the kernel's name last" {
    source "$REPO/lib/hostname.sh"

    hostname_set web

    [ "$(calls hostname | tail -1)" = web ]
}

@test "a file the machine does not have is skipped" {
    source "$REPO/lib/hostname.sh"
    rm "$HOSTNAME_ROOT/etc/mailname"

    hostname_set web

    [ ! -e "$HOSTNAME_ROOT/etc/mailname" ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = web ]
}

@test "the files are the ones 09hostname has always rewritten" {
    source "$REPO/lib/hostname.sh"

    [ "${#HOSTNAME_FILES[@]}" -eq 13 ]
    [[ " ${HOSTNAME_FILES[*]} " == *" /etc/hostname "* ]]
    [[ " ${HOSTNAME_FILES[*]} " == *" /etc/hosts "* ]]
    [[ " ${HOSTNAME_FILES[*]} " == *" /etc/ssh/ssh_host_ed25519_key.pub "* ]]
}

@test "the root defaults to the machine's own files" {
    unset HOSTNAME_ROOT
    source "$REPO/lib/hostname.sh"

    [ -z "$HOSTNAME_ROOT" ]
}

@test "09hostname renames the machine to the preseeded HOSTNAME" {
    echo "export HOSTNAME=web" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/09hostname"

    [ "$status" -eq 0 ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = web ]
    [ "$(calls hostname | tail -1)" = web ]
}

@test "09hostname without a preseed renames the machine to bash's HOSTNAME" {
    # bash sets HOSTNAME itself, to the name of the machine it runs on, so
    # without a conf file the hook has always renamed the machine to the
    # name it already has; here the stub answers another name, so the
    # rename shows
    run "$REPO/firstboot.d/09hostname"

    [ "$status" -eq 0 ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = "$HOSTNAME" ]
    [ "$(calls hostname | tail -1)" = "$HOSTNAME" ]
}

@test "09hostname exits without a name" {
    # HOSTNAME empty, as a conf file can make it
    echo "export HOSTNAME=" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/09hostname"

    [ "$status" -eq 0 ]
    [ -z "$(calls hostname)" ]
}
