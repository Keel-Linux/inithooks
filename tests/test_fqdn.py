"""libinithooks.fqdn: the fully qualified domain name of the machine

What the first boot hook 31fqdn records once the operator has answered:
the hostname and the name /etc/hosts answers for it, and the instance
description (instance.hostname, instance.fqdn, tls.acme.domains when the
description has none). The checks on a typed name are here too, so the
screen and a preseeded FQDN refuse the same things.

keel exposes no writer for the description, so the one here follows
confconsole's (keelcli.py): the new document is written beside the old
one, handed to `keel spec validate --no-secret-files` when keel is
installed, and moved into place only then. keel is a stub on PATH in
these tests; nothing touches the live system.
"""

import os
import stat
import tempfile
import unittest
from os.path import abspath, dirname, exists, join

import yaml

from helpers import declarative
from libinithooks import fqdn

REPO = dirname(dirname(abspath(__file__)))

DEBIAN_HOSTS = (
    "127.0.0.1\tlocalhost\n"
    "127.0.1.1\tblog\n"
    "\n"
    "# The following lines are desirable for IPv6 capable hosts\n"
    "::1     localhost ip6-localhost ip6-loopback\n"
    "ff02::1 ip6-allnodes\n"
    "ff02::2 ip6-allrouters\n"
)


class TestNormalize(unittest.TestCase):
    def test_a_domain_name_is_accepted_as_typed(self):
        self.assertEqual(fqdn.normalize("blog.example.org"),
                         ("blog.example.org", None))

    def test_whitespace_and_one_trailing_dot_are_dropped(self):
        self.assertEqual(fqdn.normalize("  blog.example.org. \n"),
                         ("blog.example.org", None))

    def test_only_one_trailing_dot_is_the_root(self):
        self.assertEqual(fqdn.normalize("blog.example.org..")[0], "")

    def test_the_name_is_lower_cased(self):
        # DNS names are compared without case; the files hold one spelling
        self.assertEqual(fqdn.normalize("Blog.Example.ORG"),
                         ("blog.example.org", None))

    def test_a_single_label_is_a_valid_name(self):
        self.assertEqual(fqdn.normalize("blog"), ("blog", None))

    def test_digits_and_dashes_inside_a_label_are_accepted(self):
        self.assertEqual(fqdn.normalize("web-2.example.org"),
                         ("web-2.example.org", None))

    def test_an_empty_answer_is_empty_and_not_a_problem(self):
        # the hook keeps what the machine has
        self.assertEqual(fqdn.normalize("   "), ("", None))

    def test_a_label_may_not_start_or_end_with_a_dash(self):
        for typed in ("-blog.example.org", "blog-.example.org"):
            with self.subTest(typed=typed):
                name, problem = fqdn.normalize(typed)
                self.assertEqual(name, "")
                self.assertIn(typed, problem)

    def test_an_empty_label_is_refused(self):
        for typed in ("blog..example.org", ".example.org", "..."):
            with self.subTest(typed=typed):
                self.assertEqual(fqdn.normalize(typed)[0], "")

    def test_a_scheme_a_path_a_port_or_a_space_is_refused(self):
        for typed in ("http://blog.example.org", "blog.example.org/wp",
                      "blog.example.org:443", "blog example.org",
                      "blog_1.example.org", "blög.example.org"):
            with self.subTest(typed=typed):
                name, problem = fqdn.normalize(typed)
                self.assertEqual(name, "")
                self.assertIn("blog.example.org", problem)

    def test_a_label_longer_than_63_characters_is_refused(self):
        self.assertEqual(fqdn.normalize("a" * 64 + ".example.org")[0], "")
        self.assertEqual(fqdn.normalize("a" * 63 + ".example.org")[1], None)

    def test_a_name_longer_than_253_characters_is_refused(self):
        label = "a" * 63
        fits = ".".join([label, label, label, "a" * 61])
        self.assertEqual(len(fits), 253)
        self.assertEqual(fqdn.normalize(fits)[1], None)
        self.assertEqual(fqdn.normalize(fits + "b")[0], "")


class TestSplit(unittest.TestCase):
    def test_the_hostname_is_the_first_label(self):
        self.assertEqual(fqdn.split("blog.example.org"),
                         ("blog", "blog.example.org"))

    def test_a_single_label_is_a_hostname_without_a_domain(self):
        self.assertEqual(fqdn.split("blog"), ("blog", ""))


