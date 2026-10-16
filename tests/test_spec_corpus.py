# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""The fixture corpus, run through both readers (differential testing)

The same documents keel validates are validated here, so the two readers
of one description cannot disagree about what it may say. Differential
testing is the technique: the same input through both implementations,
and the verdicts compared. The one allowed disagreement is a section keel
gained that this reader does not render; each fixture's expectation says
so, and TestTheReadersDisagreeOnlyAboutUnrenderedSections holds the line.
"""

import glob
import unittest
from os.path import abspath, basename, dirname, join

from helpers import declarative, keel_validate

FIXTURES = join(dirname(abspath(__file__)), "fixtures", "specs")

# name -> (accepted by this reader's fallback, accepted by keel,
#          fragments an error must contain for the reader that rejects)
CASES = {
    "valid_full.yaml": (True, True, ()),
    "issue31.yaml": (True, True, ()),
    "invalid_rendered_key.yaml": (
        False,
        False,
        ("instance.colour: unknown key",),
    ),
    "invalid_unknown_section.yaml": (
        True,
        False,
        ("unknown top level key",),
    ),
    "invalid_appliance.yaml": (
        True,
        False,
        ("appliance.name: must match",),
    ),
}


def fixtures():
    return sorted(glob.glob(join(FIXTURES, "*.yaml")))


class TestEveryFixtureIsCovered(unittest.TestCase):
    def test_the_table_names_exactly_the_fixtures_on_disk(self):
        self.assertEqual({basename(p) for p in fixtures()}, set(CASES))


class TestTheFallbackVerdict(unittest.TestCase):
    def test_the_reader_verdict_and_the_errors_it_reports(self):
        for name, (accept, _keel, fragments) in CASES.items():
            with self.subTest(fixture=name):
                doc = declarative.load(join(FIXTURES, name))
                errors = declarative._validate_local(doc)
                self.assertEqual(errors == [], accept)
                if accept:
                    continue
                for fragment in fragments:
                    self.assertTrue(
                        any(fragment in error for error in errors), errors
                    )


class TestKeelAgrees(unittest.TestCase):
    """The same corpus through keel, when keel is at hand"""

    def setUp(self):
        self.keel = keel_validate()
        if self.keel is None:
            self.skipTest("keel is not at hand (set KEEL_SRC)")

    def test_the_keel_verdict_and_the_errors_it_reports(self):
        for name, (_local, accept, fragments) in CASES.items():
            with self.subTest(fixture=name):
                doc = declarative.load(join(FIXTURES, name))
                errors = self.keel(doc)
                self.assertEqual(errors == [], accept)
                if accept:
                    continue
                for fragment in fragments:
                    self.assertTrue(
                        any(fragment in error for error in errors), errors
                    )

    def test_the_readers_disagree_only_about_unrendered_sections(self):
        for name, (_local, _keel, _fragments) in CASES.items():
            with self.subTest(fixture=name):
                doc = declarative.load(join(FIXTURES, name))
                local = declarative._validate_local(doc) == []
                keel = self.keel(doc) == []
                if local == keel:
                    continue
                # the only allowed disagreement is a section outside the
                # tuple this reader renders
                extra = set(doc) - set(declarative.RENDERED_SECTIONS)
                self.assertTrue(
                    extra, f"{name} disagrees on a rendered section"
                )


if __name__ == "__main__":
    unittest.main()
