"""The first boot dialogs, driven through a fake pythondialog

Every test scripts what the operator presses (tests/fake_dialog.py) and
reads back what the wrapper returned and what it put on the screen. The
generated password is offered by get_password() (Keel-Linux/inithooks#23,
from turnkeylinux/inithooks#71 as revised in #74).
"""

import logging
import os
import re
import string
import tempfile
import unittest
from unittest import mock

from fake_dialog import (
    CANCEL,
    ESC,
    OK,
    FakeConsole,
    ScriptExhausted,
    load_wrapper,
)

dw = load_wrapper()

GENERATE = (OK, "Generate")
MANUAL = (OK, "Manual")

# Characters a generated password must never carry, and why: quotes,
# backslash, dollar, backtick and the rest are shell syntax; = ends the
# KEY=value line the database hooks read and bash's read drops a trailing
# one; # : @ / ? % + & are URL delimiters or escapes; ! is history
# expansion; space and other whitespace split words.
NEVER = "\"'`\\$=#:@/?%+&!*;|<>(){}[],^ \t\n"
AMBIGUOUS = "0O1lIo"


def dialog(*answers):
    """A wrapper Dialog whose console answers with ANSWERS"""
    wrapper = dw.Dialog("Keel - First boot configuration")
    wrapper.console = FakeConsole(*answers)
    return wrapper


def shown_password(text: str) -> str:
    """The password in the reverse video band of TEXT"""
    found = re.findall(r"^ *\\Zb\\Zr (\S+) \\Zn$", text, re.MULTILINE)
    if len(found) != 1:
        raise AssertionError(f"no single password band in {text!r}")
    return found[0]


class TestGeneratePassword(unittest.TestCase):
    def test_default_length_is_twenty(self):
        self.assertEqual(dw.GENERATED_LENGTH, 20)
        self.assertEqual(len(dw.generate_password()), 20)

    def test_length_is_honoured(self):
        for length in (12, 16, 33, 64):
            self.assertEqual(len(dw.generate_password(length)), length)

    def test_length_under_twelve_is_refused_not_bumped(self):
        with self.assertRaises(ValueError):
            dw.generate_password(11)

    def test_characters_come_from_the_alphabet(self):
        for _ in range(200):
            password = dw.generate_password()
            self.assertTrue(set(password) <= set(dw.PASSWORD_ALPHABET), password)

    def test_alphabet_has_nothing_a_shell_url_or_hook_would_mangle(self):
        self.assertEqual(set(dw.PASSWORD_ALPHABET) & set(NEVER), set())
        for char in dw.PASSWORD_ALPHABET:
            self.assertTrue(char.isascii() and char.isprintable(), repr(char))

    def test_alphabet_leaves_out_characters_read_as_each_other(self):
        self.assertEqual(set(dw.PASSWORD_ALPHABET) & set(AMBIGUOUS), set())

    def test_alphabet_is_fifty_nine_characters(self):
        # 24 upper, 24 lower, 8 digits, 3 symbols: log2(59) is 5.88 bits a
        # character, about 117 bits at the default length.
        self.assertEqual(len(dw.PASSWORD_ALPHABET), 59)
        self.assertEqual(len(set(dw.PASSWORD_ALPHABET)), 59)
        self.assertEqual(dw.PASSWORD_SYMBOLS, "-.~")

    def test_every_symbol_counts_as_one_for_the_complexity_score(self):
        for symbol in dw.PASSWORD_SYMBOLS:
            self.assertEqual(dw.password_complexity(symbol), 1, symbol)
            self.assertRegex(symbol, r"\W")

    def test_every_class_is_present_and_complexity_is_four(self):
        for _ in range(200):
            password = dw.generate_password(12)
            self.assertRegex(password, "[A-Z]")
            self.assertRegex(password, "[a-z]")
            self.assertRegex(password, "[0-9]")
            self.assertRegex(password, r"\W")
            self.assertEqual(dw.password_complexity(password), 4)

    def test_first_and_last_characters_are_letters_or_digits(self):
        # A leading - reads as an option and a leading ~ as a home
        # directory; a trailing . or - is lost when copied from a sentence.
        for _ in range(200):
            password = dw.generate_password(12)
            self.assertTrue(password[0].isalnum(), password)
            self.assertTrue(password[-1].isalnum(), password)

    def test_every_password_passes_the_manual_validation(self):
        for _ in range(200):
            password = dw.generate_password()
            self.assertIsNone(dw.password_problem(password, 20, 4, []))

    def test_excluded_characters_never_appear(self):
        for _ in range(100):
            password = dw.generate_password(exclude="-.~ABCabc")
            self.assertEqual(set(password) & set("-.~ABCabc"), set())
            self.assertEqual(dw.password_complexity(password), 3)

    def test_excluding_every_letter_and_digit_is_refused(self):
        alnum = string.ascii_letters + string.digits
        with self.assertRaises(ValueError):
            dw.generate_password(exclude=alnum)

    def test_draws_from_the_secrets_module(self):
        with mock.patch.object(
            dw.secrets, "choice", wraps=dw.secrets.choice
        ) as choice:
            dw.generate_password()
        self.assertGreaterEqual(choice.call_count, 20)

    def test_two_passwords_differ(self):
        self.assertNotEqual(dw.generate_password(), dw.generate_password())


