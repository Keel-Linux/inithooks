# Copyright (c) 2010 Alon Swartz <alon@turnkeylinux.org>
# Copyright (c) 2020-2025 TurnKey GNU/Linux <admin@turnkeylinux.org>

import os
import re
import secrets
import string
import sys
import dialog
import traceback
from collections.abc import Iterator
from contextlib import contextmanager
from io import StringIO
from os import environ
from urllib.parse import urlparse
import logging

EMAIL_RE = re.compile(r"(?:^|\s).*\S@\S+(?:\s|$)", re.IGNORECASE)

LOG_LEVEL = logging.INFO
if "DIALOG_DEBUG" in environ.keys():
    LOG_LEVEL = logging.DEBUG

logging.basicConfig(
    filename="/var/log/dialog.log", encoding="utf-8", level=LOG_LEVEL
)


class Error(Exception):
    pass


def password_complexity(password: str) -> int:
    """return password complexity score from 0 (invalid) to 4 (strong)"""

    lowercase = re.search("[a-z]", password) is not None
    uppercase = re.search("[A-Z]", password) is not None
    number = re.search(r"\d", password) is not None
    nonalpha = re.search(r"\W", password) is not None

    return sum([lowercase, uppercase, number, nonalpha])


# The characters of a generated password. Letters and digits read as each
# other on a console or on paper (0 O o 1 l I) are left out, since the
# operator copies the password by eye. The symbols are unreserved in
# RFC 3986 (its fourth, _, is a word character to password_complexity() and
# would not count as one), so the password needs no escaping in a URL, in a
# shell word, in a single quoted PHP string, in a SQL parameter, in a dialog
# text, or in the KEY=value line that bin/dbpass.py and bin/wordpress.py
# print for their hooks (whose `IFS='=' read` drops a trailing =), and it
# can be typed on any keyboard layout. The first and last characters are a
# letter or a digit: a leading - reads as an option, a leading ~ as a home
# directory, and a trailing . or - is lost when copied from a sentence.
# 59 characters, 5.88 bits each: about 117 bits at the default length.
PASSWORD_UPPER = "".join(c for c in string.ascii_uppercase if c not in "IO")
PASSWORD_LOWER = "".join(c for c in string.ascii_lowercase if c not in "lo")
PASSWORD_DIGITS = "23456789"
PASSWORD_SYMBOLS = "-.~"
PASSWORD_ALPHABET = (
    PASSWORD_UPPER + PASSWORD_LOWER + PASSWORD_DIGITS + PASSWORD_SYMBOLS
)
GENERATED_LENGTH = 20
# The menu tag of get_password(keep=...): the account keeps its password.
KEEP = "Keep"
# Columns a menu box takes besides its longest tag and description, and the
# widest box drawn, which an 80 column console shows whole (measured with
# dialog 1.3 on tty1 of an LXC container: a box 76 wide shows 58 columns of
# description beside an 8 column tag).
MENU_MARGIN = 10
MENU_MAX_WIDTH = 76
GENERATED_MIN_LENGTH = 12
# Generated candidates tried against the caller's rules before the operator
# is asked to type a password instead (a pass_req regex can refuse them all).
GENERATE_TRIES = 100
# Widgets whose answer is a secret: their value is never logged.
SECRET_WIDGETS = ("passwordbox",)
# The controlling terminal, where the widgets draw when stdout is not one.
TTY = "/dev/tty"
# The name every first boot backtitle starts with. Hooks written for
# TurnKey (in appliance repositories and in common) still pass a title
# starting with one of LEGACY_BRANDS; backtitle() shows those as BRAND, so
# the operator never reads another distribution's name at the top of the
# screen whichever package the hook came from.
BRAND = "Keel Linux"
LEGACY_BRANDS = ("TurnKey GNU/Linux", "TurnKey Linux")


def backtitle(title: str) -> str:
    """TITLE with a leading TurnKey name replaced by BRAND"""
    for legacy in LEGACY_BRANDS:
        if title.startswith(legacy):
            return BRAND + title[len(legacy):]
    return title


