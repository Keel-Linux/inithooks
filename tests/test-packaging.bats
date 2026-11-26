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

# --no-start alone turns off restart-after-upgrade, and debhelper then stops
# every unit in preinst on an upgrade: keel-host-keys inactive until a reboot,
# confconsole gone from tty1. master's preinst stops nothing.
@test "the packaged preinst stops no unit on an upgrade" {
    packaged_scripts
    run ! grep 'deb-systemd-invoke stop' "$DEBIAN/preinst"
}

# prerm stops the units when the package is removed, as master's did, and
# never on an upgrade: every stop sits under a `"$1" = remove` guard.
@test "the packaged prerm stops the fence on removal" {
    packaged_scripts
    grep -q 'for unit in turnkey-init-fence ' "$DEBIAN/prerm"
}

@test "the packaged prerm stops a unit only on removal" {
    packaged_scripts
    run ! awk '/"\$1" = remove/ { guard = 1 } /deb-systemd-invoke stop/ && !guard { bad = 1 } /^fi/ { guard = 0 } END { exit !bad }' "$DEBIAN/prerm"
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

# The cluster of PostgreSQL is a template instance, postgresql@17-main.service.
# Before=postgresql.service above does not order it. On a first boot the server
# started while the snakeoil certificate did not exist, failed, and started
# again after 35pgsqlpass had run: 35pgsqlpass and 36pgsqlverify failed
# (keel-postgresql#20).
@test "every postgresql@ instance starts after keel-host-keys.service" {
    local dropin=$REPO/systemd/postgresql@.service.d/10-keel-host-keys.conf
    [[ -f "$dropin" ]]
    [[ "$(awk '/^\[/ { section = $0 } /^After=/ { print section ":" $0 }' "$dropin")" \
        == "[Unit]:After=keel-host-keys.service" ]]
}

@test "the package installs the postgresql@ drop-in under /usr/lib/systemd/system" {
    grep -Eq '^systemd/postgresql@\.service\.d/\*[[:space:]]+/usr/lib/systemd/system/postgresql@\.service\.d$' \
        "$REPO/debian/inithooks.install"
}

# prepare_postinst: the packaged postinst, with every command it calls
# stubbed, against a scratch hourly cron directory (CRON_HOURLY). The script
# names /etc/cron.hourly literally; the copy run here has that one path
# pointed at the scratch directory, nothing else changed.
prepare_postinst() {
    packaged_scripts
    load helpers
    setup_stubs
    local cmd
    for cmd in systemctl chmod deb-systemd-helper deb-systemd-invoke \
        py3compile pypy3compile dpkg-maintscript-helper; do
        stub "$cmd"
    done
    CRON_HOURLY=$BATS_TEST_TMPDIR/etc/cron.hourly
    mkdir -p "$CRON_HOURLY"
    sed "s|/etc/cron.hourly/|$CRON_HOURLY/|g" "$DEBIAN/postinst" \
        > "$BATS_TEST_TMPDIR/postinst"
}

# The first boot of an older inithooks left a cron job that posts the
# operator's email address to the TurnKey Hub every hour until it gets an
# answer; an upgrade has to stop it, not only stop creating it.
@test "an upgrade removes the job that posted the alert address to the TurnKey Hub" {
    prepare_postinst
    echo '#!/bin/bash -e' > "$CRON_HOURLY/enable_secalerts"
    touch "$CRON_HOURLY/other-job"
    run sh "$BATS_TEST_TMPDIR/postinst" configure 2.3.6+keel14
    [ "$status" -eq 0 ]
    [ ! -e "$CRON_HOURLY/enable_secalerts" ]
    [ -e "$CRON_HOURLY/other-job" ]
}

# getty_answers: systemctl answers from the environment, for the upgrade
# branch of postinst: INITHOOKS_STATE is what is-active says of
# inithooks.service, INITHOOKS_JOB a queued job, GETTY_UNITS the getty units
# the machine has (systemctl cat), GETTY_ACTIVE the ones running,
# FENCE_ENABLED and FENCE_FAILED (any value) what is-enabled and is-failed
# say of turnkey-init-fence.service, FENCE_START the status of its restart.
getty_answers() {
    stub systemctl 'case "$1" in
    is-active)
        unit=${2#--quiet}; unit=${unit:-$3}
        case "$unit" in
            inithooks.service) echo "${INITHOOKS_STATE:-inactive}"
                [ "${INITHOOKS_STATE:-inactive}" = active ] ;;
            *) [[ " ${GETTY_ACTIVE-} " == *" $unit "* ]] ;;
        esac ;;
    list-jobs) printf "%s" "${INITHOOKS_JOB-}" ;;
    cat) [[ " ${GETTY_UNITS-} " == *" $2 "* ]] ;;
    is-enabled) [ -n "${FENCE_ENABLED-}" ] ;;
    is-failed) [ -n "${FENCE_FAILED-}" ] ;;
    start|restart) [ "$2" != turnkey-init-fence.service ] || exit "${FENCE_START:-0}" ;;
    *) exit 0 ;;
