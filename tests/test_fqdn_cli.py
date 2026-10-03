"""bin/fqdn.py (run by firstboot.d/31fqdn) with the dialogs faked

The screen asks the fully qualified domain name, prefilled with the name
the machine has, and prints HOSTNAME= and FQDN= for the hook; with --fqdn
(a preseeded FQDN) it asks nothing. With --record it writes what the hook
applied into /etc/hosts and the instance description. Every path is a
scratch file and keel is not on PATH, so nothing touches the live system.
"""

import importlib.util
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from os.path import abspath, dirname, join
from unittest import mock

import yaml

from fake_dialog import ESC, OK, FakeConsole, load_wrapper

dw = load_wrapper()

FQDN_PY = join(dirname(dirname(abspath(__file__))), "bin", "fqdn.py")


def load_fqdn():
    spec = importlib.util.spec_from_file_location("fqdn_cli", FQDN_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FqdnCase(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.dir = scratch.name
        self.spec = join(self.dir, "instance.yaml")
        self.hosts = join(self.dir, "hosts")
        with open(self.hosts, "w") as fob:
            fob.write("127.0.0.1\tlocalhost\n127.0.1.1\tblog\n")

    def environ(self):
        return {"INITHOOKS_DECL": self.spec, "INITHOOKS_HOSTS": self.hosts,
                "PATH": join(self.dir, "nowhere")}

    def run_fqdn(self, *answers, argv=()):
        """Run fqdn.py ARGV with the dialogs answering ANSWERS; returns
        (exit status, stdout, stderr, the console)"""
        cli = load_fqdn()
        console = FakeConsole(*answers)
        out, err = io.StringIO(), io.StringIO()
        status = 0
        with (
            mock.patch.object(dw.dialog, "Dialog", return_value=console),
            mock.patch.object(cli.signal, "signal"),
            mock.patch.object(cli.sys, "argv", ["fqdn.py", *argv]),
            mock.patch.dict(cli.os.environ, self.environ(), clear=True),
            redirect_stdout(out),
            redirect_stderr(err),
        ):
            try:
                cli.main()
            except SystemExit as stopped:
                status = stopped.code
        return status, out.getvalue(), err.getvalue(), console

    def read_spec(self):
        with open(self.spec) as fob:
            return yaml.safe_load(fob)

    def read_hosts(self):
        with open(self.hosts) as fob:
            return fob.read()


class TestAsk(FqdnCase):
    def test_the_typed_name_is_printed_for_the_hook(self):
        status, out, _, console = self.run_fqdn(
            (OK, "blog.example.org"), argv=("--current=blog",))

        self.assertEqual(status, 0)
        self.assertEqual(out, "HOSTNAME=blog\nFQDN=blog.example.org\n")
        self.assertEqual(console.widgets(), ["inputbox"])

    def test_the_box_is_prefilled_with_the_current_hostname(self):
        _, _, _, console = self.run_fqdn((OK, "blog.example.org"),
                                         argv=("--current=blog",))

        self.assertEqual(console.calls[0][3]["init"], "blog")
        self.assertEqual(console.calls[0][3]["title"], "Domain name")
        self.assertIn("blog.example.org", console.calls[0][1])
        self.assertEqual(console.calls[0][3]["ok_label"], "Apply")
        self.assertTrue(console.calls[0][3]["no_cancel"])

    def test_a_dotted_hostname_is_the_prefill_as_it_is(self):
        _, out, _, console = self.run_fqdn(
            (OK, "blog.example.org"), argv=("--current=blog.example.org",))

        self.assertEqual(console.calls[0][3]["init"], "blog.example.org")
        self.assertEqual(out, "HOSTNAME=blog\nFQDN=blog.example.org\n")

    def test_the_declared_fqdn_is_the_prefill_under_keel_init(self):
        with open(self.spec, "w") as fob:
            yaml.safe_dump({"version": 1, "instance": {
                "hostname": "blog", "fqdn": "blog.example.org"}}, fob)

        _, _, _, console = self.run_fqdn((OK, "blog.example.org"),
                                         argv=("--current=blog",))

        self.assertEqual(console.calls[0][3]["init"], "blog.example.org")

    def test_an_empty_answer_keeps_what_the_machine_has(self):
        status, out, _, console = self.run_fqdn((OK, "  "),
                                                argv=("--current=blog",))

        self.assertEqual((status, out), (0, ""))
        self.assertEqual(console.widgets(), ["inputbox"])

    def test_a_name_that_is_not_a_domain_is_refused_and_asked_again(self):
        _, out, _, console = self.run_fqdn(
            (OK, "http://blog.example.org"), OK, (OK, "blog.example.org"),
            argv=("--current=blog",))

        self.assertEqual(console.widgets(), ["inputbox", "msgbox", "inputbox"])
        self.assertEqual(console.calls[1][3]["title"], "Error")
        self.assertIn("http://blog.example.org", console.calls[1][1])
        # what was typed stays in the box to be corrected
        self.assertEqual(console.calls[2][3]["init"],
                         "http://blog.example.org")
        self.assertEqual(out, "HOSTNAME=blog\nFQDN=blog.example.org\n")

    def test_a_single_label_is_kept_as_the_hostname_after_a_notice(self):
        status, out, _, console = self.run_fqdn(
            (OK, "blog"), OK, argv=("--current=blog",))

        self.assertEqual(status, 0)
        self.assertEqual(console.widgets(), ["inputbox", "yesno"])
        notice = console.calls[1]
        self.assertEqual(notice[3]["title"], "Domain name")
        self.assertIn("no certificate", notice[1].lower())
        self.assertEqual((notice[3]["yes_label"], notice[3]["no_label"]),
                         ("Continue", "Back"))
        self.assertEqual(out, "HOSTNAME=blog\nFQDN=\n")

    def test_back_from_the_notice_asks_again_with_the_label(self):
        _, out, _, console = self.run_fqdn(
            (OK, "blog"), "cancel", (OK, "blog.example.org"),
            argv=("--current=web",))

        self.assertEqual(console.widgets(), ["inputbox", "yesno", "inputbox"])
        self.assertEqual(console.calls[2][3]["init"], "blog")
        self.assertEqual(out, "HOSTNAME=blog\nFQDN=blog.example.org\n")

    def test_escape_in_the_box_asks_again(self):
        _, out, _, console = self.run_fqdn(
            (ESC, ""), (OK, "blog.example.org"), argv=("--current=blog",))

        self.assertEqual(console.widgets(), ["inputbox", "inputbox"])
        self.assertEqual(out, "HOSTNAME=blog\nFQDN=blog.example.org\n")

    def test_the_name_is_normalised_before_it_is_printed(self):
        _, out, _, _ = self.run_fqdn((OK, " Blog.Example.org. "),
                                     argv=("--current=blog",))

        self.assertEqual(out, "HOSTNAME=blog\nFQDN=blog.example.org\n")

    def test_a_description_that_does_not_read_is_fatal(self):
        with open(self.spec, "w") as fob:
            fob.write("version: [1\n")

        status, out, err, console = self.run_fqdn(argv=("--current=blog",))

        self.assertEqual((status, out), (1, ""))
        self.assertIn("not valid YAML", err)
        self.assertEqual(console.calls, [])


class TestPreseeded(FqdnCase):
    def test_a_preseeded_fqdn_asks_nothing(self):
        status, out, _, console = self.run_fqdn(
            argv=("--fqdn=Blog.example.org", "--current=web"))

        self.assertEqual((status, out), (0, "HOSTNAME=blog\n"
                                            "FQDN=blog.example.org\n"))
        self.assertEqual(console.calls, [])

    def test_a_preseeded_single_label_is_the_hostname_alone(self):
        status, out, _, _ = self.run_fqdn(argv=("--fqdn=blog",))

        self.assertEqual((status, out), (0, "HOSTNAME=blog\nFQDN=\n"))

    def test_the_declared_hostname_goes_with_the_declared_fqdn(self):
        # a described machine: 00declarative rendered both, 09hostname set
        # the hostname, and this hook changes neither
        with open(self.spec, "w") as fob:
            yaml.safe_dump({"version": 1, "instance": {
                "hostname": "wp", "fqdn": "blog.example.org"}}, fob)

        _, out, _, _ = self.run_fqdn(argv=("--fqdn=blog.example.org",))

        self.assertEqual(out, "HOSTNAME=wp\nFQDN=blog.example.org\n")

    def test_a_preseeded_name_with_a_description_that_does_not_read(self):
        with open(self.spec, "w") as fob:
            fob.write("version: [1\n")

        status, _, err, _ = self.run_fqdn(argv=("--fqdn=blog.example.org",))

        self.assertEqual(status, 1)
        self.assertIn("not valid YAML", err)

    def test_a_preseeded_name_that_is_not_a_domain_is_fatal(self):
        status, out, err, console = self.run_fqdn(
            argv=("--fqdn=blog_1.example.org",))

        self.assertEqual((status, out), (1, ""))
        self.assertIn("blog_1.example.org", err)
        self.assertEqual(console.calls, [])


class TestRecord(FqdnCase):
    def test_the_description_is_written(self):
        status, out, err, console = self.run_fqdn(
            argv=("--record", "--hostname=blog", "--fqdn=blog.example.org"))

        self.assertEqual((status, out, err), (0, "", ""))
        self.assertEqual(console.calls, [])
        self.assertEqual(self.read_spec(), {
            "version": 1,
            "instance": {"hostname": "blog", "fqdn": "blog.example.org"},
            "tls": {"acme": {"domains": ["blog.example.org"]}}})
        # the hosts file is the --hosts step's, after the rename
        self.assertEqual(self.read_hosts(),
                         "127.0.0.1\tlocalhost\n127.0.1.1\tblog\n")

    def test_the_rest_of_the_description_is_preserved(self):
        with open(self.spec, "w") as fob:
            yaml.safe_dump({"version": 1, "instance": {"hostname": "old"},
                            "app": {"email": "a@example.org"},
                            "tls": {"acme": {"enabled": True,
                                             "domains": ["www.example.org"]}}},
                           fob)

        self.run_fqdn(argv=("--record", "--hostname=blog",
                            "--fqdn=blog.example.org"))

        self.assertEqual(self.read_spec(), {
            "version": 1,
            "instance": {"hostname": "blog", "fqdn": "blog.example.org"},
            "app": {"email": "a@example.org"},
            "tls": {"acme": {"enabled": True, "domains": ["www.example.org"]}}})

    def test_a_description_that_declares_the_name_is_not_written(self):
        with open(self.spec, "w") as fob:
            fob.write("# kept as the operator wrote it\n"
                      "version: 1\ninstance:\n  hostname: wp\n"
                      "  fqdn: blog.example.org\n"
                      "tls:\n  acme:\n    domains: [blog.example.org]\n")

        status, _, err, _ = self.run_fqdn(
            argv=("--record", "--hostname=wp", "--fqdn=blog.example.org"))

        self.assertEqual(status, 0)
        self.assertIn("already declares the name", err)
        with open(self.spec) as fob:
            self.assertTrue(fob.read().startswith("# kept"))

    def test_a_hostname_alone_is_recorded_without_a_domain(self):
        # the options in the hook's order, --record last
        self.run_fqdn(argv=("--hostname=blog", "--fqdn=", "--record"))

        self.assertEqual(self.read_spec(),
                         {"version": 1, "instance": {"hostname": "blog"}})

    def test_a_description_that_cannot_be_written_is_fatal(self):
        self.spec = join(self.dir, "missing", "instance.yaml")

        status, _, err, _ = self.run_fqdn(
            argv=("--record", "--hostname=blog", "--fqdn=blog.example.org"))

        self.assertEqual(status, 1)
        self.assertIn(self.spec, err)

    def test_a_description_that_does_not_read_is_fatal(self):
        with open(self.spec, "w") as fob:
            fob.write("version: [1\n")

        status, _, err, _ = self.run_fqdn(
            argv=("--record", "--hostname=blog", "--fqdn=blog.example.org"))

        self.assertEqual(status, 1)
        self.assertIn("not valid YAML", err)

    def test_record_needs_the_hostname(self):
        status, _, err, _ = self.run_fqdn(argv=("--record",))

        self.assertEqual(status, 1)
        self.assertIn("--record needs --hostname", err)


class TestHosts(FqdnCase):
    def test_the_entry_is_written(self):
        status, out, err, console = self.run_fqdn(
            argv=("--hosts", "--hostname=blog", "--fqdn=blog.example.org"))

        self.assertEqual((status, out, err), (0, "", ""))
        self.assertEqual(console.calls, [])
        self.assertEqual(self.read_hosts(), "127.0.0.1\tlocalhost\n"
                                            "127.0.1.1 blog.example.org blog\n")
        self.assertFalse(os.path.exists(self.spec))

    def test_a_hostname_alone(self):
        self.run_fqdn(argv=("--hosts", "--hostname=web", "--fqdn="))

        self.assertEqual(self.read_hosts(), "127.0.0.1\tlocalhost\n"
                                            "127.0.1.1\tblog\n127.0.1.1 web\n")

    def test_hosts_that_cannot_be_written_is_fatal(self):
        os.remove(self.hosts)
        os.mkdir(self.hosts)

        status, _, err, _ = self.run_fqdn(
            argv=("--hosts", "--hostname=blog", "--fqdn=blog.example.org"))

        self.assertEqual(status, 1)
        self.assertIn(self.hosts, err)

    def test_hosts_needs_the_hostname(self):
        status, _, err, _ = self.run_fqdn(argv=("--hosts",))

        self.assertEqual(status, 1)
        self.assertIn("--hosts needs --hostname", err)

    def test_the_default_paths_are_the_machine_s(self):
        cli = load_fqdn()
        with mock.patch.dict(cli.os.environ, {}, clear=True):
            self.assertEqual(cli.hosts_path(), "/etc/hosts")
            self.assertEqual(cli.fqdn.spec_path(cli.os.environ,
                                                exists=lambda p: False),
                             "/etc/keel/instance.yaml")


class TestMachine(FqdnCase):
    """--machine: the name the machine has, for a first boot nobody
    answers and for an operator who skipped, printed as the answer is"""

    def test_the_hostname_and_the_domain_of_its_hosts_line(self):
        with open(self.hosts, "w") as fob:
            fob.write("127.0.1.1 keel-web1.pop.coop keel-web1\n")

        status, out, err, console = self.run_fqdn(
            argv=("--machine", "--current=keel-web1"))

        self.assertEqual((status, err), (0, ""))
        self.assertEqual(out, "HOSTNAME=keel-web1\nFQDN=keel-web1.pop.coop\n")
        self.assertEqual(console.calls, [])

    def test_a_hostname_without_a_domain(self):
        status, out, _, _ = self.run_fqdn(argv=("--machine", "--current=web"))

        self.assertEqual((status, out), (0, "HOSTNAME=web\nFQDN=\n"))

    def test_a_hosts_file_that_does_not_exist_gives_no_domain(self):
        os.remove(self.hosts)

        status, out, _, _ = self.run_fqdn(argv=("--machine", "--current=web"))

        self.assertEqual((status, out), (0, "HOSTNAME=web\nFQDN=\n"))

    def test_a_hosts_file_that_cannot_be_read_is_fatal(self):
        os.remove(self.hosts)
        os.mkdir(self.hosts)

        status, _, err, _ = self.run_fqdn(argv=("--machine", "--current=web"))

        self.assertEqual(status, 1)
        self.assertIn(self.hosts, err)

    def test_machine_needs_the_current_name(self):
        status, _, err, _ = self.run_fqdn(argv=("--machine",))

        self.assertEqual(status, 1)
        self.assertIn("--machine needs --current", err)


class TestUsage(FqdnCase):
    def test_an_unknown_option_is_a_usage_error(self):
        status, _, err, _ = self.run_fqdn(argv=("--nonsense",))

        self.assertEqual(status, 1)
        self.assertIn("Syntax", err)

    def test_help(self):
        status, _, err, _ = self.run_fqdn(argv=("--help",))

        self.assertEqual(status, 1)
        self.assertIn("--record", err)

    def test_an_argument_is_a_usage_error(self):
        status, _, err, _ = self.run_fqdn(argv=("blog.example.org",))

        self.assertEqual(status, 1)
        self.assertIn("Syntax", err)

    def test_the_script_is_its_own_entry_point(self):
        import runpy

        err = io.StringIO()
        with (
            mock.patch.object(sys, "argv", ["fqdn.py", "--help"]),
            redirect_stderr(err),
            self.assertRaises(SystemExit) as stopped,
        ):
            runpy.run_path(FQDN_PY, run_name="__main__")

        self.assertEqual(stopped.exception.code, 1)
        self.assertIn("Syntax", err.getvalue())


if __name__ == "__main__":
    unittest.main()
