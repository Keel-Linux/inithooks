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

import yaml

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

    def test_the_issue_21_spec_writes_the_static_ipv6_conf(self):
        """A static IPv6 address keel accepts is written at first boot too,
        with the same IP6_* variables a day-two `keel spec apply` renders
        (inithooks#21, decision 0018)"""
        conf = join(self.tmpdir, "inithooks.conf")
        out = self.run_cli(
            "--apply", f"--conf={conf}", self.spec("issue21.yaml")
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        with open(conf) as fob:
            written = fob.read()
        self.assertIn("export IP6_CONFIG=static", written)
        self.assertIn("export IP6_ADDRESS=2001:db8:1::10/64", written)
        self.assertIn("export IP6_GW=fe80::1", written)
        self.assertIn("export IP6_SLAAC=no", written)
        # keel#45: the single static (v6) stanza carries one resolver of
        # each family
        self.assertIn("export IP6_DNS1=2001:db8:1::53", written)
        self.assertIn("export IP6_DNS2=192.0.2.53", written)


class KeelNetworkParity(unittest.TestCase):
    """declarative._network_env and keel.spec.render.network_env agree

    The issue 21 fix is a port of keel's renderer; this holds the port to
    the original over a matrix of documents, both readers on the same
    input, so a drift in either shows up here.
    """

    DOCS = [
        # (yaml, what the case exercises)
        ("version: 1\nnetwork:\n  managed_by: file\n", "empty network"),
        (
            "version: 1\nnetwork:\n  managed_by: file\n"
            "  nameservers: [192.0.2.53, 2001:db8:1::53]\n",
            "nameservers, no interfaces",
        ),
        (
            "version: 1\nnetwork:\n  managed_by: file\n"
            "  interfaces:\n    eth0:\n      ipv4:\n"
            "        method: static\n        address: 192.0.2.10/24\n"
            "        gateway: 192.0.2.1\n",
            "ipv4 static only",
        ),
        (
            "version: 1\nnetwork:\n  managed_by: file\n"
            "  interfaces:\n    eth0:\n      ipv6:\n"
            "        method: static\n        address: 2001:db8:1::10/64\n"
            "        gateway: fe80::1\n        slaac: false\n",
            "ipv6 static, slaac off",
        ),
        (
            "version: 1\nnetwork:\n  managed_by: file\n"
            "  interfaces:\n    eth0:\n      ipv4:\n        method: dhcp\n"
            "      ipv6:\n        method: auto\n",
            "both dynamic",
        ),
        (
            "version: 1\nnetwork:\n  managed_by: file\n"
            "  interfaces:\n    eth0:\n      ipv4:\n        method: static\n"
            "        address: 192.0.2.10/24\n      ipv6:\n"
            "        method: manual\n",
            "v4 static, v6 manual",
        ),
        (
            "version: 1\nnetwork:\n  managed_by: file\n"
            "  interfaces:\n    eth0:\n      ipv6:\n"
            "        method: static\n        address: 2001:db8:1::10/64\n"
            "    eth1:\n      ipv6:\n        method: auto\n",
            "last ipv6 block wins",
        ),
        (
            "version: 1\nnetwork:\n  managed_by: host\n"
            "  interfaces:\n    eth0:\n      ipv6:\n"
            "        method: static\n        address: 2001:db8:1::10/64\n",
            "host managed exports nothing",
        ),
    ]

    NAMESERVERS = [
        [],
        ["192.0.2.53"],
        ["2001:db8:1::53"],
        ["192.0.2.53", "192.0.2.54"],
        ["2001:db8:1::53", "2001:db8:2::53"],
        ["2001:db8:1::53", "192.0.2.53"],
        ["192.0.2.53", "2001:db8:1::53", "192.0.2.54", "2001:db8:2::53"],
    ]

    def setUp(self):
        checkout = keel_checkout()
        if checkout is None:
            self.skipTest("keel is not at hand (set KEEL_SRC)")
        if checkout not in sys.path:
            sys.path.insert(0, checkout)
        from keel.spec.render import network_env as keel_network_env

        self.keel_network_env = keel_network_env
        sys.path.insert(0, ROOT)
        from libinithooks import declarative

        self.declarative = declarative

    def documents(self):
        for text, label in self.DOCS:
            for nameservers in self.NAMESERVERS:
                doc = yaml.safe_load(text)
                if nameservers:
                    doc["network"]["nameservers"] = nameservers
                yield f"{label}, nameservers={nameservers or 'none'}", doc

    def test_the_readers_render_the_same_network_variables(self):
        for label, document in self.documents():
            with self.subTest(document=label):
                ours = self.declarative._network_env(document.get("network"))
                theirs = self.keel_network_env(document.get("network"))
                self.assertEqual(ours, theirs)

    def test_the_conf_network_lines_are_identical_in_order(self):
        """The conf file itself, not only the variable set: the hook
        sources the file, and the day-two conf is compared line by line
        in tests, so the order must match too"""
        from keel.spec.render import render_env as keel_render_env

        for label, document in self.documents():
            with self.subTest(document=label):
                ours = self.declarative.render_env(document, {})
                theirs = keel_render_env(document, {})
                our_lines = [line for line in ours.splitlines()
                             if line.startswith("export IP")]
                their_lines = [line for line in theirs.splitlines()
                               if line.startswith("export IP")]
                self.assertEqual(our_lines, their_lines)


if __name__ == "__main__":
    unittest.main()
