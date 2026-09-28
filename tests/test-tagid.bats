#!/usr/bin/env bats
# Tests for lib/tagid.sh and firstboot.d/29tagid: the page the appliance
# serves on first boot, before anybody has logged in.
#
# The verdict that matters is taken from the rendered page, not from the
# source of the hook: the page is parsed for every host a <script>, <link>,
# <img> or <iframe> would fetch from, and that set has to be empty
# (docs/traps.md, "Asserting the configuration is not asserting the
# behaviour"). A grep for one known hostname would pass the day somebody
# adds a different one.
#
# Refutations are written "run ! cmd", never a bare "! cmd": bash does not
# apply errexit to a negated command, so a bare one asserts nothing.

bats_require_minimum_version 1.5.0

load helpers

REPO=$BATS_TEST_DIRNAME/..
HOOK=$REPO/firstboot.d/29tagid
TKL_VERSION=turnkey-core-19.0-trixie-amd64
APT_LINE='Acquire::http::User-Agent "TurnKey APT-HTTP/1.3 (turnkey-core-19.0-trixie-amd64)";'
# what an image built before this change put at the end of the page
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
    mkdir -p "$INITHOOKS_PATH/turnkey-init-fence/htdocs"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
    cp "$REPO/turnkey-init-fence/htdocs/index.html" \
        "$INITHOOKS_PATH/turnkey-init-fence/htdocs/index.html"

    export HTDOCS=$BATS_TEST_TMPDIR/var/turnkey-init-fence/htdocs
    export INITFENCE_DEFAULT=$BATS_TEST_TMPDIR/default-turnkey-init-fence
    echo "HTDOCS=$HTDOCS" > "$INITFENCE_DEFAULT"

    export TURNKEY_VERSION_FILE=$BATS_TEST_TMPDIR/turnkey_version
    export APT_CONF_TURNKEY=$BATS_TEST_TMPDIR/01turnkey
    echo "$TKL_VERSION" > "$TURNKEY_VERSION_FILE"
    echo "$APT_LINE" > "$APT_CONF_TURNKEY"

    PACKAGED=$REPO/turnkey-init-fence/htdocs/index.html
    RENDERED=$HTDOCS/index.html
}

# Every host the page would fetch from while rendering: the src of a script,
# frame or image and the href of a stylesheet, absolute or protocol relative.
# An <a href> is not here on purpose: a link is somewhere the operator may
# choose to go, not something the page loads on its own.
loaded_hosts() {
    grep -oiE '<(script|link|img|iframe)[^>]+(src|href)[[:space:]]*=[[:space:]]*"[^"]+"' "$1" \
        | grep -oiE '"(https?:)?//[^/"]+' \
        | sed 's|^"||' \
        | sort -u
}

script_hosts() {
    grep -oiE '<script[^>]+src[[:space:]]*=[[:space:]]*"[^"]+"' "$1" \
        | grep -oiE '"(https?:)?//[^/"]+' \
        | sed 's|^"||' \
        | sort -u
}

# ------------------------------------------------- the page that is served

@test "the rendered page loads no script from another host" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ -s "$RENDERED" ]
    run script_hosts "$RENDERED"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the rendered page loads nothing at all from another host" {
    "$HOOK"
    run loaded_hosts "$RENDERED"
    [ -z "$output" ]
}

@test "the packaged page loads nothing from another host either" {
    run loaded_hosts "$PACKAGED"
    [ -z "$output" ]
}

@test "the rendered page names no third party host in a script element" {
    "$HOOK"
    run ! grep -qiE '<script[^>]+src[^>]*(ajax\.turnkeylinux\.org|googleapis\.com)' "$RENDERED"
}

@test "a page inherited from an older image loses the scripts it carried" {
    # /var survives, so an index tagged by a previous build can still be there
    mkdir -p "$HTDOCS"
    { cat "$PACKAGED"; printf '%s\n' "$OLD_SCRIPTS"; } > "$RENDERED"
    run script_hosts "$RENDERED"
    [ -n "$output" ]
    "$HOOK"
    run script_hosts "$RENDERED"
    [ -z "$output" ]
}

