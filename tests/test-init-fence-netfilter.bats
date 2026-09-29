#!/usr/bin/env bats
# What the init fence does to traffic, asked of the real netfilter.
#
# tests/test-init-fence.bats drives lib/init-fence.sh against stubs and
# asserts the commands it issues. This file runs the same functions against
# real iptables and ip6tables in a network namespace of its own
# (tests/netns-sandbox) and connects to the ports from a client on the other
# end of a veth pair, over IPv6 and IPv4, and from the appliance itself over
# loopback. The answer is what a connection gets: the application, the
# fence page, a refusal, or silence.
#
# The rules the appliance firewall restores are tests/fixtures/webmin-fw.*,
# rendered from Keel-Linux/common conf/turnkey.d/webmin-fw (ae064ba) with its
# defaults. The appliance applies them with iptables-legacy and the sandbox
# with the nf_tables backend; what a restore does to a table it names, and
# what the rules do to a packet, is the same in both.

bats_require_minimum_version 1.5.0

SANDBOX=$BATS_TEST_DIRNAME/netns-sandbox

# fence [NO_NAT [NO_FILTER]] < BODY
# Runs BODY in the sandbox. A sandbox that cannot be made fails the test;
# it is never read as an answer.
fence() {
    local rc=0
    "$SANDBOX" "$@" || rc=$?
    if [[ $rc -eq 77 ]]; then
        echo "no network namespace here: nothing was asked" >&2
    fi
    return "$rc"
}

@test "with both nat tables, every fenced port gets the fence page, over both families" {
    run fence none <<'EOF'
iptables_redirect start >/dev/null
for port in 80 443 12321 12322; do
    echo "$port $(probe 6 "$port") $(probe 4 "$port")"
done
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' '80 fence fence' '443 fence fence' \
        '12321 fence fence' '12322 fence fence')" ]
}

@test "without the IPv6 nat table, IPv6 is refused on every fenced port and IPv4 still gets the fence" {
    run fence ip6tables <<'EOF'
iptables_redirect start >/dev/null 2>&1
for port in 80 443 12321 12322; do
    echo "$port $(probe 6 "$port") $(probe 4 "$port")"
done
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' '80 refused fence' '443 refused fence' \
        '12321 refused fence' '12322 refused fence')" ]
}

@test "without the IPv6 nat table, the fence page stays reachable on its own ports over IPv6" {
    run fence ip6tables <<'EOF'
iptables_redirect start >/dev/null 2>&1
echo "$(probe 6 60080) $(probe 6 60443)"
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "fence fence" ]
}

@test "a refusal comes before the appliance firewall restored ahead of the fence" {
    run fence ip6tables <<'EOF'
ip6tables-restore < "$FIXTURES/webmin-fw.rules.v6"
iptables-restore < "$FIXTURES/webmin-fw.rules.v4"
echo "restored $(probe 6 443) $(probe 4 443)"
iptables_redirect start >/dev/null 2>&1
echo "fenced $(probe 6 443) $(probe 6 12321) $(probe 4 443) $(probe 6 60443)"
EOF
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "restored app app" ]
    [ "${lines[1]}" = "fenced refused refused fence fence" ]
}

@test "loopback reaches the application behind a refused port, as it does behind a redirected one" {
    run fence ip6tables <<'EOF'
ip6tables-restore < "$FIXTURES/webmin-fw.rules.v6"
iptables-restore < "$FIXTURES/webmin-fw.rules.v4"
iptables_redirect start >/dev/null 2>&1
echo "$(probe_local 6 443) $(probe_local 4 443) $(probe_local 6 12321)"
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "app app app" ]
}

@test "stop gives every port back to the application, over both families" {
    run fence ip6tables <<'EOF'
iptables_redirect start >/dev/null 2>&1
iptables_redirect stop >/dev/null 2>&1
for port in 80 443 12321 12322; do
    echo "$port $(probe 6 "$port") $(probe 4 "$port")"
done
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' '80 app app' '443 app app' \
        '12321 app app' '12322 app app')" ]
}

# The start stops at the first port it cannot fence (80, over IPv6), as the
# script does under errexit, so the ports after it were never touched. Then
# stop-post runs 'iptables_redirect stop', which is the second half here:
# what a failed fence ends with is every port open, not closed.
@test "a port that can be neither redirected nor refused fails the start, and the cleanup leaves everything open" {
    run fence ip6tables ip6tables <<'EOF'
set +e
(set -e; iptables_redirect start >/dev/null 2>&1)
echo "start $?"
echo "failed $(probe 6 80) $(probe 4 80) $(probe 6 443) $(probe 4 443)"
iptables_redirect stop >/dev/null 2>&1
echo "cleaned $(probe 6 80) $(probe 4 80) $(probe 6 443) $(probe 4 443)"
EOF
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "start 1" ]
    [ "${lines[1]}" = "failed app fence app app" ]
    [ "${lines[2]}" = "cleaned app app app app" ]
}

@test "a restore while the fence is up removes it, redirect and refusal alike" {
    run fence ip6tables <<'EOF'
iptables_redirect start >/dev/null 2>&1
echo "fenced $(probe 6 443) $(probe 4 443)"
ip6tables-restore < "$FIXTURES/webmin-fw.rules.v6"
iptables-restore < "$FIXTURES/webmin-fw.rules.v4"
echo "restored $(probe 6 443) $(probe 4 443)"
EOF
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "fenced refused fence" ]
    [ "${lines[1]}" = "restored app app" ]
}
