"""One first boot run at a time (Keel-Linux/inithooks#24), and keel-init
as the command with turnkey-init a link to it (Keel-Linux/inithooks#22)

The lock is the real flock(2) on a scratch file. flock locks belong to an
open file description, so two os.open calls in this process conflict the
way two processes do; where a separate process matters (a killed holder,
the boot run waiting in a hook) a real one is started.

keel-init is loaded from the checkout with conffile, which comes from
turnkey-pylib on an appliance, replaced by a stub that reads
INITHOOKS_PATH from the test.
"""

import fcntl
import importlib.machinery
import importlib.util
import os
import signal
import subprocess
import sys
import textwrap
import threading
import time
import types
from os.path import abspath, dirname, join

import pytest

REPO = dirname(dirname(abspath(__file__)))
sys.path.insert(0, REPO)

from libinithooks import init_lock  # noqa: E402

KEEL_INIT = join(REPO, "keel-init")
TURNKEY_INIT = join(REPO, "turnkey-init")
RUN = join(REPO, "run")

CONFFILE_STUB = textwrap.dedent(
    """\
    import os


    class ConfFile:
        def __init__(self):
            self.inithooks_path = os.environ["TEST_INITHOOKS_PATH"]
    """
)


def eventually(check, timeout=10.0):
    deadline = time.monotonic() + timeout
    while not check():
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out waiting for {check}")
        time.sleep(0.01)


def executable(path, body):
    with open(path, "w") as fob:
        fob.write(body)
    os.chmod(path, 0o755)


@pytest.fixture
def lock(tmp_path, monkeypatch):
    path = str(tmp_path / "inithooks.lock")
    monkeypatch.setenv("INITHOOKS_LOCK", path)
    return path


@pytest.fixture
def stubs(tmp_path, monkeypatch):
    """A directory first in PATH for command stubs"""
    directory = tmp_path / "stubs"
    directory.mkdir()
    monkeypatch.setenv("PATH", f"{directory}:{os.environ['PATH']}")
    return directory