class TestPasswordProblem(unittest.TestCase):
    def test_accepts_a_good_password(self):
        self.assertIsNone(dw.password_problem("Abcdefg1", 8, 3, []))

    def test_empty(self):
        self.assertIn("non-empty", dw.password_problem("", 8, 3, []))

    def test_short(self):
        self.assertIn("at least 8", dw.password_problem("Abc1", 8, 3, []))

    def test_regex_requirement(self):
        self.assertIn(
            "complexity requirements",
            dw.password_problem("Abcdefg1", r"^x", 3, []),
        )
        self.assertIsNone(dw.password_problem("xAbcdefg1", r"^x", 3, []))

    def test_complexity_three_and_four(self):
        self.assertIn("at least one number", dw.password_problem("abcdefgh", 8, 3, []))
        self.assertIn("special", dw.password_problem("Abcdefg1", 8, 4, []))

    def test_complexity_above_four_is_reported(self):
        self.assertIn("Insecure", dw.password_problem("Ab1-cdefg", 8, 5, []))

    def test_blacklist(self):
        problem = dw.password_problem("Abcdef\"1", 8, 3, ['"'])
        self.assertIn("can NOT include", problem)


class TestGetPasswordGenerate(unittest.TestCase):
    def test_generate_is_offered_first_and_recommended(self):
        d = dialog(GENERATE, OK, OK)
        d.get_password("Root Password", "Please enter new password.")
        widget, text, _, kwargs = d.console.calls[0]
        self.assertEqual(widget, "menu")
        self.assertIn("Please enter new password.", text)
        tags = [tag for tag, _ in kwargs["choices"]]
        self.assertEqual(tags, ["Generate", "Manual"])
        self.assertIn("recommended", kwargs["choices"][0][1])

    def test_generated_password_is_shown_confirmed_and_returned(self):
        d = dialog(GENERATE, OK, OK)
        password = d.get_password("Root Password", "text")
        self.assertEqual(d.console.widgets(), ["menu", "msgbox", "yesno"])
        _, shown, _, shown_kwargs = d.console.calls[1]
        _, confirm, _, confirm_kwargs = d.console.calls[2]
        self.assertEqual(len(password), 20)
        self.assertEqual(shown_password(shown), password)
        self.assertIn("not shown again", shown)
        # the screen said so, and the question after it keeps its word
        self.assertNotIn(password, confirm)
        self.assertNotIn("\\Zr", confirm)
        self.assertIn("Did you save the password?", confirm)
        self.assertTrue(shown_kwargs["colors"])
        self.assertEqual(confirm_kwargs["yes_label"], "Saved")
        self.assertIn("New", confirm_kwargs["no_label"])

    def test_only_attributes_are_used_so_a_monochrome_console_shows_it(self):
        d = dialog(GENERATE, OK, OK)
        d.get_password("Root Password", "text")
        codes = set(re.findall(r"\\Z.", d.console.shown()))
        self.assertEqual(codes - {"\\Zb", "\\Zr", "\\Zn"}, set())
        self.assertNotIn("--colors", d.console.persistent_args)

    def test_refused_confirmation_generates_another(self):
        d = dialog(GENERATE, OK, CANCEL, OK, OK)
        password = d.get_password("Root Password", "text")
        self.assertEqual(
            d.console.widgets(), ["menu", "msgbox", "yesno", "msgbox", "yesno"]
        )
        first = shown_password(d.console.calls[1][1])
        self.assertNotEqual(password, first)
        self.assertEqual(shown_password(d.console.calls[3][1]), password)

    def test_nothing_is_returned_before_the_operator_says_saved(self):
        d = dialog(GENERATE, OK, CANCEL, OK, CANCEL)
        with self.assertRaises(ScriptExhausted):
            d.get_password("Root Password", "text")

    def test_generated_password_meets_the_callers_rules(self):
        d = dialog(GENERATE, OK, OK)
        password = d.get_password("t", "x", pass_req=24, min_complexity=4)
        self.assertEqual(len(password), 24)
        self.assertIsNone(dw.password_problem(password, 24, 4, []))

    def test_gen_length_is_used(self):
        d = dialog(GENERATE, OK, OK)
        self.assertEqual(len(d.get_password("t", "x", gen_length=32)), 32)

    def test_blacklisted_characters_are_left_out_of_the_generated_one(self):
        blacklist = ["-", ".", "~"]
        d = dialog(GENERATE, OK, OK)
        password = d.get_password("t", "x", min_complexity=3, blacklist=blacklist)
        self.assertEqual(set(password) & set("-.~"), set())
        self.assertIsNone(dw.password_problem(password, 8, 3, blacklist))

    def test_rules_no_generated_password_can_meet_fall_back_to_manual(self):
        # No generated password starts with !, which is not in the alphabet.
        d = dialog(GENERATE, OK, (OK, "!Abcdefg1"), (OK, "!Abcdefg1"))
        password = d.get_password("t", "x", pass_req=r"^!")
        self.assertEqual(password, "!Abcdefg1")
        self.assertEqual(
            d.console.widgets(), ["menu", "msgbox", "passwordbox", "passwordbox"]
        )
        self.assertIn("type one", d.console.calls[1][1])

    def test_escape_on_the_menu_shows_it_again(self):
        d = dialog((ESC, ""), (ESC, ""), GENERATE, OK, OK)
        self.assertEqual(len(d.get_password("t", "x")), 20)
        self.assertEqual(
            d.console.widgets(), ["menu", "menu", "menu", "msgbox", "yesno"]
        )
        self.assertNotIn("quit", d.console.shown())

    def test_escape_in_the_generate_flow_never_skips_the_password(self):
        # Before, "really quit?" and Yes ended setpass.py with status 0 and
        # no chpasswd, and 30rootpass carried on with the password unset.
        d = dialog(GENERATE, ESC, OK, ESC, OK)
        password = d.get_password("t", "x")
        self.assertEqual(
            d.console.widgets(), ["menu", "msgbox", "msgbox", "yesno", "yesno"]
        )
        for call in d.console.calls[1:3]:
            self.assertEqual(shown_password(call[1]), password)
        for call in d.console.calls[3:]:
            self.assertNotIn(password, call[1])
        self.assertNotIn("quit", d.console.shown())

    def test_the_password_is_on_one_screen_only(self):
        # "It is not shown again": a refused confirmation shows a new
        # password once, and never the one it discarded
        d = dialog(GENERATE, OK, CANCEL, OK, OK)
        password = d.get_password("Root Password", "text")
        bands = [call[1] for call in d.console.calls if "\\Zr" in call[1]]
        self.assertEqual(len(bands), 2)
        self.assertEqual(shown_password(bands[-1]), password)
        self.assertEqual(sum(password in call[1] for call in d.console.calls),
                         1)

    def test_generator_refusing_the_length_falls_back_to_manual(self):
        d = dialog(GENERATE, OK, (OK, "Abcdefg1"), (OK, "Abcdefg1"))
        self.assertEqual(d.get_password("t", "x", gen_length=8), "Abcdefg1")
        self.assertEqual(
            d.console.widgets(), ["menu", "msgbox", "passwordbox", "passwordbox"]
        )
        self.assertIn("type one", d.console.calls[1][1])

    def test_blacklist_leaving_no_letter_or_digit_falls_back_to_manual(self):
        blacklist = list(string.ascii_letters + string.digits)
        d = dialog(GENERATE, OK, (OK, "-.~-.~-.~"), (OK, "-.~-.~-.~"))
        password = d.get_password(
            "t", "x", min_complexity=1, blacklist=blacklist
        )
        self.assertEqual(password, "-.~-.~-.~")
        self.assertEqual(d.console.calls[1][3]["title"], "Error")


