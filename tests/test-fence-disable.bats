#!/usr/bin/env bats
# Tests for firstboot.d/97turnkey-init-fence-disable: whether the first
# login starts keel-init.
#
# On BR2, 2026-11-05, a WordPress LXC nobody was attached to left the root
# password to keel-init (30rootpass), but the boot run disabled the fence
# and left the profile fence (/root/.profile.d/turnkey-init-fence, which
# starts keel-init at a login) not executable: the first login opened
# confconsole, never keel-init. The hook now keeps the fence when a hook
# recorded a question for keel-init (console_deferred, lib/console.sh).
#
# systemctl is a stub. The homes are under the scratch FENCE_ROOT, and
# INITHOOKS_PATH, the conf file and the record are scratch paths.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..
HOOK=$REPO/firstboot.d/97turnkey-init-fence-disable

setup() {
    setup_stubs
    stub systemctl
    unset _TURNKEY_INIT AUTO_RUN
    export FENCE_ROOT=$BATS_TEST_TMPDIR/fs
    ROOT_FENCE=$FENCE_ROOT/root/.profile.d/turnkey-init-fence
    ADMIN_FENCE=$FENCE_ROOT/home/admin/.profile.d/turnkey-init-fence
    mkdir -p "${ROOT_FENCE%/*}"
    install -m 644 /dev/null "$ROOT_FENCE"

    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH/firstboot.d"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
    install -m 755 "$REPO/firstboot.d/30turnkey-init-fence" "$HOOK" \
        "$INITHOOKS_PATH/firstboot.d/"
    export INITHOOKS_CONF=$BATS_TEST_TMPDIR/inithooks.conf
    export INITHOOKS_DEFAULT=$BATS_TEST_TMPDIR/default-inithooks
    write_default false
    export INITHOOKS_DEFERRED=$BATS_TEST_TMPDIR/deferred
}

# write_default SUDOADMIN
write_default() {
    {
        echo "INITHOOKS_PATH=$INITHOOKS_PATH"
        echo "INITHOOKS_CONF=$INITHOOKS_CONF"
        echo "SUDOADMIN=$1"
    } > "$INITHOOKS_DEFAULT"
}

# fence_disabled: the hook disabled and stopped the fence service
fence_disabled() {
    [ "$(calls systemctl)" = "$(printf 'disable turnkey-init-fence\nstop turnkey-init-fence')" ]
}

# --- the boot run ---------------------------------------------------------

@test "nothing left to keel-init: the fence goes down, as before" {
    run "$HOOK"

    [ "$status" -eq 0 ]
    fence_disabled
    [ ! -x "$ROOT_FENCE" ]
}

@test "an empty record leaves nothing to keel-init" {
    : > "$INITHOOKS_DEFERRED"

    run "$HOOK"

    [ "$status" -eq 0 ]
    fence_disabled
    [ ! -x "$ROOT_FENCE" ]
}

@test "a question left to keel-init arms the profile fence and keeps the service" {
    printf '30rootpass\n35mysqlpass\n' > "$INITHOOKS_DEFERRED"

    run "$HOOK"

    [ "$status" -eq 0 ]
    [ -x "$ROOT_FENCE" ]
    [ -z "$(calls systemctl)" ]
    [ "$output" = "turnkey-init-fence stays up: the first login starts keel-init, which asks what 30rootpass 35mysqlpass left" ]
    # keel-init itself must still find the hook, to disarm the fence
    [ -x "$INITHOOKS_PATH/firstboot.d/97turnkey-init-fence-disable" ]
}

@test "with a sudo admin, the admin's profile fence is armed" {
    write_default true
    mkdir -p "${ADMIN_FENCE%/*}"
    install -m 644 /dev/null "$ADMIN_FENCE"
    echo 30rootpass > "$INITHOOKS_DEFERRED"

    run "$HOOK"

    [ "$status" -eq 0 ]
    [ -x "$ADMIN_FENCE" ]
    [ ! -x "$ROOT_FENCE" ]
}

@test "with no profile fence the service stays up, and the hook says so" {
    rm "$ROOT_FENCE"
    echo 30rootpass > "$INITHOOKS_DEFERRED"

    run "$HOOK"

    [ "$status" -eq 0 ]
    [ -z "$(calls systemctl)" ]
    [ "$output" = "turnkey-init-fence stays up: no $ROOT_FENCE to start keel-init at the login, run keel-init to answer what 30rootpass left" ]
}

@test "AUTO_RUN keeps the fence, as before" {
    echo "AUTO_RUN=yes" > "$INITHOOKS_CONF"

    run "$HOOK"

    [ "$status" -eq 0 ]
    [ -z "$(calls systemctl)" ]
}

# --- the keel-init run ----------------------------------------------------

@test "keel-init disarms the fence and clears the record" {
    export _TURNKEY_INIT=1
    chmod +x "$ROOT_FENCE"
    mkdir -p "${ADMIN_FENCE%/*}"
    install -m 755 /dev/null "$ADMIN_FENCE"
    # keel-init emptied the record before its hooks ran
    : > "$INITHOOKS_DEFERRED"

    run "$HOOK"

    [ "$status" -eq 0 ]
    fence_disabled
    [ ! -x "$ROOT_FENCE" ]
    [ ! -x "$ADMIN_FENCE" ]
    [ ! -x "$INITHOOKS_PATH/firstboot.d/30turnkey-init-fence" ]
    [ ! -x "$INITHOOKS_PATH/firstboot.d/97turnkey-init-fence-disable" ]
    [ ! -e "$INITHOOKS_DEFERRED" ]
    [ "${lines[-1]}" = "turnkey-init-fence is down" ]
}

@test "keel-init with no record and no profile fence still disarms" {
    export _TURNKEY_INIT=1
    rm "$ROOT_FENCE"

    run "$HOOK"

    [ "$status" -eq 0 ]
    fence_disabled
}

@test "a question keel-init's own run left again keeps the fence up" {
    # BR1, 2026-11-06: ESC on the installation mode under keel-init left
    # the node with no mode; the next login must start keel-init again
    export _TURNKEY_INIT=1
    echo 75keel-role > "$INITHOOKS_DEFERRED"

    run "$HOOK"

    [ "$status" -eq 0 ]
    [ -z "$(calls systemctl)" ]
    [ -x "$ROOT_FENCE" ]
    [ -x "$INITHOOKS_PATH/firstboot.d/97turnkey-init-fence-disable" ]
    [ "$(cat "$INITHOOKS_DEFERRED")" = 75keel-role ]
    [ "$output" = "turnkey-init-fence stays up: the first login starts keel-init, which asks what 75keel-role left" ]
}
