# Parsing and rendering for firstboot.d/29tagid.
#
# Sourced by the hook and by tests/test-tagid.bats. Every function here only
# reads its arguments or stdin and prints; the hook applies the results.

# tagid_app_name TURNKEY_VERSION
# Prints the appliance name of a turnkey_version string, e.g. core for
# turnkey-core-19.0-trixie-amd64.
tagid_app_name() {
    perl -pe 's/^turnkey-//; s/-[^-]+(-[^-]+){2}$//' <<< "$1"
}

# tagid_strip_remote_scripts
# Copies stdin to stdout without any <script> element that loads from another
# host: an src with a scheme (https://...) or a protocol relative one (//...).
#
# A <script src="/local.js"> is served by the appliance itself and is kept, as
# is an inline <script>, as is an <a href> to anywhere at all - a link is
# somewhere the operator may choose to go, not something the page fetches on
# its own.
#
# This exists because the page is the first thing an operator sees on a
# machine nobody has logged into yet, and because /var survives: an index
# tagged by an image built before Keel-Linux/inithooks#13 is still on disk on
# such a machine, so removing the code that wrote it is not enough on its own.
tagid_strip_remote_scripts() {
    perl -0777 -pe 's{<script\b[^>]*\bsrc\s*=\s*(["\x27])\s*(?:[a-z][a-z0-9+.-]*:)?//.*?\1[^>]*>\s*(?:</script\s*>)?[^\S\n]*\n?}{}gis'
}
