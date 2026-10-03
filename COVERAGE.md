# Test coverage baseline

Measured on 2026-09-24 against upstream master (33c43b8), following the
project decision 0003 (90 percent floor per repository, 95 percent for every
file our changes touch).

## Branch fix/secupdates-never-hold-boot: shell 99.71 (2026-10-03)

`firstboot.d/95secupdates` 110/111 (the line not run is still the TurnKey
Hub status call). `tests/test-secupdates.bats` gains 12 tests: an apt-get
update and an upgrade that hang, stopped within their limits and timed, the
run's limit applied to apt-get update, dpkg configured after a stopped
upgrade, an upgrade that fails, one that succeeds, the one line naming
cron-apt (offline too) or turnkey-install-security-updates without it, a
limit that is not a number of seconds, and three through the real `run`:
a hung or failed upgrade and no network leave the hook after it running.
379 bats; shell total 99.71.

## Branch fix/headless-first-boot: shell 99.69, Python 99 (2026-10-03)

A first boot nobody can answer, the hosts entry and the certificate's
name. `lib/console.sh` is new, 22/22, and `lib/sslcert.sh`, 51/51, takes
the body of `firstboot.d/15regen-sslcert` (9/9 now). The new
`tests/test-console.bats` (23 tests) runs the rule on ptys whose master
is never read, unsized and sized, on a read pty under `script`, on the
controlling terminal and with none, and every hook that draws a screen
on both unread ptys within a deadline, its screen a stand-in that never
returns (31fqdn's the real `bin/fqdn.py`). The python pty harnesses of
this file and `test-run.bats` keep kcov's trace descriptor open
(`close_fds=False`): with it closed, what ran under them was not
measured. `firstboot.d/31fqdn` 43/43, with the hosts entry after SKIP, an
empty answer and nobody to answer, and the certificate made again after
a rename (real openssl), kept when it is for the name, signed by an
authority, or unreadable. `bin/fqdn.py` and `libinithooks/fqdn.py` stay
at 100 percent with `--machine`, `in_hosts` and `machine`. 367 bats, 530
pytest; shell total 99.69, Python 99.

## Branch fix/first-boot-without-journal-or-console: shell 99.64 (2026-10-03)

Two first boot stalls of the published core booted headless.
`firstboot.d/15regen-sslcert` is measured for the first time, 27/27, from
`tests/test-regen-sslcert.bats` (8 tests): the certificate made and the
trust store updated, a logger that fails (journald down) not stopping the
hook, the services that run restarted, a key still being written waited
for, one that never matches, no turnkey-make-ssl-cert (fatal, said with
logger failing too), keel-init, the conf file. `tests/test-secupdates.bats`
gains three tests with logger failing (SKIP recorded, FORCE installed, the
record that cannot be written); `firstboot.d/95secupdates` 71/72 as
before. `tests/test-run.bats` gains three: the terminal tests run on a
sized pty (`stty rows 24 cols 80` under `script`, as a VT or an attached
console is), a pty nobody is attached to (no size) gets no notice and the
log says so once, and a sized pty nobody reads (python `pty.openpty`, the
master never read, dialog a stub writing more than the pty holds) does not
hold the boot: the notice is given up after NOTICE_TIMEOUT and the hooks
run on. `run` itself sits outside the directories kcov measures, as
before. 322 bats in all, total 99.64.

## Branch feat/first-boot-fqdn: shell 99.62, Python 99 (2026-10-02)

The first boot asks the fully qualified domain name (31fqdn). Shell:
`lib/hostname.sh` 9/9 (the rename 09hostname has always done, as a
function that replaces the name as a whole name or a first label, through
perl), `firstboot.d/09hostname` 8/8, measured for the first time, and
`firstboot.d/31fqdn` 21/21, 100 percent each, from
`tests/test-hostname.bats` (13 tests) and `tests/test-fqdn.bats` (16
tests): the rename over scratch copies of the files, the name inside other
words left alone, a colon and a dot matched literally, the same name again
touching nothing, bash's own HOSTNAME, the screen asked with the name the
machine has, the description recorded before the rename and the hosts
entry after it, a hostname without a domain, an empty answer, FQDN
preseeded and SKIP, a failing screen, record or hosts entry, an answer the
screen did not shape, and the real `bin/fqdn.py` with FQDN preseeded
writing a new instance.yaml, one that is there, leaving one that already
declares the name alone, and refusing a name that is not a domain. 301
bats in all. The file list of the rename is a `readarray` here document
because kcov marks the lines of a multi-line array assignment as not run.

Python: `libinithooks/fqdn.py` (152 statements, 50 branches) 100 percent
and `bin/fqdn.py` (97 statements, 34 branches) 100 percent, from
`tests/test_fqdn.py` (66 tests: the checks on a typed name, the split, the
declared names, the hostname that goes with a name, the prefill, the
/etc/hosts entry, the updated description and the one left equal, the
path, the writer with keel stubbed on PATH accepting and refusing, without
keel, and keeping the file's mode) and `tests/test_fqdn_cli.py` (32 tests
on the fake dialog: the screen, the notice without a domain, Back, ESC, a
preseeded name, --record, --hosts and the usage errors).
`test_dialog_brand.py` checks `bin/fqdn.py` as well; the reader accepts
`tls.acme.agree_tos` (two tests in `test_declarative_validate.py`). 515
passed (3 skipped without `KEEL_SRC`); total 99.

## Branch fix/password-once-and-updates-record: shell 99.58, Python 99 (2026-10-02)

`firstboot.d/95secupdates` is measured for the first time: 49 of 50
lines, 98 percent, from 9 tests in `tests/test-secupdates.bats` (preseeded
SKIP and FORCE, Skip and Install on the screen, a failing screen, an
invalid preseed, a record that cannot be written, dpkg in an inconsistent
state with a new kernel arming 99reboot, no conf file). The line not run
is the TurnKey Hub status call, for a machine registered with the Hub.
Shell total 99.58, down from 99.76 only because a file under 100 percent
joined the measured set. Python: `libinithooks/dialog_wrapper.py`
unchanged at 98 percent (the same two lines missed as before), 373 tests;
total 99 percent.

## Branch feat/first-boot-role: shell 99.76, Python 99 (2026-09-30)

`lib/keel-firstboot.sh` 8/8, `firstboot.d/75keel-role` 4/4 and
`firstboot.d/80keel-cloud` 4/4, 100 percent each, from 8 tests in
`tests/test-keel-firstboot.bats` with python3 stubbed: the step each
hook asks for, a preseeded HUB_APIKEY reaching the screen, no conf file,
confconsole absent (nothing asked, the boot goes on), a failed screen's
status, the default entry point, and 80hub-services and
bin/hubservices.py gone. 223 bats in all with master's restart-getty
tests, shell total 99.76. The screens themselves are confconsole's
`keelfirstboot.py`, measured there at 100 percent. `bin/hubservices.py`
is removed, so it leaves the `omit` list; Python unchanged, 99 percent.

## Branch fix/restart-getty-container: shell 99.75 percent (2026-09-30)

`bin/restart-getty` was 0 percent, with no test; it is now 61/61 under
kcov 43, from `tests/test-restart-getty.bats` (15 tests). systemctl and
systemd-run are stubs answering from a scratch state directory, and the
ttys are scratch files and links resolved by the real readlink, as
/dev/tty1 -> lxc/tty1 is in an LXC container: the VM case, plain LXC
(getty@tty1 skipped, agetty in a transient unit on lxc/tty1), Proxmox
(container-getty@1 on lxc/tty1), a getty unit on another tty, none
enabled, a failed start, the wait for inithooks.service and giving up,
and the fatal paths with the Keel issues URL. 213 bats in all, total
99.75, the lowest file still `lib/init-fence.sh` at 98.81.

## Branch feat/generated-password: dialog_wrapper.py 98 percent (2026-09-30)

`libinithooks/dialog_wrapper.py` leaves the `omit` list of
`pyproject.toml` and joins `include`: it was 0 percent, with no test.
`tests/test_dialog_wrapper.py` (65 tests) drives it through
`tests/fake_dialog.py`, a stand-in for pythondialog that answers each
widget from a script and records what was shown, so no terminal is needed:
the generator (alphabet, length, classes, exclusions, the secrets module),
the generate path, the refused confirmation, the manual path and its
refusals, `offer_generate=False`, ESC (shown again in every dialog of
`get_password` and every value widget, "really quit?" on a message only),
the fallback to Manual when nothing can be generated, the height at the
dialog's own width, the logs (a file handler
at DEBUG on the root logger, as `DIALOG_DEBUG` gives `/var/log/dialog.log`,
must not contain the generated or the typed password), the screen drawn on
the terminal with a captured stdout, and the other widgets and
`validate_domain`. `tests/test_setpass.py` (2 tests) runs `bin/setpass.py`
with ESC in the password box and in the generate flow, and asserts that
chpasswd still receives the password.

