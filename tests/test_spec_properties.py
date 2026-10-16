# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""Properties that must hold for every document, generated at random

A corpus pins the cases someone thought of; these tests pin the invariants
that must hold for all of them. The generator is seeded, so a failure is
reproducible, and stdlib only, so the suite needs no property-testing
dependency (the CI runner installs pytest, coverage and PyYAML alone).
"""

import os
import random
import sys
import tempfile
import unittest

from helpers import declarative, keel_checkout, keel_validate

SEEDS = range(50)
UNRENDERED = ("appliance", "installation", "overlays", "monitor", "nonsense")

INSTANCE = (
    {"hostname": "blog"},
    {"hostname": "blog", "fqdn": "blog.example.org"},
    {"hostname": ""},
    {"hostname": "blog", "colour": "blue"},
    {"hostname": 42},
)
SECURITY = (
    {"alerts": "admin@example.org"},
    {"updates_at_first_boot": "force"},
    {"updates": "skip"},
    {"updates_at_first_boot": "weekly"},
    {"firewall": "on"},
)


def rand_doc(rng: random.Random) -> dict:
    doc = {"version": rng.choice([1, 1, 1, 2])}
    if rng.random() < 0.8:
        doc["instance"] = rng.choice(INSTANCE)
    if rng.random() < 0.6:
        doc["security"] = rng.choice(SECURITY)
    if rng.random() < 0.4:
        doc[rng.choice(UNRENDERED)] = {"a": 1}
    return doc


class TestCanonicalProperties(unittest.TestCase):
    def test_canonical_is_idempotent(self):
        for seed in SEEDS:
            rng = random.Random(seed)
            doc = rand_doc(rng)
            once = declarative.canonical(doc)
            self.assertEqual(declarative.canonical(once), once)

    def test_canonical_does_not_mutate_its_argument(self):
        for seed in SEEDS:
            rng = random.Random(seed)
            doc = rand_doc(rng)
            before = repr(doc)
            declarative.canonical(doc)
            self.assertEqual(repr(doc), before)


class TestValidateProperties(unittest.TestCase):
    def test_the_verdict_is_the_same_under_canonical(self):
        for seed in SEEDS:
            rng = random.Random(seed)
            doc = rand_doc(rng)
            plain = declarative._validate_local(doc) == []
            renamed = declarative._validate_local(
                declarative.canonical(doc)
            ) == []
            self.assertEqual(plain, renamed)

    def test_a_valid_document_stays_valid_when_an_unrendered_section_goes(
        self,
    ):
        for seed in SEEDS:
            rng = random.Random(seed)
            doc = rand_doc(rng)
            if declarative._validate_local(doc) != []:
                continue
            for key in list(doc):
                if key in declarative.RENDERED_SECTIONS or key == "version":
                    continue
                without = {k: v for k, v in doc.items() if k != key}
                self.assertEqual(
                    declarative._validate_local(without),
                    [],
                    f"seed {seed}: dropping {key} changed the verdict",
                )

    def test_rendering_is_the_same_under_canonical(self):
        for seed in SEEDS:
            rng = random.Random(seed)
            doc = rand_doc(rng)
            self.assertEqual(
                declarative.render_env(doc, {}),
                declarative.render_env(declarative.canonical(doc), {}),
            )


class TestKeelProperties(unittest.TestCase):
    """The same generated documents through keel, when it is at hand"""

    def setUp(self):
        self.keel = keel_validate()
        if self.keel is None:
            self.skipTest("keel is not at hand (set KEEL_SRC)")

    def test_the_verdict_is_the_same_under_canonical(self):
        for seed in SEEDS:
            rng = random.Random(seed)
            doc = rand_doc(rng)
            plain = self.keel(doc) == []
            renamed = self.keel(declarative.canonical(doc)) == []
            self.assertEqual(plain, renamed)


IPV4_METHODS = ("static", "dhcp", "manual", "none")
IPV6_METHODS = ("static", "auto", "dhcp", "manual", "none")


def rand_network(rng: random.Random) -> dict:
    """A random but valid network section, for the render parity property"""
    network = {"managed_by": rng.choice(["file", "file", "host"])}
    nameservers = []
    for _ in range(rng.randrange(5)):
        nameservers.append(rng.choice([
            f"192.0.2.{rng.randrange(1, 255)}",
            f"2001:db8:{rng.randrange(1, 4096):x}::1",
        ]))
    if nameservers:
        network["nameservers"] = nameservers
    interfaces = {}
    for index in range(rng.randrange(4)):
        iface = {}
        if rng.random() < 0.8:
            method = rng.choice(IPV4_METHODS)
            family = {"method": method}
            if method == "static":
                family["address"] = f"192.0.2.{rng.randrange(1, 255)}/24"
                if rng.random() < 0.5:
                    family["gateway"] = "192.0.2.1"
            iface["ipv4"] = family
        if rng.random() < 0.8:
            method = rng.choice(IPV6_METHODS)
            family = {"method": method}
            if method == "static":
                family["address"] = (
                    f"2001:db8:{rng.randrange(1, 4096):x}::1/64"
                )
                if rng.random() < 0.5:
                    family["gateway"] = "fe80::1"
                if rng.random() < 0.5:
                    family["slaac"] = rng.random() < 0.5
            iface["ipv6"] = family
        interfaces[f"eth{index}"] = iface
    network["interfaces"] = interfaces
    return network


class TestNetworkRenderParity(unittest.TestCase):
    """Random valid network sections render the same in both readers

    The seeded generator crosses methods, families, several interfaces,
    gateways and up to four nameservers of both families, so drift
    between the port and keel's original shows up without hand-picking
    cases. Keel-gated, like the rest of the differential tests.
    """

    def setUp(self):
        checkout = keel_checkout()
        if checkout is None:
            self.skipTest("keel is not at hand (set KEEL_SRC)")
        if checkout not in sys.path:
            sys.path.insert(0, checkout)
        from keel.spec.render import network_env as keel_network_env

        self.keel_network_env = keel_network_env

    def test_random_network_sections_render_the_same_variables(self):
        for seed in SEEDS:
            rng = random.Random(seed)
            network = rand_network(rng)
            with self.subTest(seed=seed):
                ours = declarative._network_env(network)
                theirs = self.keel_network_env(network)
                self.assertEqual(ours, theirs)


class TestLoadFuzz(unittest.TestCase):
    """load() on arbitrary bytes either returns a mapping or says why"""

    def test_random_bytes_never_raise_anything_else(self):
        rng = random.Random(1234)
        for _ in range(200):
            blob = bytes(rng.randrange(256) for _ in range(rng.randrange(64)))
            with tempfile.NamedTemporaryFile(delete=False) as fob:
                fob.write(blob)
                path = fob.name
            try:
                try:
                    doc = declarative.load(path)
                except declarative.DeclarativeError:
                    continue
                self.assertIsInstance(doc, dict)
            finally:
                os.remove(path)


if __name__ == "__main__":
    unittest.main()
