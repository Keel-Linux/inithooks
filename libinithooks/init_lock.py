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
cannot leave it held.

The holder describes itself in the file, one key=value per line (kind, pid,
tty, dtach, phase, hook, preseeded; lib/init-lock.sh writes the boot run's),
so that a refusal can say where that run is: a wizard waiting on the
console, a keel-init in a dtach session somebody lost, or a run nobody has
to answer. The description is only read while the lock is held.

keel-init does not wait for the lock, it refuses and says where the run in
progress is. The boot run waits, since it cannot be asked to come back
later (lib/init-lock.sh). keel-init also refuses before the boot run of the
first boot has run (boot_pending): hooks under keel-init skip what only a
first boot does, and the boot run would then find the first boot done.
"""

import fcntl
import os
import subprocess
import time
from dataclasses import dataclass

LOCK_PATH = "/run/inithooks.lock"
DEFAULT_PATH = "/etc/default/inithooks"
# written by run once its hooks are done, every boot
COMPLETE_PATH = "/run/inithooks-complete"

# EX_TEMPFAIL of sysexits.h: try again later, when the run in progress is
# finished
EXIT_BUSY = 75

# the login message probes the lock with a shared lock of its own; a
# keel-init started in that instant tries again rather than refusing
ATTEMPTS = 10
INTERVAL = 0.05

# systemd-detect-virt names of the containers Proxmox and plain LXC run
LXC = ("lxc", "lxc-libvirt")

HINT_LXC = "pct console <ctid> on Proxmox, or lxc-console -n <name> on LXC"
HINT_VM = "the VM's console"
HINT_ANY = (
    "pct console <ctid> on Proxmox, lxc-console -n <name> on LXC,"
    " or the VM's console"
)

# how far up the process tree a dtach master is looked for: keel-init's
# parent is the shell dtach started
DTACH_DEPTH = 8
DTACH_CREATE = ("-A", "-c", "-n", "-N")


@dataclass(frozen=True)
class Run:
    """A first boot run, as its holder described it; pid is None when it
    cannot be read, and kind is empty when nothing says what it is"""

    pid: int | None
    kind: str = ""
    tty: str = ""
    dtach: str = ""
    phase: str = ""
    hook: str = ""
    preseeded: bool = False


class Busy(Exception):
    """The lock is held by another run"""

    def __init__(self, run: Run) -> None:
        super().__init__(f"a first boot run is in progress (pid {run.pid})")
        self.run = run


def lock_path() -> str:
    return os.environ.get("INITHOOKS_LOCK") or LOCK_PATH


def parse(text: str) -> Run:
    """The Run described by the text of a lock file"""
    fields = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            fields[key.strip()] = value.strip()
    pid = fields.get("pid", "")
    return Run(
        pid=int(pid) if pid.isdigit() else None,
        kind=fields.get("kind", ""),
        tty=fields.get("tty", ""),
        dtach=fields.get("dtach", ""),
        phase=fields.get("phase", ""),
        hook=fields.get("hook", ""),
        preseeded=fields.get("preseeded", "") == "yes",
    )


def describe(run: Run) -> str:
    return (
        f"kind={run.kind}\npid={run.pid or ''}\ntty={run.tty}\n"
        f"dtach={run.dtach}\nphase={run.phase}\nhook={run.hook}\n"
        f"preseeded={'yes' if run.preseeded else ''}\n"
    )


def _read(fd: int) -> Run:
    return parse(os.pread(fd, 4096, 0).decode("utf-8", "replace"))


def acquire(
    path: str,
    holder: Run | None = None,
    attempts: int = ATTEMPTS,
    interval: float = INTERVAL,
) -> int:
    """Takes the lock, describes HOLDER in it, and returns its descriptor

    Tries ATTEMPTS times, INTERVAL seconds apart, then raises Busy. The
    descriptor is not inherited by child processes (PEP 446), so a hook
    that leaves a daemon behind does not keep the lock with it.
    """
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    attempt = 1
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if attempt >= attempts:
                run = _read(fd)
                os.close(fd)
                raise Busy(run) from None
            attempt += 1
            time.sleep(interval)
    os.ftruncate(fd, 0)
    os.pwrite(fd, describe(holder or Run(os.getpid())).encode(), 0)
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
        return _read(fd)
    else:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return None
    finally:
        os.close(fd)


def boot_pending(default: str, complete: str) -> bool:
    """True while the first boot's own run has not finished this boot

    That is RUN_FIRSTBOOT=true in DEFAULT (read the way run reads it,
    case aside) and no COMPLETE marker, which run writes when its hooks
    are done.
    """
    if os.path.exists(complete):
        return False
    try:
        with open(default) as fob:
            lines = fob.read().splitlines()
    except FileNotFoundError:
        return False
    value = ""
    for line in lines:
        key, sep, rest = line.strip().partition("=")
        if sep and key == "RUN_FIRSTBOOT":
            value = rest.strip().strip("\"'")
    return value.lower() == "true"


def default_path() -> str:
    return os.environ.get("INITHOOKS_DEFAULT") or DEFAULT_PATH


def complete_path() -> str:
    return os.environ.get("INITHOOKS_COMPLETE") or COMPLETE_PATH


def _ppid(pid: int, proc: str) -> int:
    with open(os.path.join(proc, str(pid), "stat")) as fob:
        # the command name, in parentheses, may itself hold spaces
        return int(fob.read().rpartition(")")[2].split()[1])


def _cmdline(pid: int, proc: str) -> list[str]:
    with open(os.path.join(proc, str(pid), "cmdline"), "rb") as fob:
        return fob.read().decode("utf-8", "replace").split("\0")


def dtach_socket(pid: int, proc: str = "/proc") -> str:
    """The socket of the dtach session PID runs in, or ''"""
    for _ in range(DTACH_DEPTH):
        try:
            argv = _cmdline(pid, proc)
            if (
                os.path.basename(argv[0]) == "dtach"
                and len(argv) > 2
                and argv[1] in DTACH_CREATE
            ):
                return argv[2]
            pid = _ppid(pid, proc)
        except (OSError, ValueError, IndexError):
            return ""
        if pid <= 1:
            return ""
    return ""


def current_tty() -> str:
    try:
        return os.ttyname(0)
    except OSError:
        return ""


def this_keel_init() -> Run:
    """How a keel-init describes itself in the lock"""
    pid = os.getpid()
    return Run(
        pid=pid, kind="keel-init", tty=current_tty(), dtach=dtach_socket(pid)
    )


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


def _where(run: Run) -> str:
    """ (pid N, on TTY, in HOOK), each part only when known"""
    parts = [f"pid {run.pid}"] if run.pid else []
    if run.tty:
        parts.append(f"on {run.tty}")
    if run.hook:
        parts.append(f"in {run.hook}")
    return f" ({', '.join(parts)})" if parts else ""


def wait_message(run: Run, virt: str) -> str:
    """Where RUN is, and what an operator should do about it"""
    pid = f" (pid {run.pid})" if run.pid else ""
    if run.kind == "keel-init":
        if run.dtach:
            return (
                f"keel-init is already running{pid} in the dtach session"
                f" {run.dtach}; attach to it with: dtach -a {run.dtach}"
            )
        if run.tty:
            return (
                f"keel-init is already running{pid} on {run.tty};"
                " answer it there, or wait for it to finish."
            )
        return f"keel-init is already running{pid}; wait for it to finish."
    if run.kind == "run" and run.phase == "everyboot":
        return (
            f"the boot run is running its everyboot hooks{_where(run)};"
            " nothing waits for an answer, wait for it to finish."
        )
    if run.kind == "run" and run.preseeded:
        return (
            f"the first boot is running from its preseed{_where(run)};"
            " nothing waits for an answer, wait for it to finish."
        )
    return (
        f"the first-boot wizard is running on the console{_where(run)};"
        f" answer it there: {console_hint(virt)}."
    )


def pending_message(virt: str) -> str:
    """Why keel-init refuses before the boot run of the first boot"""
    return (
        "the first boot has not finished yet: its own run starts at boot"
        " and asks its questions on the console, answer them there:"
        f" {console_hint(virt)}. keel-init reconfigures the machine once"
        " that run has finished."
    )