@test "the page keeps its own local stylesheet and image" {
    "$HOOK"
    grep -q 'href="/style.css"' "$RENDERED"
    grep -q 'src="/turnkey-init-root.png"' "$RENDERED"
}

@test "the inline script that fills in the ssh address survives" {
    "$HOOK"
    grep -q 'document.getElementById("p1")' "$RENDERED"
    grep -q 'document.getElementById("p3")' "$RENDERED"
    # it is inline: the element that holds it has no src
    run ! grep -qE '<script[^>]+src[^>]*>[[:space:]]*$' "$RENDERED"
}

@test "running the hook twice leaves the same page" {
    "$HOOK"
    cp "$RENDERED" "$BATS_TEST_TMPDIR/once"
    "$HOOK"
    diff "$BATS_TEST_TMPDIR/once" "$RENDERED"
}

@test "a failing strip leaves the page it was rewriting intact" {
    # the temporary file exists for this: the fence must never be left with a
    # truncated index (docs/traps.md, "gpg truncates its output file before
    # asking for the passphrase")
    "$HOOK"
    cp "$RENDERED" "$BATS_TEST_TMPDIR/good"
    stub perl 'exit 1'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ -s "$RENDERED" ]
    diff "$BATS_TEST_TMPDIR/good" "$RENDERED"
    [ ! -e "$RENDERED.tmp" ]
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

@test "strip_remote_scripts removes an absolute script element" {
    run tagid_strip_remote_scripts <<< '<p>a</p>
<script src="https://ajax.turnkeylinux.org/initfence/iso/19.0/core.js" async></script>
<p>b</p>'
    [ "$status" -eq 0 ]
    [[ "$output" != *script* ]]
    [[ "$output" == *"<p>a</p>"* ]]
    [[ "$output" == *"<p>b</p>"* ]]
}

@test "strip_remote_scripts removes a protocol relative one" {
    run tagid_strip_remote_scripts <<< '<script src="//cdn.example.net/x.js"></script>'
    [ -z "${output// /}" ]
}

@test "strip_remote_scripts removes one that is not on a line of its own" {
    run tagid_strip_remote_scripts <<< '<p>a</p><script src="https://h.example/x.js"></script><p>b</p>'
    [[ "$output" != *script* ]]
    [[ "$output" == *"<p>a</p>"* ]]
    [[ "$output" == *"<p>b</p>"* ]]
}

@test "strip_remote_scripts keeps a script served by the appliance" {
    local local_script='<script src="/local.js"></script>'
    run tagid_strip_remote_scripts <<< "$local_script"
    [ "$output" = "$local_script" ]
}

@test "strip_remote_scripts keeps an inline script" {
    run tagid_strip_remote_scripts <<< '<script>
let a = 1;
</script>'
    [[ "$output" == *"let a = 1;"* ]]
    [[ "$output" == *"<script>"* ]]
}

@test "strip_remote_scripts keeps a link to somewhere the operator may click" {
    local anchor='<a href="https://www.debian.org">Debian</a>'
    run tagid_strip_remote_scripts <<< "$anchor"
    [ "$output" = "$anchor" ]
}

@test "strip_remote_scripts passes an empty input through" {
    run tagid_strip_remote_scripts < /dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the library no longer renders or detects a remote tag" {
    run ! declare -F tagid_render_scripts
    run ! declare -F tagid_is_tagged
    run ! declare -F tagid_build
    run ! declare -F tagid_version
}

@test "the library names no third party host" {
    run ! grep -qE 'ajax\.turnkeylinux\.org|googleapis\.com' "$REPO/lib/tagid.sh"
    run ! grep -qE 'ajax\.turnkeylinux\.org|googleapis\.com' "$HOOK"
}

# ---------------------------------------------------------------- the hook

@test "hook does nothing under turnkey-init" {
    _TURNKEY_INIT=1 run "$HOOK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$HTDOCS" ]
    [ -z "$(calls systemctl)" ]
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

@test "hook names the appliance in an existing writable index" {
    mkdir -p "$HTDOCS"
    echo '<title>@APP_NAME@</title>' > "$RENDERED"
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$RENDERED")" = "<title>core</title>" ]
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
