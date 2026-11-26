#!/usr/bin/env bats
# Tests for lib/init-fence.sh and bin/turnkey-init-fence.
#
# nft and pgrep are stubs on PATH; the mini server is a stub under a
# scratch INITHOOKS_PATH; /etc/default/turnkey-init-fence, the htdocs, the
# pid file, the log file and the console are scratch paths.
# tests/test-init-fence-netfilter.bats loads the same scripts into the real
# nftables.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..
FENCE=$REPO/bin/turnkey-init-fence

# stub_nft [FAIL]
# Stubs nft: each script it gets on its standard input is appended to
# nft.scripts, after a line "--". FAIL is what the kernel cannot do: "nat"
# fails a script with a nat chain (an LXC host with no nftables nat),
# "all" fails every script (nft cannot load a table).
stub_nft() {
    stub nft "script=\$(cat)
printf -- '--\n%s\n' \"\$script\" >> '$STUBS/nft.scripts'
case '${1:-}' in
    all) echo 'Error: Could not process rule: Operation not supported' >&2
         exit 1 ;;
    nat) if [[ \"\$script\" == *'type nat'* ]]; then
             echo 'Error: Could not process rule: No such file or directory' >&2
             exit 1
         fi ;;
esac
exit 0"
}

# scripts
# The scripts nft got, in order.
scripts() {
    cat "$STUBS/nft.scripts" 2>/dev/null || true
}

setup() {
    setup_stubs
    stub_nft
    stub pgrep 'exit 1'
    export FENCE_CONSOLE=$BATS_TEST_TMPDIR/console

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

@test "the drop script loads the table again with a drop of the fenced ports from outside" {
    run fence_table_drop
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' \
        'table inet keel_fence' \
        'delete table inet keel_fence' \
        'table inet keel_fence {' \
        '	chain input {' \
        '		type filter hook input priority filter - 5; policy accept;' \
        '		iifname != "lo" tcp dport { 80, 443, 12321, 12322 } drop' \
        '	}' \
        '}')" ]
}

@test "the redirect script sends each fenced port to its fence port" {
    run fence_table_redirect
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' \
        'table inet keel_fence {' \
        '	chain prerouting {' \
        '		type nat hook prerouting priority dstnat; policy accept;' \
        '		iifname != "lo" tcp dport 80 redirect to :60080' \
        '		iifname != "lo" tcp dport 443 redirect to :60443' \
        '		iifname != "lo" tcp dport 12321 redirect to :60443' \
        '		iifname != "lo" tcp dport 12322 redirect to :60443' \
        '	}' \
        '}')" ]
}

@test "the delete script removes the fence's table only, also when there is none" {
    run fence_table_delete
    [ "$output" = "$(printf '%s\n' 'table inet keel_fence' 'delete table inet keel_fence')" ]
}

@test "the scripts follow the ports of the defaults file" {
    HTTP_PORTS=(8080)
    HTTPS_PORTS=(8443)
    HTTP_FENCE_PORT=61080
    HTTPS_FENCE_PORT=61443
    [[ "$(fence_table_drop)" == *'tcp dport { 8080, 8443 } drop'* ]]
    [[ "$(fence_table_redirect)" == *'tcp dport 8080 redirect to :61080'* ]]
    [[ "$(fence_table_redirect)" == *'tcp dport 8443 redirect to :61443'* ]]
}

@test "check_ports leaves valid ports alone and says nothing" {
    run fence_check_ports
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    fence_check_ports
    [ "$(fence_ports)" = '80 443 12321 12322' ]
    [ "$HTTP_FENCE_PORT $HTTPS_FENCE_PORT" = '60080 60443' ]
}

@test "check_ports puts the default ports in place of empty port lists" {
    HTTP_PORTS=()
    HTTPS_PORTS=()
    run fence_check_ports
    [ "${lines[0]}" = "<4>HTTP_PORTS in $INITFENCE_DEFAULT is not a list of port numbers: fencing 80" ]
    [ "${lines[1]}" = "<4>HTTPS_PORTS in $INITFENCE_DEFAULT is not a list of port numbers: fencing 443 12321 12322" ]
    fence_check_ports 2>/dev/null
    [ "$(fence_ports)" = '80 443 12321 12322' ]
    [[ "$(fence_table_drop)" == *'tcp dport { 80, 443, 12321, 12322 } drop'* ]]
}

@test "check_ports puts the defaults in place of a list with a value that is not a port" {
    local bad
    for bad in 80x 0 65536 -1 '' '80;drop'; do
        HTTP_PORTS=(8080 "$bad")
        HTTPS_PORTS=(8443)
        fence_check_ports 2>/dev/null
        [ "$(fence_ports)" = '80 8443' ] || {
            echo "not refused: '$bad'" >&2
            return 1
        }
    done
}

@test "check_ports writes the ports in decimal, with no leading zero" {
    HTTP_PORTS=(080)
    HTTPS_PORTS=(0443 8443)
    HTTP_FENCE_PORT=060080
    fence_check_ports
    [ "$(fence_ports)" = '80 443 8443' ]
    [ "$HTTP_FENCE_PORT" = 60080 ]
}

@test "check_ports puts the default fence ports in place of values that are not ports" {
    HTTP_FENCE_PORT=
    HTTPS_FENCE_PORT=99999
    run fence_check_ports
    [ "${lines[0]}" = "<4>HTTP_FENCE_PORT in $INITFENCE_DEFAULT is not a port number: using 60080" ]
    [ "${lines[1]}" = "<4>HTTPS_FENCE_PORT in $INITFENCE_DEFAULT is not a port number: using 60443" ]
    fence_check_ports 2>/dev/null
    [[ "$(fence_table_redirect)" == *'tcp dport 80 redirect to :60080'* ]]
    [[ "$(fence_table_redirect)" == *'tcp dport 443 redirect to :60443'* ]]
}

@test "rules start fences the default ports when the lists are empty" {
    HTTP_PORTS=()
    HTTPS_PORTS=()
    run fence_rules start
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = 'Redirecting TCP ports 80 443 12321 12322 to the fence page (nftables table inet keel_fence)' ]
    [[ "$(scripts)" == *'tcp dport { 80, 443, 12321, 12322 } drop'* ]]
}

@test "rules start loads the drop first, then the redirect" {
    run fence_rules start
    [ "$status" -eq 0 ]
    [ "$output" = 'Redirecting TCP ports 80 443 12321 12322 to the fence page (nftables table inet keel_fence)' ]
    [ "$(scripts)" = "$(printf -- '--\n%s\n--\n%s\n' "$(fence_table_drop)" "$(fence_table_redirect)")" ]
    [ ! -e "$FENCE_CONSOLE" ]
}

@test "rules start without nftables nat keeps the drop, and says so in the journal and on the console" {
    stub_nft nat
    run fence_rules start
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = '<4>cannot redirect TCP ports 80 443 12321 12322 to the fence page (no nftables nat): the fence drops them from outside until keel-init' ]
    [ "$(cat "$FENCE_CONSOLE")" = 'turnkey-init-fence: cannot redirect TCP ports 80 443 12321 12322 to the fence page (no nftables nat): the fence drops them from outside until keel-init' ]
    # the drop was loaded, and nothing removed it after the failed redirect
    [ "$(scripts | grep -c '^delete table')" -eq 1 ]
    [ "$(scripts | grep -c 'drop$')" -eq 1 ]
}

