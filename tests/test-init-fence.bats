#!/usr/bin/env bats
# Tests for lib/init-fence.sh and bin/turnkey-init-fence.
#
# iptables, ip6tables and pgrep are stubs on PATH; the mini server is a stub
# under a scratch INITHOOKS_PATH; /etc/default/turnkey-init-fence, the
# htdocs, the pid file and the log file are scratch paths.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..
FENCE=$REPO/bin/turnkey-init-fence

# stub_tables NAME NAT_STATUS DELETE_OK [INSERT_STATUS]
# Stubs iptables or ip6tables: 'nat -n -L' exits NAT_STATUS (0 means the
# table is available), the first DELETE_OK rule deletions succeed and the
# next ones fail (the rule is gone), a rule insertion exits INSERT_STATUS
# (default 0, a filter table that cannot be used exits non-zero),
# everything else succeeds.
stub_tables() {
    stub "$1" "if [[ \"\$*\" == *'-t nat -n -L PREROUTING'* ]]; then
    exit $2
fi
if [[ \" \$* \" == *' -D '* ]]; then
    n=\$(cat '$STUBS/$1.deleted' 2>/dev/null || echo 0)
    if (( n < $3 )); then
        echo \$((n + 1)) > '$STUBS/$1.deleted'
        exit 0
    fi
    exit 1
fi
if [[ \" \$* \" == *' -I '* ]]; then
    exit ${4:-0}
fi
exit 0"
}

# count NAME PATTERN
# Number of recorded calls of stub NAME containing PATTERN.
count() {
    calls "$1" | grep -c -- "$2" || true
}

setup() {
    setup_stubs
    stub_tables iptables 0 0
    stub_tables ip6tables 0 0
    stub pgrep 'exit 1'

    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH/bin" "$INITHOOKS_PATH/turnkey-init-fence/htdocs"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
    echo packaged > "$INITHOOKS_PATH/turnkey-init-fence/htdocs/index.html"
    stub simplehttpd.py
    ln -s "$STUBS/simplehttpd.py" "$INITHOOKS_PATH/bin/simplehttpd.py"

    export PIDFILE=$BATS_TEST_TMPDIR/init-fence.pid
    export LOGFILE=$BATS_TEST_TMPDIR/init-fence.log
    export INITFENCE_DEFAULT=$BATS_TEST_TMPDIR/default-turnkey-init-fence
    WRITABLE_HTDOCS=$BATS_TEST_TMPDIR/var/turnkey-init-fence/htdocs
    mkdir -p "$WRITABLE_HTDOCS/sub"
    echo tagged > "$WRITABLE_HTDOCS/index.html"
    cat > "$INITFENCE_DEFAULT" <<EOT
HTDOCS=$WRITABLE_HTDOCS
HTTP_PORTS=(80)
HTTPS_PORTS=(443 12321 12322)
RUNAS=$(id -un)
HTTP_FENCE_PORT=60080
HTTPS_FENCE_PORT=60443
HTTPS_FENCE_CERTFILE=$BATS_TEST_TMPDIR/cert.pem
HTTPS_FENCE_KEYFILE=$BATS_TEST_TMPDIR/cert.key
EOT
    # the library tests use the same values as the script would
    source "$INITFENCE_DEFAULT"
    source "$REPO/lib/init-fence.sh"
}

teardown() {
    # start_mini_server leaves the htdocs read-only (0555 directories, 0444
    # files); give write permission back so bats can remove the scratch tree
    # when the tests run as a regular user
    chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# ---------------------------------------------------------------- library

@test "htdocs is the writable copy when it exists" {
    [ "$(fence_htdocs "$WRITABLE_HTDOCS" /packaged)" = "$WRITABLE_HTDOCS" ]
}

@test "htdocs falls back to the packaged copy" {
    [ "$(fence_htdocs "$BATS_TEST_TMPDIR/missing" /packaged)" = /packaged ]
}

@test "nat_available asks the family for its nat PREROUTING chain" {
    fence_nat_available iptables
    stub_tables ip6tables 3 0
    run ! fence_nat_available ip6tables
    [ "$(calls ip6tables)" = '-t nat -n -L PREROUTING' ]
}

@test "delete_redirect removes the rule until it is gone, per family" {
    stub_tables iptables 0 2
    stub_tables ip6tables 0 1
    run iptables_delete_redirect 80 60080
    [ "$status" -eq 0 ]
    [ "$output" = 'Removing REDIRECT firewall rule: 80 => 60080' ]
    [ "$(count iptables '-t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 60080')" -eq 3 ]
    [ "$(count ip6tables '-t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 60080')" -eq 2 ]
}

@test "add_redirect adds the rule for both families" {
    run iptables_add_redirect 443 60443
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'Adding REDIRECT firewall rule: 443 => 60443' ]
    [ "${lines[1]}" = 'Removing REDIRECT firewall rule: 443 => 60443' ]
    [ "${#lines[@]}" -eq 2 ]
    [ "$(count iptables '-t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 60443')" -eq 1 ]
    [ "$(count ip6tables '-t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 60443')" -eq 1 ]
}

@test "add_redirect refuses the port of a family whose nat table is unavailable" {
    stub_tables ip6tables 3 0
    run iptables_add_redirect 443 60443
    [ "$status" -eq 0 ]
    [ "${lines[2]}" = '<4>ip6tables nat table unavailable, refusing 443 rather than redirecting it to 60443' ]
    [ "${lines[3]}" = 'Refusing port 443 on ip6tables for as long as the fence is up' ]
    [ "$(count iptables ' -A PREROUTING ')" -eq 1 ]
    [ "$(count ip6tables ' -A PREROUTING ')" -eq 0 ]
    [ "$(count ip6tables '-t filter -I INPUT 1 ! -i lo -p tcp -m tcp --dport 443 -j REJECT --reject-with tcp-reset')" -eq 1 ]
    [ "$(count iptables ' -I ')" -eq 0 ]
}

@test "add_redirect refuses the port on both families when neither has nat" {
    stub_tables iptables 3 0
    stub_tables ip6tables 3 0
    run iptables_add_redirect 80 60080
    [ "$status" -eq 0 ]
    [ "$(count iptables ' -A PREROUTING ')" -eq 0 ]
    [ "$(count ip6tables ' -A PREROUTING ')" -eq 0 ]
    [ "$(count iptables '-t filter -I INPUT 1 ! -i lo -p tcp -m tcp --dport 80 -j REJECT --reject-with tcp-reset')" -eq 1 ]
    [ "$(count ip6tables '-t filter -I INPUT 1 ! -i lo -p tcp -m tcp --dport 80 -j REJECT --reject-with tcp-reset')" -eq 1 ]
    [ "$(printf '%s\n' "${lines[@]}" | grep -c '^<4>ip6\?tables nat table unavailable')" -eq 2 ]
}

@test "add_redirect fails when a port can be neither redirected nor refused" {
    stub_tables ip6tables 3 0 4
    run iptables_add_redirect 12321 60443
    [ "$status" -eq 1 ]
    [ "${lines[-1]}" = '<3>ip6tables cannot refuse 12321 either, nothing is fencing it' ]
    # the journal never claims a refusal that was not installed
    [ "$(printf '%s\n' "${lines[@]}" | grep -c '^Refusing port')" -eq 0 ]
}

@test "close_port inserts the refusal first, before the appliance's own rules" {
    run fence_close_port ip6tables 443
    [ "$status" -eq 0 ]
    [ "$output" = 'Refusing port 443 on ip6tables for as long as the fence is up' ]
    [ "$(calls ip6tables | tail -1)" = '-t filter -I INPUT 1 ! -i lo -p tcp -m tcp --dport 443 -j REJECT --reject-with tcp-reset' ]
}

@test "open_port removes the refusal until it is gone" {
    stub_tables ip6tables 0 2
    run fence_open_port ip6tables 443
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(count ip6tables '-t filter -D INPUT ! -i lo -p tcp -m tcp --dport 443 -j REJECT --reject-with tcp-reset')" -eq 3 ]
}

@test "unensure_accept removes the ACCEPT rules until they are gone" {
    stub_tables iptables 0 1
    stub_tables ip6tables 0 2
    run iptables_unensure_accept 60080
    [ "$status" -eq 0 ]
    [ "$output" = 'Removing ACCEPT firewall rule for fence port: 60080' ]
    [ "$(count iptables '-t filter -D INPUT -p tcp -m tcp --dport 60080 -j ACCEPT')" -eq 2 ]
    [ "$(count ip6tables '-t filter -D INPUT -p tcp -m tcp --dport 60080 -j ACCEPT')" -eq 3 ]
}

@test "ensure_accept adds one ACCEPT rule per family" {
    run iptables_ensure_accept 60443
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'Adding ACCEPT firewall rule for fence port: 60443' ]
    [ "$(count iptables '-t filter -A INPUT -p tcp -m tcp --dport 60443 -j ACCEPT')" -eq 1 ]
    [ "$(count ip6tables '-t filter -A INPUT -p tcp -m tcp --dport 60443 -j ACCEPT')" -eq 1 ]
}

@test "redirect start covers every configured port and the fence ports" {
    run iptables_redirect start
    [ "$status" -eq 0 ]
    [ "$(count iptables ' -A PREROUTING ')" -eq 4 ]
    [ "$(count ip6tables ' -A PREROUTING ')" -eq 4 ]
    [ "$(count iptables -- '--dport 80 -j REDIRECT --to-port 60080')" -ge 1 ]
    [ "$(count iptables -- '--dport 12322 -j REDIRECT --to-port 60443')" -ge 1 ]
    [ "$(count iptables ' -A INPUT ')" -eq 2 ]
    [ "$(count ip6tables ' -A INPUT ')" -eq 2 ]
}

@test "redirect stop only deletes, the redirects and the refusals alike" {
    run iptables_redirect stop
    [ "$status" -eq 0 ]
    [ "$(count iptables ' -A ')" -eq 0 ]
    [ "$(count ip6tables ' -A ')" -eq 0 ]
    [ "$(count iptables ' -I ')" -eq 0 ]
    [ "$(count ip6tables ' -I ')" -eq 0 ]
    [ "$(count iptables ' -D PREROUTING ')" -eq 4 ]
    [ "$(count iptables '-t filter -D INPUT ! -i lo -p tcp -m tcp --dport 443 -j REJECT --reject-with tcp-reset')" -eq 1 ]
    [ "$(count ip6tables '-j REJECT')" -eq 4 ]
    [ "$(count iptables '-j ACCEPT')" -eq 2 ]
}

@test "start_mini_server prepares the files and runs the server" {
    run start_mini_server
    [ "$status" -eq 0 ]
    [ "$output" = "Starting init-fence mini-server (serving $HTDOCS)" ]
    [ -f "$PIDFILE" ]
    [ -f "$LOGFILE" ]
    [ "$(stat -c %a "$HTDOCS/sub")" = 555 ]
    [ "$(stat -c %a "$HTDOCS/index.html")" = 444 ]
    [ "$(calls simplehttpd.py)" = "--daemonize=$PIDFILE --runas=$(id -un) --logfile=$LOGFILE $HTDOCS 60080 60443 $BATS_TEST_TMPDIR/cert.pem $BATS_TEST_TMPDIR/cert.key" ]
}

@test "start_mini_server exits 1 when the server does not start" {
    stub simplehttpd.py 'exit 7'
    run start_mini_server
    [ "$status" -eq 1 ]
    [ "${lines[1]}" = '<3>init-fence mini server failed to start' ]
}

@test "stop_mini_server kills the pid in the pid file and removes it" {
    sleep 300 &
    local pid=$!
    echo "$pid" > "$PIDFILE"
    run stop_mini_server
    [ "$status" -eq 0 ]
    [ "$output" = 'Stopping init-fence mini-server' ]
    [ ! -e "$PIDFILE" ]
    sleep 0.2
    run ! kill -0 "$pid" 2>/dev/null
    [ -z "$(calls pgrep)" ]
}

@test "stop_mini_server without a pid file kills the process pgrep finds" {
    sleep 300 &
    local pid=$!
    stub pgrep "echo $pid"
    run stop_mini_server
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "<4>pid file '$PIDFILE' not found" ]
    [ "${lines[3]}" = "Found simplehttpd.py (pid: $pid) - killing" ]
    [ "$(calls pgrep)" = '--oldest --full /usr/lib/inithooks/bin/simplehttpd.py.*lib/inithooks/turnkey-init-fence/htdocs' ]
    sleep 0.2
    run ! kill -0 "$pid" 2>/dev/null
}

@test "stop_mini_server reports when no server is found" {
    run stop_mini_server
    [ "$status" -eq 0 ]
    [ "${lines[3]}" = '<3>No simplehttpd.py process found' ]
}

# ----------------------------------------------------------------- script

@test "start with both nat tables redirects both families and serves" {
    run "$FENCE" start
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'Starting turnkey-init-fence' ]
    [ "${lines[-1]}" = 'Started turnkey-init-fence' ]
    [ "$(count iptables ' -A PREROUTING ')" -eq 4 ]
    [ "$(count ip6tables ' -A PREROUTING ')" -eq 4 ]
    [ "$(count iptables ' -A INPUT ')" -eq 2 ]
    [ "$(count ip6tables ' -A INPUT ')" -eq 2 ]
    [ "$(count iptables ' -I ')" -eq 0 ]
    [ "$(count ip6tables ' -I ')" -eq 0 ]
    [ "$(printf '%s\n' "${lines[@]}" | grep -c '^<[0-9]>')" -eq 0 ]
    [[ "$(calls simplehttpd.py)" == *"$WRITABLE_HTDOCS 60080 60443 "* ]]
}

@test "start without the IPv6 nat table refuses what it cannot redirect" {
    stub_tables ip6tables 3 0
    run "$FENCE" start
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = 'Started turnkey-init-fence' ]
    [ "$(count iptables ' -A PREROUTING ')" -eq 4 ]
    [ "$(count ip6tables ' -A PREROUTING ')" -eq 0 ]
    [ "$(count ip6tables ' -I INPUT 1 ')" -eq 4 ]
    [ "$(count ip6tables ' -A INPUT ')" -eq 2 ]
    [ "$(printf '%s\n' "${lines[@]}" | grep -c '^<4>ip6tables nat table unavailable')" -eq 4 ]
    [ -n "$(calls simplehttpd.py)" ]
}

