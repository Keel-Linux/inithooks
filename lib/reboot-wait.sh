# shellcheck shell=bash
# The reboot for a new kernel at the first boot (firstboot.d/99reboot)
# waits while an SSH session is open or keel-init runs (maintainer decision
# 2026-11-26). A first boot with a key from the cloud-init drive asks its
# questions in keel-init over SSH (firstboot.d/02cloud-drive), and a
# reboot would end that session, or stop keel-init in its middle. The
# updates are installed before (95secupdates); only the reboot waits.
#
# With nothing open the machine reboots at once, as before. Otherwise a
# transient unit (systemd-run) runs bin/reboot-when-idle, which looks every
# REBOOT_WAIT_STEP seconds. An SSH session holds the reboot for at most
# REBOOT_WAIT_MAX seconds (6 hours): a session left open must not keep a
# kernel with known holes for good. keel-init holds it for as long as it
# runs: the machine never reboots in the middle of keel-init.

REBOOT_WAIT_MAX="${REBOOT_WAIT_MAX:-21600}"
REBOOT_WAIT_STEP="${REBOOT_WAIT_STEP:-30}"
REBOOT_UNIT=inithooks-reboot-when-idle

# reboot_ssh_open: an SSH session is open. OpenSSH names the process of
# each connection "sshd-session: USER..." (and older ones "sshd: USER...");
# the listener is "sshd: /usr/sbin/sshd ...", which is not a session.
reboot_ssh_open() {
    pgrep -f '^sshd(-session)?: [^/]' > /dev/null
}

# reboot_keel_init: keel-init (or its turnkey-init link) runs
reboot_keel_init() {
    pgrep -x 'keel-init|turnkey-init' > /dev/null
}

# reboot_log LINE: on stderr (the journal) and in the journal by logger
reboot_log() {
    echo "reboot: $1" >&2
    logger -t inithooks -p info "[reboot] $1" 2>/dev/null || true
}

# reboot_when_idle: reboots now when no SSH session and no keel-init
# remain; otherwise leaves the reboot to a unit that waits for that, and
# returns
reboot_when_idle() {
    if ! reboot_ssh_open && ! reboot_keel_init; then
        init 6
        return 0
    fi
    reboot_log "an SSH session or keel-init is open: the reboot waits until none remains, for an SSH session at most $REBOOT_WAIT_MAX s, for keel-init until it ends"
    if ! systemd-run --no-block --unit="$REBOOT_UNIT" \
            --description="Reboot for the new kernel once no SSH session and no keel-init remain" \
            "$INITHOOKS_PATH/bin/reboot-when-idle" > /dev/null 2>&1; then
        reboot_log "the unit $REBOOT_UNIT cannot start: the new kernel is installed, reboot by hand"
    fi
    return 0
}

# reboot_wait: what the unit runs; returns once it has asked for the reboot
reboot_wait() {
    local waited=0
    while true; do
        if reboot_keel_init; then
            :
        elif ! reboot_ssh_open; then
            reboot_log "no SSH session and no keel-init remain: rebooting for the new kernel"
            init 6
            return 0
        elif (( waited >= REBOOT_WAIT_MAX )); then
            reboot_log "waited $REBOOT_WAIT_MAX s and an SSH session is still open: rebooting for the new kernel"
            init 6
            return 0
        fi
        sleep "$REBOOT_WAIT_STEP"
        waited=$((waited + REBOOT_WAIT_STEP))
    done
}