@contextmanager
def screen_on_terminal() -> Iterator[None]:
    """While the block runs, fd 1 is the controlling terminal if it was not
    a terminal already.

    dialog draws its screen on its standard output, which it inherits.
    bin/dbpass.py (keel-mariadb) and bin/wordpress.py (keel-wordpress)
    print KEY=value on theirs for a hook that reads it through a pipe, so
    the screen went into that pipe: the operator saw nothing, dialog failed
    and the run hung, and a generated password drawn on the screen would
    have gone to the hook, whose stderr is the journal. With no controlling
    terminal (nothing to draw on anyway), fd 1 is left as it is."""
    if os.isatty(1):
        yield
        return
    try:
        tty = os.open(TTY, os.O_WRONLY | os.O_NOCTTY)
    except OSError:
        yield
        return
    sys.stdout.flush()
    saved = os.dup(1)
    try:
        os.dup2(tty, 1)
        yield
    finally:
        os.dup2(saved, 1)
        os.close(saved)
        os.close(tty)


def generate_password(length: int = GENERATED_LENGTH, exclude: str = "") -> str:
    """Generate a random password from PASSWORD_ALPHABET.

    Uses the secrets module (the system CSPRNG). Every character class left
    after EXCLUDE is present, so the password scores the highest complexity
    those classes allow (4 unless the symbols are all excluded). Candidates
    are drawn uniformly and rejected until they qualify, which keeps every
    qualifying password equally likely.

    Raises ValueError when LENGTH is under GENERATED_MIN_LENGTH or when
    EXCLUDE leaves no letter or digit.
    """
    if length < GENERATED_MIN_LENGTH:
        raise ValueError(
            f"generate_password(): length must be at least"
            f" {GENERATED_MIN_LENGTH}, got {length}"
        )
    classes = [
        "".join(c for c in chars if c not in exclude)
        for chars in (
            PASSWORD_UPPER,
            PASSWORD_LOWER,
            PASSWORD_DIGITS,
            PASSWORD_SYMBOLS,
        )
    ]
    classes = [chars for chars in classes if chars]
    alphabet = "".join(classes)
    if not any(c.isalnum() for c in alphabet):
        raise ValueError("generate_password(): no letter or digit left")

    while True:
        chars = [secrets.choice(alphabet) for _ in range(length)]
        if not (chars[0].isalnum() and chars[-1].isalnum()):
            continue
        if all(any(c in group for c in chars) for group in classes):
            return "".join(chars)


def password_problem(
    password: str,
    pass_req: int | str,
    min_complexity: int,
    blacklist: list[str],
) -> str | None:
    """What is wrong with PASSWORD under the rules of get_password(), as the
    message to show, or None when it is acceptable"""
    if not password:
        return "Please enter non-empty password!"

    if isinstance(pass_req, int):
        if len(password) < pass_req:
            return f"Password must be at least {pass_req} characters."
    elif not re.match(pass_req, password):
        return "Password does not match complexity requirements."

    if password_complexity(password) < min_complexity:
        if min_complexity <= 3:
            return (
                "Insecure password! Mix uppercase, lowercase,"
                " and at least one number. Multiple words and"
                " punctuation are highly recommended but not"
                " strictly required."
            )
        return (
            "Insecure password! Mix uppercase, lowercase,"
            " numbers and at least one special/punctuation"
            " character. Multiple words are highly"
            " recommended but not strictly required."
        )

    found_items = [item for item in blacklist if item in password]
    if found_items:
        return (
            f"Password can NOT include these characters: {blacklist}."
            f" Found {found_items}"
        )
    return None


