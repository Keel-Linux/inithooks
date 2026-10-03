"""bin/setpass.py (run by firstboot.d/30rootpass) with the dialogs faked

ESC in the password dialogs must never end setpass.py without a password:
before, "really quit?" and Yes exited 0 without calling chpasswd, and
30rootpass carried on with the root (or admin) password unchanged. chpasswd
is replaced at the subprocess boundary and records what it was given.

A password set before the first boot, by `pct create --password` or by LXC
in the root file system, is offered as Keep, first, but only one the image
did not ship: passwd -S must say it is usable, the image must carry its
build date (/etc/keel/build-date, written by common's seal-root) and the
password must have changed on or after it, and the shadow field must be
neither empty nor a known placeholder. passwd -S is replaced at the
subprocess boundary; the shadow file and the build date are scratch files.
The field is compared, never printed or logged.
"""

import datetime
import importlib.util
import io
import logging
import os
import subprocess
import tempfile
import unittest
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from os.path import abspath, dirname, join
from unittest import mock

from fake_dialog import ESC, OK, FakeConsole, load_wrapper

dw = load_wrapper()

SETPASS = join(dirname(dirname(abspath(__file__))), "bin", "setpass.py")

USABLE = "root P 2026-10-02 0 99999 7 -1\n"
LOCKED = "root L 2026-10-02 0 99999 7 -1\n"
EMPTY = "root NP 2026-10-02 0 99999 7 -1\n"

BUILT = datetime.date(2026, 10, 2)
BUILD_DAY = (BUILT - datetime.date(1970, 1, 1)).days
HASH = "$y$j9T$scratchsaltscratch$scratchhashscratchhashscratchhash12"
PLACEHOLDER = "U6aMy0wojraho"


