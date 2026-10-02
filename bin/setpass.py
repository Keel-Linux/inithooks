#!/usr/bin/python3
# Copyright (c) 2010 Alon Swartz <alon@turnkeylinux.org>
"""Set account password

Arguments:
    username      username of account to set password for

Options:
    -p --pass=    if not provided, will ask interactively

Asked interactively at first boot, an account that can already log in with
a password set when the container was created (`pct create --password`, or
LXC writing /etc/shadow in the root file system before the first boot) is
offered Keep, first: the password stays as it is. Only one the image did
not ship: `passwd -S` says it is usable, the image carries its build date
(/etc/keel/build-date, written by common's seal-root, which fails a build
whose root is not locked) and the password last changed on or after it,
and the shadow field is neither empty nor a placeholder older images
shipped. The field is compared and never printed or logged. keel-init
(_TURNKEY_INIT) asks as before.
"""

import datetime
import os
import sys
import getopt
import subprocess
import signal
from typing import NoReturn

# `passwd -S` status of an account that can log in with a password: L is
# locked (a hash starting with ! or *, which is how images ship root), NP
# has none.
USABLE = "P"
PASSWD_TIMEOUT = 10
# systemd writes it in a container, whatever the container manager
CONTAINER_MARKER = "/run/systemd/container"
# Where the account database and the image's build date are read; the
# variables point a test at scratch files.
SHADOW = "/etc/shadow"
BUILD_DATE = "/etc/keel/build-date"
SHADOW_VAR = "INITHOOKS_SHADOW"
BUILD_DATE_VAR = "INITHOOKS_BUILD_DATE"
EPOCH = datetime.date(1970, 1, 1)
# Password fields images shipped: the crypt() of the empty string, in five
# older WordPress images.
PLACEHOLDERS = frozenset({"U6aMy0wojraho"})
EXPLICIT_RUN = "_TURNKEY_INIT"
# Each fits beside the Generate tag in the widest menu dialog_wrapper draws
KEEP_CONTAINER = "Password set when the container was created (recommended)"
KEEP_MACHINE = "Password already set on this machine (recommended)"


def fatal(
    msg: str | subprocess.TimeoutExpired | subprocess.CalledProcessError,
) -> NoReturn:
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def usage(msg: str | getopt.GetoptError = "") -> NoReturn:
    if msg:
        print(f"Error: {msg}", file=sys.stderr)
    print(f"Syntax: {sys.argv[0]} <username> [options]", file=sys.stderr)
    print(__doc__, file=sys.stderr)
    sys.exit(1)


def password_usable(username: str) -> bool:
    """Whether USERNAME can log in with a password now, by `passwd -S`

    Anything but a clear yes (passwd missing, failing, slow, or another
    status) is no, and the screen is the one without Keep.
    """
    try:
        out = subprocess.run(
            ["passwd", "-S", username],
            capture_output=True,
            text=True,
            check=False,
            timeout=PASSWD_TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    fields = out.stdout.split()
    return out.returncode == 0 and len(fields) > 1 and fields[1] == USABLE


def build_day(path: str) -> int | None:
    """The day the image was built, in days since 1970-01-01 as shadow
    counts them, from PATH (YYYY-MM-DD); None when it cannot be read"""
    try:
        with open(path) as fob:
            built = datetime.date.fromisoformat(fob.read().strip())
    except (OSError, ValueError):
        return None
    return (built - EPOCH).days


def set_after_build(username: str) -> bool:
    """Whether USERNAME's password was set on this machine, not shipped

    Its shadow entry must hold a field that is neither empty nor one of
    PLACEHOLDERS, last changed on or after the build day. The same day
    counts: shadow keeps days, a container is often created the day its
    image was built, and the image left the build with root locked.
    """
    built = build_day(os.environ.get(BUILD_DATE_VAR, BUILD_DATE))
    if built is None:
        return False
    try:
        with open(os.environ.get(SHADOW_VAR, SHADOW)) as fob:
            entry = next(
                (line.rstrip("\n").split(":") for line in fob
                 if line.split(":", 1)[0] == username),
                None,
            )
    except OSError:
        return False
    if entry is None or len(entry) < 3:
        return False
    if not entry[1] or entry[1] in PLACEHOLDERS:
        return False
    try:
        return int(entry[2]) >= built > 0
    except ValueError:
        return False


def keep_offer(username: str) -> str:
    """The description of Keep for USERNAME, or "" for no Keep"""
    if os.environ.get(EXPLICIT_RUN) or not password_usable(username):
        return ""
    if not set_after_build(username):
        return ""
    if os.path.exists(CONTAINER_MARKER):
        return KEEP_CONTAINER
    return KEEP_MACHINE


def main():
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        opts, args = getopt.gnu_getopt(sys.argv[1:], "hp:", ["help", "pass="])
    except getopt.GetoptError as e:
        usage(e)

    if len(args) != 1:
        usage()

    username = args[0]
    password = ""
    for opt, val in opts:
        if opt in ("-h", "--help"):
            usage()
        elif opt in ("-p", "--pass"):
            password = val

    if not password:
        from libinithooks.dialog_wrapper import Dialog

        d = Dialog("Keel Linux - First boot configuration")
        password = d.get_password(
            f"{username.capitalize()} Password",
            f"Please enter new password for the {username} account.",
            keep=keep_offer(username),
        )
        if password is None:
            print(
                f"setpass: the {username} password set before the first"
                " boot was kept",
                file=sys.stderr,
            )
            return

    assert password
    command = ["chpasswd"]
    std_input = ":".join([username, password])

    try:
        p = subprocess.Popen(command, stdin=subprocess.PIPE, shell=False)
        p.communicate(std_input.encode(sys.stdin.encoding))
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as e:
        fatal(e)


if __name__ == "__main__":
    main()