class Dialog:
    def __init__(self, title: str, width: int = 60, height: int = 20) -> None:
        self.width = width
        self.height = height
        # True while get_password() runs: no widget of it may quit
        self._value_required = False

        self.console = dialog.Dialog(dialog="dialog")
        self.console.add_persistent_args(["--no-collapse"])
        self.console.add_persistent_args(["--backtitle", backtitle(title)])
        self.console.add_persistent_args(["--no-mouse"])

    def _handle_exitcode(self, retcode: str) -> bool:
        logging.debug(f"_handle_exitcode(retcode={retcode!r})")
        if retcode == self.console.ESC:  # ESC, ALT+?
            text = "Do you really want to quit?"
            if self.console.yesno(text) == self.console.OK:
                sys.exit(0)
            return False
        logging.debug(
            "_handle_exitcode(): [no conditions met, returning True]"
        )
        return True

    def _calc_height(self, text: str, width: int | None = None) -> int:
        """Rows for TEXT in a dialog WIDTH wide (self.width by default);
        the \\Z attribute codes take no room on the screen"""
        width = width or self.width
        height = 6
        for line in text.splitlines():
            visible = len(re.sub(r"\\Z.", "", line))
            height += (visible // width) + 1

        return height

    def wrapper(
        self, dialog_name: str, text: str, *args, **kws
    ) -> str | tuple[str, str]:
        """Show widget DIALOG_NAME with TEXT and return what pythondialog
        returns: the exit code, or (exit code, value) for a widget that
        takes input.

        ESC asks whether to quit, and quits with status 0 on Yes, only on
        a widget that returns a bare code outside get_password(). On a
        widget that returns a value (a menu, an input or a password box),
        and on every widget of get_password(), ESC shows the widget again:
        a quit there would end the caller with status 0 and no value, and
        firstboot.d/30rootpass would carry on with the password unset.

        TEXT is never logged, nor is the value of a password box: TEXT may
        carry a generated password, and at DEBUG (DIALOG_DEBUG) the rest
        of the call goes to /var/log/dialog.log."""
        retcode: str | tuple[str, str] = ""
        logging.debug(
            f"wrapper(dialog_name={dialog_name!r}, text=<redacted>,"
            f" *{args!r}, **{kws!r})"
        )
        try:
            method = getattr(self.console, dialog_name)
        except AttributeError as e:
            logging.error(
                f"wrapper(dialog_name={dialog_name!r}, ...) raised exception",
                exc_info=e,
            )
            raise Error("dialog not supported: " + dialog_name)

        with screen_on_terminal():
            while 1:
                try:
                    retcode = method("\n" + text, *args, **kws)
                    code = retcode[0] if isinstance(retcode, tuple) else retcode
                    shown = repr(retcode)
                    if dialog_name in SECRET_WIDGETS:
                        shown = f"({code!r}, <redacted>)"
                    logging.debug(
                        f"wrapper(dialog_name={dialog_name!r}, ...) -> {shown}"
                    )
                    if code == self.console.ESC and (
                        isinstance(retcode, tuple) or self._value_required
                    ):
                        logging.debug(
                            f"wrapper(dialog_name={dialog_name!r}, ...):"
                            " ESC, a value is required, asking again"
                        )
                        continue
                    if self._handle_exitcode(code):
                        break

                except Exception as e:
                    sio = StringIO()
                    traceback.print_exc(file=sio)
                    logging.error(
                        f"wrapper(dialog_name={dialog_name!r}) raised"
                        " exception",
                        exc_info=e,
                    )
                    self.msgbox("Caught exception", sio.getvalue())

        return retcode

    def error(self, text: str) -> str:
        """'Error' titled message with single 'ok' button
        Returns 'ok'"""
        height = self._calc_height(text)
        return self.wrapper("msgbox", text, height, self.width, title="Error")

    def msgbox(self, title: str, text: str) -> str:
        """Titled message with single 'ok' button
        Returns 'ok'"""
        height = self._calc_height(text)
        logging.debug(f"msgbox(title={title!r}, text=<redacted>)")
        return self.wrapper("msgbox", text, height, self.width, title=title)

    def infobox(self, text: str) -> str:
        """Untitled message with single 'ok' button
        Returns 'Ok'"""
        height = self._calc_height(text)
        logging.debug(f"infobox(text={text!r}")
        return self.wrapper("infobox", text, height, self.width)

    def inputbox(
        self,
        title: str,
        text: str,
        init: str = "",
        ok_label: str = "OK",
        cancel_label: str = "Cancel",
    ) -> tuple[str, str]:
        """Titled message with text input and single choice of 2 buttons
        Returns ('ok' or 'cancel', the input string)"""
        logging.debug(
            f"inputbox(title={title!r}, text=<redacted>,"
            + f" init={init!r}, ok_label={ok_label!r},"
            + f" cancel_label={cancel_label!r})"
        )

        height = self._calc_height(text) + 3
        no_cancel = True if cancel_label == "" else False
        logging.debug(
            f"inputbox(...) [calculated height={height},"
            f" no_cancel={no_cancel}]"
        )
        return self.wrapper(
            "inputbox",
            text,
            height,
            self.width,
            title=title,
            init=init,
            ok_label=ok_label,
            cancel_label=cancel_label,
            no_cancel=no_cancel,
        )

    def yesno(
        self,
        title: str,
        text: str,
        yes_label: str = "Yes",
        no_label: str = "No",
    ) -> bool:
        """Titled message with single choice of 2 buttons
        Returns True ('Yes" button) or False ('No' button)"""
        height = self._calc_height(text)
        retcode = self.wrapper(
            "yesno",
            text,
            height,
            self.width,
            title=title,
            yes_label=yes_label,
            no_label=no_label,
        )
        logging.debug(
            f"yesno(title={title!r}, text=<redacted>,"
            f" yes_label={yes_label!r}, no_label={no_label!r})"
            f" -> {retcode}"
        )
        return True if retcode == "ok" else False

    def menu(
        self,
        title: str,
        text: str,
        choices: list[tuple[str, str]],
    ) -> str:
        """Titled message with single choice of options & 'ok' button.
        choices is a list of options, each a tuple of the option tag and
        its short description: [(opt1, opt1_info), (opt2, opt2_info)]
        The box is self.width wide, wider when an option needs it, up to
        MENU_MAX_WIDTH, so that no description is cut off.
        Returns the selected option tag - e.g. 'opt1'"""
        needed = MENU_MARGIN + max(len(tag) for tag, _ in choices) + max(
            len(info) for _, info in choices
        )
        _, choice = self.wrapper(  # return_code, choice
            "menu",
            text,
            self.height,
            max(self.width, min(needed, MENU_MAX_WIDTH)),
            menu_height=len(choices) + 1,
            title=title,
            choices=choices,
            no_cancel=True,
        )
        return choice

    def get_password(
        self,
        title: str,
        text: str,
        pass_req: int = 8,
        min_complexity: int = 3,
        blacklist: list[str] | None = None,
        offer_generate: bool = True,
        gen_length: int = GENERATED_LENGTH,
        keep: str = "",
    ) -> str | None:
        """Validated password, generated or typed; None when kept.

        When offer_generate is True (the default), a menu comes first:
          - Keep, only when KEEP is given: the password the account has
            already, which KEEP describes. It is first, the default and
            the recommendation, and choosing it returns None.
          - Generate (recommended without Keep): a random password
            (generate_password), shown to the operator, who must confirm
            it was saved; 'New' discards it and shows another.
          - Manual: the password box below.
        Existing callers get the menu without any change. Pass
        offer_generate=False for the password box alone, as before; Keep
        needs the menu, and asking for both raises ValueError.

        The generated password satisfies the same rules as a typed one
        (pass_req, min_complexity, blacklist): it is gen_length characters
        long or pass_req if that is longer, leaves out every single
        character of the blacklist, and is checked by password_problem().
        When no generated password can satisfy them (a pass_req regex), the
        operator is told so and asked to type one.

        ESC never skips the password: every dialog of it is shown again.

        Returns password, or None when the operator chose Keep"""
        if keep and not offer_generate:
            raise ValueError("get_password(): keep needs the menu")
        required = self._value_required
        self._value_required = True
        try:
            return self._get_password(
                title,
                text,
                pass_req,
                min_complexity,
                list(blacklist or []),
                offer_generate,
                gen_length,
                keep,
            )
        finally:
            self._value_required = required

    def _get_password(
        self,
        title: str,
        text: str,
        pass_req: int | str,
        min_complexity: int,
        blacklist: list[str],
        offer_generate: bool,
        gen_length: int,
        keep: str = "",
    ) -> str | None:
        if offer_generate:
            generate = "A strong random password"
            choices = [(KEEP, keep)] if keep else []
            if not keep:
                generate += " (recommended)"
            choices += [
                ("Generate", generate),
                ("Manual", "Type my own password"),
            ]
            choice = self.menu(
                title,
                f"{text}\n\nChoose how to set this password:",
                choices,
            )
            if choice == KEEP:
                return None
            if choice == "Generate":
                password = self._generate_password_flow(
                    title, pass_req, min_complexity, blacklist, gen_length
                )
                if password is not None:
                    return password
        return self._manual_password_flow(
            title, text, pass_req, min_complexity, blacklist
        )

    def _password_band(self, password: str) -> tuple[str, int]:
        """PASSWORD in bold reverse video, centered, and the width of the
        dialog that shows it. Only attributes are used, not colors, so it
        shows on a monochrome console as well. The band is one space wider
        than the password on each side and no more: dialog collapses a run
        of spaces that follows a \\Z code, so a wider band or blank band
        lines above and below (turnkeylinux/inithooks#71) show as a single
        reverse cell on the console."""
        width = max(self.width, len(password) + 12)
        return self._centered(f"\\Zb\\Zr {password} \\Zn", width), width

    @staticmethod
    def _centered(line: str, width: int) -> str:
        """LINE indented to the middle of a dialog WIDTH wide; the \\Z
        attribute codes take no room on the screen"""
        visible = len(re.sub(r"\\Z.", "", line))
        return " " * max((width - 4 - visible) // 2, 0) + line

    def _generate_password_flow(
        self,
        title: str,
        pass_req: int | str,
        min_complexity: int,
        blacklist: list[str],
        length: int = GENERATED_LENGTH,
    ) -> str | None:
        """Generate a password that satisfies the rules, show it, and return
        it once the operator confirms it was saved; None when no generated
        password can satisfy the rules.

        The password goes into the dialog text only. It is never logged
        (see wrapper()), and pythondialog hands dialog its arguments in a
        temporary file rather than on the command line where the dialog
        version allows it, so it is not in the process list either."""
        if isinstance(pass_req, int):
            length = max(length, pass_req)
        exclude = "".join(item for item in blacklist if len(item) == 1)
        while True:
            password = None
            for _ in range(GENERATE_TRIES):
                try:
                    candidate = generate_password(length, exclude)
                except ValueError as e:
                    # a length under the minimum, or a blacklist that
                    # leaves no letter or digit: nothing can be generated
                    logging.error(f"_generate_password_flow(): {e}")
                    break
                if not password_problem(
                    candidate, pass_req, min_complexity, blacklist
                ):
                    password = candidate
                    break
            if password is None:
                self.error(
                    "No generated password meets the requirements of this"
                    " password: please type one."
                )
                return None

            band, width = self._password_band(password)
            shown = "\n".join(
                [
                    self._centered("\\ZbYour generated password:\\Zn", width),
                    "",
                    band,
                    "",
                    self._centered(
                        "\\ZbSave it now, in a password manager.\\Zn", width
                    ),
                    self._centered("It is not shown again.", width),
                ]
            )
            self.wrapper(
                "msgbox",
                shown,
                self._calc_height(shown, width),
                width,
                title=title,
                colors=True,
            )

            # The screen above says the password is not shown again, so
            # the question does not show it: an operator who did not save
            # it answers New and gets another one, shown once as well.
            confirm = "\n".join(
                [
                    self._centered("Did you save the password?", width),
                    "",
                    self._centered(
                        "Saved: continue.  New: discard it, show another.",
                        width,
                    ),
                ]
            )
            saved = self.wrapper(
                "yesno",
                confirm,
                self._calc_height(confirm, width),
                width,
                title=title,
                yes_label="Saved",
                no_label="New",
                colors=True,
            )
            if saved == self.console.OK:
                return password

    def _manual_password_flow(
        self,
        title: str,
        text: str,
        pass_req: int | str,
        min_complexity: int,
        blacklist: list[str],
    ) -> str:
        """The password typed twice in a password box (input shown as
        asterisks), asked again until password_problem() finds nothing
        wrong with it and both entries match.
        Returns password"""
        req_string = (
            f"\n\nPassword Requirements\n - must be at least {pass_req}"
            " characters long\n - must contain characters from at"
            f" least {min_complexity} of the following categories: uppercase,"
            " lowercase, numbers, symbols"
        )
        if blacklist:
            req_string = (
                f"{req_string}. Also must NOT contain these characters:"
                f" {' '.join(blacklist)}"
            )
        height = self._calc_height(text + req_string) + 3

        def ask(title: str, text: str) -> str:
            """Titled input box (input redacted) & 'ok' button"""
            return self.wrapper(
                "passwordbox",
                text + req_string,
                height,
                self.width,
                title=title,
                ok_label="OK",
                no_cancel="True",
                insecure=True,
            )[1]

        while 1:
            password = ask(title, text)
            problem = password_problem(
                password, pass_req, min_complexity, blacklist
            )
            if problem:
                self.error(problem)
                continue

            if password == ask(title, "Confirm password"):
                return password

            self.error("Password mismatch, please try again.")

    def get_email(self, title: str, text: str, init: str = "") -> str | None:
        """Vaidated input box (email) with optional prefilled value and 'Ok'
        button
        Returns email"""
        logging.debug(
            f"get_email(title={title!r}, text=<redacted>, init={init!r})"
        )
        while 1:
            email = self.inputbox(title, text, init, "Apply", "")[1]
            logging.debug(f"get_email(...) email={email!r}")
            if not email:
                self.error("Email is required.")
                continue

            if not EMAIL_RE.match(email):
                self.error("Email is not valid")
                continue

            return email

    def get_domain(self, title: str, text: str, init: str = "") -> tuple[str, str] | None:
        """Validated domain input box with optional prefilled value. Strips scheme
        Returns domain"""
        logging.debug(
            f"get_domain(title={title!r}, text=<redacted>, init={init!r})"
        )
        while 1:
            domain = self.inputbox(title, text, init, "Apply", "")[1]

            domain, scheme, message = validate_domain(domain)

            if not domain:
                self.error(message)
                continue
            elif message == 'Extra parts':
                if self.yesno('Domain Confirmation', f'Extra non-domain parts recieved, is this the domain you want to set? `{p.netloc}`'):
                    return (scheme, domain)
                continue
            else:
                return (scheme, domain)

    def get_input(self, title: str, text: str, init: str = "") -> str | None:
        """Input box within optional prefilled value & 'Ok' button
        Returns input"""
        while 1:
            s = self.inputbox(title, text, init, "Apply", "")[1]
            if not s:
                self.error(f"{title} is required.")
                continue
            return s

_LABEL_RE = re.compile(r'^(?!-)[A-Za-z0-9-]{1,63}(?<!-)$')
_SCHEME_RE = re.compile(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://')
 
def validate_domain(domain: str) -> tuple[str | None, str | None, str | None]:
    """
    Returns (domain, scheme, message).
 
    - domain is None only on a hard failure (input could not be salvaged);
      `message` explains why and the UI should block submission.
    - domain is not None and message is not None when something *meaningful*
      was removed (path, query, fragment, port) - UI should confirm (yes/no)
      before accepting the cleaned value.
    - domain is not None and message is None when input was already clean,
      or only had a non-meaningful change removed (scheme pulled into its
      own field, a lone trailing slash, surrounding whitespace).
    - scheme is None if the input had no scheme, or on hard failure.
    """
    if not domain or not domain.strip():
        return None, None, "Domain is required."
 
    raw = domain
    domain = domain.strip()
 
    if domain.startswith('//'):
        return None, None, "Domain cannot start with `//`"
 
    has_scheme = bool(_SCHEME_RE.match(domain))
    candidate = domain if has_scheme else '//' + domain
 
    try:
        p = urlparse(candidate)
    except ValueError:
        return None, None, "Domain is invalid"
 
    scheme = p.scheme or None
    if scheme and scheme not in ('http', 'https'):
        return None, None, f'Unsupported scheme "{scheme}"'
 
    netloc = p.netloc
 
    if '@' in netloc:
        return None, None, "Domain cannot include a username or password"
 
    host, sep, port = netloc.partition(':')
 
    # A doubled/nested scheme (e.g. "http://http://example.com") ends up
    # looking like a host of "http" with an empty/garbage port.
    if sep and not port.isdigit():
        return None, None, f'Domain "{raw}" contains a nested URL'
 
    if sep and not (0 < int(port) < 65536):
        return None, None, 'Domain port specifier is malformed'
 
    if not host:
        return None, None, f'Domain "{raw}" is invalid'
 
    labels = host.rstrip('.').split('.')
    if len(host) > 253 or not labels or not all(_LABEL_RE.match(l) for l in labels):
        return None, None, f'Domain "{raw}" is invalid'
 
    meaningful_changes = []
    if sep:
        meaningful_changes.append('port')
    if p.path not in ('', '/'):
        meaningful_changes.append('path')
    if p.query:
        meaningful_changes.append('query string')
    if p.fragment:
        meaningful_changes.append('fragment')
 
    if meaningful_changes:
        parts = ', '.join(meaningful_changes)
        return host, scheme, f'The {parts} in "{raw}" will be removed - is "{host}" correct?'
 
    return host, scheme, None