class TestDeclared(unittest.TestCase):
    def test_the_names_the_description_declares(self):
        self.assertEqual(fqdn.declared({"instance": {
            "hostname": "blog", "fqdn": "blog.example.org"}}),
            ("blog", "blog.example.org"))

    def test_none_when_it_declares_nothing(self):
        for document in ({}, {"instance": None}, {"instance": "x"},
                         {"instance": {}}):
            self.assertEqual(fqdn.declared(document), ("", ""))


class TestHostnameFor(unittest.TestCase):
    DOCUMENT = {"instance": {"hostname": "wp", "fqdn": "blog.example.org"}}

    def test_the_first_label(self):
        self.assertEqual(fqdn.hostname_for("blog.example.org", {}), "blog")
        self.assertEqual(fqdn.hostname_for("blog", {}), "blog")

    def test_the_declared_hostname_beside_the_unchanged_fqdn(self):
        # 09hostname set it from the same description
        self.assertEqual(fqdn.hostname_for("blog.example.org", self.DOCUMENT),
                         "wp")

    def test_another_name_is_a_change_and_takes_its_first_label(self):
        self.assertEqual(fqdn.hostname_for("shop.example.org", self.DOCUMENT),
                         "shop")

    def test_without_a_declared_hostname_the_first_label(self):
        document = {"instance": {"fqdn": "blog.example.org"}}
        self.assertEqual(fqdn.hostname_for("blog.example.org", document),
                         "blog")


class TestPrefill(unittest.TestCase):
    def test_the_current_hostname_when_the_description_names_none(self):
        self.assertEqual(fqdn.prefill("blog", {"version": 1}), "blog")

    def test_a_dotted_hostname_is_used_as_it_is(self):
        # what `pct create --hostname blog.example.org` set
        self.assertEqual(fqdn.prefill("blog.example.org", {}),
                         "blog.example.org")

    def test_the_declared_fqdn_comes_first(self):
        # keel-init asks again on a machine whose description answers
        document = {"instance": {"hostname": "blog",
                                 "fqdn": "blog.example.org"}}
        self.assertEqual(fqdn.prefill("blog", document), "blog.example.org")

    def test_a_description_whose_instance_is_not_a_mapping(self):
        self.assertEqual(fqdn.prefill("blog", {"instance": "x"}), "blog")


