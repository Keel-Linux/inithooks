# Copyright (c) 2026 KeelLinux maintainers
"""Whether this cloud node still needs a join, for the login message

Handbook decision 0076: in a cloud mode (cloud_simple, cloud_advanced)
the first boot makes the mesh on the primary and joins the replica and
the witness to it. A node whose instance description says a cloud mode
and holds no overlay address, or an overlay with no peer, has not done
that yet, for example when nobody was at the console and the questions
were left to keel-init. keel-init --status, which the login message
prints, then says so in one line.

The description is read, never written, and a description that cannot
be read says nothing: the login must never fail because of it.
"""

import os

import yaml

DEFAULT_SPEC = "/etc/keel/instance.yaml"
CLOUD_MODES = ("cloud_simple", "cloud_advanced")
NO_MESH = (
    "This node is in the {mode} mode and is in no mesh yet: run keel-init"
    " to make the mesh, or to join this node to one with the line that"
    " Invite a node shows on the other node."
)
NO_PEER = (
    "This node is in the {mode} mode and no other node has joined its mesh"
    " yet: run keel-init to show the invite line again, or join this node"
    " to a mesh."
)


def spec_path() -> str:
    """The description keel reads: $KEEL_SPEC, else the default"""
    return os.environ.get("KEEL_SPEC") or DEFAULT_SPEC


def _section(found, key: str) -> dict:
    value = found.get(key) if isinstance(found, dict) else None
    return value if isinstance(value, dict) else {}


def read(path: str) -> dict:
    """The description, or {} when it cannot be read as one"""
    try:
        with open(path) as fob:
            found = yaml.safe_load(fob)
    except (OSError, yaml.YAMLError):
        return {}
    return found if isinstance(found, dict) else {}


def message(path: str | None = None) -> str:
    """The login line for a cloud node that still needs a join, or "" """
    document = read(path or spec_path())
    mode = _section(document, "installation").get("mode")
    if mode not in CLOUD_MODES:
        return ""
    wireguard = _section(_section(_section(document, "network"), "overlay"),
                         "wireguard")
    if not wireguard.get("address"):
        return NO_MESH.format(mode=mode)
    if not wireguard.get("peers"):
        return NO_PEER.format(mode=mode)
    return ""
