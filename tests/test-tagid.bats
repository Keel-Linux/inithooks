#!/usr/bin/env bats
# Tests for lib/tagid.sh and firstboot.d/29tagid: the pages the appliance
# serves on first boot, before anybody has logged in.
#
# The verdict that matters is taken from what is served, not from the
# source of the hook (docs/traps.md, "Asserting the configuration is not
# asserting the behaviour"), and by two detectors that do not share a
# parser: tests/remote_loads.py, which parses the page with Python's
# HTMLParser and knows every attribute and style construct that fetches,
# and remote_tokens below, which knows no HTML at all and reports any URL
# with a host in any tag that is not a link, in any quoting or none. A grep
# for one known hostname would pass the day somebody adds a different one.
#
# Refutations are written "run ! cmd", never a bare "! cmd": bash does not
# apply errexit to a negated command, so a bare one asserts nothing.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..
HOOK=$REPO/firstboot.d/29tagid
TKL_VERSION=turnkey-core-19.0-trixie-amd64
APT_LINE='Acquire::http::User-Agent "TurnKey APT-HTTP/1.3 (turnkey-core-19.0-trixie-amd64)";'
# what an image built before Keel-Linux/inithooks#13 put at the end of the page
OLD_SCRIPTS='<script src="https://ajax.turnkeylinux.org/initfence/iso/19.0-trixie-amd64/core.js" async></script>
<script src="https://ajax.turnkeylinux.org/initfence/iso/19.0-trixie-amd64/core.direct" async></script>'

setup() {
    source "$REPO/lib/tagid.sh"
    setup_stubs
    # the fence is inactive unless a test says otherwise
    stub systemctl '[[ "$1" == is-active ]] && exit 3
exit 0'

    # a scratch /usr/lib/inithooks with the packaged htdocs and the library
    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH/turnkey-init-fence"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
    cp -R "$REPO/turnkey-init-fence/htdocs" "$INITHOOKS_PATH/turnkey-init-fence/"

    export HTDOCS=$BATS_TEST_TMPDIR/var/turnkey-init-fence/htdocs
    export INITFENCE_DEFAULT=$BATS_TEST_TMPDIR/default-turnkey-init-fence
    echo "HTDOCS=$HTDOCS" > "$INITFENCE_DEFAULT"

    export TURNKEY_VERSION_FILE=$BATS_TEST_TMPDIR/turnkey_version
    export APT_CONF_TURNKEY=$BATS_TEST_TMPDIR/01turnkey
    echo "$TKL_VERSION" > "$TURNKEY_VERSION_FILE"
    echo "$APT_LINE" > "$APT_CONF_TURNKEY"

    PACKAGED=$REPO/turnkey-init-fence/htdocs/index.html
    RENDERED=$HTDOCS/index.html
    # the page the hook is expected to serve: the packaged one, named
    EXPECTED=$BATS_TEST_TMPDIR/expected.html
    sed 's|@APP_NAME@|core|' "$PACKAGED" > "$EXPECTED"
}

# remote_loads FILE
# What tests/remote_loads.py says FILE fetches from another host.
remote_loads() {
    python3 "$BATS_TEST_DIRNAME/remote_loads.py" "$1"
}

# remote_tokens FILE
# Every URL with a host in a tag of FILE that is not a link (<a>, <area>),
# and in its style elements, in any quoting or none: scheme://host,
# //host, and the backslash forms a browser reads the same way. Knows no
# HTML beyond where a tag starts and ends, so it is wider than any parser
# and never quieter than one about a well formed page.
remote_tokens() {
    tr '\n' ' ' < "$1" \
        | grep -oiE '<[a-z!/][^>]*>|<style[^>]*>.*</style>' \
        | grep -viE '^<(a|area)[[:space:]/>]' \
        | grep -oiE '([a-z][a-z0-9+.-]*:)?[/\\]{2}[^/\\[:space:]"'"'"')>]+' \
        || true
}