KEEP = (OK, "Keep")
KEEP_TEXT = "Password set when the container was created (recommended)"


class TestGetPasswordKeep(unittest.TestCase):
    def test_keep_is_offered_first_and_is_the_only_recommendation(self):
        d = dialog(KEEP)
        d.get_password("Root Password", "text", keep=KEEP_TEXT)
        _, _, _, kwargs = d.console.calls[0]
        tags = [tag for tag, _ in kwargs["choices"]]
        self.assertEqual(tags, ["Keep", "Generate", "Manual"])
        self.assertEqual(kwargs["choices"][0][1], KEEP_TEXT)
        recommended = [tag for tag, info in kwargs["choices"]
                       if "recommended" in info]
        self.assertEqual(recommended, ["Keep"])

    def test_the_menu_is_wide_enough_for_keep_on_an_80_column_console(self):
        d = dialog(KEEP)
        d.get_password("t", "x", keep=KEEP_TEXT)
        _, _, args, _ = d.console.calls[0]
        width = args[1]
        # nothing cut off: the description, the tag column and the margin
        self.assertEqual(
            width, len(KEEP_TEXT) + len("Generate") + dw.MENU_MARGIN
        )
        self.assertLessEqual(width, dw.MENU_MAX_WIDTH)

    def test_the_menu_keeps_its_width_without_keep(self):
        d = dialog(GENERATE, OK, OK)
        d.get_password("t", "x")
        self.assertEqual(d.console.calls[0][2][1], d.width)

    def test_a_menu_wider_than_the_console_is_capped(self):
        d = dialog((OK, "a"))
        d.menu("t", "x", [("a", "y" * 200)])
        self.assertEqual(d.console.calls[0][2][1], dw.MENU_MAX_WIDTH)

    def test_keep_returns_none_and_asks_nothing_else(self):
        d = dialog(KEEP)
        self.assertIsNone(d.get_password("t", "x", keep=KEEP_TEXT))
        self.assertEqual(d.console.widgets(), ["menu"])

    def test_generate_below_keep_still_shows_and_confirms(self):
        d = dialog(GENERATE, OK, OK)
        password = d.get_password("t", "x", keep=KEEP_TEXT)
        self.assertEqual(len(password), 20)
        self.assertEqual(d.console.widgets(), ["menu", "msgbox", "yesno"])

    def test_manual_below_keep_is_the_password_box(self):
        d = dialog(MANUAL, (OK, "Abcdefg1"), (OK, "Abcdefg1"))
        self.assertEqual(d.get_password("t", "x", keep=KEEP_TEXT), "Abcdefg1")

    def test_escape_on_the_menu_with_keep_shows_it_again(self):
        d = dialog((ESC, ""), KEEP)
        self.assertIsNone(d.get_password("t", "x", keep=KEEP_TEXT))
        self.assertEqual(d.console.widgets(), ["menu", "menu"])

    def test_no_keep_without_a_description(self):
        d = dialog(GENERATE, OK, OK)
        d.get_password("t", "x")
        tags = [tag for tag, _ in d.console.calls[0][3]["choices"]]
        self.assertEqual(tags, ["Generate", "Manual"])

    def test_keep_without_the_menu_is_refused(self):
        # offer_generate=False is the password box alone: there is no menu
        # to put Keep on, and a caller asking for both is told so
        with self.assertRaises(ValueError):
            dialog().get_password("t", "x", offer_generate=False,
                                  keep=KEEP_TEXT)


