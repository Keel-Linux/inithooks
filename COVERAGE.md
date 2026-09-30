# Test coverage baseline

Measured on 2026-09-24 against upstream master (33c43b8), following the
project decision 0003 (90 percent floor per repository, 95 percent for every
file our changes touch).

## Branch fix/one-first-boot-run, after review: shell 99.71, Python 99

keel-init refuses before the first boot's own run has finished, the lock
file describes its holder so the refusal can say where it is, and keel-init
retries the lock briefly. `lib/init-lock.sh` 22/22;
`tests/test-init-lock.bats` 12 tests, `tests/test-run.bats` 17, 198 bats
in all, shell total 99.71. `libinithooks/init_lock.py` 154 statements, 36
branches, 100 percent, from 78 tests in `tests/test_init_lock.py`; Python
total 99. The race is tested with the real `run`: keel-init first is
refused and leaves the lock, the boot run then runs the firstboot hook and
writes its marker, and keel-init runs after it. Mutations checked: without
the first boot check three tests fail, without the description in `run`
three bats fail.

## Branch fix/one-first-boot-run: shell 99.71 percent, Python 99 (2026-09-30)

One first boot run at a time (Keel-Linux/inithooks#24) and `keel-init` as
the command, `turnkey-init` a relative link to it (Keel-Linux/inithooks#22).

Shell: `lib/init-lock.sh` is new, 21/21 under kcov 43, from
`tests/test-init-lock.bats` (10 tests) and the six lock tests added to
`tests/test-run.bats` (13 in the file). `tests/test-motd.bats` (4 tests)
runs `update-motd.d/06-keel-init`; like `run`, it sits outside the
directories `coverage.sh` measures. 192 bats in all, total 99.71, the
lowest file still `lib/init-fence.sh` at 98.81; the gate stays at 98.

Python: `libinithooks/init_lock.py` is new and joins the measured files in
`pyproject.toml`: 63 statements, 4 branches, 100 percent, from
`tests/test_init_lock.py` (38 tests). `keel-init` itself is at the top of
the tree, outside `--source=libinithooks,bin`, so the logic it adds is in
the library; the tests still load and run the command in process, run it
and its link as processes, and start the real `run` waiting in a hook to
check that keel-init refuses and names that run's pid. Total 99.

Every lock is a real flock(2) on a scratch file, taken on the other side by
another process or the util-linux `flock` command, never a stub. Mutations
checked: removing the lock from `run`, the release before confconsole, or
the close of the descriptor for each hook, and in `keel-init` the lock or
its release, each turns the suites red.

## Branch feat/static-ipv6-slaac: shell 99.69 percent (2026-09-30)

`lib/ipconfig.sh` gains `ipconfig_render_slaac6`, `ipconfig_valid_slaac`,
`ipconfig_ip4_syntax` and `ipconfig_check_dns6`, and `01ipconfig` reads
`IP6_SLAAC` (Keel-Linux/keel#45). `tests/test-ipconfig.bats` grows from 64
to 75 tests (171 bats in all): the rendering of both values, the validation,
the fatal paths before anything is touched, the full file with
`IP6_SLAAC=no`, and an IPv4 resolver in a static inet6 stanza.

Measured with kcov 43: `firstboot.d/01ipconfig` 33/33, `lib/ipconfig.sh`
84/84, `lib/init-fence.sh` 83/84 (98.81, the same line as before), total
99.69. The shell gate stays at 98.

After review: the sysctl key is written with slashes so a VLAN name stays
one component (one more bats test, 76 in the file, 172 in all; the same
line counts), and `libinithooks/declarative.py` accepts `ipv6.slaac`
(`tests/test_declarative_network.py`, four tests; `FULL` in
`tests/test_vocabulary.py` uses it, and both readers accept it with
`KEEL_SRC` set). Python 203 passed, 99 percent.

## Branch fix/fence-no-silent-skip: shell 99.57 percent (2026-09-28)

`lib/init-fence.sh` gains `fence_close_port` and `fence_open_port`, and
`iptables_add_redirect` refuses a port it cannot redirect instead of leaving
it open. `tests/test-init-fence.bats` grows from 27 to 31 tests (116 bats
over the six files): the refusal for one family and for both, the insertion
first in the INPUT chain so it precedes the appliance's own ACCEPT rules,
the removal loop, the fatal path when a port can be neither redirected nor
refused, and the same path through the script, which is the one that proves
the library stops its caller rather than dying invisibly.

Measured with kcov 43: `bin/turnkey-init-fence` 28/28, `lib/init-fence.sh`
78/79 (98.73), `firstboot.d/01ipconfig` 29/29, `lib/ipconfig.sh` 72/72,
`firstboot.d/29tagid` 19/19, `lib/tagid.sh` 8/8, total 99.57.

The one uncovered line of `lib/init-fence.sh` is line 154, the first line of
the multi-line `simplehttpd.py` invocation, which kcov attributes to a later
line. It is the same line that was uncovered before this branch, and it is
not part of this change. Every line this branch adds is covered.

The shell gate stays at 98, the lowest file rounded down; 98.73 clears it
and decision 0003's 95 percent bar for a file a change touches.

After review (2026-09-29): the stubs say which commands the fence issues,
not what they do to traffic, so `tests/test-init-fence-netfilter.bats`
(8 tests) asks the real netfilter. `tests/netns-sandbox` runs the library
against real iptables and ip6tables in a network namespace of its own, with
a client namespace on the other end of a veth pair, and connects to the
ports over IPv6, IPv4 and loopback; the only stand-in is the answer
"there is no nat table" (or "the filter table refuses the insert") for one
family. It found that the default ICMP refusal left an IPv6 client waiting
for its timeout, that the refusal also refused loopback, and that a
restore of the appliance firewall's own rules removes the whole fence.
125 bats in all; `lib/init-fence.sh` 83/84 (98.81), total 99.58, the same
one line uncovered.

## bin/keel-host-keys (2026-09-29, keel-core#8)

`tests/test-host-keys.bats`, 22 tests, measures `bin/keel-host-keys` at
65/65 lines; shell total 99.65 under `tests/coverage.sh`. SSH keys are made
by the real ssh-keygen; the TLS and snakeoil generators are stubs that write
a real openssl key where the script reads it. Mutating the shared-key lookup,
the post-generation check or the missing-list check each turns the suite
red. The same script run against the keys extracted from the published core
layer replaced all three SSH host keys and the TLS key.

## Measured baseline on master: shell 98 percent, Python 99 percent (2026-09-26)

Pull requests #1 to #4 merged on 2026-09-26 (merge commits 4e09d1e, a20a94a,
8f77b85, e1334073). `tests/coverage.sh` under kcov 43 measures 112 bats over
six files: 01ipconfig 23/23, lib/ipconfig.sh 25/25, 29tagid 19/19,
lib/tagid.sh 8/8, turnkey-init-fence 28/28, lib/init-fence.sh 63/64 (98.44,
the lowest file; total 99.40). The shell gate is set to 98, the lowest file
rounded down. `coverage run --branch --source=libinithooks,bin -m pytest`
measures 185 tests (3 more skipped unless
KEEL_SRC points at the instance tooling, which the vocabulary parity tests
read): libinithooks/declarative.py 100 percent,
bin/declarative.py 99 percent (one partial branch, the loop over the ignored
candidates falling through), total 99; the Python gate is 95, the bar for
project-authored code, with the inherited modules without tests omitted in
`pyproject.toml` until their tests land. Both thresholds are only ever
raised. The sections that follow record the state before the merges.

## Branch fix/no-third-party-script: the first boot page (2026-09-28)

`firstboot.d/29tagid` and `lib/tagid.sh` stop putting a third party script
on the page the appliance serves before anybody has logged in
(Keel-Linux/inithooks#13). `tests/test-tagid.bats` grows from 14 to 27
tests. Measured with kcov 43 and bats 1.11, 124 bats over the six files:

| File | Before | After |
| --- | --- | --- |
| `firstboot.d/29tagid` | 19/19 | 17/17, 100 percent |
| `lib/tagid.sh` | 8/8 | 2/2, 100 percent |

Both files shrank because four functions went away with the scripts they
built. Total 99.53 (was 99.40). The lowest file is still
`lib/init-fence.sh` at 98.44, so the shell gate stays at 98. Python is
untouched: 187 passed, 3 skipped.

**What is asserted, and what is not.** The verdict is taken from the
rendered page, not from the source of the hook: the page is parsed for
every host a `<script>`, `<link>`, `<img>` or `<iframe>` would fetch from,
and that set has to be empty. A grep for one known hostname would pass the
day somebody adds a different one, which is how the jQuery from
`ajax.googleapis.com` survived next to the two scripts the issue named. An
`<a href>` is deliberately not in that set: a link is somewhere the
operator may choose to go, not something the page loads.

Both the packaged page and a page inherited in `/var` from an older image
are covered, because `/var` survives and `29tagid` is the only thing that
looks at that copy again. The failure path of the rewrite has a test too:
with `perl` stubbed to fail, the index is left byte for byte as it was and
no `.tmp` is left behind, which is the `docs/traps.md` entry "gpg truncates
its output file before asking for the passphrase".

Refutations use `run !`, never a bare `! cmd`: bash does not apply errexit
to a negated command, so a bare one passes whatever happens.

After review (2026-09-29): the strip and the detector shared a blind spot
(double quoted attributes of four elements), so an unquoted
`<script src=...>`, a remote stylesheet, image or frame got past both.
`29tagid` no longer strips anything: it rebuilds the `/var` copy from the
packaged pages on every run, beside the served directory, and swaps it in;
`lib/tagid.sh` is down to `tagid_app_name`, 1/1, and `29tagid` is 29/29.
The pages are now judged by two detectors that share no parser:
`tests/remote_loads.py` (HTMLParser, every attribute and style construct
that fetches, with its own 9 Python tests and 48 cases) and a tag level
regular expression that knows no HTML, and each hostile page the review
measured, plus parser differentials such as `<!--><img src=...>`, is
served as an inherited page and must be gone. `tests/test-tagid.bats` has
27 tests, 125 bats in all, total 99.55; Python 196 passed, 3 skipped.

## Branch feat/ip6-preseed: IPv6 preseed keys in 01ipconfig (2026-09-26)

Adds `IP6_CONFIG`, `IP6_ADDRESS`, `IP6_GW`, `IP6_DNS1` and `IP6_DNS2` to
`firstboot.d/01ipconfig`, with the IPv6 checks and rendering as pure
functions in `lib/ipconfig.sh`. `tests/test-ipconfig.bats` grows from 27
to 64 tests (105 bats over the six files), one per new branch: every
refusal message of the IPv6 checks, static with and without gateway and
nameservers, IPv4 in an IPv6 field, an invalid `IP6_CONFIG`, the dhcp
default, IPv4 static together with IPv6 static, the unchanged short
circuit over both stanzas, and a byte for byte comparison of the file an
`IP_*` only preseed produced before the change. Measured locally under
kcov 43 with bats 1.11: lib/ipconfig.sh 72/72 (was 25/25), 01ipconfig
29/29 (was 23/23), the other files unchanged, total 99.55 (was 99.40).
The lowest file is still lib/init-fence.sh at 98.44, so the shell gate
stays at 98. Python is untouched.

## Baseline before the merges: 0 percent measured on upstream master

Upstream has one file under `tests/`, `test-simplehttpd.sh` (4 lines). It
starts `bin/simplehttpd.py` on the loopback ports and prints the URL; it
asserts nothing and is a manual smoke launcher, not a test. No coverage tool
is wired up. Line counts are lines neither blank nor comment.

Inventory command (shebang or extension decides the kind):

    find . -type f -not -path './.git/*' -not -path './debian/*' \
      | while read f; do h=$(head -1 "$f"); case "$f$h" in *.py*|*python*) k=py;; \
      *sh*) k=sh;; *) continue;; esac; echo "$k $(grep -cvE '^\s*(#|$)' "$f") $f"; done

