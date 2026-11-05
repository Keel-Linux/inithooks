#!/usr/bin/env bats
# Tests for lib/hostname.sh and firstboot.d/09hostname: renaming the
# machine. The hook has always replaced the old name with the new one in
# the files that carry it and set the kernel's name; the rename is now a
# function in lib/hostname.sh, so that firstboot.d/31fqdn renames the
# machine the same way instead of carrying a copy.
#
# hostname is a stub: it answers the name the machine has and records the
# name it is given, and from then on answers that name, as the kernel
# does. The files are scratch copies under HOSTNAME_ROOT.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..

# stateful_hostname NAME
# Stubs hostname: with no argument it answers NAME, or the last name it
# was given.
stateful_hostname() {
    stub hostname "state='$BATS_TEST_TMPDIR/hostname.state'
if [[ \$# -eq 0 ]]; then
    cat \"\$state\" 2>/dev/null || echo '$1'
else
    echo \"\$1\" > \"\$state\"
fi"
}

setup() {
    setup_stubs
    stateful_hostname blog

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
    [ "$(calls hostname | grep . | tail -1)" = web ]
}

@test "09hostname without a preseed renames the machine to bash's HOSTNAME" {
    # bash sets HOSTNAME itself, to the name of the machine it runs on, so
    # without a conf file the hook has always renamed the machine to the
    # name it already has; here the stub answers another name, so the
    # rename shows
    run "$REPO/firstboot.d/09hostname"

    [ "$status" -eq 0 ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = "$HOSTNAME" ]
    [ "$(calls hostname | grep . | tail -1)" = "$HOSTNAME" ]
}

@test "09hostname exits without a name" {
    # HOSTNAME empty, as a conf file can make it
    echo "export HOSTNAME=" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/09hostname"

    [ "$status" -eq 0 ]
    [ -z "$(calls hostname)" ]
}

# --- the build name -------------------------------------------------------
# The image is built on a host called core: common/conf/turnkey.d/
# postfix-local sets myhostname to the build host's name, and /etc/mailname
# has it too. On LXC, Proxmox names the machine before it boots, so the old
# name hostname_set replaces is already the new one. On BR2, 2026-11-05, a
# WordPress LXC kept "myhostname = core" and sent its mail From root@core.

# build_image NAME
# The scratch files as an image built on the host NAME has them.
build_image() {
    echo "$1" > "$HOSTNAME_ROOT/etc/mailname"
    printf 'myhostname = %s\nmydestination = $myhostname, %s, localhost.localdomain, localhost\nsmtpd_banner = $myhostname ESMTP\n' "$1" "$1" \
        > "$HOSTNAME_ROOT/etc/postfix/main.cf"
    mkdir -p "$HOSTNAME_ROOT/etc/ssh"
    echo "ssh-ed25519 AAAA root@$1" > "$HOSTNAME_ROOT/etc/ssh/ssh_host_ed25519_key.pub"
}

@test "hostname_adopt replaces the build name with the machine's name" {
    source "$REPO/lib/hostname.sh"
    stateful_hostname wp-br2
    build_image core

    hostname_adopt

    [ "$(cat "$HOSTNAME_ROOT/etc/mailname")" = wp-br2 ]
    [ "$(sed -n 1p "$HOSTNAME_ROOT/etc/postfix/main.cf")" = "myhostname = wp-br2" ]
    [ "$(sed -n 2p "$HOSTNAME_ROOT/etc/postfix/main.cf")" = 'mydestination = $myhostname, wp-br2, localhost.localdomain, localhost' ]
    [ "$(cat "$HOSTNAME_ROOT/etc/ssh/ssh_host_ed25519_key.pub")" = "ssh-ed25519 AAAA root@wp-br2" ]
    # the kernel's name is not set: it is already the right one
    [ "$(calls hostname)" = "" ]
}

@test "a dotted machine name is adopted whole" {
    source "$REPO/lib/hostname.sh"
    stateful_hostname wp.example.org
    build_image core

    hostname_adopt

    [ "$(cat "$HOSTNAME_ROOT/etc/mailname")" = wp.example.org ]
    [ "$(sed -n 1p "$HOSTNAME_ROOT/etc/postfix/main.cf")" = "myhostname = wp.example.org" ]
}

@test "the build name is the first label of a dotted mailname" {
    source "$REPO/lib/hostname.sh"
    stateful_hostname wp-br2
    build_image core
    echo core.localdomain > "$HOSTNAME_ROOT/etc/mailname"

    hostname_adopt

    [ "$(cat "$HOSTNAME_ROOT/etc/mailname")" = wp-br2.localdomain ]
    [ "$(sed -n 1p "$HOSTNAME_ROOT/etc/postfix/main.cf")" = "myhostname = wp-br2" ]
}

@test "without a mailname the build name is postfix's myhostname" {
    source "$REPO/lib/hostname.sh"
    stateful_hostname wp-br2
    build_image core
    rm "$HOSTNAME_ROOT/etc/mailname"
    stub postconf 'echo core.localdomain'

    hostname_adopt

    [ "$(calls postconf)" = "-c $HOSTNAME_ROOT/etc/postfix -h myhostname" ]
    [ "$(sed -n 1p "$HOSTNAME_ROOT/etc/postfix/main.cf")" = "myhostname = wp-br2" ]
}

@test "a postconf that fails gives no build name" {
    source "$REPO/lib/hostname.sh"
    stateful_hostname wp-br2
    build_image core
    rm "$HOSTNAME_ROOT/etc/mailname"
    stub postconf 'exit 1'
    touch -d '2020-01-01' "$HOSTNAME_ROOT/etc/postfix/main.cf"

    hostname_adopt

    [ "$(stat -c %Y "$HOSTNAME_ROOT/etc/postfix/main.cf")" = "$(date -d '2020-01-01' +%s)" ]
}

@test "with neither a mailname nor postconf there is no build name" {
    source "$REPO/lib/hostname.sh"
    rm "$HOSTNAME_ROOT/etc/mailname"
    # PATH has the stubs only, and there is no postconf stub
    PATH=$STUBS run hostname_build_name

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a machine that already has the build name touches no file" {
    source "$REPO/lib/hostname.sh"
    stateful_hostname core.example.org
    build_image core
    touch -d '2020-01-01' "$HOSTNAME_ROOT/etc/postfix/main.cf"

    hostname_adopt

    [ "$(stat -c %Y "$HOSTNAME_ROOT/etc/postfix/main.cf")" = "$(date -d '2020-01-01' +%s)" ]
}

@test "localhost is never taken for a build name" {
    # replacing localhost would rewrite the loopback line of /etc/hosts
    source "$REPO/lib/hostname.sh"
    stateful_hostname wp-br2
    echo localhost.localdomain > "$HOSTNAME_ROOT/etc/mailname"

    hostname_adopt

    [ "$(sed -n 1p "$HOSTNAME_ROOT/etc/hosts")" = "$(printf '127.0.0.1\tlocalhost')" ]
    [ "$(cat "$HOSTNAME_ROOT/etc/mailname")" = localhost.localdomain ]
}

@test "09hostname without a preseed adopts the name Proxmox gave the LXC" {
    stateful_hostname wp-br2
    build_image core
    echo wp-br2 > "$HOSTNAME_ROOT/etc/hostname"

    # bash takes HOSTNAME from its environment: here the stub's name, as
    # the bash of a machine has the machine's name
    HOSTNAME=wp-br2 run "$REPO/firstboot.d/09hostname"

    [ "$status" -eq 0 ]
    [ "$(cat "$HOSTNAME_ROOT/etc/mailname")" = wp-br2 ]
    [ "$(sed -n 1p "$HOSTNAME_ROOT/etc/postfix/main.cf")" = "myhostname = wp-br2" ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = wp-br2 ]
}

@test "09hostname with a preseeded name replaces the build name too" {
    stateful_hostname wp-br2
    build_image core
    echo wp-br2 > "$HOSTNAME_ROOT/etc/hostname"
    echo "export HOSTNAME=blog" > "$INITHOOKS_CONF"

    run "$REPO/firstboot.d/09hostname"

    [ "$status" -eq 0 ]
    [ "$(cat "$HOSTNAME_ROOT/etc/hostname")" = blog ]
    [ "$(cat "$HOSTNAME_ROOT/etc/mailname")" = blog ]
    [ "$(sed -n 1p "$HOSTNAME_ROOT/etc/postfix/main.cf")" = "myhostname = blog" ]
}
