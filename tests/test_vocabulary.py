# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""The vocabulary this reader accepts, frozen, and compared with the other

The same instance description is read twice on a running appliance: here, at
first boot, and by the instance tooling afterwards, which validates and
compares the very same file. Two readers of one document drift apart unless
something holds them together, and drift means an appliance whose
description is valid to one half and rejected by the other.

So the vocabulary is written down here rather than left implicit in the
validator, and when the other reader's source is at hand the two are run over
one document and have to agree. Point KEEL_SRC at that checkout to include
the comparison; without it the frozen table still fails a rename that is not
recorded.
"""

import sys
import types
import unittest
from unittest import mock

from helpers import declarative, doc, keel_validate

# section -> the fields this version accepts, current names only
VOCABULARY = {
    "instance": ("hostname", "fqdn"),
    "app": ("email", "domain", "options"),
    "hub": ("api_key",),
    "security": ("alerts", "updates_at_first_boot"),
}

# One document using every current name, valid by construction
FULL = """
version: 1
instance:
  hostname: blog
  fqdn: blog.example.org
network:
  managed_by: host
  interfaces:
    eth0:
      ipv6:
        method: static
        address: 2001:db8:1::10/64
        gateway: fe80::1
        slaac: false
  nameservers:
    - 2001:db8:1::53
tls:
  acme:
    enabled: false
    challenge: http-01
    domains:
      - blog.example.org
app:
  email: admin@example.org
  domain: blog.example.org
  options:
    ip_bind: "[2001:db8:1::10]"
security:
  alerts: admin@example.org
  updates_at_first_boot: force
first_login_wizard: false
"""

DEPRECATED = FULL.replace("updates_at_first_boot: force", "updates: force")


class TestFrozenVocabulary(unittest.TestCase):
    def test_each_section_accepts_exactly_the_fields_recorded_here(self):
        for section, fields in VOCABULARY.items():
            with self.subTest(section=section):
                body = "\n".join(f"  {field}: skip" for field in fields)
                text = f"version: 1\n{section}:\n{body}\n"
                unknown = [
                    error
                    for error in declarative._validate_local(doc(text))
                    if "unknown key" in error
                ]
                self.assertEqual(unknown, [])

    def test_a_field_outside_the_vocabulary_is_an_unknown_key(self):
        for section in VOCABULARY:
            with self.subTest(section=section):
                text = f"version: 1\n{section}:\n  not_a_field: x\n"
                self.assertIn(
                    f"{section}.not_a_field: unknown key",
                    declarative._validate_local(doc(text)),
                )

    def test_the_full_document_is_valid(self):
        self.assertEqual(declarative._validate_local(doc(FULL)), [])

    def test_a_section_this_reader_does_not_render_is_accepted(self):
        # appliance, installation, overlays and monitor are keel's to
        # check; the fallback validates only the sections it renders, so
        # it does not refuse a section keel gained (inithooks#31)
        text = (
            "version: 1\n"
            "appliance:\n  name: core\n"
            "installation:\n  mode: simple\n"
            "overlays:\n  etcd: disabled\n"
            "monitor:\n  enabled: true\n"
        )
        self.assertEqual(declarative._validate_local(doc(text)), [])

    def test_an_unknown_key_inside_a_rendered_section_is_still_an_error(self):
        text = "version: 1\nsecurity:\n  firewall: on\n"
        self.assertIn(
            "security.firewall: unknown key",
            declarative._validate_local(doc(text)),
        )


class TestRenames(unittest.TestCase):
    def test_a_deprecated_name_is_still_read(self):
        self.assertEqual(declarative._validate_local(doc(DEPRECATED)), [])

    def test_a_deprecated_name_is_reported_with_its_replacement(self):
        messages = declarative.deprecations(doc(DEPRECATED))
        self.assertEqual(len(messages), 1)
        self.assertIn("security.updates is deprecated", messages[0])
        self.assertIn("security.updates_at_first_boot", messages[0])

    def test_the_current_name_is_not_reported(self):
        self.assertEqual(declarative.deprecations(doc(FULL)), [])

    def test_canonical_renames_without_touching_the_document(self):
        original = doc(DEPRECATED)
        renamed = declarative.canonical(original)
        self.assertIn("updates", original["security"])
        self.assertNotIn("updates_at_first_boot", original["security"])
        self.assertNotIn("updates", renamed["security"])
        self.assertEqual(
            renamed["security"]["updates_at_first_boot"], "force"
        )

    def test_the_current_name_wins_when_both_are_present(self):
        both = {"security": {"updates": "skip", "updates_at_first_boot": "force"}}
        self.assertEqual(
            declarative.canonical(both)["security"],
            {"updates_at_first_boot": "force"},
        )

    def test_a_document_that_is_not_a_mapping_is_returned_as_it_is(self):
        self.assertEqual(declarative.canonical(None), None)
        self.assertEqual(declarative.deprecations(None), [])

    def test_a_section_that_is_not_a_mapping_is_left_alone(self):
        broken = {"security": "force"}
        self.assertEqual(declarative.canonical(broken), broken)
        self.assertEqual(declarative.deprecations(broken), [])

    def test_the_deprecated_name_renders_the_same_conf(self):
        current = declarative.render_env(doc(FULL), {})
        deprecated = declarative.render_env(doc(DEPRECATED), {})
        self.assertEqual(current, deprecated)
        self.assertIn("export SEC_UPDATES=FORCE", current)


class TestBothReadersAgree(unittest.TestCase):
    """The instance tooling's validate() over the same documents"""

    def setUp(self):
        self.validate = keel_validate()
        if self.validate is None:
            self.skipTest("the instance tooling is not here (set KEEL_SRC)")

    def test_the_full_document_is_valid_to_both(self):
        self.assertEqual(self.validate(doc(FULL)), [])
        self.assertEqual(declarative._validate_local(doc(FULL)), [])

    def test_the_deprecated_name_is_read_by_both(self):
        self.assertEqual(self.validate(doc(DEPRECATED)), [])
        self.assertEqual(declarative._validate_local(doc(DEPRECATED)), [])

    def test_both_carry_the_same_rename_table(self):
        from keel.spec import compat

        self.assertEqual(compat.RENAMED, declarative.RENAMED)