@test "start with neither nat table refuses every port it was given" {
    stub_tables iptables 3 0
    stub_tables ip6tables 3 0
    run "$FENCE" start
    [ "$status" -eq 0 ]
    [ "$(count iptables ' -A PREROUTING ')" -eq 0 ]
    [ "$(count ip6tables ' -A PREROUTING ')" -eq 0 ]
    [ "$(count iptables ' -I INPUT 1 ')" -eq 4 ]
    [ "$(count ip6tables ' -I INPUT 1 ')" -eq 4 ]
    [ "$(printf '%s\n' "${lines[@]}" | grep -c '^<4>')" -eq 8 ]
    [ "$(count iptables ' -A INPUT ')" -eq 2 ]
    [ -n "$(calls simplehttpd.py)" ]
}

@test "start fails and serves nothing when a port cannot even be refused" {
    stub_tables ip6tables 3 0 4
    run "$FENCE" start
    [ "$status" -ne 0 ]
    [ "${lines[-1]}" = '<3>ip6tables cannot refuse 80 either, nothing is fencing it' ]
    [ -z "$(calls simplehttpd.py)" ]
}

@test "start serves the packaged htdocs when the writable copy is missing" {
    rm -r "$WRITABLE_HTDOCS"
    run "$FENCE" start
    [ "$status" -eq 0 ]
    [[ "$(calls simplehttpd.py)" == *"$INITHOOKS_PATH/turnkey-init-fence/htdocs 60080 60443 "* ]]
}

