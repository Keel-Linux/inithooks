# The first boot lock, taken by run (the boot run of inithooks.service).
#
# keel-init takes the same lock (libinithooks/init_lock.py, which explains
# why there is one): an exclusive flock(2) on INITHOOKS_LOCK, by default
# /run/inithooks.lock, held for as long as hooks run. Sourced by run and by
# tests/test-init-lock.bats.
#
# The boot run waits for the lock where keel-init refuses: a run started by
# systemd cannot be told to come back later, and a keel-init that finished
# the first boot has also set RUN_FIRSTBOOT=false, which run reads after it
# has the lock.
#
# The descriptor is inherited by whatever run starts, so run closes it for
# each hook (INIT_LOCK_FD, "{INIT_LOCK_FD}>&-"): a hook that leaves a daemon
# behind must not leave the lock held with it. confconsole, which run starts
# last and which stays up, is started after init_lock_release.

INITHOOKS_LOCK=${INITHOOKS_LOCK:-/run/inithooks.lock}

# init_lock_describe PATH PHASE HOOK
# Writes what this run is doing into PATH, which it holds, for keel-init to
# word its refusal by (libinithooks/init_lock.py reads the same keys): the
# kind of holder, its pid, the terminal it answers on, the phase
# (firstboot or everyboot, empty before the first hook), the hook it is in,
# and whether the preseed says nobody will be asked anything (AUTO_RUN, set
# by the preseed of headless builds). Rewritten before every hook.
init_lock_describe() {
    printf 'kind=run\npid=%s\ntty=%s\nphase=%s\nhook=%s\npreseeded=%s\n' \
        "$$" "$(readlink "/proc/$$/fd/0" 2>/dev/null)" "$2" "$3" \
        "${AUTO_RUN:+yes}" > "$1"
}

# init_lock_take PATH
# Opens PATH on a new descriptor, INIT_LOCK_FD, and waits for the exclusive
# lock on it; then describes this run in PATH (init_lock_describe). Says so
# on stderr before waiting, naming the holder's pid, and fails when PATH
# cannot be opened or locked, leaving INIT_LOCK_FD unset.
init_lock_take() {
    local path=$1
    local holder
    INIT_LOCK_FD=
    if ! exec {INIT_LOCK_FD}<>"$path"; then
        INIT_LOCK_FD=
        echo "inithooks: cannot open the first boot lock $path" >&2
        return 1
    fi
    if ! flock -n "$INIT_LOCK_FD"; then
        holder=$(sed -n 's/^pid=//p' "$path" 2>/dev/null)
        echo "inithooks: another first boot run holds $path" \
            "(pid ${holder:-unknown}), waiting for it to finish" >&2
        if ! flock "$INIT_LOCK_FD"; then
            exec {INIT_LOCK_FD}>&-
            INIT_LOCK_FD=
            echo "inithooks: cannot lock $path" >&2
            return 1
        fi
    fi
    init_lock_describe "$path" "" ""
}

# init_lock_release
# Drops the lock and closes its descriptor; nothing to do when not held.
# The unlock comes first because it releases the lock for every process
# sharing the descriptor, where a close only drops this one's reference.
init_lock_release() {
    [[ -n "${INIT_LOCK_FD:-}" ]] || return 0
    flock -u "$INIT_LOCK_FD"
    exec {INIT_LOCK_FD}>&-
    INIT_LOCK_FD=
}
