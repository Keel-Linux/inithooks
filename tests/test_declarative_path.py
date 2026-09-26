# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""Which declarative description is read, and how the hook asks

One document is read from one path, and two places name that path: the
instance description the operator edits and the conf file inithooks has
always read. The first appliance boot showed what happens when the two
disagree, so the search order is a tested contract, not a default buried
in a shell assignment.
"""

import os
import stat
import subprocess
import tempfile
import unittest
from os.path import abspath, dirname, join

from helpers import declarative

ROOT = dirname(dirname(abspath(__file__)))
HOOK = join(ROOT, "firstboot.d", "00declarative")

VALID = "version: 1\ninstance:\n  hostname: blog\n"


def present(*paths: str):
    """An exists() that answers True for these paths and nothing else"""
    return lambda path: path in paths


class TestSearchOrder(unittest.TestCase):
    def test_the_instance_description_is_looked_for_first(self):
        assert declarative.DECL_PATHS[0] == "/etc/keel/instance.yaml"

    def test_the_inithooks_path_is_still_a_candidate(self):
        assert declarative.DECL_DEFAULT in declarative.DECL_PATHS

    def test_the_first_candidate_that_exists_wins(self):
        path, ignored = declarative.resolve_path(
            env={}, exists=present(*declarative.DECL_PATHS)
        )
        assert (path, ignored) == (
            "/etc/keel/instance.yaml",
            ("/etc/inithooks.yaml",),
        )

    def test_the_second_candidate_is_read_when_the_first_is_absent(self):
        path, ignored = declarative.resolve_path(
            env={}, exists=present("/etc/inithooks.yaml")
        )
        assert (path, ignored) == ("/etc/inithooks.yaml", ())

    def test_nothing_is_found_when_no_candidate_exists(self):
        path, ignored = declarative.resolve_path(
            env={}, exists=lambda _: False
        )
        assert (path, ignored) == (None, ())

    def test_the_environment_names_the_file_and_stops_the_search(self):
        path, ignored = declarative.resolve_path(
            env={"INITHOOKS_DECL": "/srv/instance.yaml"},
            exists=present(*declarative.DECL_PATHS),
        )
        assert (path, ignored) == ("/srv/instance.yaml", ())

    def test_a_named_file_that_is_absent_is_still_returned_by_name(self):
        path, _ = declarative.resolve_path(
            env={"INITHOOKS_DECL": "/srv/absent.yaml"}, exists=lambda _: False
        )
        assert path == "/srv/absent.yaml"

    def test_surrounding_space_in_the_environment_is_dropped(self):
        path, _ = declarative.resolve_path(
            env={"INITHOOKS_DECL": "  /srv/instance.yaml \n"},
            exists=lambda _: False,
        )
        assert path == "/srv/instance.yaml"

    def test_an_empty_environment_value_falls_back_to_the_search(self):
        path, _ = declarative.resolve_path(
            env={"INITHOOKS_DECL": ""}, exists=present("/etc/inithooks.yaml")
        )
        assert path == "/etc/inithooks.yaml"

    def test_the_process_environment_is_read_when_none_is_given(self):
        os.environ["INITHOOKS_DECL"] = "/srv/from-process.yaml"
        try:
            path, _ = declarative.resolve_path(exists=lambda _: False)
        finally:
            del os.environ["INITHOOKS_DECL"]
        assert path == "/srv/from-process.yaml"


class HookTestCase(unittest.TestCase):
    """The hook driven with a reader that records how it was called

    The reader is a stub because the contract under test is the hook's: ask
    which file to read, then apply that file, and stay out of the way when
    there is nothing to read.
    """

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.conf = join(self.tmpdir, "inithooks.conf")
        self.calls = join(self.tmpdir, "calls")
        self.stub = join(self.tmpdir, "lib", "bin", "declarative.py")
        os.makedirs(dirname(self.stub))

    def write_stub(self, which: str = "", code: int = 0) -> None:
        with open(self.stub, "w") as fob:
            fob.write(
                "#!/bin/bash\n"
                f'echo "$@" >> {self.calls}\n'
                'if [[ "$1" == "--which" ]]; then\n'
                f"    printf '%s' '{which}'\n"
                f"    [[ -n '{which}' ]] && echo\n"
                f"    exit {code}\n"
                "fi\n"
                f'echo applied >> {self.conf}\n'
            )
        os.chmod(self.stub, os.stat(self.stub).st_mode | stat.S_IEXEC)

    def write_default(self, decl: str | None) -> str:
        path = join(self.tmpdir, "default-inithooks")
        with open(path, "w") as fob:
            fob.write(f"INITHOOKS_CONF={self.conf}\n")
            if decl is not None:
                fob.write(f"INITHOOKS_DECL={decl}\n")
            fob.write(f"INITHOOKS_PATH={join(self.tmpdir, 'lib')}\n")
            fob.write(f"INITHOOKS_LOGFILE={join(self.tmpdir, 'log')}\n")
        return path

    def run_hook(self, decl: str | None) -> subprocess.CompletedProcess:
        environment = dict(os.environ)
        environment.pop("INITHOOKS_DECL", None)
        environment["INITHOOKS_DEFAULT"] = self.write_default(decl)
        return subprocess.run([HOOK], capture_output=True, env=environment)

    def recorded(self) -> list[str]:
        if not os.path.exists(self.calls):
            return []
        with open(self.calls) as fob:
            return fob.read().splitlines()


class TestHookAsksWhichFile(HookTestCase):
    def test_an_explicit_setting_is_applied_without_a_search(self):
        decl = join(self.tmpdir, "named.yaml")
        with open(decl, "w") as fob:
            fob.write(VALID)
        self.write_stub()

        out = self.run_hook(decl)

        assert out.returncode == 0, out.stderr
        assert self.recorded() == [f"--apply --conf={self.conf} {decl}"]

    def test_with_nothing_set_the_reader_is_asked_and_answered(self):
        decl = join(self.tmpdir, "instance.yaml")
        with open(decl, "w") as fob:
            fob.write(VALID)
        self.write_stub(which=decl)

        out = self.run_hook(None)

        assert out.returncode == 0, out.stderr
        assert self.recorded() == [
            "--which",
            f"--apply --conf={self.conf} {decl}",
        ]

    def test_an_empty_answer_leaves_the_boot_alone(self):
        self.write_stub(which="")

        out = self.run_hook(None)

        assert out.returncode == 0, out.stderr
        assert self.recorded() == ["--which"]
        assert not os.path.exists(self.conf)

    def test_an_answer_naming_an_absent_file_leaves_the_boot_alone(self):
        self.write_stub(which=join(self.tmpdir, "absent.yaml"))

        out = self.run_hook(None)

        assert out.returncode == 0, out.stderr
        assert self.recorded() == ["--which"]
        assert not os.path.exists(self.conf)

    def test_a_reader_that_fails_warns_and_the_boot_carries_on(self):
        self.write_stub(which="", code=3)

        out = self.run_hook(None)

        assert out.returncode == 0
        assert b"--which failed" in out.stderr
        assert not os.path.exists(self.conf)

    def test_an_interactive_run_is_still_a_no_op(self):
        self.write_stub(which=join(self.tmpdir, "instance.yaml"))
        environment = dict(os.environ)
        environment.pop("INITHOOKS_DECL", None)
        environment["INITHOOKS_DEFAULT"] = self.write_default(None)
        environment["_TURNKEY_INIT"] = "y"

        out = subprocess.run([HOOK], capture_output=True, env=environment)

        assert out.returncode == 0
        assert self.recorded() == []


if __name__ == "__main__":
    unittest.main()