class TestGetPasswordManual(unittest.TestCase):
    def test_manual_is_the_old_prompt_twice(self):
        d = dialog(MANUAL, (OK, "Abcdefg1"), (OK, "Abcdefg1"))
        self.assertEqual(d.get_password("t", "x"), "Abcdefg1")
        self.assertEqual(d.console.widgets(), ["menu", "passwordbox", "passwordbox"])
        self.assertIn("Password Requirements", d.console.calls[1][1])
        self.assertTrue(d.console.calls[1][3]["insecure"])

    def test_manual_rejects_then_accepts(self):
        d = dialog(
            MANUAL,
            (OK, ""), OK,
            (OK, "short"), OK,
            (OK, "abcdefgh"), OK,
            (OK, "Abcdefg1"), (OK, "Mismatch1"), OK,
            (OK, "Abcdefg1"), (OK, "Abcdefg1"),
        )
        self.assertEqual(d.get_password("t", "x"), "Abcdefg1")
        errors = [text for w, text, _, kw in d.console.calls if kw.get("title") == "Error"]
        self.assertEqual(len(errors), 4)
        self.assertIn("mismatch", errors[-1])

    def test_blacklist_is_listed_and_enforced(self):
        d = dialog(
            MANUAL, (OK, 'Abcdef"1'), OK, (OK, "Abcdefg1"), (OK, "Abcdefg1")
        )
        self.assertEqual(d.get_password("t", "x", blacklist=['"']), "Abcdefg1")
        self.assertIn('NOT contain these characters: "', d.console.calls[1][1])

    def test_escape_in_the_password_box_asks_again(self):
        d = dialog(
            MANUAL,
            (ESC, ""),
            (OK, "Abcdefg1"),
            (ESC, ""),
            (OK, "Abcdefg1"),
        )
        self.assertEqual(d.get_password("t", "x"), "Abcdefg1")
        self.assertEqual(d.console.widgets(), ["menu"] + ["passwordbox"] * 4)
        self.assertNotIn("quit", d.console.shown())

    def test_escape_in_the_password_box_without_the_menu(self):
        d = dialog((ESC, ""), (OK, "Abcdefg1"), (OK, "Abcdefg1"))
        password = d.get_password("t", "x", offer_generate=False)
        self.assertEqual(password, "Abcdefg1")
        self.assertEqual(d.console.widgets(), ["passwordbox"] * 3)

    def test_offer_generate_false_is_the_old_behaviour(self):
        d = dialog((OK, "Abcdefg1"), (OK, "Abcdefg1"))
        password = d.get_password("t", "x", offer_generate=False)
        self.assertEqual(password, "Abcdefg1")
        self.assertEqual(d.console.widgets(), ["passwordbox", "passwordbox"])
        self.assertNotIn("Generate", d.console.shown())