@test "start fails when the mini server does not start" {
    stub simplehttpd.py 'exit 7'
    run "$FENCE" start
    [ "$status" -eq 1 ]
    [ "${lines[-1]}" = '<3>init-fence mini server failed to start' ]
}

@test "stop removes the rules and stops the server" {
    sleep 300 &
    local pid=$!
    echo "$pid" > "$PIDFILE"
    run "$FENCE" stop
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'Stopping turnkey-init-fence' ]
    [ "${lines[-1]}" = 'Stopped turnkey-init-fence' ]
    [ "$(count iptables ' -A ')" -eq 0 ]
    [ "$(count iptables ' -D PREROUTING ')" -eq 4 ]
    [ "$(count ip6tables ' -D PREROUTING ')" -eq 4 ]
    [ "$(count iptables '-j REJECT')" -eq 4 ]
    [ "$(count ip6tables '-j REJECT')" -eq 4 ]
    [ "$(count iptables '-t filter -D INPUT -p tcp -m tcp --dport 60080 -j ACCEPT')" -eq 1 ]
    [ ! -e "$PIDFILE" ]
    sleep 0.2
    run ! kill -0 "$pid" 2>/dev/null
}

@test "stop-post removes the rules after a failed run" {
    SERVICE_RESULT=exit-code run "$FENCE" stop-post
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'Post-stop cleanup for failed turnkey-init-fence' ]
    [ "${lines[-1]}" = 'Firewall rules removed' ]
    [ "$(count iptables ' -D PREROUTING ')" -eq 4 ]
}

