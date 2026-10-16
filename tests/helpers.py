# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""Shared helpers for the declarative reader tests"""

import os
import sys
import tempfile
from os.path import abspath, dirname, exists, join

sys.path.insert(0, dirname(dirname(abspath(__file__))))

from libinithooks import declarative


def keel_checkout():
    """The path of a keel checkout, or None when there is none at hand

    Point KEEL_SRC at a keel checkout, or keep one beside this repository.
    """
    checkout = os.environ.get("KEEL_SRC") or join(
        dirname(dirname(dirname(abspath(__file__)))), "keel"
    )
    if not exists(join(checkout, "keel", "spec", "validate.py")):
        return None
    return checkout


def keel_validate():
    """keel's own validate(), or None when its source is not at hand

    Used by the tests that hold this reader and keel together; they skip
    when it is not there, so the suite runs with or without keel.
    """
    checkout = keel_checkout()
    if checkout is None:
        return None
    if checkout not in sys.path:
        sys.path.insert(0, checkout)
    try:
        from keel.spec.validate import validate
    except ImportError:
        return None
    return validate


def doc(text: str) -> dict:
    """Load a YAML document from a string through declarative.load()"""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fob:
        fob.write(text)
        path = fob.name
    try:
        return declarative.load(path)
    finally:
        os.remove(path)


def env(text: str) -> dict:
    """Render a YAML document to a dict of exported variables"""
    document = doc(text)
    found = declarative._validate_local(document)
    if found:
        raise AssertionError(f"unexpected errors: {found}")
    secrets = declarative.resolve_secrets(document)
    rendered = declarative.render_env(document, secrets)
    exported = {}
    for line in rendered.splitlines():
        if not line.startswith("export "):
            continue
        key, _, value = line[len("export ") :].partition("=")
        exported[key] = value
    return exported


def errors(text: str) -> list[str]:
    return declarative._validate_local(doc(text))


def secret_file(directory: str, content: str, name: str = "secret") -> str:
    path = join(directory, name)
    with open(path, "w") as fob:
        fob.write(content)
    os.chmod(path, 0o600)
    return path