class TestNoPasswordInAnyLog(unittest.TestCase):
    """dialog.log is the root logger's file (logging.basicConfig in the
    wrapper); DIALOG_DEBUG turns it up to DEBUG, the level that logs each
    widget's arguments and answers. A file handler at DEBUG on the root
    logger stands in for it."""

    def setUp(self):
        fd, self.path = tempfile.mkstemp(suffix=".log")
        os.close(fd)
        self.handler = logging.FileHandler(self.path, encoding="utf-8")
        self.handler.setLevel(logging.DEBUG)
        root = logging.getLogger()
        self.level = root.level
        root.addHandler(self.handler)
        root.setLevel(logging.DEBUG)

    def tearDown(self):
        root = logging.getLogger()
        root.removeHandler(self.handler)
        root.setLevel(self.level)
        self.handler.close()
        os.remove(self.path)

    def logged(self) -> str:
        self.handler.flush()
        with open(self.path, encoding="utf-8") as fob:
            return fob.read()

    def test_generated_password_never_reaches_the_log(self):
        d = dialog(GENERATE, OK, CANCEL, OK, OK)
        password = d.get_password("Root Password", "text")
        discarded = shown_password(d.console.calls[1][1])
        logged = self.logged()
        self.assertIn("wrapper(dialog_name='msgbox'", logged)
        self.assertIn("wrapper(dialog_name='yesno', ...) -> 'cancel'", logged)
        self.assertNotIn(password, logged)
        self.assertNotIn(discarded, logged)

    def test_typed_password_never_reaches_the_log(self):
        d = dialog(MANUAL, (OK, "Typed-Secret-9"), (OK, "Typed-Secret-9"))
        self.assertEqual(d.get_password("t", "x"), "Typed-Secret-9")
        logged = self.logged()
        self.assertIn("wrapper(dialog_name='passwordbox'", logged)
        self.assertNotIn("Typed-Secret-9", logged)

    def test_inithooks_log_is_not_written(self):
        with mock.patch("builtins.open", wraps=open) as opened:
            d = dialog(GENERATE, OK, OK)
            d.get_password("t", "x")
        paths = [str(call.args[0]) for call in opened.call_args_list if call.args]
        self.assertFalse([p for p in paths if "inithooks" in p], paths)