Measured with `coverage run --branch --source=libinithooks,bin`: 300
statements, 4 missed, 98 percent. The missed lines are line 22 (`LOG_LEVEL`
under `DIALOG_DEBUG`, set at import) and lines 654 to 656 of `get_domain`,
a branch on a message `validate_domain` never returns, which would raise
`NameError` on `p` if it could run (inherited). Python total 99 percent,
369 passed and 3 skipped (the vocabulary tests, without `KEEL_SRC`) with
master merged, `init_lock.py` of fix/one-first-boot-run included.

## Branch fix/one-first-boot-run, second review: shell 99.71, Python 99

A pending first boot that nothing runs (the unit stopped, failed, or
skipped by its container condition) is run by keel-init through the boot
run instead of being refused; RUN_FIRSTBOOT is read by bash; a relative
dtach socket is made absolute. `libinithooks/init_lock.py` 173 statements,
36 branches, 100 percent, from 102 tests in `tests/test_init_lock.py`,
including a stopped unit, a failed one, a skipped one, and a boot run
killed in its wizard, each followed by the real `run` doing the first
boot. Python total 99. Shell unchanged: 198 bats, 99.71. Making keel-init
refuse in those states again fails four tests.

`tests/test_vocabulary.py` fails two tests locally when a sibling `keel`
checkout older than keel#48 is found by default (no `ipv6.slaac`); with
`KEEL_SRC` at current keel main, master and this branch pass. CI skips
those tests.

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
