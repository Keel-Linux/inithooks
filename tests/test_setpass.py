"""bin/setpass.py (run by firstboot.d/30rootpass) with the dialogs faked

ESC in the password dialogs must never end setpass.py without a password:
before, "really quit?" and Yes exited 0 without calling chpasswd, and
30rootpass carried on with the root (or admin) password unchanged. chpasswd
is replaced at the subprocess boundary and records what it was given.
"""

import importlib.util
import unittest
from os.path import abspath, dirname, join
from unittest import mock

from fake_dialog import ESC, OK, FakeConsole, load_wrapper

dw = load_wrapper()

SETPASS = join(dirname(dirname(abspath(__file__))), "bin", "setpass.py")


def load_setpass():
    spec = importlib.util.spec_from_file_location("setpass", SETPASS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestSetpass(unittest.TestCase):
    def run_setpass(self, *answers):
        """Run setpass.py root with the dialogs answering ANSWERS; return
        what chpasswd read and the console"""
        setpass = load_setpass()
        console = FakeConsole(*answers)
        chpasswd = mock.MagicMock()
        chpasswd.return_value.communicate.return_value = (b"", b"")
        stdin = mock.MagicMock(encoding="utf-8")
        with (
            mock.patch.object(dw.dialog, "Dialog", return_value=console),
            mock.patch.object(setpass.subprocess, "Popen", chpasswd),
            mock.patch.object(setpass.signal, "signal"),
            mock.patch.object(setpass.sys, "argv", ["setpass.py", "root"]),
            mock.patch.object(setpass.sys, "stdin", stdin),
        ):
            setpass.main()
        chpasswd.assert_called_once()
        self.assertEqual(chpasswd.call_args.args[0], ["chpasswd"])
        given = chpasswd.return_value.communicate.call_args.args[0]
        return given.decode(), console

    def test_escape_in_the_password_box_still_sets_the_password(self):
        given, console = self.run_setpass(
            (OK, "Manual"),
            (ESC, ""),
            (OK, "Abcdefg1"),
            (OK, "Abcdefg1"),
        )
        self.assertEqual(given, "root:Abcdefg1")
        self.assertNotIn("yesno", console.widgets())

    def test_escape_in_the_generate_flow_still_sets_the_password(self):
        given, console = self.run_setpass(
            (ESC, ""), (OK, "Generate"), ESC, OK, ESC, OK
        )
        user, _, password = given.partition(":")
        self.assertEqual(user, "root")
        self.assertEqual(len(password), dw.GENERATED_LENGTH)
        self.assertIn(password, console.calls[-1][1])
        self.assertEqual(
            console.widgets(),
            ["menu", "menu", "msgbox", "msgbox", "yesno", "yesno"],
        )


if __name__ == "__main__":
    unittest.main()