esac'
}

upgrade_postinst() {
    run sh "$BATS_TEST_TMPDIR/postinst" configure 2.3.6+keel18
    [ "$status" -eq 0 ]
}

# 2026-10-03: the maintainer ran apt upgrade from the container console and
# was logged out mid-upgrade; postinst restarted the getty of the console
# the upgrade was running on, "to make sure" it was running.
@test "an upgrade never restarts a getty" {
    prepare_postinst
    getty_answers
    export GETTY_UNITS="getty@tty1.service container-getty@1.service"
    export GETTY_ACTIVE="getty@tty1.service container-getty@1.service"
    upgrade_postinst
    run ! grep -qE "^(start|restart)" "$STUBS/systemctl.calls"
}

@test "the packaged postinst has no getty restart left in it" {
    packaged_scripts
    run ! grep -E 'restart.*getty' "$DEBIAN/postinst"
}

@test "an upgrade starts a getty that is inactive, among the units the machine has" {
    prepare_postinst
    getty_answers
    # a container: container-getty@1 only, not running
    export GETTY_UNITS="container-getty@1.service"
    upgrade_postinst
    [ "$(grep -E '^start' "$STUBS/systemctl.calls")" = "start container-getty@1.service" ]
}

@test "an upgrade starts each getty the machine has and does not run" {
    prepare_postinst
    getty_answers
    export GETTY_UNITS="getty@tty1.service container-getty@1.service"
    export GETTY_ACTIVE="container-getty@1.service"
    upgrade_postinst
    [ "$(grep -E '^start' "$STUBS/systemctl.calls")" = "start getty@tty1.service" ]
}

@test "an upgrade touches no getty while the first boot runs" {
    prepare_postinst
    getty_answers
    export GETTY_UNITS="getty@tty1.service"
    export INITHOOKS_STATE=activating
    upgrade_postinst
    run ! grep -qE "^(start|restart)" "$STUBS/systemctl.calls"
}

@test "an upgrade touches no getty while the first boot is queued" {
    prepare_postinst
    getty_answers
    export GETTY_UNITS="getty@tty1.service"
    export INITHOOKS_JOB="12 inithooks.service start waiting"
    upgrade_postinst
    run ! grep -qE "^(start|restart)" "$STUBS/systemctl.calls"
}

@test "an upgrade with inithooks running before it restarts inithooks, as before" {
    prepare_postinst
    getty_answers
    export GETTY_UNITS="getty@tty1.service"
    # the marker preinst leaves: the copy run here reads the real /run, so
    # the path is pointed at a scratch one, the way the cron path is
    sed -i "s|/run/inithooks-was-active|$BATS_TEST_TMPDIR/inithooks-was-active|g" \
        "$BATS_TEST_TMPDIR/postinst"
    touch "$BATS_TEST_TMPDIR/inithooks-was-active"
    upgrade_postinst
    grep -qx "restart inithooks.service" "$STUBS/systemctl.calls"
    [ ! -e "$BATS_TEST_TMPDIR/inithooks-was-active" ]
    run ! grep -q getty "$STUBS/systemctl.calls"
}

