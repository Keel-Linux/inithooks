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

import importlib.machinery
import importlib.util
import os
import signal
import subprocess
import sys
import textwrap
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
    """The keel-init module, run as root, with hooks under tmp_path/lib"""
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
    return module


def hook(directory, name, body):
    executable(str(directory / name), "#!/bin/bash\n" + body + "\n")


# the library


def test_lock_path_defaults_to_run(monkeypatch):
    monkeypatch.delenv("INITHOOKS_LOCK", raising=False)
    assert init_lock.lock_path() == "/run/inithooks.lock"


def test_lock_path_from_environment(lock):
    assert init_lock.lock_path() == lock


def test_acquire_writes_the_pid_and_holds(lock):
    fd = init_lock.acquire(lock)
    try:
        with open(lock) as fob:
            assert fob.read() == f"{os.getpid()}\n"
        assert init_lock.in_progress(lock) == init_lock.Run(os.getpid())
    finally:
        init_lock.release(fd)


def test_acquire_replaces_a_longer_stale_pid(lock):
    with open(lock, "w") as fob:
        fob.write("123456789\n")
    fd = init_lock.acquire(lock)
    init_lock.release(fd)
    with open(lock) as fob:
        assert fob.read() == f"{os.getpid()}\n"


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


def test_keel_init_refuses_while_the_boot_run_waits_in_a_hook(
    keel_init, lock, stubs, tmp_path, capsys
):
    """The report of 2026-09-30: the boot run waits in 30rootpass on the
    console, and keel-init is typed in another shell"""
    for name, body in (
        ("logger", "exit 0"),
        ("systemctl", "echo running"),
        ("confconsole", "exit 0"),
        ("sleep", "exit 0"),
        ("systemd-detect-virt", "echo lxc"),
    ):
        executable(str(stubs / name), f"#!/bin/sh\n{body}\n")
    boot = tmp_path / "boot"
    (boot / "firstboot.d").mkdir(parents=True)
    fifo = tmp_path / "answer"
    os.mkfifo(fifo)
    seen = tmp_path / "seen"
    hook(
        boot / "firstboot.d",
        "30rootpass",
        f"echo boot >> '{seen}'\nread -r _ < '{fifo}'",
    )
    hook(keel_init.firstboot, "30rootpass", f"echo keel-init >> '{seen}'")
    default = tmp_path / "default-inithooks"
    default.write_text(
        f"INITHOOKS_CONF={tmp_path}/inithooks.conf\n"
        f"INITHOOKS_PATH={boot}\n"
        f"INITHOOKS_LOGFILE={tmp_path}/inithooks.log\n"
        "RUN_FIRSTBOOT=true\nREDIRECT_OUTPUT=false\n"
    )
    runner = subprocess.Popen(
        [RUN],
        env={**os.environ, "INITHOOKS_DEFAULT": str(default)},
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        eventually(lambda: seen.exists())

        with pytest.raises(SystemExit) as refused:
            keel_init.main()

        assert refused.value.code == 75
        assert f"(pid {runner.pid})" in capsys.readouterr().err
        assert seen.read_text() == "boot\n"
    finally:
        with open(fifo, "w") as fob:
            fob.write("answered\n")
        runner.wait(timeout=10)

    # the boot run is over: now keel-init runs
    keel_init.main()
    assert seen.read_text() == "boot\nkeel-init\n"
