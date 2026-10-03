# Whether anybody can answer a first boot screen. run asks it before its
# notices, and every hook that draws a screen asks it before drawing one:
# 30rootpass, 31fqdn, 75keel-role and 80keel-cloud (lib/keel-firstboot.sh),
# 85secalerts, 95secupdates and 99reboot. When nobody can, the hook asks
# nothing and does what it does with no answer, and says so in one line
# (console_skipped).
#
# The published Web 19.0-3 booted headless in an LXC container on
# 2026-10-03 stopped at 31fqdn for good: its screen was drawn on tty1, a pty
# whose master only an attached console reads (pct console, lxc-console),
# and waited for an answer nobody could give.
#
# The console is the terminal dialog draws on: standard output when it is
# a terminal, else the controlling terminal (screen_on_terminal() of
# libinithooks/dialog_wrapper.py). Nobody can answer it when
#   - there is none;
#   - it has no size: stty answers 0 0 on the tty of an LXC container
#     nobody is attached to, where a VT or an attached console answers its
#     rows and columns;
#   - it does not take CONSOLE_PROBE_BYTES NUL bytes within
#     CONSOLE_TIMEOUT seconds. A pty whose master nobody reads takes about
#     17 KB (Linux 6.12) and then blocks every write, so a small write
#     would pass and the screen after it would wait for good; the probe is
#     larger than any pty's buffer, and a terminal shows nothing for a NUL.
#
# The answer is exported in INITHOOKS_UNATTENDED, "no" when somebody can
# answer and otherwise the reason nobody can, so that run asks once and
# its hooks inherit what it found. Set beforehand, it is taken as it is.

CONSOLE_TIMEOUT="${CONSOLE_TIMEOUT:-${NOTICE_TIMEOUT:-2}}"
CONSOLE_PROBE_BYTES="${CONSOLE_PROBE_BYTES:-131072}"
CONSOLE_TTY="${CONSOLE_TTY:-/dev/tty}"

# console_unattended
# Succeeds when nobody can answer the console, the reason then being in
# INITHOOKS_UNATTENDED. Run it in the shell that keeps the answer, not in
# a command substitution.
console_unattended() {
    if [[ -z "${INITHOOKS_UNATTENDED:-}" ]]; then
        if [[ -t 1 ]]; then
            console_check 3>&1
        elif { : > "$CONSOLE_TTY"; } 2>/dev/null; then
            console_check 3>"$CONSOLE_TTY"
        else
            INITHOOKS_UNATTENDED="there is no terminal"
        fi
        export INITHOOKS_UNATTENDED="${INITHOOKS_UNATTENDED:-no}"
    fi
    [[ "$INITHOOKS_UNATTENDED" != "no" ]]
}

# console_check
# Sets INITHOOKS_UNATTENDED to why nobody can answer the console on fd 3,
# when nobody can.
console_check() {
    local size
    size=$(stty size <&3 2>/dev/null) || size=
    if [[ -z "$size" ]] || [[ "$size" == "0 0" ]]; then
        INITHOOKS_UNATTENDED="the console has no size, nobody is attached to it"
    elif ! console_probe; then
        INITHOOKS_UNATTENDED="the console did not take a write in ${CONSOLE_TIMEOUT} s, nobody is reading it"
    fi
}

# console_probe: writes the probe on fd 3, within CONSOLE_TIMEOUT
console_probe() {
    timeout --foreground "$CONSOLE_TIMEOUT" \
        head -c "$CONSOLE_PROBE_BYTES" /dev/zero >&3 2>/dev/null
}

# console_skipped HOOK WHAT
# The one line a hook leaves when it asks nothing: on stderr, which
# inithooks.service sends to the journal, and in the inithooks log. Never
# on the console, which may not take it.
console_skipped() {
    local line="[$1] not asked, nobody can answer ($INITHOOKS_UNATTENDED): $2"
    echo "$line" >&2
    if [[ -n "${INITHOOKS_LOGFILE:-}" ]]; then
        { echo "INFO: $line" >> "$INITHOOKS_LOGFILE"; } 2>/dev/null || true
    fi
}