@test "a fresh install touches no getty" {
    prepare_postinst
    getty_answers
    export GETTY_UNITS="getty@tty1.service"
    run sh "$BATS_TEST_TMPDIR/postinst" configure
    [ "$status" -eq 0 ]
    run ! grep -q getty "$STUBS/systemctl.calls"
    grep -qx "enable inithooks.service" "$STUBS/systemctl.calls"
}

@test "a system that never had the job installs cleanly" {
    prepare_postinst
    run sh "$BATS_TEST_TMPDIR/postinst" configure
    [ "$status" -eq 0 ]
    [ ! -e "$CRON_HOURLY/enable_secalerts" ]
}

# The fence on nftables (inithooks#68). Up to 2.3.6+keel38 it wrote
# iptables rules, which the new stop does not remove: preinst stops a
# running fence with the old script, and postinst starts it again.

# preinst_copy: debian/preinst with its /run markers in BATS_TEST_TMPDIR and
# systemctl a stub; is-active says FENCE_ACTIVE (any value) of the fence
preinst_copy() {
    load helpers
    setup_stubs
    stub systemctl 'echo "systemctl $*" >> "'"$STUBS"'/order"
case "$1" in
    is-active) [ "$3" = turnkey-init-fence.service ] && [ -n "${FENCE_ACTIVE-}" ] ;;
    *) exit 0 ;;
esac'
    stub_order_nft
    FENCE_DEFAULTS=$BATS_TEST_TMPDIR/default-turnkey-init-fence
    printf '%s\n' 'HTTP_PORTS=(80)' 'HTTPS_PORTS=(443 12321 12322)' > "$FENCE_DEFAULTS"
    sed -e "s|/run/|$BATS_TEST_TMPDIR/|g" \
        -e "s|/etc/default/turnkey-init-fence|$FENCE_DEFAULTS|g" \
        "$REPO/debian/preinst" > "$BATS_TEST_TMPDIR/preinst"
}

# stub_order_nft: nft records "nft", then the script it got, in the file
# order, which the systemctl stubs here also write; NFT_STATUS is its exit
stub_order_nft() {
    stub nft '{ echo nft; cat; } >> "'"$STUBS"'/order"; exit "${NFT_STATUS:-0}"'
}

order() {
    cat "$STUBS/order" 2>/dev/null || true
}

@test "an upgrade from the iptables fence stops the running fence before the files change" {
    preinst_copy
    export FENCE_ACTIVE=yes
    run sh "$BATS_TEST_TMPDIR/preinst" upgrade 2.3.6+keel38
    [ "$status" -eq 0 ]
    grep -qx "stop turnkey-init-fence.service" "$STUBS/systemctl.calls"
    [ -e "$BATS_TEST_TMPDIR/turnkey-init-fence-was-active" ]
}

# The first boot's security update of an older image upgrades inithooks
# while the wizard waits: the ports must stay fenced while dpkg unpacks.
@test "an upgrade from the iptables fence loads the drop before it stops the old fence" {
    preinst_copy
    export FENCE_ACTIVE=yes
    run sh "$BATS_TEST_TMPDIR/preinst" upgrade 2.3.6+keel38
    [ "$status" -eq 0 ]
    [ "$(order | grep -v is-active)" = "$(printf '%s\n' nft \
        'table inet keel_fence' \
        'delete table inet keel_fence' \
        'table inet keel_fence {' \
        '	chain input {' \
        '		type filter hook input priority filter - 5; policy accept;' \
        '		iifname != "lo" tcp dport { 80, 443, 12321, 12322 } drop' \
        '	}' \
        '}' \
        'systemctl stop turnkey-init-fence.service')" ]
}

@test "the early drop reads the ports of the defaults file" {
    preinst_copy
    export FENCE_ACTIVE=yes
    printf '%s\n' 'HTTP_PORTS=(8080)' 'HTTPS_PORTS=(8443 9443)' > "$FENCE_DEFAULTS"
    run sh "$BATS_TEST_TMPDIR/preinst" upgrade 2.3.6+keel38
    [ "$status" -eq 0 ]
    order | grep -qx '		iifname != "lo" tcp dport { 8080, 8443, 9443 } drop'
}