@pytest.fixture
def keel_init(tmp_path, monkeypatch):
    """The keel-init module, run as root, with hooks under tmp_path/lib,
    on a machine whose first boot is done (module.default holds
    RUN_FIRSTBOOT, module.complete is run's marker, absent)"""
    default = tmp_path / "default-inithooks"
    default.write_text("RUN_FIRSTBOOT=false\n")
    complete = tmp_path / "inithooks-complete"
    monkeypatch.setenv("INITHOOKS_DEFAULT", str(default))
    monkeypatch.setenv("INITHOOKS_COMPLETE", str(complete))
    stub = types.ModuleType("conffile")
    exec(CONFFILE_STUB, stub.__dict__)
    monkeypatch.setitem(sys.modules, "conffile", stub)
    firstboot = tmp_path / "lib" / "firstboot.d"
    firstboot.mkdir(parents=True)
    monkeypatch.setenv("TEST_INITHOOKS_PATH", str(tmp_path / "lib"))
    loader = importlib.machinery.SourceFileLoader("keel_init", KEEL_INIT)
    spec = importlib.util.spec_from_loader("keel_init", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    monkeypatch.setattr(module.os, "geteuid", lambda: 0)
    monkeypatch.setattr(sys, "argv", ["keel-init"])
    module.firstboot = firstboot
    module.default = default
    module.complete = complete
    return module


def hook(directory, name, body):
    executable(str(directory / name), "#!/bin/bash\n" + body + "\n")


def unit(stubs, state, jobs=""):
    """A systemctl stub for which inithooks.service is in STATE, with the
    queued JOBS; anything else it is asked is answered 'running', as the
    runner's is-system-running wants"""
    executable(
        str(stubs / "systemctl"),
        textwrap.dedent(
            f"""\
            #!/bin/sh
            case "$1" in
                is-active) echo {state}; [ {state} = active ] ;;
                list-jobs) printf '%s' '{jobs}' ;;
                *) echo running ;;
            esac
            """
        ),
    )


# the library


def test_lock_path_defaults_to_run(monkeypatch):
    monkeypatch.delenv("INITHOOKS_LOCK", raising=False)
    assert init_lock.lock_path() == "/run/inithooks.lock"


def test_lock_path_from_environment(lock):
    assert init_lock.lock_path() == lock


def read_lock(path):
    with open(path) as fob:
        return init_lock.parse(fob.read())


def test_acquire_writes_the_pid_and_holds(lock):
    fd = init_lock.acquire(lock)
    try:
        assert read_lock(lock) == init_lock.Run(os.getpid())
        assert init_lock.in_progress(lock) == init_lock.Run(os.getpid())
    finally:
        init_lock.release(fd)


def test_acquire_describes_the_holder(lock):
    holder = init_lock.Run(
        pid=4242, kind="keel-init", tty="/dev/pts/3", dtach="/root/.d"
    )
    fd = init_lock.acquire(lock, holder)
    try:
        assert init_lock.in_progress(lock) == holder
    finally:
        init_lock.release(fd)


def test_acquire_replaces_a_longer_stale_description(lock):
    with open(lock, "w") as fob:
        fob.write("kind=run\npid=123456789\nhook=30rootpass\n" * 20)
    fd = init_lock.acquire(lock)
    init_lock.release(fd)
    assert read_lock(lock) == init_lock.Run(os.getpid())


def test_acquire_tries_again_while_a_probe_holds_the_lock(lock):
    # the login message's probe holds a shared lock for an instant
    probe = os.open(lock, os.O_RDONLY | os.O_CREAT)
    fcntl.flock(probe, fcntl.LOCK_SH)
    timer = threading.Timer(0.1, os.close, [probe])
    timer.start()
    try:
        fd = init_lock.acquire(lock, attempts=100, interval=0.01)
        init_lock.release(fd)
    finally:
        timer.join()


def test_acquire_tries_at_least_once(lock):
    init_lock.release(init_lock.acquire(lock, attempts=0))
    fd = init_lock.acquire(lock)
    try:
        with pytest.raises(init_lock.Busy):
            init_lock.acquire(lock, attempts=0)
    finally:
        init_lock.release(fd)


def test_parse_and_describe_agree():
    run = init_lock.Run(
        pid=260,
        kind="run",
        tty="/dev/tty1",
        phase="firstboot",
        hook="30rootpass",
        preseeded=True,
    )
    assert init_lock.parse(init_lock.describe(run)) == run


@pytest.mark.parametrize(
    "text, run",
    [
        ("", init_lock.Run(None)),
        ("260\n", init_lock.Run(None)),
        ("pid=abc\nkind=run\n", init_lock.Run(None, kind="run")),
        ("pid=7\npreseeded=\n", init_lock.Run(7)),
        (" pid = 7 \nnoise\n", init_lock.Run(7)),
    ],
)
def test_parse_what_the_file_may_hold(text, run):
    assert init_lock.parse(text) == run


def test_acquire_refuses_while_held_and_names_the_holder(lock):
    fd = init_lock.acquire(lock)
    try:
        with pytest.raises(init_lock.Busy) as busy:
            init_lock.acquire(lock)
        assert busy.value.run == init_lock.Run(os.getpid())
        assert str(os.getpid()) in str(busy.value)
    finally:
        init_lock.release(fd)


def test_busy_without_a_readable_pid(lock):
    fd = init_lock.acquire(lock)
    os.ftruncate(fd, 0)
    try:
        with pytest.raises(init_lock.Busy) as busy:
            init_lock.acquire(lock)
        assert busy.value.run == init_lock.Run(None)
    finally:
        init_lock.release(fd)


def test_release_lets_the_next_run_in(lock):
    init_lock.release(init_lock.acquire(lock))
    init_lock.release(init_lock.acquire(lock))
    assert init_lock.in_progress(lock) is None


def test_in_progress_never_creates_the_file(lock):
    assert init_lock.in_progress(lock) is None
    assert not os.path.exists(lock)


def test_in_progress_of_a_lock_nobody_holds(lock):
    init_lock.release(init_lock.acquire(lock))
    assert init_lock.in_progress(lock) is None


def holder(lock, *, daemon=False):
    """A separate process that takes the lock and waits; with daemon, it
    leaves a child behind and exits"""
    code = textwrap.dedent(
        f"""\
        import subprocess, sys, time
        sys.path.insert(0, {REPO!r})
        from libinithooks import init_lock
        init_lock.acquire({lock!r})
        if {daemon!r}:
            child = subprocess.Popen(["sleep", "30"], close_fds=False)
            print(child.pid, flush=True)
            sys.exit(0)
        print("held", flush=True)
        time.sleep(30)
        """
    )
    return subprocess.Popen(
        [sys.executable, "-c", code], stdout=subprocess.PIPE, text=True
    )


def test_a_killed_holder_does_not_keep_the_lock(lock):
    proc = holder(lock)
    assert proc.stdout.readline() == "held\n"
    assert init_lock.in_progress(lock) == init_lock.Run(proc.pid)

    proc.send_signal(signal.SIGKILL)
    proc.wait()

    assert init_lock.in_progress(lock) is None


def test_a_child_left_behind_does_not_keep_the_lock(lock):
    proc = holder(lock, daemon=True)
    child = int(proc.stdout.readline())
    proc.wait()
    try:
        os.kill(child, 0)
        assert init_lock.in_progress(lock) is None
    finally:
        os.kill(child, signal.SIGTERM)


def test_detect_virt_answers_what_systemd_says(stubs):
    executable(str(stubs / "systemd-detect-virt"), "#!/bin/sh\necho lxc\n")
    assert init_lock.detect_virt() == "lxc"


def test_detect_virt_without_the_command(tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", str(tmp_path))
    assert init_lock.detect_virt() == ""


@pytest.mark.parametrize(
    "virt, hint",
    [
        ("lxc", init_lock.HINT_LXC),
        ("lxc-libvirt", init_lock.HINT_LXC),
        ("kvm", init_lock.HINT_VM),
        ("qemu", init_lock.HINT_VM),
        ("none", init_lock.HINT_ANY),
        ("", init_lock.HINT_ANY),
    ],
)
def test_console_hint(virt, hint):
    assert init_lock.console_hint(virt) == hint


def test_wait_message_in_a_container():
    message = init_lock.wait_message(init_lock.Run(260), "lxc")
    assert message == (
        "the first-boot wizard is running on the console (pid 260);"
        " answer it there: pct console <ctid> on Proxmox,"
        " or lxc-console -n <name> on LXC."
    )


def test_wait_message_without_a_pid_on_bare_metal():
    message = init_lock.wait_message(init_lock.Run(None), "none")
    assert message == (
        "the first-boot wizard is running on the console;"
        " answer it there: pct console <ctid> on Proxmox,"
        " lxc-console -n <name> on LXC, or the VM's console."
    )


def test_wait_message_of_the_boot_wizard_names_its_tty_and_hook():
    run = init_lock.Run(
        260, kind="run", tty="/dev/pts/1", phase="firstboot", hook="30rootpass"
    )
    assert init_lock.wait_message(run, "lxc") == (
        "the first-boot wizard is running on the console"
        " (pid 260, on /dev/pts/1, in 30rootpass); answer it there:"
        " pct console <ctid> on Proxmox, or lxc-console -n <name> on LXC."
    )


def test_wait_message_of_a_preseeded_boot_run():
    run = init_lock.Run(
        260, kind="run", phase="firstboot", hook="95secupdates", preseeded=True
    )
    assert init_lock.wait_message(run, "lxc") == (
        "the first boot is running from its preseed"
        " (pid 260, in 95secupdates); nothing waits for an answer,"
        " wait for it to finish."
    )


def test_wait_message_of_the_everyboot_phase():
    run = init_lock.Run(
        260, kind="run", tty="/dev/tty1", phase="everyboot", hook="01empty"
    )
    assert init_lock.wait_message(run, "kvm") == (
        "the boot run is running its everyboot hooks"
        " (pid 260, on /dev/tty1, in 01empty); nothing waits for an answer,"
        " wait for it to finish."
    )


def test_wait_message_of_a_keel_init_in_dtach():
    run = init_lock.Run(
        900,
        kind="keel-init",
        tty="/dev/pts/4",
        dtach="/root/.inithooks.dtach",
    )
    assert init_lock.wait_message(run, "lxc") == (
        "keel-init is already running (pid 900) in the dtach session"
        " /root/.inithooks.dtach; attach to it with:"
        " dtach -a /root/.inithooks.dtach"
    )


def test_wait_message_of_a_keel_init_on_a_terminal():
    run = init_lock.Run(900, kind="keel-init", tty="/dev/pts/2")
    assert init_lock.wait_message(run, "lxc") == (
        "keel-init is already running (pid 900) on /dev/pts/2;"
        " answer it there, or wait for it to finish."
    )


def test_wait_message_of_a_keel_init_without_a_terminal():
    run = init_lock.Run(None, kind="keel-init")
    assert init_lock.wait_message(run, "lxc") == (
        "keel-init is already running; wait for it to finish."
    )


def test_pending_message():
    assert init_lock.pending_message("kvm") == (
        "the first boot has not finished yet: its own run"
        " (inithooks.service) is starting, and asks its questions on the"
        " console, answer them there: the VM's console. keel-init"
        " reconfigures the machine once that run has finished."
    )


@pytest.mark.parametrize(
    "text, pending",
    [
        ("RUN_FIRSTBOOT=true\n", True),
        ("RUN_FIRSTBOOT=TRUE\n", True),
        ('RUN_FIRSTBOOT="true"\n', True),
        ("  RUN_FIRSTBOOT=true  \n", True),
        ("RUN_FIRSTBOOT=false\n", False),
        ("RUN_FIRSTBOOT=true\nRUN_FIRSTBOOT=false\n", False),
        ("#RUN_FIRSTBOOT=true\n", False),
        ("INITHOOKS_PATH=/usr/lib/inithooks\n", False),
    ],
)
def test_boot_pending_reads_run_firstboot(tmp_path, text, pending):
    default = tmp_path / "default"
    default.write_text(text)
    complete = str(tmp_path / "complete")
    assert init_lock.boot_pending(str(default), complete) is pending


def test_boot_pending_ends_when_the_boot_run_completes(tmp_path):
    default = tmp_path / "default"
    default.write_text("RUN_FIRSTBOOT=true\n")
    complete = tmp_path / "complete"
    complete.touch()
    assert init_lock.boot_pending(str(default), str(complete)) is False


def test_boot_pending_without_a_default_file(tmp_path):
    missing = str(tmp_path / "missing")
    assert init_lock.boot_pending(missing, missing) is False


def test_boot_paths(monkeypatch):
    monkeypatch.delenv("INITHOOKS_DEFAULT", raising=False)
    monkeypatch.delenv("INITHOOKS_COMPLETE", raising=False)
    assert init_lock.default_path() == "/etc/default/inithooks"
    assert init_lock.complete_path() == "/run/inithooks-complete"
    monkeypatch.setenv("INITHOOKS_DEFAULT", "/d")
    monkeypatch.setenv("INITHOOKS_COMPLETE", "/c")
    assert init_lock.default_path() == "/d"
    assert init_lock.complete_path() == "/c"


@pytest.mark.parametrize(
    "text, value",
    [
        ("RUN_FIRSTBOOT=true # redo\n", "true"),
        ("export RUN_FIRSTBOOT=true\n", "true"),
        ("RUN_FIRSTBOOT='TRUE'\n", "TRUE"),
        ("RUN_FIRSTBOOT=true\nRUN_FIRSTBOOT=false\n", "false"),
        ("#RUN_FIRSTBOOT=true\n", ""),
        ("RUN_FIRSTBOOT=\"tr\"'ue'\n", "true"),
    ],
)
def test_run_firstboot_reads_the_file_as_run_does(tmp_path, text, value):
    default = tmp_path / "default"
    default.write_text(text)
    assert init_lock.run_firstboot(str(default)) == value


def test_run_firstboot_ignores_the_environment(tmp_path, monkeypatch):
    monkeypatch.setenv("RUN_FIRSTBOOT", "true")
    default = tmp_path / "default"
    default.write_text("SUDOADMIN=false\n")
    assert init_lock.run_firstboot(str(default)) == ""


def test_run_firstboot_without_bash(tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", str(tmp_path))
    assert init_lock.run_firstboot("/nonexistent") == ""


def test_boot_pending_with_a_comment_and_export(tmp_path):
    default = tmp_path / "default"
    default.write_text("export RUN_FIRSTBOOT=true # redo\n")
    missing = str(tmp_path / "complete")
    assert init_lock.boot_pending(str(default), missing) is True


@pytest.mark.parametrize(
    "active, jobs, state",
    [
        ("active", "", "running"),
        ("activating", "", "running"),
        ("deactivating", "", "running"),
        ("inactive", "7 inithooks.service start waiting", "queued"),
        ("inactive", "", "stopped"),
        ("failed", "", "stopped"),
    ],
)
def test_boot_unit_state(stubs, active, jobs, state):
    unit(stubs, active, jobs)
    assert init_lock.boot_unit_state() == state


def test_boot_unit_state_without_systemctl(tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", str(tmp_path))
    assert init_lock.boot_unit_state() == "stopped"


def test_dtach_socket_named_relative_to_the_dtach_cwd(tmp_path):
    # dtach -A s ...: the socket is where dtach was started, not here
    proc = tmp_path / "proc"
    fake_process(proc, 40, 1, ["dtach", "-A", "sock/s", "-Ez", "bash"])
    os.symlink("/root/work", proc / "40" / "cwd")
    fake_process(proc, 60, 40, ["keel-init"])
    assert init_lock.dtach_socket(60, str(proc)) == "/root/work/sock/s"


def test_dtach_socket_relative_when_the_cwd_cannot_be_read(tmp_path):
    proc = tmp_path / "proc"
    fake_process(proc, 40, 1, ["dtach", "-c", "s", "bash"])
    fake_process(proc, 60, 40, ["keel-init"])
    assert init_lock.dtach_socket(60, str(proc)) == "s"


def fake_process(proc, pid, ppid, argv, name="cmd"):
    directory = proc / str(pid)
    directory.mkdir(parents=True)
    (directory / "stat").write_text(f"{pid} ({name}) S {ppid} {pid} 0 0\n")
    (directory / "cmdline").write_bytes("\0".join(argv).encode() + b"\0")


def test_dtach_socket_of_a_keel_init_started_by_the_profile(tmp_path):
    # common's .profile.d: dtach -A SOCKET -Ez /bin/bash -c "turnkey-init"
    proc = tmp_path / "proc"
    socket = "/root/.inithooks.dtach"
    fake_process(
        proc,
        40,
        1,
        ["/usr/bin/dtach", "-A", socket, "-Ez", "/bin/bash", "-c", "x"],
    )
    fake_process(proc, 50, 40, ["/bin/bash", "-c", "turnkey-init"],
                 name="odd ) name")
    fake_process(proc, 60, 50, ["/usr/bin/python3", "/usr/sbin/turnkey-init"])
    assert init_lock.dtach_socket(60, str(proc)) == "/root/.inithooks.dtach"


def test_dtach_socket_outside_dtach(tmp_path):
    proc = tmp_path / "proc"
    fake_process(proc, 50, 1, ["/bin/bash"])
    fake_process(proc, 60, 50, ["/usr/sbin/keel-init"])
    assert init_lock.dtach_socket(60, str(proc)) == ""


def test_dtach_socket_ignores_a_dtach_that_only_attaches(tmp_path):
    proc = tmp_path / "proc"
    fake_process(proc, 50, 1, ["dtach", "-a", "/root/.inithooks.dtach"])
    fake_process(proc, 60, 50, ["keel-init"])
    assert init_lock.dtach_socket(60, str(proc)) == ""


def test_dtach_socket_of_a_vanished_process(tmp_path):
    assert init_lock.dtach_socket(60, str(tmp_path)) == ""


def test_dtach_socket_gives_up_on_a_deep_tree(tmp_path):
    proc = tmp_path / "proc"
    depth = init_lock.DTACH_DEPTH + 2
    for pid in range(2, depth + 2):
        fake_process(proc, pid, pid - 1 if pid > 2 else 1, ["sh"])
    # the dtach is above the depth looked at
    assert init_lock.dtach_socket(depth + 1, str(proc)) == ""


def test_this_keel_init_describes_itself():
    run = init_lock.this_keel_init()
    assert run.kind == "keel-init"
    assert run.pid == os.getpid()
    assert run.dtach == ""


def test_current_tty_without_a_terminal(monkeypatch):
    def not_a_tty(fd):
        raise OSError("not a tty")

    monkeypatch.setattr(init_lock.os, "ttyname", not_a_tty)
    assert init_lock.current_tty() == ""


def test_current_tty_on_a_terminal(monkeypatch):
    monkeypatch.setattr(init_lock.os, "ttyname", lambda fd: "/dev/pts/7")
    assert init_lock.current_tty() == "/dev/pts/7"


# keel-init


def test_keel_init_runs_the_hooks_holding_the_lock(keel_init, lock, tmp_path):
    seen = tmp_path / "seen"
    hook(
        keel_init.firstboot,
        "01probe",
        f"flock -n '{lock}' true || echo held >> '{seen}'",
    )
    keel_init.main()
    assert seen.read_text() == "held\n"
    assert init_lock.in_progress(lock) is None


def test_keel_init_describes_itself_in_the_lock(keel_init, lock, tmp_path):
    seen = tmp_path / "seen"
    hook(keel_init.firstboot, "01probe", f"cat '{lock}' > '{seen}'")
    keel_init.main()
    run = init_lock.parse(seen.read_text())
    assert run.kind == "keel-init"
    assert run.pid == os.getpid()


def test_keel_init_refuses_before_the_boot_run_of_the_first_boot(
    keel_init, lock, stubs, tmp_path, capsys
):
    """The race: keel-init typed after `pct enter` before inithooks.service
    has started. Under keel-init the hooks skip what only a first boot
    does, and the boot run would then find the first boot done."""
    executable(str(stubs / "systemd-detect-virt"), "#!/bin/sh\necho lxc\n")
    unit(stubs, "activating")
    keel_init.default.write_text("RUN_FIRSTBOOT=true\n")
    seen = tmp_path / "seen"
    hook(keel_init.firstboot, "05autogrow-fs", f"echo ran >> '{seen}'")

    with pytest.raises(SystemExit) as refused:
        keel_init.main()

    assert refused.value.code == 75
    assert not seen.exists()
    # the lock is let go, for the boot run that is about to start
    assert init_lock.in_progress(lock) is None
    assert capsys.readouterr().err == (
        "keel-init: the first boot has not finished yet: its own run"
        " (inithooks.service) is starting, and asks its questions on the"
        " console, answer them there: pct console <ctid> on Proxmox, or"
        " lxc-console -n <name> on LXC. keel-init reconfigures the machine"
        " once that run has finished.\n"
    )


def test_keel_init_refuses_while_the_boot_run_is_queued(
    keel_init, lock, stubs, tmp_path, capsys
):
    # at boot the unit waits for getty.target with a start job queued
    unit(stubs, "inactive", jobs="42 inithooks.service start waiting")
    keel_init.default.write_text("RUN_FIRSTBOOT=true\n")
    with pytest.raises(SystemExit) as refused:
        keel_init.main()
    assert refused.value.code == 75
    assert "is starting" in capsys.readouterr().err


def test_keel_init_runs_once_the_boot_run_has_completed(
    keel_init, lock, tmp_path
):
    # RUN_FIRSTBOOT may still say true when 98finalize did not run; the
    # marker says the boot run of this boot is over
    keel_init.default.write_text("RUN_FIRSTBOOT=true\n")
    keel_init.complete.touch()
    seen = tmp_path / "seen"
    hook(keel_init.firstboot, "30rootpass", f"echo ran >> '{seen}'")
    keel_init.main()
    assert seen.read_text() == "ran\n"


def test_keel_init_releases_the_lock_before_confconsole(
    keel_init, lock, monkeypatch
):
    states = []
    real_run = subprocess.run

    def run(cmd, *args, **kwargs):
        if cmd[0] in ("/bin/true", "/usr/bin/confconsole"):
            states.append(init_lock.in_progress(lock))
            return subprocess.CompletedProcess(cmd, 0)
        return real_run(cmd, *args, **kwargs)

    monkeypatch.setattr(keel_init.subprocess, "run", run)
    keel_init.main()
    assert states == [None]


def test_keel_init_refuses_while_a_run_is_in_progress(
    keel_init, lock, stubs, tmp_path, capsys
):
    executable(str(stubs / "systemd-detect-virt"), "#!/bin/sh\necho lxc\n")
    seen = tmp_path / "seen"
    hook(keel_init.firstboot, "30rootpass", f"echo ran >> '{seen}'")
    fd = init_lock.acquire(lock)
    try:
        with pytest.raises(SystemExit) as refused:
            keel_init.main()
    finally:
        init_lock.release(fd)

    assert refused.value.code == init_lock.EXIT_BUSY == 75
    assert not seen.exists()
    err = capsys.readouterr().err
    assert err.startswith(
        f"keel-init: the first-boot wizard is running on the console"
        f" (pid {os.getpid()}); answer it there: pct console <ctid>"
        " on Proxmox, or lxc-console -n <name> on LXC.\n"
    )
    assert "run keel-init again once that one has finished" in err


def test_keel_init_names_the_command_that_was_typed(
    keel_init, lock, monkeypatch, capsys
):
    monkeypatch.setattr(sys, "argv", ["/usr/sbin/turnkey-init"])
    fd = init_lock.acquire(lock)
    try:
        with pytest.raises(SystemExit):
            keel_init.main()
    finally:
        init_lock.release(fd)
    err = capsys.readouterr().err
    assert err.startswith("turnkey-init: the first-boot wizard")
    assert "run turnkey-init again" in err


def test_keel_init_needs_root(keel_init, monkeypatch, capsys):
    monkeypatch.setattr(keel_init.os, "geteuid", lambda: 1000)
    with pytest.raises(SystemExit) as refused:
        keel_init.main()
    assert refused.value.code == 1
    assert capsys.readouterr().err == (
        "keel-init: error: keel-init must be run with root permissions\n"
    )


def test_keel_init_help_names_keel_init(keel_init, monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["/usr/sbin/keel-init", "--help"])
    with pytest.raises(SystemExit):
        keel_init.main()
    out, err = capsys.readouterr()
    assert err.startswith("Syntax: keel-init [-h|--help]")
    assert "-s|--status" in out
    assert "turnkey-init" not in out + err


def test_keel_init_full_confconsole(keel_init, lock, monkeypatch):
    commands = []
    monkeypatch.setattr(keel_init.os.path, "exists", lambda path: True)
    monkeypatch.setattr(keel_init.os, "access", lambda path, mode: True)
    monkeypatch.setattr(
        keel_init.subprocess,
        "run",
        lambda cmd, *a, **k: commands.append(cmd),
    )
    monkeypatch.setattr(sys, "argv", ["keel-init", "-c"])
    keel_init.main()
    assert commands[-1] == ["/usr/bin/confconsole"]


@pytest.fixture
def status_argv(monkeypatch):
    monkeypatch.setattr(sys, "argv", ["keel-init", "--status"])


def test_status_while_a_run_is_in_progress(
    keel_init, lock, stubs, status_argv, capsys
):
    executable(str(stubs / "systemd-detect-virt"), "#!/bin/sh\necho kvm\n")
    fd = init_lock.acquire(lock)
    try:
        with pytest.raises(SystemExit) as busy:
            keel_init.main()
    finally:
        init_lock.release(fd)
    assert busy.value.code == 75
    assert capsys.readouterr().out == (
        f"    the first-boot wizard is running on the console"
        f" (pid {os.getpid()}); answer it there: the VM's console.\n\n"
    )


def test_status_before_the_boot_run_of_the_first_boot(
    keel_init, lock, stubs, status_argv, capsys
):
    executable(str(stubs / "systemd-detect-virt"), "#!/bin/sh\necho kvm\n")
    unit(stubs, "active")
    keel_init.default.write_text("RUN_FIRSTBOOT=true\n")
    with pytest.raises(SystemExit) as pending:
        keel_init.main()
    assert pending.value.code == 75
    assert capsys.readouterr().out == (
        "    " + init_lock.pending_message("kvm") + "\n\n"
    )


def test_status_of_a_first_boot_nothing_runs(
    keel_init, lock, stubs, status_argv, capsys
):
    unit(stubs, "failed")
    keel_init.default.write_text("RUN_FIRSTBOOT=true\n")
    with pytest.raises(SystemExit) as pending:
        keel_init.main()
    assert pending.value.code == 75
    assert capsys.readouterr().out == (
        "    the first boot has not finished and nothing is running it:"
        " run keel-init to run it.\n\n"
    )


def test_status_needs_no_root(keel_init, lock, monkeypatch, capsys):
    monkeypatch.setattr(keel_init.os, "geteuid", lambda: 1000)
    monkeypatch.setattr(keel_init, "fence_up", lambda: False)
    monkeypatch.setattr(sys, "argv", ["keel-init", "-s"])
    with pytest.raises(SystemExit) as done:
        keel_init.main()
    assert done.value.code == 0
    assert capsys.readouterr().out == ""


def test_status_while_the_fence_is_up(
    keel_init, lock, stubs, status_argv, capsys
):
    executable(
        str(stubs / "systemctl"),
        '#!/bin/sh\n[ "$*" = "is-active --quiet turnkey-init-fence" ]\n',
    )
    with pytest.raises(SystemExit) as done:
        keel_init.main()
    assert done.value.code == 0
    assert capsys.readouterr().out == (
        "    This system is not initialized yet: run keel-init to set it"
        " up.\n\n"
    )


def test_status_when_the_fence_is_down(
    keel_init, lock, stubs, status_argv, capsys
):
    executable(str(stubs / "systemctl"), "#!/bin/sh\nexit 3\n")
    with pytest.raises(SystemExit) as done:
        keel_init.main()
    assert done.value.code == 0
    assert capsys.readouterr().out == ""


def test_fence_down_without_systemctl(keel_init, tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", str(tmp_path))
    assert keel_init.fence_up() is False


# turnkey-init, and the boot run on the other side of the lock


def test_turnkey_init_is_a_relative_link_to_keel_init():
    # relative, per decision 0015: an absolute link does not resolve in a
    # chroot
    assert os.path.islink(TURNKEY_INIT)
    assert os.readlink(TURNKEY_INIT) == "keel-init"
    assert not os.path.islink(KEEL_INIT)


@pytest.fixture
def conffile_path(tmp_path):
    """A PYTHONPATH with the conffile stub and the checkout"""
    directory = tmp_path / "pylib"
    directory.mkdir()
    (directory / "conffile.py").write_text(CONFFILE_STUB)
    return f"{directory}:{REPO}"


@pytest.mark.parametrize("command", [KEEL_INIT, TURNKEY_INIT])
def test_both_names_refuse_while_a_run_is_in_progress(
    command, lock, stubs, conffile_path, tmp_path
):
    # the command itself, run by its name as an operator would
    executable(str(stubs / "systemd-detect-virt"), "#!/bin/sh\necho lxc\n")
    fd = init_lock.acquire(lock)
    try:
        done = subprocess.run(
            [sys.executable, command, "--status"],
            env={
                **os.environ,
                "PYTHONPATH": conffile_path,
                "TEST_INITHOOKS_PATH": str(tmp_path),
            },
            capture_output=True,
            text=True,
        )
    finally:
        init_lock.release(fd)
    assert done.returncode == 75
    assert "pct console <ctid> on Proxmox" in done.stdout


def test_turnkey_init_names_itself(conffile_path, tmp_path):
    done = subprocess.run(
        [sys.executable, TURNKEY_INIT, "--help"],
        env={**os.environ, "PYTHONPATH": conffile_path},
        capture_output=True,
        text=True,
    )
    assert done.stderr.startswith("Syntax: turnkey-init ")


@pytest.fixture
def boot(keel_init, stubs, tmp_path):
    """A first boot for the real run: its hooks under tmp_path/boot, the
    same default file and completion marker keel-init reads, and
    keel-init's own hooks under tmp_path/lib"""
    for name, body in (
        ("logger", "exit 0"),
        ("confconsole", "exit 0"),
        ("sleep", "exit 0"),
        ("systemd-detect-virt", "echo lxc"),
    ):
        executable(str(stubs / name), f"#!/bin/sh\n{body}\n")
    # the unit is starting, unless a test says otherwise
    unit(stubs, "activating")
    # keel-init's inithooks_path holds the runner too, as on an appliance
    lib = tmp_path / "lib"
    os.symlink(RUN, lib / "run")
    os.symlink(join(REPO, "lib"), lib / "lib")
    directory = tmp_path / "boot"
    (directory / "firstboot.d").mkdir(parents=True)
    keel_init.default.write_text(
        f"INITHOOKS_CONF={tmp_path}/inithooks.conf\n"
        f"INITHOOKS_PATH={directory}\n"
        f"INITHOOKS_LOGFILE={tmp_path}/inithooks.log\n"
        "RUN_FIRSTBOOT=true\nREDIRECT_OUTPUT=false\n"
    )
    return directory / "firstboot.d"


def start_run():
    # INITHOOKS_DEFAULT, INITHOOKS_COMPLETE and INITHOOKS_LOCK are in the
    # environment the fixtures set
    return subprocess.Popen(
        [RUN],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def test_keel_init_refuses_while_the_boot_run_waits_in_a_hook(
    keel_init, lock, boot, tmp_path, capsys
):
    """The report of 2026-09-30: the boot run waits in 30rootpass on the
    console, and keel-init is typed in another shell"""
    fifo = tmp_path / "answer"
    os.mkfifo(fifo)
    seen = tmp_path / "seen"
    hook(boot, "30rootpass", f"echo boot >> '{seen}'\nread -r _ < '{fifo}'")
    hook(keel_init.firstboot, "30rootpass", f"echo keel-init >> '{seen}'")
    runner = start_run()
    try:
        eventually(lambda: seen.exists())

        with pytest.raises(SystemExit) as refused:
            keel_init.main()

        assert refused.value.code == 75
        assert capsys.readouterr().err.startswith(
            "keel-init: the first-boot wizard is running on the console"
            f" (pid {runner.pid}, on /dev/null, in 30rootpass);"
            " answer it there: pct console <ctid> on Proxmox"
        )
        assert seen.read_text() == "boot\n"
    finally:
        with open(fifo, "w") as fob:
            fob.write("answered\n")
        runner.wait(timeout=10)

    # the boot run is over: now keel-init runs
    keel_init.main()
    assert seen.read_text() == "boot\nkeel-init\n"


def test_keel_init_before_the_boot_run_leaves_the_first_boot_to_it(
    keel_init, lock, boot, tmp_path, capsys
):
    """keel-init wins the race to the lock: it must not take the first
    boot, and the boot run that follows must still do it"""
    seen = tmp_path / "seen"
    hook(boot, "05autogrow-fs", f"echo boot >> '{seen}'")
    hook(keel_init.firstboot, "05autogrow-fs", f"echo keel-init >> '{seen}'")

    with pytest.raises(SystemExit) as refused:
        keel_init.main()
    assert refused.value.code == 75
    assert "the first boot has not finished yet" in capsys.readouterr().err
    assert not seen.exists()

    runner = start_run()
    assert runner.wait(timeout=10) == 0
    assert seen.read_text() == "boot\n"
    assert keel_init.complete.exists()

    keel_init.main()
    assert seen.read_text() == "boot\nkeel-init\n"


# a first boot nothing else will run: keel-init runs the boot run itself


@pytest.fixture
def execv(monkeypatch):
    """os.execv, run as a child instead of replacing the test process; the
    calls are recorded"""
    calls = []

    def run_instead(path, argv):
        calls.append((path, argv))
        done = subprocess.run(argv, stdin=subprocess.DEVNULL)
        raise SystemExit(done.returncode)

    monkeypatch.setattr(os, "execv", run_instead)
    return calls


@pytest.mark.parametrize(
    "state",
    [
        # systemctl stop inithooks
        "inactive",
        # the run died: killed, hung up, or failed
        "failed",
    ],
)
def test_keel_init_runs_the_first_boot_nothing_else_runs(
    keel_init, lock, boot, stubs, execv, tmp_path, capsys, state
):
    unit(stubs, state)
    seen = tmp_path / "seen"
    hook(boot, "05autogrow-fs", f"echo boot >> '{seen}'")
    hook(keel_init.firstboot, "05autogrow-fs", f"echo keel-init >> '{seen}'")

    with pytest.raises(SystemExit) as done:
        keel_init.main()

    run = str(tmp_path / "lib" / "run")
    assert done.value.code == 0
    assert execv == [(run, [run])]
    # the whole first boot, by the boot run: not keel-init's hooks
    assert seen.read_text() == "boot\n"
    assert keel_init.complete.exists()
    assert capsys.readouterr().err == (
        "keel-init: the first boot has not finished and inithooks.service"
        " is not running it (stopped, failed, or skipped by its condition);"
        f" running the whole first boot here instead: {run}\n"
    )


def test_keel_init_in_a_container_that_skips_the_unit(
    keel_init, lock, boot, stubs, execv, tmp_path
):
    """inithooks.service has ConditionPathExists=!.../lxc: a container
    with that file skips the unit, which is then inactive with no job,
    and never runs; nothing but keel-init will do the first boot"""
    unit(stubs, "inactive", jobs="")
    seen = tmp_path / "seen"
    hook(boot, "30rootpass", f"echo boot >> '{seen}'")

    with pytest.raises(SystemExit):
        keel_init.main()

    assert seen.read_text() == "boot\n"
    assert init_lock.in_progress(lock) is None


def test_keel_init_after_a_killed_boot_run(
    keel_init, lock, boot, stubs, execv, tmp_path
):
    """The boot run killed in its wizard: the kernel drops its lock, the
    unit is failed, and keel-init redoes the first boot with the runner"""
    fifo = tmp_path / "answer"
    os.mkfifo(fifo)
    seen = tmp_path / "seen"
    hook(
        boot,
        "30rootpass",
        f"echo boot >> '{seen}'\n"
        f"[ -e '{tmp_path}/killed' ] || read -r _ < '{fifo}'",
    )
    runner = start_run()
    eventually(lambda: seen.exists())
    # the hook is killed with its run, as systemd kills the unit's cgroup
    runner.send_signal(signal.SIGSTOP)
    subprocess.run(["pkill", "-KILL", "-P", str(runner.pid)])
    runner.send_signal(signal.SIGKILL)
    runner.wait(timeout=10)
    (tmp_path / "killed").touch()
    unit(stubs, "failed")
    assert init_lock.in_progress(lock) is None
    assert not keel_init.complete.exists()

    with pytest.raises(SystemExit) as done:
        keel_init.main()

    assert done.value.code == 0
    assert seen.read_text() == "boot\nboot\n"
    assert keel_init.complete.exists()
