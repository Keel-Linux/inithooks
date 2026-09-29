# Parsing for firstboot.d/29tagid.
#
# Sourced by the hook and by tests/test-tagid.bats. Every function here only
# reads its arguments or stdin and prints; the hook applies the results.

# tagid_app_name TURNKEY_VERSION
# Prints the appliance name of a turnkey_version string, e.g. core for
# turnkey-core-19.0-trixie-amd64.
tagid_app_name() {
    perl -pe 's/^turnkey-//; s/-[^-]+(-[^-]+){2}$//' <<< "$1"
}