@test "the early drop fences the default ports for empty or invalid lists" {
    preinst_copy
    export FENCE_ACTIVE=yes
    printf '%s\n' 'HTTP_PORTS=()' 'HTTPS_PORTS=(443 "1;x")' > "$FENCE_DEFAULTS"
    run sh "$BATS_TEST_TMPDIR/preinst" upgrade 2.3.6+keel38
    [ "$status" -eq 0 ]
    order | grep -qx '		iifname != "lo" tcp dport { 80, 443, 12321, 12322 } drop'
    rm "$FENCE_DEFAULTS" "$STUBS/order"
    run sh "$BATS_TEST_TMPDIR/preinst" upgrade 2.3.6+keel38
    [ "$status" -eq 0 ]
    order | grep -qx '		iifname != "lo" tcp dport { 80, 443, 12321, 12322 } drop'
}

@test "an early drop that nft refuses does not stop the upgrade" {
    preinst_copy
    export FENCE_ACTIVE=yes NFT_STATUS=1
    run sh "$BATS_TEST_TMPDIR/preinst" upgrade 2.3.6+keel38
    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks: cannot load the fence's drop table; the ports are open until postinst starts the fence"* ]]
    grep -qx "stop turnkey-init-fence.service" "$STUBS/systemctl.calls"
}

@test "with no nft the old fence still stops, and the upgrade goes on" {
    preinst_copy
    export FENCE_ACTIVE=yes
    rm "$STUBS/nft"
    PATH=$STUBS:/usr/bin:/bin run sh "$BATS_TEST_TMPDIR/preinst" upgrade 2.3.6+keel38
    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks: no nft; the ports are open until postinst starts the fence"* ]]
    grep -qx "stop turnkey-init-fence.service" "$STUBS/systemctl.calls"
}

@test "an upgrade from the nftables fence stops no unit" {
    preinst_copy
    export FENCE_ACTIVE=yes
    run sh "$BATS_TEST_TMPDIR/preinst" upgrade 2.3.6+keel39
    [ "$status" -eq 0 ]
    run ! grep -q "^stop" "$STUBS/systemctl.calls"
}

@test "an upgrade with the fence down stops no unit" {
    preinst_copy
    run sh "$BATS_TEST_TMPDIR/preinst" upgrade 2.3.6+keel38
    [ "$status" -eq 0 ]
    run ! grep -q "^stop" "$STUBS/systemctl.calls"
}

# fence_postinst: the packaged postinst with the fence's /run marker in
# BATS_TEST_TMPDIR
fence_postinst() {
    prepare_postinst
    getty_answers
    sed -i "s|/run/turnkey-init-fence-was-active|$BATS_TEST_TMPDIR/turnkey-init-fence-was-active|g" \
        "$BATS_TEST_TMPDIR/postinst"
}

# start, not restart: a restart stops the new fence first, and its stop
# removes the drop that preinst loaded
@test "an upgrade starts the fence again when it ran, also with inithooks down" {
    fence_postinst
    touch "$BATS_TEST_TMPDIR/turnkey-init-fence-was-active"
    upgrade_postinst
    grep -qx "start turnkey-init-fence.service" "$STUBS/systemctl.calls"
    run ! grep -q "^restart turnkey-init-fence" "$STUBS/systemctl.calls"
    [ ! -e "$BATS_TEST_TMPDIR/turnkey-init-fence-was-active" ]
}

@test "an upgrade from the nftables fence does not restart the running fence" {
    fence_postinst
    touch "$BATS_TEST_TMPDIR/turnkey-init-fence-was-active"
    run sh "$BATS_TEST_TMPDIR/postinst" configure 2.3.6+keel39
    [ "$status" -eq 0 ]
    run ! grep -q "turnkey-init-fence" "$STUBS/systemctl.calls"
    [ ! -e "$BATS_TEST_TMPDIR/turnkey-init-fence-was-active" ]
}

@test "an upgrade starts the fence when it is enabled and failed" {
    fence_postinst
    export FENCE_ENABLED=yes FENCE_FAILED=yes
    upgrade_postinst
    grep -qx "restart turnkey-init-fence.service" "$STUBS/systemctl.calls"
}

