"""bin/setpass.py (run by firstboot.d/30rootpass) with the dialogs faked

ESC in the password dialogs must never end setpass.py without a password:
before, "really quit?" and Yes exited 0 without calling chpasswd, and
30rootpass carried on with the root (or admin) password unchanged. chpasswd
is replaced at the subprocess boundary and records what it was given.

A password set before the first boot, by `pct create --password` or by LXC
in the root file system, is offered as Keep, first: passwd -S is replaced
at the same boundary, and it is the only thing asked about that password,
whose hash is never read.
"""

import importlib.util
import subprocess
import unittest
from os.path import abspath, dirname, join
from unittest import mock

from fake_dialog import ESC, OK, FakeConsole, load_wrapper

dw = load_wrapper()

SETPASS = join(dirname(dirname(abspath(__file__))), "bin", "setpass.py")

USABLE = "root P 2026-10-02 0 99999 7 -1\n"
LOCKED = "root L 2026-10-02 0 99999 7 -1\n"
EMPTY = "root NP 2026-10-02 0 99999 7 -1\n"


def load_setpass():
    spec = importlib.util.spec_from_file_location("setpass", SETPASS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def passwd_answering(stdout: str = LOCKED, code: int = 0):
    """A subprocess.run stand-in for `passwd -S` printing STDOUT"""
    return mock.MagicMock(
        return_value=subprocess.CompletedProcess([], code, stdout, "")
    )


class SetpassCase(unittest.TestCase):
    def run_setpass(self, *answers, status=LOCKED, argv=("root",),
                    environ=None, container=True):
        """Run setpass.py ARGV with the dialogs answering ANSWERS and
        passwd -S printing STATUS; return what chpasswd read ("" when it
        was not run), the console and the passwd -S stand-in"""
        setpass = load_setpass()
        console = FakeConsole(*answers)
        chpasswd = mock.MagicMock()
        chpasswd.return_value.communicate.return_value = (b"", b"")
        passwd = passwd_answering(status)
        stdin = mock.MagicMock(encoding="utf-8")
        with (
            mock.patch.object(dw.dialog, "Dialog", return_value=console),
            mock.patch.object(setpass.subprocess, "Popen", chpasswd),
            mock.patch.object(setpass.subprocess, "run", passwd),
            mock.patch.object(setpass.signal, "signal"),
            mock.patch.object(setpass.sys, "argv", ["setpass.py", *argv]),
            mock.patch.object(setpass.sys, "stdin", stdin),
            mock.patch.dict(setpass.os.environ, environ or {}, clear=True),
            mock.patch.object(setpass.os.path, "exists",
                              return_value=container),
        ):
            setpass.main()
        if not chpasswd.called:
            return "", console, passwd
        chpasswd.assert_called_once()
        self.assertEqual(chpasswd.call_args.args[0], ["chpasswd"])
        given = chpasswd.return_value.communicate.call_args.args[0]
        return given.decode(), console, passwd


class TestSetpass(SetpassCase):
    def test_escape_in_the_password_box_still_sets_the_password(self):
        given, console, _ = self.run_setpass(
            (OK, "Manual"),
            (ESC, ""),
            (OK, "Abcdefg1"),
            (OK, "Abcdefg1"),
        )
        self.assertEqual(given, "root:Abcdefg1")
        self.assertNotIn("yesno", console.widgets())

    def test_escape_in_the_generate_flow_still_sets_the_password(self):
        given, console, _ = self.run_setpass(
            (ESC, ""), (OK, "Generate"), ESC, OK, ESC, OK
        )
        user, _, password = given.partition(":")
        self.assertEqual(user, "root")
        self.assertEqual(len(password), dw.GENERATED_LENGTH)
        # shown on the message, never on the question that follows it
        self.assertIn(password, console.calls[3][1])
        self.assertNotIn(password, console.calls[-1][1])
        self.assertEqual(
            console.widgets(),
            ["menu", "menu", "msgbox", "msgbox", "yesno", "yesno"],
        )


class TestKeepThePasswordOfTheContainer(SetpassCase):
    def menu_tags(self, console) -> list[str]:
        return [tag for tag, _ in console.calls[0][3]["choices"]]

    def test_a_usable_password_is_offered_as_keep_first(self):
        _, console, passwd = self.run_setpass((OK, "Keep"), status=USABLE)
        self.assertEqual(self.menu_tags(console), ["Keep", "Generate", "Manual"])
        keep = console.calls[0][3]["choices"][0][1]
        self.assertIn("set when the container was created", keep)
        self.assertIn("recommended", keep)
        passwd.assert_called_once()
        self.assertEqual(passwd.call_args.args[0], ["passwd", "-S", "root"])

    def test_keep_leaves_the_password_alone(self):
        given, console, _ = self.run_setpass((OK, "Keep"), status=USABLE)
        self.assertEqual(given, "")
        self.assertEqual(console.widgets(), ["menu"])

    def test_generate_below_keep_replaces_it(self):
        given, console, _ = self.run_setpass(
            (OK, "Generate"), OK, OK, status=USABLE
        )
        user, _, password = given.partition(":")
        self.assertEqual((user, len(password)), ("root", dw.GENERATED_LENGTH))
        self.assertEqual(console.widgets(), ["menu", "msgbox", "yesno"])

    def test_manual_below_keep_replaces_it(self):
        given, _, _ = self.run_setpass(
            (OK, "Manual"), (OK, "Abcdefg1"), (OK, "Abcdefg1"), status=USABLE
        )
        self.assertEqual(given, "root:Abcdefg1")

    def test_a_locked_password_is_not_offered(self):
        _, console, _ = self.run_setpass(
            (OK, "Generate"), OK, OK, status=LOCKED
        )
        self.assertEqual(self.menu_tags(console), ["Generate", "Manual"])

    def test_an_empty_password_is_not_offered(self):
        _, console, _ = self.run_setpass(
            (OK, "Generate"), OK, OK, status=EMPTY
        )
        self.assertEqual(self.menu_tags(console), ["Generate", "Manual"])

    def test_passwd_failing_is_not_offered(self):
        setpass = load_setpass()
        for failure in (
            passwd_answering("", code=1),
            mock.MagicMock(side_effect=OSError("no passwd")),
            mock.MagicMock(side_effect=subprocess.TimeoutExpired("passwd", 1)),
        ):
            with mock.patch.object(setpass.subprocess, "run", failure):
                self.assertFalse(setpass.password_usable("root"))

    def test_the_hash_is_never_asked_for(self):
        # passwd -S prints the status; no other command, no file is read
        setpass = load_setpass()
        passwd = passwd_answering(USABLE)
        with (
            mock.patch.object(setpass.subprocess, "run", passwd),
            mock.patch("builtins.open") as opened,
        ):
            self.assertTrue(setpass.password_usable("root"))
        opened.assert_not_called()
        self.assertEqual(passwd.call_args.args[0], ["passwd", "-S", "root"])

    def test_outside_a_container_keep_names_this_machine(self):
        _, console, _ = self.run_setpass(
            (OK, "Keep"), status=USABLE, container=False
        )
        keep = console.calls[0][3]["choices"][0][1]
        self.assertNotIn("container", keep)
        self.assertIn("already set on this machine", keep)

    def test_every_keep_text_fits_the_widest_menu(self):
        # a box 76 wide on an 80 column console cut the first wording off
        # at "(recommende"
        setpass = load_setpass()
        for text in (setpass.KEEP_CONTAINER, setpass.KEEP_MACHINE):
            self.assertLessEqual(
                len("Generate") + len(text) + dw.MENU_MARGIN,
                dw.MENU_MAX_WIDTH,
            )

    def test_keel_init_asks_as_before(self):
        # an explicit run is there to set the password: no Keep
        _, console, passwd = self.run_setpass(
            (OK, "Generate"), OK, OK, status=USABLE,
            environ={"_TURNKEY_INIT": "y"},
        )
        self.assertEqual(self.menu_tags(console), ["Generate", "Manual"])
        passwd.assert_not_called()

    def test_a_preseeded_password_asks_nothing(self):
        given, console, passwd = self.run_setpass(
            status=USABLE, argv=("root", "--pass=Preseeded1")
        )
        self.assertEqual(given, "root:Preseeded1")
        self.assertEqual(console.calls, [])
        passwd.assert_not_called()

    def test_the_admin_account_is_asked_about_itself(self):
        _, _, passwd = self.run_setpass((OK, "Keep"), status=USABLE,
                                        argv=("admin",))
        self.assertEqual(passwd.call_args.args[0], ["passwd", "-S", "admin"])


if __name__ == "__main__":
    unittest.main()