class TestHostsWithName(unittest.TestCase):
    def test_the_short_entry_09hostname_leaves_is_replaced_in_place(self):
        text = fqdn.hosts_with_name(DEBIAN_HOSTS, "blog", "blog.example.org")

        self.assertEqual(text, DEBIAN_HOSTS.replace(
            "127.0.1.1\tblog\n", "127.0.1.1 blog.example.org blog\n"))

    def test_an_entry_at_the_address_naming_the_host_is_replaced(self):
        before = DEBIAN_HOSTS.replace(
            "127.0.1.1\tblog\n", "127.0.1.1 old.example.org blog\n")

        text = fqdn.hosts_with_name(before, "blog", "blog.example.org")

        self.assertIn("127.0.1.1 blog.example.org blog\n", text)
        self.assertNotIn("old.example.org", text)

    def test_a_file_without_an_entry_gets_one_appended(self):
        before = "127.0.0.1\tlocalhost\n"

        text = fqdn.hosts_with_name(before, "blog", "blog.example.org")

        self.assertEqual(text, before + "127.0.1.1 blog.example.org blog\n")

    def test_an_empty_file_gets_the_entry(self):
        self.assertEqual(fqdn.hosts_with_name("", "blog", "blog.example.org"),
                         "127.0.1.1 blog.example.org blog\n")

    def test_the_container_manager_s_line_is_rewritten_in_place(self):
        # pct writes `<ip> name.domain name` for a static address, and
        # the rename of 31fqdn has already put the new hostname in it; a
        # second line at 127.0.1.1 would come after it and hostname -f
        # would keep answering the old domain
        before = ("127.0.0.1 localhost\n192.0.2.10 blog.old.example blog\n"
                  "::1 localhost ip6-localhost\n")

        text = fqdn.hosts_with_name(before, "blog", "blog.example.org")

        self.assertEqual(text, "127.0.0.1 localhost\n"
                               "192.0.2.10 blog.example.org blog\n"
                               "::1 localhost ip6-localhost\n")

    def test_a_line_of_another_host_with_a_domain_is_kept(self):
        before = "192.0.2.10 old.example.org old\n"

        text = fqdn.hosts_with_name(before, "blog", "blog.example.org")

        self.assertEqual(text, before + "127.0.1.1 blog.example.org blog\n")

    def test_the_name_is_matched_without_case(self):
        text = fqdn.hosts_with_name("127.0.1.1 Blog\n", "blog",
                                    "blog.example.org")

        self.assertEqual(text, "127.0.1.1 blog.example.org blog\n")

    def test_a_line_naming_the_host_beside_another_name_is_kept(self):
        # not this hook's to rewrite: keel apply says the same
        before = "127.0.0.1\tlocalhost blog\n"

        text = fqdn.hosts_with_name(before, "blog", "blog.example.org")

        self.assertEqual(
            text, before + "127.0.1.1 blog.example.org blog\n")

    def test_another_host_s_entry_and_the_comments_are_kept(self):
        before = ("# hosts\n127.0.1.1 other\n"
                  "2001:db8:1::20 db.example.org db\n")

        text = fqdn.hosts_with_name(before, "blog", "blog.example.org")

        self.assertEqual(text, before + "127.0.1.1 blog.example.org blog\n")

    def test_a_last_line_without_a_newline_is_still_one_line(self):
        text = fqdn.hosts_with_name("127.0.0.1 localhost", "blog",
                                    "blog.example.org")

        self.assertEqual(text, "127.0.0.1 localhost\n"
                               "127.0.1.1 blog.example.org blog\n")

    def test_two_lines_naming_the_host_become_one_entry(self):
        # a short line 09hostname left and an entry an operator wrote
        before = ("127.0.1.1 blog\n127.0.0.1 localhost\n"
                  "127.0.1.1 blog.example.org blog\n")

        text = fqdn.hosts_with_name(before, "blog", "blog.example.org")

        self.assertEqual(text, "127.0.1.1 blog.example.org blog\n"
                               "127.0.0.1 localhost\n")

    def test_writing_the_same_name_twice_changes_nothing(self):
        once = fqdn.hosts_with_name(DEBIAN_HOSTS, "blog", "blog.example.org")

        self.assertEqual(
            fqdn.hosts_with_name(once, "blog", "blog.example.org"), once)

    def test_without_a_domain_the_entry_names_the_host_alone(self):
        before = DEBIAN_HOSTS.replace(
            "127.0.1.1\tblog\n", "127.0.1.1 blog.example.org blog\n")

        text = fqdn.hosts_with_name(before, "blog", "")

        self.assertIn("127.0.1.1 blog\n", text)
        self.assertNotIn("blog.example.org", text)

    def test_a_hostname_that_is_the_fqdn_is_named_once(self):
        text = fqdn.hosts_with_name("127.0.0.1 localhost\n",
                                    "blog.example.org", "blog.example.org")

        self.assertEqual(text, "127.0.0.1 localhost\n"
                               "127.0.1.1 blog.example.org\n")


class TestInHosts(unittest.TestCase):
    """The dotted name /etc/hosts gives the host, as keel inspect reads it
    (keel.inspect.hostname.fqdn_in_hosts): from the first line naming it"""

    def test_the_dotted_name_on_the_host_s_line(self):
        # what pct writes for a container whose host has a search domain
        text = "127.0.0.1 localhost\n127.0.1.1 web1.pop.coop web1\n"

        self.assertEqual(fqdn.in_hosts(text, "web1"), "web1.pop.coop")

    def test_nothing_when_no_line_names_the_host(self):
        self.assertEqual(fqdn.in_hosts("127.0.0.1 localhost\n", "web"), "")

    def test_nothing_when_the_first_line_naming_it_has_no_domain(self):
        # a resolver answers from the first line, so the later one does
        # not give the host its name
        text = "127.0.1.1 web\n192.0.2.10 web.example.org web\n"

        self.assertEqual(fqdn.in_hosts(text, "web"), "")

    def test_comments_and_short_lines_are_not_entries(self):
        text = "# 127.0.1.1 web.example.org web\nweb\n"

        self.assertEqual(fqdn.in_hosts(text, "web"), "")

    def test_the_host_is_matched_without_case_and_as_a_first_label(self):
        text = "127.0.1.1 Web.Example.org\n"

        self.assertEqual(fqdn.in_hosts(text, "web"), "web.example.org")