class TestScreenOnTheTerminal(unittest.TestCase):
    """dialog draws on its standard output. bin/dbpass.py (keel-mariadb)
    and bin/wordpress.py (keel-wordpress) print KEY=value on theirs for a
    hook that reads it through a pipe, so the screen, and a generated
    password drawn on it, went into the hook's read loop: the operator saw
    nothing, the hook got no value and the boot run hung. While a widget
    runs, fd 1 is the controlling terminal. A file stands in for the
    terminal and another for the captured stdout."""

    SCREEN = b"\x1b[?1049h screen with Pw-Shown-7 \x1b[?1049l"

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.tty = os.path.join(self.dir.name, "tty")
        self.out = os.path.join(self.dir.name, "stdout")
        open(self.tty, "wb").close()
        self.saved = os.dup(1)
        fd = os.open(self.out, os.O_WRONLY | os.O_CREAT, 0o600)
        os.dup2(fd, 1)
        os.close(fd)

    def tearDown(self):
        os.dup2(self.saved, 1)
        os.close(self.saved)
        self.dir.cleanup()

    def draw(self):
        os.write(1, self.SCREEN)
        return OK

    def read(self, path):
        with open(path, "rb") as fob:
            return fob.read()

    def test_screen_goes_to_the_terminal_and_stdout_keeps_the_value(self):
        d = dialog(self.draw)
        with mock.patch.object(dw, "TTY", self.tty):
            d.msgbox("T", "m")
            os.write(1, b"DB_PASS=value\n")
        self.assertEqual(self.read(self.tty), self.SCREEN)
        self.assertEqual(self.read(self.out), b"DB_PASS=value\n")

    def test_stdout_that_is_a_terminal_is_left_alone(self):
        d = dialog(self.draw)
        with (
            mock.patch.object(dw, "TTY", self.tty),
            mock.patch.object(dw.os, "isatty", return_value=True),
        ):
            d.msgbox("T", "m")
        self.assertEqual(self.read(self.tty), b"")
        self.assertEqual(self.read(self.out), self.SCREEN)

    def test_no_controlling_terminal_draws_where_it_always_did(self):
        d = dialog(self.draw)
        with mock.patch.object(dw, "TTY", os.path.join(self.dir.name, "none")):
            d.msgbox("T", "m")
        self.assertEqual(self.read(self.out), self.SCREEN)

    def test_wide_password_with_stdout_already_on_the_terminal(self):
        # A script that dup'd the terminal onto fd 1 before using Dialog:
        # nothing is redirected, ESC re-shows the box, and the height is
        # computed at the width the password dialogs are drawn with.
        def draw_text():
            os.write(1, d.console.calls[-1][1].encode())
            return OK

        d = dialog(GENERATE, ESC, draw_text, draw_text)
        with (
            mock.patch.object(dw, "TTY", self.tty),
            mock.patch.object(dw.os, "isatty", return_value=True),
        ):
            password = d.get_password("t", "x", gen_length=56)
        self.assertEqual(len(password), 56)
        self.assertEqual(self.read(self.tty), b"")
        self.assertIn(password.encode(), self.read(self.out))
        for widget, shown, args, _ in d.console.calls[1:]:
            height, width = args
            text = shown.removeprefix("\n")  # wrapper() adds it
            self.assertEqual(width, 68, widget)
            self.assertEqual(height, d._calc_height(text, width), widget)
            if password in text:
                # the wide band wraps at the default width, not at 68
                self.assertLess(height, d._calc_height(text), widget)
        self.assertEqual([call[0] for call in d.console.calls
                          if password in call[1]], ["msgbox", "msgbox"])

    def test_generated_password_never_reaches_a_captured_stdout(self):
        def draw_text():
            os.write(1, d.console.calls[-1][1].encode())
            return OK

        # the password is on the first screen only; the question after it
        # draws nothing here, so it cannot write over what the first drew
        d = dialog(GENERATE, draw_text, OK)
        with mock.patch.object(dw, "TTY", self.tty):
            password = d.get_password("t", "x")
        self.assertIn(password.encode(), self.read(self.tty))
        self.assertNotIn(password.encode(), self.read(self.out))