@test "rules start fails when nft can load no table, and says the ports are not fenced" {
    stub_nft all
    run fence_rules start
    [ "$status" -eq 1 ]
    [ "${lines[-1]}" = '<3>cannot load the nftables table inet keel_fence: TCP ports 80 443 12321 12322 are not fenced, the application answers on them before keel-init' ]
    [[ "$(cat "$FENCE_CONSOLE")" == 'turnkey-init-fence: cannot load the nftables table inet keel_fence: '* ]]
    # no redirect is tried after a failed drop
    [ "$(scripts | grep -c 'type nat')" -eq 0 ]
}

@test "rules start succeeds also when the console cannot be written" {
    stub_nft nat
    export FENCE_CONSOLE=$BATS_TEST_TMPDIR/missing/console
    run fence_rules start
    [ "$status" -eq 0 ]
    [[ "${lines[-1]}" == '<4>cannot redirect '* ]]
}

@test "the console write has a time limit" {
    stub timeout 'exit 124'
    run fence_alert 4 'a message'
    [ "$status" -eq 0 ]
    [ "$output" = '<4>a message' ]
    [ "$(calls timeout)" = "2 bash -c printf \"%s\\n\" \"\$1\" > \"\$2\" _ turnkey-init-fence: a message $FENCE_CONSOLE" ]
}

