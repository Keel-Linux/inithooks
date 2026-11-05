"""The login line of a cloud node that still needs a join (decision 0076)

libinithooks.mesh_pending reads the instance description and says, for
keel-init --status, whether a node in a cloud mode has no mesh yet or no
other node in it. It never fails: a description it cannot read says
nothing.
"""

import sys
from os.path import abspath, dirname, join

import pytest
import yaml

sys.path.insert(0, abspath(join(dirname(__file__), "..")))

from libinithooks import mesh_pending  # noqa: E402

OVERLAY = {"address": "fd2a:9c41:7e03::1/64"}
PEER = {"public_key": "k=", "allowed_ips": ["fd2a:9c41:7e03::4e1a/128"]}


@pytest.fixture
def spec(tmp_path, monkeypatch):
    path = tmp_path / "instance.yaml"
    monkeypatch.setenv("KEEL_SPEC", str(path))

    def _write(document):
        path.write_text(yaml.safe_dump(document))
        return str(path)

    return _write


def cloud(mode="cloud_simple", wireguard=None):
    document = {"version": 1, "installation": {"mode": mode}}
    if wireguard is not None:
        document["network"] = {"overlay": {"wireguard": wireguard}}
    return document


@pytest.mark.parametrize("mode", ["cloud_simple", "cloud_advanced"])
def test_a_cloud_node_in_no_mesh_needs_a_join(spec, mode):
    spec(cloud(mode))

    line = mesh_pending.message()

    assert line == mesh_pending.NO_MESH.format(mode=mode)
    assert "run keel-init" in line


def test_a_mesh_with_no_other_node_needs_one(spec):
    spec(cloud(wireguard=OVERLAY))

    assert mesh_pending.message() == mesh_pending.NO_PEER.format(
        mode="cloud_simple")


def test_a_node_with_a_peer_needs_nothing(spec):
    spec(cloud(wireguard={**OVERLAY, "peers": [PEER]}))

    assert mesh_pending.message() == ""


@pytest.mark.parametrize("document", [
    {"version": 1},
    {"version": 1, "installation": {"mode": "simple"}},
    {"version": 1, "installation": "cloud_simple"},
    ["a", "list"],
])
def test_a_node_that_is_not_in_a_cloud_mode_needs_nothing(spec, document):
    spec(document)

    assert mesh_pending.message() == ""


def test_an_odd_network_section_is_no_mesh(spec):
    path = spec({**cloud(), "network": {"overlay": "wg0"}})

    assert mesh_pending.message(path) == mesh_pending.NO_MESH.format(
        mode="cloud_simple")


def test_a_description_that_does_not_read_says_nothing(tmp_path):
    broken = tmp_path / "instance.yaml"
    broken.write_text("installation: [")

    assert mesh_pending.message(str(broken)) == ""
    assert mesh_pending.message(str(tmp_path / "absent.yaml")) == ""


def test_the_default_description_is_keels(monkeypatch):
    monkeypatch.delenv("KEEL_SPEC", raising=False)

    assert mesh_pending.spec_path() == "/etc/keel/instance.yaml"