class TestMachine(unittest.TestCase):
    """(hostname, fqdn) the machine has, for a first boot nobody answers"""

    def test_a_hostname_alone_has_no_domain(self):
        self.assertEqual(fqdn.machine("web", DEBIAN_HOSTS.replace(
            "blog", "web")), ("web", ""))

    def test_the_domain_comes_from_the_host_s_line(self):
        text = "127.0.1.1 keel-web1.pop.coop keel-web1\n"

        self.assertEqual(fqdn.machine("keel-web1", text),
                         ("keel-web1", "keel-web1.pop.coop"))

    def test_a_dotted_hostname_is_the_fqdn_and_its_first_label(self):
        self.assertEqual(fqdn.machine("Web.Example.org.", ""),
                         ("web", "web.example.org"))

    def test_a_name_that_is_no_domain_name_gives_no_fqdn(self):
        text = "127.0.1.1 web_1.example.org web_1\n"

        self.assertEqual(fqdn.machine("web_1", text), ("web_1", ""))


class TestUpdated(unittest.TestCase):
    def test_a_new_description_gets_version_instance_and_domains(self):
        self.assertEqual(
            fqdn.updated({"version": 1}, "blog", "blog.example.org"),
            {"version": 1,
             "instance": {"hostname": "blog", "fqdn": "blog.example.org"},
             "tls": {"acme": {"domains": ["blog.example.org"]}}})

    def test_the_rest_of_the_description_is_kept_in_order(self):
        document = {"version": 1, "instance": {"hostname": "old"},
                    "app": {"email": "admin@example.org"},
                    "database": {"server": {"engine": "mariadb"}}}

        after = fqdn.updated(document, "blog", "blog.example.org")

        self.assertEqual(list(after), ["version", "instance", "app",
                                       "database", "tls"])
        self.assertEqual(after["app"], document["app"])
        self.assertEqual(after["database"], document["database"])

    def test_the_document_given_is_not_changed(self):
        document = {"version": 1, "instance": {"hostname": "old"}}

        fqdn.updated(document, "blog", "blog.example.org")

        self.assertEqual(document, {"version": 1,
                                    "instance": {"hostname": "old"}})

    def test_declared_domains_are_kept(self):
        document = {"version": 1, "tls": {"acme": {
            "enabled": True, "domains": ["www.example.org"]}}}

        after = fqdn.updated(document, "blog", "blog.example.org")

        self.assertEqual(after["tls"]["acme"]["domains"], ["www.example.org"])

    def test_an_empty_domains_list_is_filled(self):
        document = {"version": 1, "tls": {"acme": {"enabled": False,
                                                   "domains": []}}}

        after = fqdn.updated(document, "blog", "blog.example.org")

        self.assertEqual(after["tls"]["acme"],
                         {"enabled": False, "domains": ["blog.example.org"]})

    def test_enabled_is_never_touched(self):
        for acme in ({}, {"enabled": True}, {"enabled": False}):
            with self.subTest(acme=acme):
                after = fqdn.updated({"version": 1, "tls": {"acme": acme}},
                                     "blog", "blog.example.org")
                self.assertEqual(after["tls"]["acme"].get("enabled"),
                                 acme.get("enabled"))

    def test_a_hostname_without_a_domain_declares_no_fqdn_or_domain(self):
        document = {"version": 1, "instance": {"hostname": "old",
                                               "fqdn": "old.example.org"}}

        after = fqdn.updated(document, "blog", "")

        self.assertEqual(after, {"version": 1,
                                 "instance": {"hostname": "blog"}})

    def test_the_unchanged_name_leaves_the_description_equal(self):
        # the preseed of a described machine: nothing to write
        document = {"version": 1,
                    "instance": {"hostname": "wp", "fqdn": "blog.example.org"},
                    "tls": {"acme": {"domains": ["blog.example.org"]}}}

        after = fqdn.updated(document, "wp", "blog.example.org")

        self.assertEqual(after, document)

    def test_a_declared_hostname_is_kept_beside_the_unchanged_fqdn(self):
        document = {"version": 1,
                    "instance": {"hostname": "wp", "fqdn": "blog.example.org"}}

        after = fqdn.updated(document, "blog", "blog.example.org")

        self.assertEqual(after["instance"]["hostname"], "wp")

    def test_a_missing_hostname_is_set_beside_the_unchanged_fqdn(self):
        document = {"version": 1, "instance": {"fqdn": "blog.example.org"}}

        after = fqdn.updated(document, "blog", "blog.example.org")

        self.assertEqual(after["instance"],
                         {"fqdn": "blog.example.org", "hostname": "blog"})

    def test_a_changed_name_sets_the_hostname(self):
        document = {"version": 1,
                    "instance": {"hostname": "wp", "fqdn": "blog.example.org"}}

        after = fqdn.updated(document, "shop", "shop.example.org")

        self.assertEqual(after["instance"],
                         {"hostname": "shop", "fqdn": "shop.example.org"})

    def test_a_changed_bare_label_sets_the_hostname(self):
        document = {"version": 1, "instance": {"hostname": "wp"}}

        self.assertEqual(fqdn.updated(document, "web", "")["instance"],
                         {"hostname": "web"})
        self.assertEqual(fqdn.updated(document, "wp", ""), document)

    def test_a_tls_section_of_another_shape_is_left_alone(self):
        for tls in ("x", {"acme": "yes"}, {"acme": {"domains": "a"}}):
            with self.subTest(tls=tls):
                after = fqdn.updated({"version": 1, "tls": tls}, "blog",
                                     "blog.example.org")
                self.assertEqual(after["tls"], tls)


