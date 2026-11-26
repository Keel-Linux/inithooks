# Firewall and mini server functions of bin/turnkey-init-fence.
#
# Sourced by the fence, by tests/test-init-fence.bats and by
# tests/netns-sandbox. The functions read
# the variables of /etc/default/turnkey-init-fence (HTDOCS, HTTP_PORTS,
# HTTPS_PORTS, RUNAS, HTTP_FENCE_PORT, HTTPS_FENCE_PORT, HTTPS_FENCE_CERTFILE,
# HTTPS_FENCE_KEYFILE) plus PIDFILE, LOGFILE and INITHOOKS_PATH, all set by
# the caller.

# fence_htdocs HTDOCS PACKAGED
# Prints the directory to serve: HTDOCS when it exists, otherwise the
# PACKAGED copy (firstboot.d/29tagid creates HTDOCS, but the fence must not
# fail if it doesn't exist yet).
fence_htdocs() {
    if [[ ! -d "$1" ]]; then
        echo "$2"
    else
        echo "$1"
    fi
}

# The fence writes nftables, the firewall keel writes (decision 0097), in a
# table of its own: keel loads, deletes and loads again its table inet keel,
# and the fence never touches it, as keel never touches this one.
#
# - The table first holds an input chain that drops the fenced ports from
#   outside. Then a second load adds the nat chain that redirects them to
#   the fence page. A redirected packet arrives at the input hook with the
#   fence port as its destination, so the drop does not apply to it, and
#   keel's table accepts it (ct status dnat, decision 0097, section 2,
#   item 4). If the second load fails (the kernel of an LXC host with no
#   nftables nat), the drop stays: the fence fails closed. A drop in any
#   table is final, with or without keel's table.
# - Loopback is not fenced: a redirect in prerouting never applied to
#   traffic from the appliance itself.
# - The fence fails, and fences nothing, only when nft cannot load the
#   table at all. It says so in the journal and on the console.
# - Stop removes this table, and nothing else.
#
# A "flush ruleset" (each start, reload, restart and stop of
# nftables.service with Debian's /etc/nftables.conf) removes this table
# with all the others. The drop-in systemd/nftables.service.d/
# turnkey-init-fence.conf loads it again while the fence is active.
FENCE_TABLE=${FENCE_TABLE:-keel_fence}
FENCE_CONSOLE=${FENCE_CONSOLE:-/dev/console}
FENCE_CONSOLE_TIMEOUT=${FENCE_CONSOLE_TIMEOUT:-2}

# fence_ports
# The fenced ports, HTTP_PORTS then HTTPS_PORTS, separated by a space.
fence_ports() {
    echo "${HTTP_PORTS[*]} ${HTTPS_PORTS[*]}"
}

