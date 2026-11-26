#!/usr/bin/env bats
# What the init fence does to traffic, asked of the real nftables.
#
# tests/test-init-fence.bats drives lib/init-fence.sh against a stub and
# asserts the scripts it gives nft. This file runs the same functions
# against the real nft in a network namespace of its own
# (tests/netns-sandbox) and connects to the ports from a client on the other
# end of a veth pair, over IPv6 and IPv4, and from the appliance itself over
# loopback. The answer is what a connection gets: the application, the
# fence page, a refusal, or silence.
#
# keel's ruleset is tests/fixtures/keel-enforce-fence.nft: the enforce
# ruleset keel renders while the fence is enabled (keel PR 339, 391f067),
# with policy drop and an accept of the fence ports for redirected packets
# only (ct status dnat, decision 0097, section 2, item 4). Without the
# fence rule it is what keel writes when the fence is gone or failed.

bats_require_minimum_version 1.5.0

SANDBOX=$BATS_TEST_DIRNAME/netns-sandbox

# fence [NFT_FAIL] < BODY
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

@test "every fenced port gets the fence page, over both families" {
    run fence <<'EOF'
fence_rules start >/dev/null
for port in 80 443 12321 12322; do
    echo "$port $(probe 6 "$port") $(probe 4 "$port")"
done
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' '80 fence fence' '443 fence fence' \
        '12321 fence fence' '12322 fence fence')" ]
}

@test "with keel's enforce ruleset, the fenced ports get the fence page and a direct connection to the fence ports is dropped" {
    run fence <<'EOF'
nft -f "$FIXTURES/keel-enforce-fence.nft"
fence_rules start >/dev/null
echo "$(probe 6 80) $(probe 4 80) $(probe 6 443) $(probe 4 12321)"
echo "$(probe 6 60080) $(probe 4 60443)"
EOF
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "fence fence fence fence" ]
    [ "${lines[1]}" = "silent silent" ]
}

@test "keel loading its ruleset again while the fence is up changes nothing" {
    run fence <<'EOF'
fence_rules start >/dev/null
nft -f "$FIXTURES/keel-enforce-fence.nft"
nft -f "$FIXTURES/keel-enforce-fence.nft"
echo "$(probe 6 80) $(probe 4 443)"
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "fence fence" ]
}

@test "without nftables nat, every fenced port is dropped from outside, over both families" {
    run fence nat <<'EOF'
fence_rules start >/dev/null 2>&1
for port in 80 443 12321 12322; do
    echo "$port $(probe 6 "$port") $(probe 4 "$port")"
done
cat "$FENCE_CONSOLE"
EOF
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "80 silent silent" ]
    [ "${lines[1]}" = "443 silent silent" ]
    [ "${lines[2]}" = "12321 silent silent" ]
    [ "${lines[3]}" = "12322 silent silent" ]
    [[ "${lines[4]}" == "turnkey-init-fence: cannot redirect TCP ports 80 443 12321 12322 "* ]]
}

@test "without nftables nat, the drop holds under keel's enforce ruleset, which accepts the fenced ports" {
    run fence nat <<'EOF'
nft -f "$FIXTURES/keel-enforce-fence.nft"
fence_rules start >/dev/null 2>&1
echo "$(probe 6 80) $(probe 4 80) $(probe 6 443) $(probe 4 12321) $(probe 6 22)"
EOF
    [ "$status" -eq 0 ]
    # 22 is no fenced port: nothing listens there, and keel accepts it
    [ "$output" = "silent silent silent silent refused" ]
}

@test "loopback reaches the application behind the redirect and behind the drop" {
    run fence <<'EOF'
fence_rules start >/dev/null
echo "$(probe_local 6 443) $(probe_local 4 80)"
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "app app" ]
    run fence nat <<'EOF'
fence_rules start >/dev/null 2>&1
echo "$(probe_local 6 443) $(probe_local 4 80)"
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "app app" ]
}

@test "stop gives every port back to the application and leaves the other tables" {
    run fence <<'EOF'
nft -f "$FIXTURES/keel-enforce-fence.nft"
nft add table ip other
fence_rules start >/dev/null
fence_rules stop >/dev/null
for port in 80 443 12321 12322; do
    echo "$port $(probe 6 "$port") $(probe 4 "$port")"
done
nft list tables
EOF
    [ "$status" -eq 0 ]
    # keel's ruleset opens 80, 443 and 12321, not 12322
    [ "$output" = "$(printf '%s\n' '80 app app' '443 app app' \
        '12321 app app' '12322 silent silent' 'table inet keel' 'table ip other')" ]
}

@test "stop after the drop gives every port back to the application" {
    run fence nat <<'EOF'
fence_rules start >/dev/null 2>&1
fence_rules stop >/dev/null
echo "$(probe 6 80) $(probe 4 443)"
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "app app" ]
}

@test "a second start replaces the first table, and one stop removes it" {
    run fence <<'EOF'
fence_rules start >/dev/null
fence_rules start >/dev/null
echo "$(nft list tables)"
fence_rules stop >/dev/null
echo "$(nft list tables) $(probe 6 80)"
EOF
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "table inet keel_fence" ]
    [ "${lines[1]}" = " app" ]
}

# nft can load no table: nothing fences the ports, and the start says so.
# This is the one case where the fence fails open, and the reason the
# unit is then failed.
@test "when nft can load no table, the start fails and every port answers as the application" {
    run fence all <<'EOF'
set +e
(set -e; fence_rules start >/dev/null 2>&1)
echo "start $?"
echo "$(probe 6 80) $(probe 4 80)"
cat "$FENCE_CONSOLE"
EOF
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "start 1" ]
    [ "${lines[1]}" = "app app" ]
    [[ "${lines[2]}" == "turnkey-init-fence: cannot load the nftables table inet keel_fence: "* ]]
}

# nftables.service flushes the ruleset; its drop-in then runs
# "turnkey-init-fence reload-rules", which loads the table again
@test "a flush of the ruleset removes the fence's table, and a new load fences again" {
    run fence <<'EOF'
fence_rules start >/dev/null
echo "fenced $(probe 6 443) $(probe 4 443)"
nft flush ruleset
echo "flushed $(probe 6 443) $(probe 4 443)"
fence_rules start >/dev/null
echo "loaded $(probe 6 443) $(probe 4 443)"
EOF
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "fenced fence fence" ]
    [ "${lines[1]}" = "flushed app app" ]
    [ "${lines[2]}" = "loaded fence fence" ]
}