class TestSpecPath(unittest.TestCase):
    def test_inithooks_decl_names_the_file(self):
        self.assertEqual(fqdn.spec_path({"INITHOOKS_DECL": "/x/i.yaml"}),
                         "/x/i.yaml")

    def test_the_description_00declarative_read(self):
        self.assertEqual(fqdn.spec_path({}, exists=lambda p: True),
                         declarative.DECL_PATHS[0])
        self.assertEqual(
            fqdn.spec_path({}, exists=lambda p: p == declarative.DECL_DEFAULT),
            declarative.DECL_DEFAULT)

    def test_the_default_when_there_is_none_yet(self):
        self.assertEqual(fqdn.spec_path({}, exists=lambda p: False),
                         "/etc/keel/instance.yaml")


class FileCase(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.dir = scratch.name
        self.spec = join(self.dir, "instance.yaml")
        self.hosts = join(self.dir, "hosts")
        self.bin = join(self.dir, "bin")
        os.mkdir(self.bin)
        self.path = os.environ.get("PATH", "")

    def tearDown(self):
        os.environ["PATH"] = self.path

    def keel(self, body="exit 0"):
        """A keel on PATH that records its arguments and runs BODY"""
        self.calls = join(self.dir, "keel.calls")
        with open(join(self.bin, "keel"), "w") as fob:
            fob.write(f"#!/bin/bash\necho \"$*\" >> '{self.calls}'\n{body}\n")
        os.chmod(join(self.bin, "keel"), 0o755)
        os.environ["PATH"] = self.bin + os.pathsep + self.path

    def no_keel(self):
        os.environ["PATH"] = self.bin

    def read(self, path):
        with open(path) as fob:
            return fob.read()


class TestLoad(FileCase):
    def test_a_description_that_is_not_there_yet_starts_at_version_1(self):
        self.assertEqual(fqdn.load(self.spec), {"version": 1})

    def test_the_description_on_disk(self):
        with open(self.spec, "w") as fob:
            fob.write("version: 1\napp:\n  email: a@example.org\n")

        self.assertEqual(fqdn.load(self.spec),
                         {"version": 1, "app": {"email": "a@example.org"}})

    def test_one_that_does_not_read_is_the_reader_s_error(self):
        with open(self.spec, "w") as fob:
            fob.write("version: [1\n")

        with self.assertRaises(declarative.DeclarativeError):
            fqdn.load(self.spec)


class TestWriteSpec(FileCase):
    DOCUMENT = {"version": 1,
                "instance": {"hostname": "blog", "fqdn": "blog.example.org"},
                "tls": {"acme": {"domains": ["blog.example.org"]}}}

    def test_the_document_is_written_root_only_keys_in_order(self):
        self.no_keel()

        fqdn.write_spec(self.spec, self.DOCUMENT)

        self.assertEqual(
            self.read(self.spec),
            "version: 1\n"
            "instance:\n  hostname: blog\n  fqdn: blog.example.org\n"
            "tls:\n  acme:\n    domains:\n    - blog.example.org\n")
        self.assertEqual(stat.S_IMODE(os.stat(self.spec).st_mode), 0o600)
        self.assertEqual(sorted(os.listdir(self.dir)), ["bin", "instance.yaml"])

    def test_a_description_keeps_the_mode_it_had(self):
        self.no_keel()
        with open(self.spec, "w") as fob:
            fob.write("version: 1\n")
        os.chmod(self.spec, 0o644)

        fqdn.write_spec(self.spec, self.DOCUMENT)

        self.assertEqual(stat.S_IMODE(os.stat(self.spec).st_mode), 0o644)

    def test_what_is_written_reads_back_as_the_same_document(self):
        self.no_keel()
        document = {**self.DOCUMENT, "network": {"managed_by": "host"},
                    "database": {"server": {"listen": ["::1", "127.0.0.1"]}}}

        fqdn.write_spec(self.spec, document)

        self.assertEqual(declarative.load(self.spec), document)

    def test_keel_validates_the_staged_file_before_it_is_moved_in(self):
        self.keel("[[ -e \"${@: -1}\" ]] && echo staged-exists >> '"
                  + join(self.dir, "keel.calls") + "'")

        fqdn.write_spec(self.spec, self.DOCUMENT)

        calls = self.read(self.calls).splitlines()
        staged = calls[0].split()[-1]
        self.assertEqual(calls[0], "spec validate --no-secret-files --spec "
                                   + staged)
        self.assertEqual(calls[1], "staged-exists")
        self.assertNotEqual(staged, self.spec)
        self.assertTrue(staged.startswith(self.spec + "."))
        self.assertFalse(exists(staged))
        self.assertEqual(yaml.safe_load(self.read(self.spec)), self.DOCUMENT)

    def test_a_document_keel_refuses_leaves_the_file_as_it_was(self):
        with open(self.spec, "w") as fob:
            fob.write("version: 1\n")
        self.keel("echo 'Error: tls.acme.domains: domain is invalid' >&2\n"
                  "exit 3")

        with self.assertRaises(fqdn.FqdnError) as refused:
            fqdn.write_spec(self.spec, self.DOCUMENT)

        self.assertIn("was NOT changed", str(refused.exception))
        self.assertIn("tls.acme.domains: domain is invalid",
                      str(refused.exception))
        self.assertEqual(self.read(self.spec), "version: 1\n")
        self.assertEqual(
            [f for f in os.listdir(self.dir) if f.startswith("instance.yaml")],
            ["instance.yaml"])

    def test_a_directory_that_cannot_be_written_is_an_error(self):
        self.no_keel()

        with self.assertRaises(fqdn.FqdnError) as refused:
            fqdn.write_spec(join(self.dir, "missing", "instance.yaml"),
                            self.DOCUMENT)

        self.assertIn("missing", str(refused.exception))

    def test_a_file_that_cannot_be_replaced_is_an_error(self):
        self.no_keel()
        os.mkdir(self.spec)

        with self.assertRaises(fqdn.FqdnError):
            fqdn.write_spec(self.spec, self.DOCUMENT)

        self.assertEqual(sorted(os.listdir(self.dir)), ["bin", "instance.yaml"])


class TestWriteHosts(FileCase):
    def test_the_entry_is_written_and_the_file_stays_world_readable(self):
        with open(self.hosts, "w") as fob:
            fob.write(DEBIAN_HOSTS)
        os.chmod(self.hosts, 0o644)

        fqdn.write_hosts(self.hosts, "blog", "blog.example.org")

        self.assertEqual(self.read(self.hosts), fqdn.hosts_with_name(
            DEBIAN_HOSTS, "blog", "blog.example.org"))
        self.assertEqual(stat.S_IMODE(os.stat(self.hosts).st_mode), 0o644)
        self.assertEqual(sorted(os.listdir(self.dir)), ["bin", "hosts"])

    def test_a_missing_file_is_made_with_the_entry(self):
        fqdn.write_hosts(self.hosts, "blog", "blog.example.org")

        self.assertEqual(self.read(self.hosts),
                         "127.0.1.1 blog.example.org blog\n")
        self.assertEqual(stat.S_IMODE(os.stat(self.hosts).st_mode), 0o644)

    def test_a_file_that_cannot_be_written_is_an_error(self):
        with self.assertRaises(fqdn.FqdnError):
            fqdn.write_hosts(join(self.dir, "missing", "hosts"), "blog",
                             "blog.example.org")


if __name__ == "__main__":
    unittest.main()