@test "stop-post does nothing after a successful run" {
    SERVICE_RESULT=success run "$FENCE" stop-post
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$(calls iptables)" ]
}

@test "reload restarts the mini server without touching the rules" {
    sleep 300 &
    echo "$!" > "$PIDFILE"
    run "$FENCE" reload
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'Reloading turnkey-init-fence' ]
    [ "${lines[-1]}" = 'Reloaded turnkey-init-fence' ]
    [ -z "$(calls iptables)" ]
    [ -n "$(calls simplehttpd.py)" ]
}

@test "an unknown command exits 1" {
    run "$FENCE" bogus
    [ "$status" -eq 1 ]
    [ "$output" = 'Unknown command: bogus' ]
    [ -z "$(calls iptables)" ]
}

@test "DEBUG turns tracing on and keeps the behaviour" {
    # the trace itself is not asserted: kcov redirects it to its own fd
    DEBUG=1 run "$FENCE" bogus
    [ "$status" -eq 1 ]
    printf '%s\n' "${lines[@]}" | grep -qx 'Unknown command: bogus'
}

# A restore of a saved firewall flushes the tables it names, and with them
# every rule the fence installed (tests/test-init-fence-netfilter.bats has
# it happen). At boot the only defence is order: start after whatever does
# the restoring. Webmin's Firewall module restores /etc/iptables/rules.v4
# and rules.v6 through webmin-iptables.service and webmin-ip6tables.service
# when "activate at boot" is set; iptables-persistent restores the same
# files through netfilter-persistent.service.
@test "the unit starts after everything that restores a saved firewall at boot" {
    local unit=$REPO/debian/inithooks.turnkey-init-fence.service
    local after
    after=" $(sed -n 's/^After=//p' "$unit" | tr '\n' ' ') "
    local restorer
    for restorer in iptables.service ip6tables.service nftables.service \
            firewalld.service ipset.service netfilter-persistent.service \
            webmin-iptables.service webmin-ip6tables.service; do
        [[ "$after" == *" $restorer "* ]] || {
            echo "not ordered after $restorer" >&2
            return 1
        }
    done
}