| Group | Files | Lines | Measured |
|-------|-------|-------|----------|
| firstboot.d/* (17 hooks) | 17 | 366 | 0 percent, no test |
| run, turnkey-init, turnkey-sudoadmin, turnkey-install-security-updates | 4 | 399 | 0 percent, no test |
| bin/*.py (hubservices 162, simplehttpd 339, secalerts 75, secupdates-ask 52, setpass 54, reboot-ask 30) | 6 | 712 | 0 percent, no test |
| bin/* shell (turnkey-init-fence 139, secalerts.sh 66, restart-getty 59, login_script.sh 2) | 4 | 266 | 0 percent, no test |
| libinithooks/*.py (dialog_wrapper 354, inithooks_cache 61, __init__ 33, inithooks_log 30) | 4 | 478 | 0 percent, no test |
| setup.py, tests/test-simplehttpd.sh | 2 | 13 | packaging and launcher, excluded |

Total: 25 shell files (970 lines) and 12 Python files (1268 lines), 0
percent measured.

## Measured on our branch feat/declarative-instance

Command, on the branch checkout:

    PYTHONPATH=. coverage run --branch --source=libinithooks,bin \
      -m pytest -q tests/test_declarative.py && coverage report -m

31 tests pass. Line plus branch coverage as reported:

| File | Stmts | Branches | Cover |
|------|-------|----------|-------|
| libinithooks/declarative.py | 438 | 222 | 72 percent (110 statements missed, 38 partial branches) |
| bin/declarative.py | 84 | 34 | 0 percent (CLI wrapper, never imported by the tests) |
| firstboot.d/00declarative | shell, 14 lines | | 0 percent, no test |
| all other files under libinithooks and bin | | | 0 percent |

Total over `libinithooks` and `bin` on that branch: 26 percent.

## Our branches and the 95 percent bar

| Branch | File touched | Automated test |
|--------|--------------|----------------|
| fix/01ipconfig-static | firstboot.d/01ipconfig (47 lines) | None. Append static options, keep the confconsole header and the IPv6 stanza: verified by hand on a VM. 0 percent. |
| fix/29tagid-inactive-fence | firstboot.d/29tagid (18 lines) | None. Reload turnkey-init-fence only when active: verified by hand on a VM. 0 percent. |
| fix/fence-without-nat | bin/turnkey-init-fence (139 lines) | None. Skip REDIRECT when the nat table is unavailable: verified by hand on a VM. 0 percent. |
| feat/declarative-instance | libinithooks/declarative.py | 31 tests, 72 percent. Below the 95 percent bar. |
| feat/declarative-instance | bin/declarative.py | None, 0 percent. |
| feat/declarative-instance | firstboot.d/00declarative | None, 0 percent. |
| feat/declarative-instance | README.rst, debian/control, default/inithooks, release notes | Documentation and packaging, not code. |

## Plan to reach 90 percent per file

Method: Python with `coverage run --branch` and `pytest`, `fail_under`
committed in `pyproject.toml`. Shell with test files under `tests/` that
run each hook against a scratch root, `INITHOOKS_CONF` and
`INITHOOKS_DEFAULT` pointed at fixtures, `PATH` holding stub commands
(`ip`, `ifup`, `iptables`, `systemctl`, `turnkey-version`, `openssl`) that
record their arguments; coverage from `bash -x` traces (kcov when the
decision 0003 open item settles). Every exit code and `fatal` path gets a
test. Addresses in fixtures are IPv6, for example `2001:db8:1::10/64` with
gateway `2001:db8:1::1`.

Priority order (size: small under 30 lines of test, medium under 150,
large above):

1. `libinithooks/declarative.py` from 72 to 95 percent (medium). The
   missed regions are lines 174 to 257 (`mask`, `default_managed_by`,
   `check_network`, `unsupported`, `_live_ipv6`: the functions that read
   the live system, to be tested with a stubbed `ip` command) and lines
   583 to 638 (`_address_errors`, `_gateway_errors`, `_validate_tls`: one
   test per error message), plus 38 partial branches in the validators.
2. `bin/declarative.py` (small): run `main()` in-process with `--apply`,
   `--conf`, a missing file and a malformed file; assert output and exit
   codes.
3. `firstboot.d/00declarative` (small): `_TURNKEY_INIT` set, description
   absent, non-empty `INITHOOKS_CONF` warning, happy path calling the stub.
4. `firstboot.d/01ipconfig` (small to medium): static and dhcp cases, lxc
   short circuit, unchanged interfaces file exits 0, header and IPv6 stanza
   preserved when rewriting, `fatal` on a bad `IP_CONFIG`.
5. `firstboot.d/29tagid` (small): htdocs missing, tag already present,
   fence active and inactive (stub `systemctl is-active`).
6. `bin/turnkey-init-fence` (medium): each `case` verb, `iptables` stubs
   returning failure for `-t nat` to cover the skip, `start_mini_server`
   failure exit 1, `stop_mini_server` with and without a pid file.
7. First-boot driver: `run` (medium: `wait_for_boot`, `exec_scripts` order,
   reboot request, output redirection), `turnkey-init` (small, Python).
8. Remaining `firstboot.d` hooks (small each): 95secupdates 56,
   05autogrow-fs 53, 15regen-sslcert 39, 10randomize-crontab 31,
   09hostname 23, 97turnkey-init-fence-disable 20, 10regen-sshkeys 18,
   30turnkey-init-fence 18, 99reboot 14, and the one to seven line hooks.
9. `libinithooks`: inithooks_cache.py 61 and inithooks_log.py 30 (small),
   `__init__.py` 33 (small), dialog_wrapper.py 354 (large: mock the
   `dialog` binary, one test per dialog type and per cancel path).
10. `bin` Python: hubservices.py 162 (medium, mock HTTP), setpass.py 54,
    secupdates-ask.py 52, reboot-ask.py 30 (small), secalerts.py 75 and
    secalerts.sh 66 (small), restart-getty 59 (small), simplehttpd.py 339
    (large: start on `[::1]` ephemeral ports, request each route).
11. `turnkey-sudoadmin` 219 (large, shell: a test per subcommand).
