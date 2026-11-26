#!/usr/bin/python3
# Copyright (c) 2026 Keel Linux maintainers
"""Read the cloud-init drive of a VM, without cloud-init

Run by firstboot.d/02cloud-drive (--firstboot) and everyboot.d/02cloud-drive
(--clone). The drive is the Proxmox cloud-init drive: NoCloud (label
cidata) or ConfigDrive (label config-2), mounted read-only for the read
and unmounted after it. Nothing from the drive is run: see
libinithooks/cloud_drive.py for what is read and how it is validated.

Options:
    --firstboot     the first boot: the SSH keys go to root (29sudoadmin
                    copies them to admin when SUDOADMIN is on); the
                    password is set and ROOT_PASS=KEEP added to the
                    inithooks conf, so 30rootpass does not ask; FQDN= or
                    HOSTNAME= is added for 09hostname and 31fqdn. With a
                    key, the boot run asks nothing on the console: keel-init
                    asks at the first login (lib/console.sh,
                    INITHOOKS_SSH_ANSWER).
    --clone         a later boot: when the instance-id is not the one
                    recorded (a clone, or a changed cloud-init setting),
                    the SSH keys are added, and HOSTNAME=, FQDN=,
                    INSTANCE_ID= and NAME= are printed for the hook.
                    HOSTNAME= and FQDN= are empty unless the machine is to
                    be renamed: only when the drive's name is not the one
                    recorded with the last instance-id. With no instance-id
                    recorded (a machine first booted without a drive, or
                    before this command), the machine keeps its name. The
                    hook renames the machine, then records with --record-id
    --record-id=ID  record ID as the instance-id the machine has applied,
                    and --name=NAME as the drive's name with it
    --sudoadmin     SUDOADMIN is on: no password is set from the drive at
                    the first boot (29sudoadmin makes admin later), and on
                    a clone the keys go to admin

Every case where there is nothing to do exits 0: a container, no drive,
an instance-id already applied, or under keel-init (_TURNKEY_INIT).

Environment (for tests; the defaults are the machine's paths):
    INITHOOKS_CONF          the inithooks conf (/etc/inithooks.conf)
    INITHOOKS_SSH_ANSWER    the marker lib/console.sh reads
                            (/run/inithooks/ssh-answer)
    CLOUD_DRIVE_STATE       the recorded instance-id, and the drive's
                            name on the next line
                            (/var/lib/inithooks/cloud-drive/instance-id)
    CLOUD_DRIVE_CONTAINER   the container marker (/run/systemd/container)
    CLOUD_DRIVE_ROOT        a directory to read as the mounted drive,
                            instead of blkid and mount
    CLOUD_DRIVE_KIND        the kind of CLOUD_DRIVE_ROOT (nocloud)
    CLOUD_DRIVE_HOME        the home of the account keys go to
"""

import contextlib
import getopt
import os
import pwd
import subprocess
import sys
import tempfile
from collections.abc import Iterator
from typing import NoReturn

from libinithooks import cloud_drive

CONF = "/etc/inithooks.conf"
SSH_ANSWER = "/run/inithooks/ssh-answer"
STATE = "/var/lib/inithooks/cloud-drive/instance-id"
CONTAINER = "/run/systemd/container"
TIMEOUT = 30
ADMIN = "admin"
ROOT = "root"
SSH_ANSWER_TEXT = (
    "an SSH key came from the cloud-init drive: keel-init asks the first"
    " boot questions at the first login\n"
)


def say(line: str) -> None:
    """One line for the journal (inithooks.service sends stderr there)"""
    print(f"cloud-drive: {line}", file=sys.stderr)


def fatal(msg: object) -> NoReturn:
    say(f"error: {msg}")
    sys.exit(1)


def usage(msg: str | getopt.GetoptError = "") -> NoReturn:
    if msg:
        print(f"Error: {msg}", file=sys.stderr)
    print(f"Syntax: {sys.argv[0]} --firstboot|--clone|--record-id=ID [--name=NAME]"
          " [--sudoadmin]", file=sys.stderr)
    print(__doc__, file=sys.stderr)
    sys.exit(1)


def env(name: str, default: str) -> str:
    return os.environ.get(name) or default


def run(cmd: list[str], data: bytes | None = None
        ) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, input=data, capture_output=True,
                          timeout=TIMEOUT, check=False)


def blkid(label: str) -> list[str]:
    """The devices whose file system has LABEL"""
    done = run(["blkid", "-o", "device", "-t", f"LABEL={label}"])
    return done.stdout.decode().split() if done.returncode == 0 else []


@contextlib.contextmanager
def mounted(device: str) -> Iterator[str]:
    """DEVICE mounted read-only, with nothing on it executable"""
    point = tempfile.mkdtemp(prefix="cloud-drive-")
    try:
        done = run(["mount", "-o", "ro,nosuid,nodev,noexec", device, point])
        if done.returncode != 0:
            raise cloud_drive.DriveError(
                f"cannot mount {device}: {done.stderr.decode().strip()}")
        try:
            yield point
        finally:
            run(["umount", point])
    finally:
        os.rmdir(point)


def read() -> cloud_drive.Settings | None:
    """The settings of the drive, None when there is no drive"""
    if os.path.exists(env("CLOUD_DRIVE_CONTAINER", CONTAINER)):
        return None
    root = os.environ.get("CLOUD_DRIVE_ROOT")
    if root:
        return cloud_drive.read_drive(
            root, env("CLOUD_DRIVE_KIND", cloud_drive.NOCLOUD))
    found = cloud_drive.find_device(blkid)
    if found is None:
        return None
    device, kind = found
    say(f"reading the cloud-init drive {device} ({kind})")
    with mounted(device) as point:
        return cloud_drive.read_drive(point, kind)


