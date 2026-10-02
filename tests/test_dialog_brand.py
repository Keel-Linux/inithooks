"""What the first boot shows the operator names Keel Linux, not TurnKey

The backtitle every first boot dialog carries is set by whoever creates the
Dialog. The hooks of this package pass Keel Linux; the hooks of appliance
repositories and of common written before the change still pass the
TurnKey title, and Dialog shows those as Keel Linux too, so no appliance
has to be released for its first boot to stop naming another distribution.

The text the dialogs of bin/ show, and the init fence page a browser gets
before the first boot has run, are checked for the name and the address
of TurnKey. What stays, and why, is listed in ALLOWED: commands and hosts
a script runs or reaches, which the operator is not shown as branding.
"""

import ast
import unittest
from os.path import abspath, dirname, join

from fake_dialog import load_wrapper

dw = load_wrapper()

ROOT = dirname(dirname(abspath(__file__)))
SHOWN = [
    "bin/reboot-ask.py",
    "bin/secalerts.py",
    "bin/secupdates-ask.py",
    "bin/setpass.py",
]
# Strings that name TurnKey and stay: a command name kept for
# compatibility (the error text tells the operator to run it, and it is
# what is installed), and the variable keel-init sets for the hooks
# (setpass.py reads it), which is never shown.
ALLOWED = {
    "turnkey-install-security-updates",
    "_TURNKEY_INIT",
}
FIRST_BOOT = "Keel Linux - First boot configuration"


def backtitle(title: str) -> str:
    d = dw.Dialog(title)
    args = d.console.persistent_args
    return args[args.index("--backtitle") + 1]


def strings(path: str) -> list[str]:
    """Every string literal of the Python file at PATH but its docstrings"""
    with open(join(ROOT, path)) as fob:
        tree = ast.parse(fob.read())
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(
            node, (ast.Module, ast.FunctionDef, ast.ClassDef)
        ) and ast.get_docstring(node, clean=False) is not None:
            docstrings.add(id(node.body[0].value))
    return [
        node.value
        for node in ast.walk(tree)
        if isinstance(node, ast.Constant)
        and isinstance(node.value, str)
        and id(node) not in docstrings
    ]


def turnkey_in(text: str) -> bool:
    for allowed in ALLOWED:
        text = text.replace(allowed, "")
    return "turnkey" in text.lower()


class TestBacktitle(unittest.TestCase):
    def test_the_old_first_boot_title_reads_keel_linux(self):
        self.assertEqual(
            backtitle("TurnKey GNU/Linux - First boot configuration"),
            FIRST_BOOT,
        )

    def test_the_short_old_title_reads_keel_linux(self):
        self.assertEqual(
            backtitle("TurnKey Linux - First boot configuration"), FIRST_BOOT
        )

    def test_any_old_title_keeps_what_follows_the_name(self):
        self.assertEqual(
            backtitle("TurnKey GNU/Linux - Reboot after kernel update"),
            "Keel Linux - Reboot after kernel update",
        )

    def test_a_keel_title_is_left_as_it_is(self):
        self.assertEqual(backtitle(FIRST_BOOT), FIRST_BOOT)

    def test_a_title_naming_turnkey_elsewhere_is_left_as_it_is(self):
        title = "Restore from a TurnKey Linux backup"
        self.assertEqual(backtitle(title), title)


class TestShownText(unittest.TestCase):
    def test_the_hooks_name_keel_linux_in_their_title(self):
        for path in SHOWN:
            with self.subTest(path=path):
                titles = [
                    s for s in strings(path) if " - " in s and "Linux" in s
                ]
                self.assertTrue(titles, f"{path} has no Dialog title")
                for title in titles:
                    self.assertTrue(title.startswith("Keel Linux - "), title)

    def test_no_dialog_text_names_turnkey(self):
        for path in SHOWN:
            for text in strings(path):
                with self.subTest(path=path, text=text[:60]):
                    self.assertFalse(turnkey_in(text))

    def test_the_update_screen_checks_it_can_reach_debian_security(self):
        # the updates come from security.debian.org (Keel-Linux/common
        # conf/bootstrap_apt), so that is the host worth resolving; the
        # TurnKey archive is no source of a Keel image
        hosts = [s for s in strings("bin/secupdates-ask.py") if "." in s]
        self.assertIn("security.debian.org", hosts)
        self.assertNotIn("archive.turnkeylinux.org", hosts)

    def test_the_security_alerts_mail_names_no_turnkey_address(self):
        with open(join(ROOT, "bin/secalerts.sh")) as fob:
            script = fob.read()
        self.assertNotIn("turnkeylinux.org", script)

    def test_the_init_fence_page_names_keel_linux(self):
        with open(join(ROOT, "turnkey-init-fence/htdocs/index.html")) as fob:
            page = fob.read()
        visible = page.replace('src="/turnkey-init-root.png"', "")
        self.assertNotIn("turnkey", visible.lower())
        self.assertIn("Keel Linux", visible)


if __name__ == "__main__":
    unittest.main()
