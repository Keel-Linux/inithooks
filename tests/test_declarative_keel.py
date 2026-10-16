# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""The first boot against keel itself: the #31 description writes the conf

Gated on keel being at hand, as the corpus tests are. Runs bin/declarative.py
end to end with keel importable, which is the state of a Core image: keel's
own validator is asked, so a description carrying the sections keel gained
is accepted and /etc/inithooks.conf is written straight from it, with no
conf rendered beforehand (inithooks#31). A malformed section, or a section
neither reader knows, is still refused: delegation validates, it does not
rubber-stamp.
"""

import os
import subprocess
import sys
import tempfile
import unittest
from os.path import abspath, dirname, exists, join

from helpers import keel_checkout

ROOT = dirname(dirname(abspath(__file__)))
CLI = join(ROOT, "bin", "declarative.py")
SPECS = join(ROOT, "tests", "fixtures", "specs")


class KeelEndToEnd(unittest.TestCase):
    def setUp(self):
        checkout = keel_checkout()
        if checkout is None:
            self.skipTest("keel is not at hand (set KEEL_SRC)")
        self.tmpdir = tempfile.mkdtemp()
        self.env = dict(
            os.environ,
            PYTHONPATH=os.pathsep.join((ROOT, checkout)),
        )

    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, CLI, *args],
            capture_output=True,
            text=True,
            env=self.env,
            check=False,
        )

    def spec(self, name):
        return join(SPECS, name)

    def test_the_issue_31_spec_writes_the_conf(self):
        conf = join(self.tmpdir, "inithooks.conf")
        out = self.run_cli(
            "--apply", f"--conf={conf}", self.spec("issue31.yaml")
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertTrue(exists(conf))
        with open(conf) as fob:
            written = fob.read()
        self.assertIn("export HOSTNAME=core", written)
        self.assertIn("export SEC_ALERTS=admin@example.org", written)

    def test_a_malformed_section_keel_gained_is_refused(self):
        out = self.run_cli("--check", self.spec("invalid_appliance.yaml"))
        self.assertEqual(out.returncode, 1)
        self.assertIn("appliance.name: must match", out.stderr)

    def test_an_unknown_top_level_key_is_refused(self):
        out = self.run_cli(
            "--check", self.spec("invalid_unknown_section.yaml")
        )
        self.assertEqual(out.returncode, 1)
        self.assertIn("unknown top level key", out.stderr)


if __name__ == "__main__":
    unittest.main()