class TestValidationIsDelegatedToKeel(unittest.TestCase):
    """validate() asks keel when keel is installed, the copy otherwise

    keel is the writer of the description, so its validator decides what
    the description may say; the copy in _validate_local is only the
    fallback for an image without keel. A fake keel stands in here so the
    delegation is tested without keel installed.
    """

    def fake_keel(self, errors):
        calls = []

        def validate(document, **kwargs):
            calls.append(document)
            return errors

        modules = {
            "keel": types.ModuleType("keel"),
            "keel.spec": types.ModuleType("keel.spec"),
            "keel.spec.validate": types.ModuleType("keel.spec.validate"),
        }
        modules["keel.spec.validate"].validate = validate
        return modules, calls

    def test_keel_is_asked_and_its_errors_are_returned(self):
        modules, calls = self.fake_keel(["appliance.name: bad"])
        with mock.patch.dict(sys.modules, modules):
            found = declarative.validate(doc("version: 1\n"))
        self.assertEqual(found, ["appliance.name: bad"])
        self.assertEqual(len(calls), 1)

    def test_keel_accepts_the_sections_the_copy_does_not_know(self):
        modules, _ = self.fake_keel([])
        text = (
            "version: 1\n"
            "instance:\n  hostname: blog\n"
            "appliance:\n  name: core\n"
            "installation:\n  mode: simple\n"
            "overlays:\n"
            "  installer: enabled\n"
            "  etcd: disabled\n"
            "security:\n  alerts: admin@example.org\n"
            "monitor:\n  enabled: true\n  notify:\n    email: true\n"
        )
        with mock.patch.dict(sys.modules, modules):
            self.assertEqual(declarative.validate(doc(text)), [])

    def test_a_deprecated_name_is_canonical_before_keel_sees_it(self):
        modules, calls = self.fake_keel([])
        with mock.patch.dict(sys.modules, modules):
            declarative.validate(doc(DEPRECATED))
        self.assertIn("updates_at_first_boot", calls[0]["security"])
        self.assertNotIn("updates", calls[0]["security"])

    def test_the_copy_answers_when_keel_is_absent(self):
        absent = {"keel": None, "keel.spec": None, "keel.spec.validate": None}
        with mock.patch.dict(sys.modules, absent):
            self.assertIsNone(declarative.keel_validator())
        self.assertEqual(
            declarative._validate_local(doc("version: 1\n")), []
        )


if __name__ == "__main__":
    unittest.main()