class TestWidgets(unittest.TestCase):
    def test_persistent_arguments(self):
        d = dw.Dialog("Title")
        self.assertEqual(
            d.console.persistent_args,
            ["--no-collapse", "--backtitle", "Title", "--no-mouse"],
        )

    def test_error_msgbox_infobox(self):
        d = dialog(OK, OK, OK)
        self.assertEqual(d.error("bad"), OK)
        self.assertEqual(d.msgbox("T", "m"), OK)
        self.assertEqual(d.infobox("i"), OK)
        self.assertEqual(d.console.calls[0][3]["title"], "Error")
        self.assertEqual(d.console.widgets(), ["msgbox", "msgbox", "infobox"])

    def test_inputbox_with_and_without_cancel(self):
        d = dialog((OK, "a"), (OK, "b"))
        self.assertEqual(d.inputbox("T", "t"), (OK, "a"))
        self.assertEqual(d.inputbox("T", "t", cancel_label=""), (OK, "b"))
        self.assertFalse(d.console.calls[0][3]["no_cancel"])
        self.assertTrue(d.console.calls[1][3]["no_cancel"])

    def test_escape_on_a_message_still_offers_to_quit(self):
        d = dialog(ESC, CANCEL, OK)
        self.assertEqual(d.msgbox("T", "m"), OK)
        self.assertEqual(d.console.widgets(), ["msgbox", "yesno", "msgbox"])
        d = dialog(ESC, OK)
        with self.assertRaises(SystemExit):
            d.msgbox("T", "m")

    def test_escape_in_an_input_box_asks_again(self):
        d = dialog((ESC, ""), (OK, "a@example.org"))
        self.assertEqual(d.get_email("E", "t"), "a@example.org")
        self.assertEqual(d.console.widgets(), ["inputbox", "inputbox"])

    def test_calc_height_counts_visible_characters_at_a_width(self):
        d = dialog()
        self.assertEqual(d._calc_height("x" * 61), 8)
        self.assertEqual(d._calc_height("x" * 61, 68), 7)
        self.assertEqual(d._calc_height("\\Zb" + "x" * 59 + "\\Zn"), 7)

    def test_yesno(self):
        d = dialog(OK, CANCEL)
        self.assertTrue(d.yesno("T", "t"))
        self.assertFalse(d.yesno("T", "t"))

    def test_menu_returns_the_tag(self):
        d = dialog((OK, "two"))
        self.assertEqual(d.menu("T", "t", [("one", "1"), ("two", "2")]), "two")

    def test_unknown_widget(self):
        d = dialog()
        with self.assertRaises(dw.Error):
            d.wrapper("nosuchwidget", "t")

    def test_exception_in_a_widget_is_shown_and_the_widget_asked_again(self):
        d = dialog(RuntimeError("boom"), OK, OK)
        self.assertEqual(d.msgbox("T", "m"), OK)
        self.assertEqual(d.console.calls[1][3]["title"], "Caught exception")
        self.assertIn("boom", d.console.calls[1][1])

    def test_get_email(self):
        d = dialog((OK, ""), OK, (OK, "nope"), OK, (OK, "a@example.org"))
        self.assertEqual(d.get_email("E", "t"), "a@example.org")

    def test_get_input(self):
        d = dialog((OK, ""), OK, (OK, "value"))
        self.assertEqual(d.get_input("Name", "t"), "value")

    def test_get_domain(self):
        d = dialog((OK, ""), OK, (OK, "https://example.org/"))
        self.assertEqual(d.get_domain("D", "t"), ("https", "example.org"))


class TestValidateDomain(unittest.TestCase):
    def test_answers(self):
        cases = {
            "": (None, None, "Domain is required."),
            "example.org": ("example.org", None, None),
            "http://example.org": ("example.org", "http", None),
            "//example.org": (None, None, "Domain cannot start with `//`"),
            "ftp://example.org": (None, None, 'Unsupported scheme "ftp"'),
            "a@example.org": (None, None, "Domain cannot include a username or password"),
            "http://http://x": (None, None, 'Domain "http://http://x" contains a nested URL'),
            "example.org:0": (None, None, "Domain port specifier is malformed"),
            "http://": (None, None, 'Domain "http://" is invalid'),
            "-bad-.org": (None, None, 'Domain "-bad-.org" is invalid'),
        }
        for given, expected in cases.items():
            self.assertEqual(dw.validate_domain(given), expected, given)

    def test_meaningful_parts_are_reported(self):
        host, scheme, message = dw.validate_domain(
            "https://example.org:8443/p?q=1#f"
        )
        self.assertEqual((host, scheme), ("example.org", "https"))
        self.assertIn("port, path, query string, fragment", message)

    def test_unparseable(self):
        self.assertEqual(
            dw.validate_domain("http://[::1"), (None, None, "Domain is invalid")
        )


if __name__ == "__main__":
    unittest.main()
