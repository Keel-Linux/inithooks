# The first boot screens of a Keel appliance, handbook decision 0020:
# this node's role (standalone, primary or replica), then an optional Keel
# Cloud API key. The screens are confconsole's: a primary or a replica goes
# through its Overlay network and Database mode screens, and keeping them
# in one place is what keeps the first boot and a later change from
# confconsole the same. confconsole is in every Keel appliance; inithooks
# recommends it and does not depend on it, so a machine without it boots
# as a standalone node and says so.
#
# keelfirstboot.py decides everything else: it skips a step the instance
# description or a preseeded HUB_APIKEY already answers, asks again under
# keel-init, and draws on the terminal. Its reasons go to stderr, which
# inithooks.service sends to the journal.

KEEL_FIRSTBOOT="${KEEL_FIRSTBOOT:-/usr/lib/confconsole/keelfirstboot.py}"

# keel_firstboot STEP
# Runs confconsole's first boot screen STEP (role or cloud) with the
# inithooks conf loaded, so a preseeded HUB_APIKEY reaches it. Returns its
# status, or 0 when confconsole is not installed.
keel_firstboot() {
    local step=$1
    if [[ -e "$INITHOOKS_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$INITHOOKS_CONF"
    fi
    if [[ ! -e "$KEEL_FIRSTBOOT" ]]; then
        echo "keel-firstboot $step: $KEEL_FIRSTBOOT not found, confconsole" \
            "is not installed: not asked, this node stays standalone" >&2
        return 0
    fi
    python3 "$KEEL_FIRSTBOOT" "$step"
}
