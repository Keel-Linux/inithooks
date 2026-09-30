"""One first boot run at a time

The boot run (/usr/lib/inithooks/run, from inithooks.service) and keel-init
(turnkey-init is a link to it) both run the firstboot hooks. Two runs at
once configure the machine twice: on 2026-09-30 a keel-init started from
`pct enter` set the root password and hung in the database password dialog
while the boot run was still waiting for the root password on the console.

Both take an exclusive flock(2) on one file, /run/inithooks.lock
(INITHOOKS_LOCK overrides it), for as long as hooks run. The lock belongs to
an open file description, so the kernel drops it when the last process
holding that description exits, however it exits: a crashed or killed run
cannot leave it held. The file stays behind with the pid of the last holder
in it; the pid is only read while the lock is held, to say which run it is.

keel-init does not wait for the lock, it refuses and says where the run in
progress is waiting. The boot run waits, since it cannot be asked to come
back later (lib/init-lock.sh).
"""

import fcntl
import os
import subprocess
from dataclasses import dataclass

LOCK_PATH = "/run/inithooks.lock"

# EX_TEMPFAIL of sysexits.h: try again later, when the run in progress is
# finished
EXIT_BUSY = 75

# systemd-detect-virt names of the containers Proxmox and plain LXC run
LXC = ("lxc", "lxc-libvirt")

HINT_LXC = "pct console <ctid> on Proxmox, or lxc-console -n <name> on LXC"
HINT_VM = "the VM's console"
HINT_ANY = (
    "pct console <ctid> on Proxmox, lxc-console -n <name> on LXC,"
    " or the VM's console"
)


@dataclass(frozen=True)
class Run:
    """A first boot run in progress; pid is None when it cannot be read"""

    pid: int | None


class Busy(Exception):
    """The lock is held by another run"""

    def __init__(self, run: Run) -> None:
        super().__init__(f"a first boot run is in progress (pid {run.pid})")
        self.run = run


def lock_path() -> str:
    return os.environ.get("INITHOOKS_LOCK") or LOCK_PATH


def _read_pid(fd: int) -> int | None:
    text = os.pread(fd, 32, 0).decode("ascii", "replace").strip()
    return int(text) if text.isdigit() else None


def acquire(path: str) -> int:
    """Takes the lock without waiting and returns its descriptor

    Raises Busy when another run holds it. The descriptor is not inherited
    by child processes (PEP 446), so a hook that leaves a daemon behind
    does not keep the lock with it.
    """
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        run = Run(_read_pid(fd))
        os.close(fd)
        raise Busy(run) from None
    os.ftruncate(fd, 0)
    os.pwrite(fd, f"{os.getpid()}\n".encode(), 0)
    return fd


def release(fd: int) -> None:
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)


def in_progress(path: str) -> Run | None:
    """The run holding the lock, or None when no run is in progress

    Never creates the file: no file means no run has started this boot.
    """
    try:
        fd = os.open(path, os.O_RDONLY)
    except FileNotFoundError:
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        return Run(_read_pid(fd))
    else:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return None
    finally:
        os.close(fd)


def detect_virt() -> str:
    """systemd-detect-virt's answer, or '' when it cannot be asked"""
    try:
        done = subprocess.run(
            ["systemd-detect-virt"], capture_output=True, text=True
        )
    except OSError:
        return ""
    return done.stdout.strip()


def console_hint(virt: str) -> str:
    if virt in LXC:
        return HINT_LXC
    if virt and virt != "none":
        return HINT_VM
    return HINT_ANY


def wait_message(run: Run, virt: str) -> str:
    """Where the first boot wizard of RUN waits, for an operator"""
    pid = f" (pid {run.pid})" if run.pid else ""
    return (
        f"the first-boot wizard is running on the console{pid};"
        f" answer it there: {console_hint(virt)}."
    )