@test "an upgrade leaves a fence alone that is disabled or not failed" {
    fence_postinst
    export FENCE_FAILED=yes
    upgrade_postinst
    run ! grep -q "turnkey-init-fence" <(grep -E "^(start|restart)" "$STUBS/systemctl.calls")
    export FENCE_ENABLED=yes FENCE_FAILED=
    upgrade_postinst
    run ! grep -q "turnkey-init-fence" <(grep -E "^(start|restart)" "$STUBS/systemctl.calls")
}

@test "a fence that does not start does not fail the upgrade" {
    fence_postinst
    export FENCE_ENABLED=yes FENCE_FAILED=yes FENCE_START=1
    upgrade_postinst
    [[ "$output" == *"inithooks: turnkey-init-fence did not start, see its journal"* ]]
}

@test "the package depends on nftables, which the fence writes" {
    sed -n '/^Package: inithooks$/,/^$/p' "$REPO/debian/control" | grep -qx ' nftables,'
}

# Each start, reload, restart and stop of nftables.service flushes the
# ruleset, and the fence's table with it.
@test "nftables.service loads the fence's table again after each flush" {
    local dropin=$REPO/systemd/nftables.service.d/turnkey-init-fence.conf
    local hook
    for hook in ExecStartPost ExecReload ExecStopPost; do
        grep -qx "$hook=-/usr/lib/inithooks/bin/turnkey-init-fence reload-rules" "$dropin"
    done
}

@test "the package installs the nftables drop-in under /usr/lib/systemd/system" {
    grep -Eq '^systemd/nftables\.service\.d/\*[[:space:]]+/usr/lib/systemd/system/nftables\.service\.d$' \
        "$REPO/debian/inithooks.install"
}

# dpkg runs "new-postrm abort-upgrade OLD" when the unpack fails after
# preinst: the drop that preinst loaded goes, and the fence that preinst
# stopped starts again from the files on disk.
postrm_copy() {
    load helpers
    setup_stubs
    stub systemctl 'echo "systemctl $*" >> "'"$STUBS"'/order"; exit "${FENCE_START:-0}"'
    stub_order_nft
    sed "s|/run/|$BATS_TEST_TMPDIR/|g" "$REPO/debian/postrm" > "$BATS_TEST_TMPDIR/postrm"
}

@test "an aborted upgrade removes the early drop and starts the fence again" {
    postrm_copy
    touch "$BATS_TEST_TMPDIR/turnkey-init-fence-was-active"
    run sh "$BATS_TEST_TMPDIR/postrm" abort-upgrade 2.3.6+keel38
    [ "$status" -eq 0 ]
    [ "$(order)" = "$(printf '%s\n' nft 'table inet keel_fence' \
        'delete table inet keel_fence' 'systemctl start turnkey-init-fence.service')" ]
}

@test "an aborted upgrade with the fence down touches nothing" {
    postrm_copy
    run sh "$BATS_TEST_TMPDIR/postrm" abort-upgrade 2.3.6+keel38
    [ "$status" -eq 0 ]
    [ -z "$(order)" ]
}

@test "an aborted upgrade from the nftables fence touches nothing" {
    postrm_copy
    touch "$BATS_TEST_TMPDIR/turnkey-init-fence-was-active"
    run sh "$BATS_TEST_TMPDIR/postrm" abort-upgrade 2.3.6+keel39
    [ "$status" -eq 0 ]
    [ -z "$(order)" ]
}

@test "an aborted upgrade does not fail when the fence does not start" {
    postrm_copy
    touch "$BATS_TEST_TMPDIR/turnkey-init-fence-was-active"
    export FENCE_START=1 NFT_STATUS=1
    run sh "$BATS_TEST_TMPDIR/postrm" abort-upgrade 2.3.6+keel38
    [ "$status" -eq 0 ]
}

@test "the packaged postrm keeps its own steps around the snippet" {
    packaged_scripts
    grep -q 'abort-upgrade' "$DEBIAN/postrm"
    tail -n 1 "$DEBIAN/postrm" | grep -qx 'exit 0'
}