# serves_nothing_remote DIR
# Every file the fence would serve from DIR loads nothing from another host,
# by both detectors.
serves_nothing_remote() {
    local file
    for file in "$1"/*; do
        if [[ -n "$(remote_tokens "$file")" ]]; then
            echo "remote_tokens: $file: $(remote_tokens "$file")" >&2
            return 1
        fi
        if [[ "$file" == *.html ]] && ! remote_loads "$file" >&2; then
            echo "remote_loads: $file" >&2
            return 1
        fi
    done
}

# inherit PAGE_SUFFIX
# An htdocs directory left in /var by an older image or by somebody else:
# the packaged files, with PAGE_SUFFIX appended to the index.
inherit() {
    mkdir -p "$(dirname "$HTDOCS")"
    cp -R "$INITHOOKS_PATH/turnkey-init-fence/htdocs" "$(dirname "$HTDOCS")"
    printf '%s\n' "$1" >> "$RENDERED"
}

# ------------------------------------------------ the detectors themselves

@test "both detectors see the scripts an older image appended" {
    inherit "$OLD_SCRIPTS"
    run remote_loads "$RENDERED"
    [ "$status" -eq 1 ]
    [ "${#lines[@]}" -eq 2 ]
    run remote_tokens "$RENDERED"
    [ "${#lines[@]}" -eq 2 ]
}

@test "remote_tokens sees what HTMLParser does not" {
    inherit '<!--><img src=https://evil.example/a>-->'
    run remote_loads "$RENDERED"
    [ "$status" -eq 0 ]
    run remote_tokens "$RENDERED"
    [ "$output" = "https://evil.example" ]
}

@test "remote_tokens ignores links and page text" {
    run remote_tokens "$EXPECTED"
    [ -z "$output" ]
    grep -q 'href="https://www.turnkeylinux.org' "$EXPECTED"
}

# ------------------------------------------------- the pages that are served

@test "the packaged pages load nothing from another host" {
    run serves_nothing_remote "$REPO/turnkey-init-fence/htdocs"
    [ "$status" -eq 0 ]
}

@test "the served pages load nothing from another host" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ -s "$RENDERED" ]
    run serves_nothing_remote "$HTDOCS"
    [ "$status" -eq 0 ]
}

@test "the page served is the packaged page, named after the appliance" {
    "$HOOK"
    diff "$EXPECTED" "$RENDERED"
    run ! grep -q '@APP_NAME@' "$RENDERED"
}

@test "a page inherited from an older image is replaced, not edited" {
    inherit "$OLD_SCRIPTS"
    "$HOOK"
    diff "$EXPECTED" "$RENDERED"
}

# The review of the first version of this branch measured these getting
# past a strip that removed double and single quoted <script src> only.
# Each is served as an inherited page and must be gone after the hook.
@test "every way an inherited page can load from another host is gone" {
    local -a pages=(
        '<script src=https://evil.example/x.js></script>'
        '<script src="https://evil.example/x.js">var a=1;</script>'
        '<link rel="stylesheet" href="https://evil.example/x.css">'
        '<img src="https://evil.example/x.png">'
        '<iframe src="https://evil.example/"></iframe>'
        "<style>@import 'https://evil.example/x.css';</style>"
        '<base href="https://evil.example/">'
        '<meta http-equiv="refresh" content="0; url=https://evil.example/">'
        '<!--><img src=https://evil.example/a>-->'
        '<script></script x><img src=https://evil.example/a>'
        '<img src="/\evil.example/x.png">'
    )
    local page
    for page in "${pages[@]}"; do
        rm -rf "$(dirname "$HTDOCS")"
        inherit "$page"
        [ -n "$(remote_tokens "$RENDERED")" ]
        "$HOOK"
        diff "$EXPECTED" "$RENDERED"
        serves_nothing_remote "$HTDOCS"
    done
}

@test "an inherited stylesheet and a file the package does not ship are replaced too" {
    inherit ''
    echo '@import url(https://evil.example/x.css);' >> "$HTDOCS/style.css"
    echo 'alert(1)' > "$HTDOCS/extra.js"
    "$HOOK"
    diff "$INITHOOKS_PATH/turnkey-init-fence/htdocs/style.css" "$HTDOCS/style.css"
    [ ! -e "$HTDOCS/extra.js" ]
    diff <(cd "$INITHOOKS_PATH/turnkey-init-fence/htdocs" && ls -A) \
        <(cd "$HTDOCS" && ls -A)
}

@test "the page keeps its own local stylesheet and image" {
    "$HOOK"
    grep -q 'href="/style.css"' "$RENDERED"
    grep -q 'src="/turnkey-init-root.png"' "$RENDERED"
    cmp "$INITHOOKS_PATH/turnkey-init-fence/htdocs/turnkey-init-root.png" \
        "$HTDOCS/turnkey-init-root.png"
}

@test "the inline script that fills in the ssh address survives" {
    "$HOOK"
    grep -q 'document.getElementById("p1")' "$RENDERED"
    grep -q 'document.getElementById("p3")' "$RENDERED"
    # it is inline: the element that holds it has no src
    run ! grep -qE '<script[^>]+src[^>]*>[[:space:]]*$' "$RENDERED"
}

@test "running the hook twice leaves the same pages" {
    "$HOOK"
    cp -R "$HTDOCS" "$BATS_TEST_TMPDIR/once"
    "$HOOK"
    diff -r "$BATS_TEST_TMPDIR/once" "$HTDOCS"
}

@test "nothing is written inside the directory the fence serves, and nothing is left beside it" {
    inherit "$OLD_SCRIPTS"
    "$HOOK"
    diff <(cd "$INITHOOKS_PATH/turnkey-init-fence/htdocs" && ls -A) \
        <(cd "$HTDOCS" && ls -A)
    [ "$(ls -A "$(dirname "$HTDOCS")")" = htdocs ]
}

@test "a render that fails leaves no inherited page to serve" {
    # the fence serves the packaged htdocs when the writable copy is missing
    # (fence_htdocs), so on failure the inherited copy goes rather than stays
    inherit "$OLD_SCRIPTS"
    stub sed 'exit 4'
    run "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"<3>"* ]]
    [ ! -e "$HTDOCS" ]
    [ -z "$(ls -A "$(dirname "$HTDOCS")")" ]
}

@test "every step that can fail leaves no inherited page and nothing half built" {
    local tool
    for tool in mkdir mktemp cp chmod mv; do
        rm -rf "$(dirname "$HTDOCS")" "${STUBS:?}/$tool"
        inherit "$OLD_SCRIPTS"
        stub "$tool" 'exit 9'
        run "$HOOK"
        [ "$status" -eq 1 ] || { echo "$tool: status $status" >&2; return 1; }
        [ ! -e "$HTDOCS" ] || { echo "$tool: htdocs left" >&2; return 1; }
        [ -z "$(ls -A "$(dirname "$HTDOCS")")" ] \
            || { echo "$tool: $(ls -A "$(dirname "$HTDOCS")")" >&2; return 1; }
        rm "$STUBS/$tool"
    done
}

@test "a missing mktemp never turns the build directory into the root" {
    # an empty NEW would make the copy land in /; it must stop instead. cp is
    # a stub that succeeds, as the real one would for root
    stub mktemp 'exit 1'
    stub cp 'exit 0'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [ -z "$(calls cp)" ]
}

@test "a default file without HTDOCS stops the hook before it removes anything" {
    echo 'HTTP_PORTS=(80)' > "$INITFENCE_DEFAULT"
    unset HTDOCS
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"HTDOCS is not set"* ]]
}

@test "the page still ends with a closing html tag" {
    "$HOOK"
    grep -q '</html>' "$RENDERED"
}

# ------------------------------------------------------------- the library

@test "app_name strips the turnkey prefix and the version" {
    [ "$(tagid_app_name turnkey-core-19.0-trixie-amd64)" = core ]
    [ "$(tagid_app_name turnkey-wordpress-19.0-trixie-amd64)" = wordpress ]
    [ "$(tagid_app_name turnkey-gitea-19.1-trixie-arm64)" = gitea ]
}

@test "the library no longer renders, detects or strips a remote tag" {
    run ! declare -F tagid_render_scripts
    run ! declare -F tagid_is_tagged
    run ! declare -F tagid_build
    run ! declare -F tagid_version
    run ! declare -F tagid_strip_remote_scripts
}

@test "the library names no third party host" {
    run ! grep -qE 'ajax\.turnkeylinux\.org|googleapis\.com' "$REPO/lib/tagid.sh"
    run ! grep -qE 'ajax\.turnkeylinux\.org|googleapis\.com' "$HOOK"
}

# ---------------------------------------------------------------- the hook

@test "hook serves the packaged page under turnkey-init as well" {
    # turnkey-init is what an operator runs when the first boot did not
    # complete, with the fence still up and the old page still in /var
    inherit "$OLD_SCRIPTS"
    _TURNKEY_INIT=1 run "$HOOK"
    [ "$status" -eq 0 ]
    diff "$EXPECTED" "$RENDERED"
}

@test "hook copies the packaged htdocs when the writable copy is missing" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ -f "$RENDERED" ]
    run ! grep -q '@APP_NAME@' "$RENDERED"
    grep -q 'core' "$RENDERED"
    # the packaged copy is left as shipped
    grep -q '@APP_NAME@' "$INITHOOKS_PATH/turnkey-init-fence/htdocs/index.html"
}

@test "hook does not read the apt user agent any more" {
    # common removes /etc/apt/apt.conf.d/01turnkey (Keel-Linux/common#6); the
    # build tag it carried had no consumer but the scripts that are now gone
    rm -f "$APT_CONF_TURNKEY"
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ -s "$RENDERED" ]
}

@test "hook exits 0 without reloading an inactive fence" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(calls systemctl)" = 'is-active --quiet turnkey-init-fence' ]
}

@test "hook reloads the fence when it is active" {
    stub systemctl 'exit 0'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(calls systemctl)" = 'is-active --quiet turnkey-init-fence
reload turnkey-init-fence' ]
}

@test "hook exits with the status of a failed reload" {
    stub systemctl '[[ "$1" == reload ]] && exit 1
exit 0'
    run "$HOOK"
    [ "$status" -eq 1 ]
}
