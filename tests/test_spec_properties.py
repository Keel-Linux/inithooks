# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""Properties that must hold for every document, generated at random

A corpus pins the cases someone thought of; these tests pin the invariants
that must hold for all of them. The generator is seeded, so a failure is
reproducible, and stdlib only, so the suite needs no property-testing
dependency (the CI runner installs pytest, coverage and PyYAML alone).
"""

import os
import random
import tempfile
import unittest

from helpers import declarative, keel_validate

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