@test "rules stop removes the fence's table" {
    run fence_rules stop
    [ "$status" -eq 0 ]
    [ "$output" = 'Removing the nftables table inet keel_fence' ]
    [ "$(scripts)" = "$(printf -- '--\n%s\n' "$(fence_table_delete)")" ]
}

@test "rules stop succeeds when nft fails" {
    stub_nft all
    run fence_rules stop
    [ "$status" -eq 0 ]
    [ "$output" = 'Removing the nftables table inet keel_fence' ]
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
    [ "${lines[1]}" = "<4>pid file '$PIDFILE' not found or empty" ]
    [ "${lines[3]}" = "Found simplehttpd.py (pid: $pid) - killing" ]
    [ "$(calls pgrep)" = '--oldest --full /usr/lib/inithooks/bin/simplehttpd.py.*lib/inithooks/turnkey-init-fence/htdocs' ]
    sleep 0.2
    run ! kill -0 "$pid" 2>/dev/null
}

@test "stop_mini_server with an empty pid file removes it and searches for the server" {
    : > "$PIDFILE"
    run stop_mini_server
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "<4>pid file '$PIDFILE' not found or empty" ]
    [ ! -e "$PIDFILE" ]
    [ -n "$(calls pgrep)" ]
}

@test "stop_mini_server with a stale pid says so and removes the file" {
    sleep 0 &
    local pid=$!
    wait "$pid"
    echo "$pid" > "$PIDFILE"
    run stop_mini_server
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "<4>no process with the pid in '$PIDFILE'" ]
    [ ! -e "$PIDFILE" ]
}

@test "stop_mini_server reports when no server is found" {
    run stop_mini_server
    [ "$status" -eq 0 ]
    [ "${lines[3]}" = '<3>No simplehttpd.py process found' ]
}

# ----------------------------------------------------------------- script

@test "start redirects the fenced ports and serves" {
    run "$FENCE" start
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'Starting turnkey-init-fence' ]
    [ "${lines[1]}" = 'Redirecting TCP ports 80 443 12321 12322 to the fence page (nftables table inet keel_fence)' ]
    [ "${lines[-1]}" = 'Started turnkey-init-fence' ]
    [ "$(scripts | grep -c 'redirect to')" -eq 4 ]
    [ "$(printf '%s\n' "${lines[@]}" | grep -c '^<[0-9]>')" -eq 0 ]
    [[ "$(calls simplehttpd.py)" == *"$WRITABLE_HTDOCS 60080 60443 "* ]]
}

@test "start without nftables nat drops the fenced ports, serves, and stays up" {
    stub_nft nat
    run "$FENCE" start
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = 'Started turnkey-init-fence' ]
    [ "$(printf '%s\n' "${lines[@]}" | grep -c '^<4>cannot redirect TCP ports')" -eq 1 ]
    [ -s "$FENCE_CONSOLE" ]
    [ -n "$(calls simplehttpd.py)" ]
}

@test "start fails and serves nothing when nft can load no table" {
    stub_nft all
    run "$FENCE" start
    [ "$status" -ne 0 ]
    [[ "${lines[-1]}" == '<3>cannot load the nftables table inet keel_fence: '* ]]
    [ -z "$(calls simplehttpd.py)" ]
}

@test "start with empty port lists in the defaults file fences the default ports" {
    sed -i 's/^HTTP_PORTS=.*/HTTP_PORTS=()/; s/^HTTPS_PORTS=.*/HTTPS_PORTS=()/' "$INITFENCE_DEFAULT"
    run "$FENCE" start
    [ "$status" -eq 0 ]
    [ "$(scripts | grep -c 'redirect to')" -eq 4 ]
    [ "${lines[-1]}" = 'Started turnkey-init-fence' ]
}

@test "start serves the packaged htdocs when the writable copy is missing" {
    rm -r "$WRITABLE_HTDOCS"
    run "$FENCE" start
    [ "$status" -eq 0 ]
    [[ "$(calls simplehttpd.py)" == *"$INITHOOKS_PATH/turnkey-init-fence/htdocs 60080 60443 "* ]]
}

