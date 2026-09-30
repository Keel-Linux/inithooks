"""A stand-in for pythondialog, so the dialog layer runs without a terminal

libinithooks.dialog_wrapper imports the `dialog` module (python3-dialog)
and calls one method per widget on a `dialog.Dialog` instance. FakeConsole
answers those calls from a script given by the test, one answer per call
in order, and records every call it received, so a test says what the
operator pressed and then reads what was shown.

load_wrapper() puts this module in sys.modules under the name `dialog`
before importing the wrapper, whether or not the real package is
installed, and gives the root logger a handler first so the wrapper's
logging.basicConfig() does not open /var/log/dialog.log.
"""

import importlib
import logging
import sys
import types

OK = "ok"
CANCEL = "cancel"
ESC = "esc"


class ScriptExhausted(BaseException):
    """The code under test asked for more dialogs than the test scripted.

    A BaseException, because the wrapper catches every Exception a widget
    raises, shows it in a message box and asks again, which would never end.
    """


class FakeConsole:
    """What dialog.Dialog looks like to the wrapper"""

    OK = OK
    CANCEL = CANCEL
    ESC = ESC

    def __init__(self, *answers, **kwargs) -> None:
        self.answers = list(answers)
        self.calls: list[tuple[str, str, tuple, dict]] = []
        self.persistent_args: list[str] = []
        self.init_kwargs = kwargs

    def add_persistent_args(self, args: list[str]) -> None:
        self.persistent_args.extend(args)

    def _answer(self, widget: str, text: str, args: tuple, kwargs: dict):
        self.calls.append((widget, text, args, kwargs))
        if not self.answers:
            raise ScriptExhausted(f"no answer scripted for {widget}: {text!r}")
        answer = self.answers.pop(0)
        if isinstance(answer, BaseException):
            raise answer
        if callable(answer):
            return answer()
        return answer

    def msgbox(self, text, *args, **kwargs):
        return self._answer("msgbox", text, args, kwargs)

    def infobox(self, text, *args, **kwargs):
        return self._answer("infobox", text, args, kwargs)

    def yesno(self, text, *args, **kwargs):
        return self._answer("yesno", text, args, kwargs)

    def inputbox(self, text, *args, **kwargs):
        return self._answer("inputbox", text, args, kwargs)

    def passwordbox(self, text, *args, **kwargs):
        return self._answer("passwordbox", text, args, kwargs)

    def menu(self, text, *args, **kwargs):
        return self._answer("menu", text, args, kwargs)

    def widgets(self) -> list[str]:
        """The widget of each call, in order"""
        return [call[0] for call in self.calls]

    def shown(self) -> str:
        """Every text and argument the operator was shown, as one string"""
        return "\n".join(
            f"{text} {args!r} {kwargs!r}" for _, text, args, kwargs in self.calls
        )


def load_wrapper():
    """Import libinithooks.dialog_wrapper against this fake"""
    module = types.ModuleType("dialog")
    module.Dialog = FakeConsole
    sys.modules["dialog"] = module
    root = logging.getLogger()
    if not root.handlers:
        root.addHandler(logging.NullHandler())
    return importlib.import_module("libinithooks.dialog_wrapper")
