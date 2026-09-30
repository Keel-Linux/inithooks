#!/usr/bin/env bats
# Tests for the maintainer scripts the package ships (debian/).
#
# The Template B3 build of 2026-09-30 booted with no SSH host key: debian/
# postinst had no #DEBHELPER# token, so dh_installsystemd's snippet that
# enables keel-host-keys.service was never put in the package, the unit never
# ran, and sshd, the init fence and apache2 found no key at first boot.
#
# The tests run the real debhelper over a scratch copy of debian/, the same
# dh_installsystemd calls debian/rules makes and dh_installdeb, which merges
# the snippets into the scripts the .deb carries, and read what it wrote. Only
# debhelper is needed, not the build dependencies. Where it is not installed
# the tests are skipped, except in CI, where that is a failure.

bats_require_minimum_version 1.5.0

REPO=$BATS_TEST_DIRNAME/..

# packaged_scripts: runs debhelper over a copy of debian/ and sets DEBIAN to
# the directory of the maintainer scripts the .deb would carry. As a
# non-root user, with DEB_RULES_REQUIRES_ROOT=no, the way dpkg-buildpackage
# runs it for a package that needs no root.
packaged_scripts() {
    if ! command -v dh_installdeb >/dev/null 2>&1; then
        [[ -z "${CI:-}" ]] || {
            echo "debhelper is not installed; the workflow must install it" >&2
            return 1
        }
        skip "debhelper is not installed"
    fi
    SRC=$BATS_TEST_TMPDIR/src
    mkdir -p "$SRC"
    cp -a "$REPO/debian" "$SRC/"
    rm -rf "$SRC/debian/inithooks" "$SRC"/debian/*.debhelper "$SRC"/debian/*.substvars
    (
        cd "$SRC"
        export DEB_RULES_REQUIRES_ROOT=no
        make -s -f debian/rules override_dh_installsystemd
        dh_installdeb -pinithooks
    ) >"$BATS_TEST_TMPDIR/debhelper.log" 2>&1 || {
        cat "$BATS_TEST_TMPDIR/debhelper.log" >&2
        return 1
    }
    DEBIAN=$SRC/debian/inithooks/DEBIAN
}

@test "every hand-written maintainer script carries the #DEBHELPER# token" {
    local script
    for script in "$REPO"/debian/{pre,post}{inst,rm}; do
        [[ -f "$script" ]] || continue
        grep -qx '#DEBHELPER#' "$script" || {
            echo "no #DEBHELPER# in $script" >&2
            return 1
        }
    done
}

@test "the packaged postinst enables keel-host-keys.service" {
    packaged_scripts
    grep -q "deb-systemd-helper enable 'keel-host-keys.service'" "$DEBIAN/postinst"
}

@test "the packaged postinst keeps its own configure steps around the snippet" {
    packaged_scripts
    grep -q 'systemctl enable inithooks.service' "$DEBIAN/postinst"
    grep -q 'chmod 755 /usr/lib/python3/dist-packages/libinithooks/inithooks_cache.py' "$DEBIAN/postinst"
    tail -n 1 "$DEBIAN/postinst" | grep -qx 'exit 0'
}

@test "the packaged postinst starts no unit, keel-host-keys and inithooks included" {
    packaged_scripts
    run ! grep -E 'deb-systemd-invoke (start|restart)|systemctl .*start keel-host-keys' "$DEBIAN/postinst"
}

# With --no-enable, debhelper only refreshes the links of a unit it already
# installed and that is enabled, under a `debian-installed` guard; the first
# enable stays with debian/postinst. keel-host-keys.service must not be under
# that guard, or an upgrade from a version that never enabled it would not.
@test "debhelper enables inithooks and the fence only where already enabled, keel-host-keys always" {
    packaged_scripts
    local unit
    for unit in inithooks turnkey-init-fence; do
        grep -q "deb-systemd-helper debian-installed '$unit.service'" "$DEBIAN/postinst" || {
            echo "debhelper enables $unit.service unguarded" >&2
            return 1
        }
    done
    run ! grep -q "deb-systemd-helper debian-installed 'keel-host-keys.service'" "$DEBIAN/postinst"
}

@test "keel-host-keys.service is wanted by multi-user.target" {
    grep -qx 'WantedBy=multi-user.target' "$REPO/debian/inithooks.keel-host-keys.service"
}

@test "keel-host-keys.service runs before every service that reads the keys" {
    local unit=$REPO/debian/inithooks.keel-host-keys.service
    local before want
    before=" $(sed -n 's/^Before=//p' "$unit" | tr '\n' ' ') "
    for want in ssh.service apache2.service nginx.service lighttpd.service \
        webmin.service postgresql.service postfix.service \
        inithooks.service turnkey-init-fence.service; do
        [[ "$before" == *" $want "* ]] || {
            echo "keel-host-keys.service is not Before=$want" >&2
            return 1
        }
    done
}