# A failed unit runs no ExecStop when 97turnkey-init-fence-disable stops
# it, and its ExecStopPost removes the table: a failure here would open
# the ports. The redirect to a port with no server refuses the connection.
@test "start stays up with the ports fenced when the mini server does not start" {
    stub simplehttpd.py 'exit 7'
    run "$FENCE" start
    [ "$status" -eq 0 ]
    printf '%s\n' "${lines[@]}" | grep -qx '<3>init-fence mini server failed to start'
    [ "${lines[-2]}" = '<3>the fence page does not answer; TCP ports 80 443 12321 12322 stay fenced' ]
    [ "${lines[-1]}" = 'Started turnkey-init-fence' ]
    [ "$(scripts | grep -c 'redirect to')" -eq 4 ]
    [ "$(scripts | grep -c '^delete table')" -eq 1 ]
}

@test "stop removes the fence's table and stops the server" {
    sleep 300 &
    local pid=$!
    echo "$pid" > "$PIDFILE"
    run "$FENCE" stop
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'Stopping turnkey-init-fence' ]
    [ "${lines[-1]}" = 'Stopped turnkey-init-fence' ]
    [ "$(scripts)" = "$(printf -- '--\n%s\n' "$(fence_table_delete)")" ]
    [ ! -e "$PIDFILE" ]
    sleep 0.2
    run ! kill -0 "$pid" 2>/dev/null
}

# The start tolerates a server that did not start; the stop after it must
# succeed too, or 97turnkey-init-fence-disable sees a failed stop.
@test "stop succeeds after a start whose mini server did not start" {
    stub simplehttpd.py 'exit 7'
    run "$FENCE" start
    [ "$status" -eq 0 ]
    run "$FENCE" stop
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = 'Stopped turnkey-init-fence' ]
    [ ! -e "$PIDFILE" ]
}

@test "reload-rules loads the table again while the fence is active" {
    stub systemctl 'exit 0'
    run "$FENCE" reload-rules
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "nftables.service flushed the ruleset: loading the fence's table again" ]
    [ "$(calls systemctl)" = '--quiet is-active turnkey-init-fence.service' ]
    [ "$(scripts)" = "$(printf -- '--\n%s\n--\n%s\n' "$(fence_table_drop)" "$(fence_table_redirect)")" ]
    [ -z "$(calls simplehttpd.py)" ]
}

@test "reload-rules does nothing while the fence is not active" {
    stub systemctl 'exit 3'
    run "$FENCE" reload-rules
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$(calls nft)" ]
}

@test "stop-post removes the fence's table after a failed run" {
    SERVICE_RESULT=exit-code run "$FENCE" stop-post
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'Post-stop cleanup for failed turnkey-init-fence' ]
    [ "${lines[-1]}" = 'Firewall rules removed' ]
    [ "$(scripts)" = "$(printf -- '--\n%s\n' "$(fence_table_delete)")" ]
}

@test "stop-post does nothing after a successful run" {
    SERVICE_RESULT=success run "$FENCE" stop-post
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$(calls nft)" ]
}

@test "reload restarts the mini server without touching the rules" {
    sleep 300 &
    echo "$!" > "$PIDFILE"
    run "$FENCE" reload
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'Reloading turnkey-init-fence' ]
    [ "${lines[-1]}" = 'Reloaded turnkey-init-fence' ]
    [ -z "$(calls nft)" ]
    [ -n "$(calls simplehttpd.py)" ]
}

@test "an unknown command exits 1" {
    run "$FENCE" bogus
    [ "$status" -eq 1 ]
    [ "$output" = 'Unknown command: bogus' ]
    [ -z "$(calls nft)" ]
}

@test "DEBUG turns tracing on and keeps the behaviour" {
    # the trace itself is not asserted: kcov redirects it to its own fd
    DEBUG=1 run "$FENCE" bogus
    [ "$status" -eq 1 ]
    printf '%s\n' "${lines[@]}" | grep -qx 'Unknown command: bogus'
}

# nftables.service loads Debian's /etc/nftables.conf, which starts with
# "flush ruleset" and removes the fence's table with every other one
# (tests/test-init-fence-netfilter.bats has it happen). At boot the only
# defence is order: start after whatever loads a saved firewall. The
# legacy restorers stay in the list: Webmin's Firewall module
# (webmin-iptables.service, webmin-ip6tables.service) and
# iptables-persistent (netfilter-persistent.service) can still be
# installed by hand.
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
