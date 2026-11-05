# shellcheck shell=bash
# The first boot screens of a Keel appliance, handbook decisions 0020,
# 0028 and 0076: the installation mode, then this node's role (in a cloud
# mode the primary, the replica or the witness, with the mesh and the
# pair), then an optional Keel Cloud API key. The screens are
# confconsole's, and keeping them in one place is what keeps the first
# boot and a later change from confconsole the same. confconsole is in
# every Keel appliance; inithooks recommends it and does not depend on
# it, so a machine without it boots as a standalone node and says so.
#
# keelfirstboot.py decides everything else: it skips a step the instance
# description or a preseeded HUB_APIKEY already answers, asks again under
# keel-init, does a step that has one answer with no terminal, and draws
# on the terminal. Its reasons go to stderr, which inithooks.service sends
# to the journal. When nobody can answer the console (lib/console.sh) it
# is given no terminal. A step that then has a question exits
# KEEL_FIRSTBOOT_DEFERRED, and the question is left to keel-init
# (console_deferred): the first login starts keel-init, which asks it.
# Any other step says in one line that it drew nothing (console_skipped).

# shellcheck source=lib/console.sh
source "$INITHOOKS_PATH/lib/console.sh"

KEEL_FIRSTBOOT="${KEEL_FIRSTBOOT:-/usr/lib/confconsole/keelfirstboot.py}"
# keelfirstboot.py's exit when a question has no terminal to be asked on
KEEL_FIRSTBOOT_DEFERRED=75

# keel_firstboot STEP
# Runs confconsole's first boot screen STEP (mode, role or cloud) with the
# inithooks conf loaded, so a preseeded HUB_APIKEY reaches it. Returns its
# status, 0 when it left its question to keel-init, or 0 when confconsole
# is not installed.
keel_firstboot() {
    local step=$1 status=0
    if [[ -e "$INITHOOKS_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$INITHOOKS_CONF"
    fi
    if [[ ! -e "$KEEL_FIRSTBOOT" ]]; then
        echo "keel-firstboot $step: $KEEL_FIRSTBOOT not found, confconsole" \
            "is not installed: not asked, this node stays standalone" >&2
        return 0
    fi
    if console_unattended; then
        python3 "$KEEL_FIRSTBOOT" "$step" < /dev/null || status=$?
        if [[ $status -eq $KEEL_FIRSTBOOT_DEFERRED ]]; then
            console_deferred "$(basename "$0")" "confconsole's $step screen has a question: keel-init asks it"
            return 0
        fi
        console_skipped "$(basename "$0")" "confconsole's $step screen is run without a terminal and draws nothing"
        return "$status"
    fi
    python3 "$KEEL_FIRSTBOOT" "$step" || status=$?
    if [[ $status -eq $KEEL_FIRSTBOOT_DEFERRED ]]; then
        # the screen found no terminal it could draw on after all
        console_deferred "$(basename "$0")" "confconsole's $step screen found no terminal: keel-init asks it"
        return 0
    fi
    return "$status"
}