def account(user: str) -> tuple[str, int, int]:
    """(home, uid, gid) of USER"""
    entry = pwd.getpwnam(user)
    return (env("CLOUD_DRIVE_HOME", entry.pw_dir), entry.pw_uid,
            entry.pw_gid)


def install_keys(settings: cloud_drive.Settings, user: str) -> int:
    home, uid, gid = account(user)
    added = cloud_drive.authorized_keys(home, uid, gid, settings.keys)
    say(f"{added} of {len(settings.keys)} SSH keys added for {user}")
    return added


def set_password(settings: cloud_drive.Settings, user: str) -> None:
    """The password by chpasswd, -e for a hash; on standard input, never
    on the command line"""
    cmd = ["chpasswd", "-e"] if settings.hashed else ["chpasswd"]
    done = run(cmd, cloud_drive.chpasswd_input(user, settings.password))
    if done.returncode != 0:
        raise cloud_drive.DriveError(f"chpasswd failed for {user}")
    say(f"the {user} password was set from the drive")


def check_user(settings: cloud_drive.Settings, target: str) -> None:
    if settings.user and settings.user not in (ROOT, target):
        say(f"user {settings.user}: no account is made from the drive, the"
            f" keys and the password go to {target}")


def firstboot(settings: cloud_drive.Settings, sudoadmin: bool) -> None:
    check_user(settings, ADMIN if sudoadmin else ROOT)
    notes: list[str] = []
    conf_path = env("INITHOOKS_CONF", CONF)
    conf = cloud_drive.read_text(conf_path)
    password_set = False
    if settings.password and sudoadmin:
        say("SUDOADMIN is on: the password is not set from the drive,"
            " 30rootpass sets the admin password")
    elif settings.password and cloud_drive.conf_sets(conf, "ROOT_PASS"):
        say("ROOT_PASS is preseeded or described, the drive's password is"
            " not used")
    elif settings.password:
        set_password(settings, ROOT)
        password_set = True
    # root's keys: 29sudoadmin, after this hook, merges them into admin's
    install_keys(settings, ROOT)
    if settings.keys:
        cloud_drive.write_text(env("INITHOOKS_SSH_ANSWER", SSH_ANSWER),
                               SSH_ANSWER_TEXT)
    lines = cloud_drive.conf_lines(settings, conf, password_set, notes)
    cloud_drive.append_conf(conf_path, lines)
    for note in notes:
        say(note)
    for line in lines:
        say(f"added to {conf_path}: {line.split('=', 1)[0]}=")
    record(settings.instance_id, drive_name(settings))


def clone(settings: cloud_drive.Settings, sudoadmin: bool) -> None:
    target = ROOT
    if sudoadmin:
        try:
            pwd.getpwnam(ADMIN)
            target = ADMIN
        except KeyError:
            pass
    check_user(settings, target)
    install_keys(settings, target)
    name = drive_name(settings)
    last_id, last_name = recorded()
    rename = bool(last_id) and bool(name) and name != last_name
    if not rename:
        say("the machine keeps its name: the drive's name is the one"
            " applied before, or none was applied from a drive")
    print(f"HOSTNAME={settings.hostname if rename else ''}")
    print(f"FQDN={settings.fqdn if rename else ''}")
    print(f"INSTANCE_ID={settings.instance_id}")
    print(f"NAME={name}")


def drive_name(settings: cloud_drive.Settings) -> str:
    return settings.fqdn or settings.hostname


def recorded() -> tuple[str, str]:
    """(instance-id, drive's name) last applied, "" for each not there"""
    lines = cloud_drive.read_text(env("CLOUD_DRIVE_STATE", STATE)
                                  ).splitlines()
    lines += ["", ""]
    return lines[0].strip(), lines[1].strip()


def record(instance_id: str, name: str) -> None:
    if not cloud_drive.INSTANCE_ID_RE.match(instance_id):
        fatal(f"not an instance-id: {instance_id!r}")
    if name and cloud_drive.fqdn.normalize(name) != (name, None):
        fatal(f"not a host name: {name!r}")
    cloud_drive.write_text(env("CLOUD_DRIVE_STATE", STATE),
                           f"{instance_id}\n{name}\n")


def main() -> None:
    try:
        opts, args = getopt.gnu_getopt(
            sys.argv[1:], "h",
            ["help", "firstboot", "clone", "record-id=", "name=",
             "sudoadmin"])
    except getopt.GetoptError as e:
        usage(e)
    if args:
        usage()
    action = record_id = name = ""
    sudoadmin = False
    for opt, val in opts:
        if opt in ("-h", "--help"):
            usage()
        elif opt == "--sudoadmin":
            sudoadmin = True
        elif opt == "--name":
            name = val
        elif opt == "--record-id":
            action, record_id = opt, val
        else:
            action = opt
    if not action:
        usage("one of --firstboot, --clone or --record-id is needed")
    if action == "--record-id":
        record(record_id, name)
        return
    if os.environ.get("_TURNKEY_INIT"):
        return
    try:
        settings = read()
        if settings is None:
            return
        for note in settings.notes:
            say(note)
        if settings.instance_id == recorded()[0]:
            say(f"instance-id {settings.instance_id} is already applied")
            return
        (firstboot if action == "--firstboot" else clone)(settings,
                                                           sudoadmin)
    except (cloud_drive.DriveError, OSError, KeyError,
            subprocess.TimeoutExpired) as e:
        fatal(e)


if __name__ == "__main__":
    main()