def load_setpass():
    spec = importlib.util.spec_from_file_location("setpass", SETPASS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@contextmanager
def capture_logs():
    """Every record logged meanwhile, at any level, as text"""
    records: list[str] = []

    class Keep(logging.Handler):
        def emit(self, record):
            records.append(record.getMessage())

    root = logging.getLogger()
    handler, level = Keep(level=logging.DEBUG), root.level
    root.addHandler(handler)
    root.setLevel(logging.DEBUG)
    try:
        yield records
    finally:
        root.removeHandler(handler)
        root.setLevel(level)


def passwd_answering(stdout: str = LOCKED, code: int = 0):
    """A subprocess.run stand-in for `passwd -S` printing STDOUT"""
    return mock.MagicMock(
        return_value=subprocess.CompletedProcess([], code, stdout, "")
    )


class SetpassCase(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.dir = scratch.name
        self.shadow = join(self.dir, "shadow")
        self.build_date = join(self.dir, "build-date")
        self.marker = join(self.dir, "container")
        self.write_shadow()
        self.write_build_date(BUILT.isoformat())
        self.in_container(True)

    def write_shadow(self, field=HASH, changed=BUILD_DAY + 1, user="root"):
        """A shadow file whose USER entry has FIELD, last changed on day
        CHANGED (an int, or the text of the field)"""
        with open(self.shadow, "w") as fob:
            fob.write("daemon:*:20000:0:99999:7:::\n")
            fob.write(f"{user}:{field}:{changed}:0:99999:7:::\n")

    def write_build_date(self, text):
        with open(self.build_date, "w") as fob:
            fob.write(text + "\n")

    def in_container(self, yes):
        if yes:
            open(self.marker, "w").close()
        elif os.path.exists(self.marker):
            os.remove(self.marker)

    def env(self, extra=None):
        return {
            "INITHOOKS_SHADOW": self.shadow,
            "INITHOOKS_BUILD_DATE": self.build_date,
            **(extra or {}),
        }

    def run_setpass(self, *answers, status=LOCKED, argv=("root",),
                    environ=None):
        """Run setpass.py ARGV with the dialogs answering ANSWERS and
        passwd -S printing STATUS; return what chpasswd read ("" when it
        was not run), the console and the passwd -S stand-in. The exit
        status, None when main() returned, is self.status."""
        setpass = load_setpass()
        console = FakeConsole(*answers)
        chpasswd = mock.MagicMock()
        chpasswd.return_value.communicate.return_value = (b"", b"")
        passwd = passwd_answering(status)
        stdin = mock.MagicMock(encoding="utf-8")
        self.printed = io.StringIO()
        with (
            mock.patch.object(dw.dialog, "Dialog", return_value=console),
            mock.patch.object(setpass.subprocess, "Popen", chpasswd),
            mock.patch.object(setpass.subprocess, "run", passwd),
            mock.patch.object(setpass.signal, "signal"),
            mock.patch.object(setpass.sys, "argv", ["setpass.py", *argv]),
            mock.patch.object(setpass.sys, "stdin", stdin),
            mock.patch.dict(setpass.os.environ, self.env(environ),
                            clear=True),
            mock.patch.object(setpass, "CONTAINER_MARKER", self.marker),
            redirect_stderr(self.printed),
            redirect_stdout(self.printed),
            capture_logs() as self.logged,
        ):
            self.status = None
            try:
                setpass.main()
            except SystemExit as stopped:
                self.status = stopped.code
        # whatever happened, the shadow field went nowhere
        for said in (self.printed.getvalue(), *self.logged, console.shown()):
            self.assertNotIn(HASH, said)
            self.assertNotIn(PLACEHOLDER, said)
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

    def assert_not_offered(self):
        _, console, _ = self.run_setpass(
            (OK, "Generate"), OK, OK, status=USABLE
        )
        self.assertEqual(self.menu_tags(console), ["Generate", "Manual"])

    # The image must not have shipped the password (review of #35): a
    # build with ROOT_PASS, or an older WordPress image with the
    # placeholder, has passwd -S say P all the same.

    def test_a_password_changed_on_the_build_day_is_offered(self):
        # common's seal-root fails a build whose root is not locked, so a
        # usable password on a stamped image was set after it; a container
        # created the day the image was built is the maintainer's case
        self.write_shadow(changed=BUILD_DAY)
        _, console, _ = self.run_setpass((OK, "Keep"), status=USABLE)
        self.assertEqual(self.menu_tags(console)[0], "Keep")

    def test_a_password_older_than_the_image_is_not_offered(self):
        self.write_shadow(changed=BUILD_DAY - 1)
        self.assert_not_offered()

    def test_an_image_without_a_build_date_offers_nothing(self):
        os.remove(self.build_date)
        self.assert_not_offered()

    def test_an_unreadable_build_date_offers_nothing(self):
        self.write_build_date("yesterday")
        self.assert_not_offered()

    def test_the_placeholder_of_older_images_is_not_offered(self):
        self.write_shadow(field=PLACEHOLDER)
        self.assert_not_offered()

    def test_an_empty_field_is_not_offered_whatever_passwd_says(self):
        self.write_shadow(field="")
        self.assert_not_offered()

    def test_a_last_change_of_zero_or_none_is_not_offered(self):
        for changed in (0, "", "x"):
            with self.subTest(changed=changed):
                self.write_shadow(changed=changed)
                self.assert_not_offered()

    def test_an_account_missing_from_shadow_is_not_offered(self):
        self.write_shadow(user="someoneelse")
        self.assert_not_offered()

    def test_a_short_shadow_entry_is_not_offered(self):
        with open(self.shadow, "w") as fob:
            fob.write("root\n")
        self.assert_not_offered()

    def test_an_unreadable_shadow_file_is_not_offered(self):
        os.remove(self.shadow)
        self.assert_not_offered()

    def test_the_build_date_is_read_as_utc_days(self):
        setpass = load_setpass()
        self.assertEqual(setpass.build_day(self.build_date), BUILD_DAY)

    def test_outside_a_container_keep_names_this_machine(self):
        self.in_container(False)
        _, console, _ = self.run_setpass((OK, "Keep"), status=USABLE)
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
        self.write_shadow(user="admin")
        _, console, passwd = self.run_setpass((OK, "Keep"), status=USABLE,
                                              argv=("admin",))
        self.assertEqual(self.menu_tags(console)[0], "Keep")
        self.assertEqual(passwd.call_args.args[0], ["passwd", "-S", "admin"])


class TestPreseededKeep(SetpassCase):
    """ROOT_PASS=KEEP: keep the password the hypervisor set, without a
    screen, under exactly the conditions the screen offers Keep. Anything
    else is an error, never a password "KEEP" and never a screen."""

    def run_keep(self, value="KEEP", status=USABLE, environ=None):
        return self.run_setpass(status=status, environ=environ,
                                argv=("root", f"--pass={value}"))

    def assert_kept(self, value="KEEP"):
        given, console, _ = self.run_keep(value)
        self.assertIsNone(self.status)
        self.assertEqual(given, "")
        self.assertEqual(console.calls, [])
        self.assertIn("kept", self.printed.getvalue())

    def assert_refused(self, status=USABLE, environ=None):
        given, console, _ = self.run_keep(status=status, environ=environ)
        self.assertEqual(self.status, 1)
        self.assertEqual(given, "")
        self.assertEqual(console.calls, [])
        said = self.printed.getvalue()
        self.assertIn("Error:", said)
        self.assertIn("ROOT_PASS=KEEP", said)

    def test_keep_leaves_a_password_set_after_the_build_alone(self):
        self.assert_kept()

    def test_keep_on_the_build_day_is_accepted(self):
        self.write_shadow(changed=BUILD_DAY)
        self.assert_kept()

    def test_keep_is_read_whatever_its_case(self):
        # "keep" must not become the password either
        for value in ("keep", "Keep"):
            with self.subTest(value=value):
                self.assert_kept(value)

    def test_keep_outside_a_container_is_accepted(self):
        self.in_container(False)
        self.assert_kept()

    def test_keep_of_a_locked_password_fails(self):
        self.assert_refused(status=LOCKED)

    def test_keep_of_an_empty_password_fails(self):
        self.assert_refused(status=EMPTY)

    def test_keep_of_a_password_older_than_the_image_fails(self):
        self.write_shadow(changed=BUILD_DAY - 1)
        self.assert_refused()

    def test_keep_on_an_image_without_a_build_date_fails(self):
        os.remove(self.build_date)
        self.assert_refused()

    def test_keep_of_the_placeholder_fails(self):
        self.write_shadow(field=PLACEHOLDER)
        self.assert_refused()

    def test_keep_under_keel_init_fails(self):
        # keel-init offers no Keep, so no KEEP either
        self.assert_refused(environ={"_TURNKEY_INIT": "y"})

    def test_a_password_containing_keep_is_set(self):
        given, _, _ = self.run_keep("KEEPme-123")
        self.assertEqual(given, "root:KEEPme-123")


if __name__ == "__main__":
    unittest.main()