# fence_table_drop
# The nft script that loads the table again with its input chain only: an
# earlier table of the fence goes, and the fenced ports from outside are
# dropped. "table" before "delete table" makes the delete succeed when
# there is no table, as keel's ruleset does.
fence_table_drop() {
    local ports
    ports=$(fence_ports)
    cat <<EOF
table inet $FENCE_TABLE
delete table inet $FENCE_TABLE
table inet $FENCE_TABLE {
	chain input {
		type filter hook input priority filter - 5; policy accept;
		iifname != "lo" tcp dport { ${ports// /, } } drop
	}
}
EOF
}

# fence_table_redirect
# The nft script that adds the redirect of each fenced port to its fence
# port, HTTP_PORTS to HTTP_FENCE_PORT and HTTPS_PORTS to HTTPS_FENCE_PORT,
# over IPv4 and IPv6 (an inet table).
fence_table_redirect() {
    local port
    echo "table inet $FENCE_TABLE {"
    printf '\tchain prerouting {\n'
    printf '\t\ttype nat hook prerouting priority dstnat; policy accept;\n'
    for port in "${HTTP_PORTS[@]}"; do
        printf '\t\tiifname != "lo" tcp dport %s redirect to :%s\n' \
            "$port" "$HTTP_FENCE_PORT"
    done
    for port in "${HTTPS_PORTS[@]}"; do
        printf '\t\tiifname != "lo" tcp dport %s redirect to :%s\n' \
            "$port" "$HTTPS_FENCE_PORT"
    done
    printf '\t}\n}\n'
}

# fence_table_delete
# The nft script that removes the table, also when there is none.
fence_table_delete() {
    printf 'table inet %s\ndelete table inet %s\n' "$FENCE_TABLE" "$FENCE_TABLE"
}

# fence_alert LEVEL MESSAGE
# MESSAGE to the journal at syslog LEVEL (3 err, 4 warning), and one line
# on the console. A write to a console that nobody reads can block (a pty
# whose master is not read, lib/console.sh), so the console write has a
# time limit, and it never makes the fence fail.
fence_alert() {
    echo "<$1>$2" >&2
    timeout "$FENCE_CONSOLE_TIMEOUT" bash -c 'printf "%s\n" "$1" > "$2"' \
        _ "turnkey-init-fence: $2" "$FENCE_CONSOLE" 2>/dev/null || true
}

# fence_rules_start
# Loads the table: the drop, then the redirect. Fails only when nothing
# fences the ports.
fence_rules_start() {
    local ports
    ports=$(fence_ports)
    if ! fence_table_drop | nft -f -; then
        fence_alert 3 "cannot load the nftables table inet $FENCE_TABLE: TCP ports $ports are not fenced, the application answers on them before keel-init"
        return 1
    fi
    if ! fence_table_redirect | nft -f -; then
        fence_alert 4 "cannot redirect TCP ports $ports to the fence page (no nftables nat): the fence drops them from outside until keel-init"
        return 0
    fi
    echo "Redirecting TCP ports $ports to the fence page (nftables table inet $FENCE_TABLE)"
}

# fence_rules_stop
# Removes the table. Stopping has to succeed, so this never fails: with no
# nft, there is no table of the fence either.
fence_rules_stop() {
    echo "Removing the nftables table inet $FENCE_TABLE"
    fence_table_delete | nft -f - 2>/dev/null || true
}

# fence_rules start|stop
fence_rules() {
    case "$1" in
        start) fence_rules_start ;;
        stop) fence_rules_stop ;;
    esac
}

start_mini_server() {
    echo "Starting init-fence mini-server (serving $HTDOCS)"
    touch "$LOGFILE" "$PIDFILE"
    chown -R "$RUNAS" "$HTDOCS" "$LOGFILE" "$PIDFILE"
    find "$HTDOCS" -type d -exec chmod 0555 {} \;
    find "$HTDOCS" -type f -exec chmod 0444 {} \;
    "$INITHOOKS_PATH/bin/simplehttpd.py" \
        --daemonize="$PIDFILE" \
        --runas="$RUNAS" \
        --logfile="$LOGFILE" \
        "$HTDOCS" \
        "$HTTP_FENCE_PORT" \
        "$HTTPS_FENCE_PORT" \
        "$HTTPS_FENCE_CERTFILE" \
        "$HTTPS_FENCE_KEYFILE" \
        || {
            echo "<3>init-fence mini server failed to start" >&2
            return 1
        }
}

stop_mini_server() {
    echo "Stopping init-fence mini-server"
    # start_mini_server writes an empty pid file before the server runs,
    # and a server that did not start leaves it empty
    if [[ -s "$PIDFILE" ]]; then
        kill "$( < "$PIDFILE" )" || echo "<4>no process with the pid in '$PIDFILE'" >&2
        rm -f "$PIDFILE"
    else
        rm -f "$PIDFILE"
        echo "<4>pid file '$PIDFILE' not found or empty" >&2
        echo "Searching for simplehttpd.py process"
        # search for process using init-fence webroot too to avoid risk of
        # killing unrelated simplehttpd.py instance
        PROC="/usr/lib/inithooks/bin/simplehttpd.py.*lib/inithooks/turnkey-init-fence/htdocs"
        if PID=$(pgrep --oldest --full "$PROC"); then
            echo "Found simplehttpd.py (pid: $PID) - killing"
            kill "$PID"
        else
            echo "<3>No simplehttpd.py process found" >&2
        fi
    fi
}
