# Renaming the machine, as firstboot.d/09hostname has always done it: the
# old name is replaced with the new one in every file of HOSTNAME_FILES
# that exists, and the kernel's name is set. firstboot.d/31fqdn renames
# the machine the same way once the operator has answered its domain
# name, so the rename lives here and both hooks source it.
#
# The old name is replaced only where it stands as a whole name, or as
# the first label of a dotted name (`blog`, `blog.example.org`), never
# inside another word (`weblog`, `backup-blog`, `www.blog`), and it is
# matched literally: 09hostname's sed took it as a pattern, so a short
# name such as `web` was rewritten inside every SSH public key comment,
# postfix setting and word of /etc/hosts that contained it, and a colon
# in the name broke the command. perl does the match (perl-base is
# essential on Debian, and lib/tagid.sh uses it too); the two names reach
# it through the environment, never through the pattern.
#
# HOSTNAME_ROOT prefixes every file, for a test that works on scratch
# copies; on a machine it is empty.

HOSTNAME_ROOT="${HOSTNAME_ROOT:-}"

readarray -t HOSTNAME_FILES <<'FILES'
/etc/exim4/update-exim4.conf.conf
/etc/printcap
/etc/hostname
/etc/hosts
/etc/network/interfaces
/etc/ssh/ssh_host_rsa_key.pub
/etc/ssh/ssh_host_dsa_key.pub
/etc/ssh/ssh_host_ecdsa_key.pub
/etc/ssh/ssh_host_ed25519_key.pub
/etc/mailname
/etc/postfix/main.cf
/etc/motd
/etc/ssmtp/ssmtp.conf
FILES

# hostname_set NEW
# Replaces the name the machine has (hostname) with NEW in the files, as a
# whole name or a first label, then sets the kernel's name to NEW. The
# same name twice touches no file.
hostname_set() {
    local new=$1 old
    old=$(hostname)
    if [[ "$old" != "$new" ]]; then
        hostname_replace "$old" "$new"
    fi
    hostname "$new"
}

# hostname_replace OLD NEW
# Replaces OLD with NEW in the files, as a whole name or a first label.
hostname_replace() {
    local file
    for file in "${HOSTNAME_FILES[@]}"; do
        if [[ -f "$HOSTNAME_ROOT$file" ]]; then
            HOSTNAME_OLD=$1 HOSTNAME_NEW=$2 perl -pi -e \
                's/(?<![A-Za-z0-9_.-])\Q$ENV{HOSTNAME_OLD}\E(?![A-Za-z0-9_-])/$ENV{HOSTNAME_NEW}/g' \
                "$HOSTNAME_ROOT$file"
        fi
    done
}

# hostname_build_name
# The name of the host the image was built on, as the image's mail
# configuration has it: the first label of /etc/mailname, else of
# postfix's myhostname. common/conf/turnkey.d/postfix-local sets
# myhostname to the build host's name. Nothing when the machine has
# neither, or when the name is localhost, which is not a build name, and
# whose replacement would rewrite the loopback line of /etc/hosts.
hostname_build_name() {
    local name=
    if [[ -s "$HOSTNAME_ROOT/etc/mailname" ]]; then
        read -r name < "$HOSTNAME_ROOT/etc/mailname" || true
    elif command -v postconf > /dev/null; then
        name=$(postconf -c "$HOSTNAME_ROOT/etc/postfix" -h myhostname 2>/dev/null) || name=
    fi
    name=${name%%.*}
    if [[ "$name" != localhost ]]; then
        echo "$name"
    fi
}

# hostname_adopt
# Replaces the build name with the name the machine has (hostname) in the
# files, when the two differ. On LXC, Proxmox names the machine before it
# boots, so hostname_set finds the new name already in place and changes
# no file: on BR2, 2026-11-05, a WordPress LXC kept postfix's
# "myhostname = core" and sent its mail From root@core. The kernel's name
# is not set: it is already the right one.
hostname_adopt() {
    local build current
    build=$(hostname_build_name)
    current=$(hostname)
    if [[ -n "$build" ]] && [[ "$build" != "${current%%.*}" ]]; then
        hostname_replace "$build" "$current"
    fi
}
