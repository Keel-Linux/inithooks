# Copyright (c) 2026 Keel Linux maintainers
"""The machine's fully qualified domain name, asked at first boot

What firstboot.d/31fqdn and bin/fqdn.py need and do not show: the checks
on a typed name, the /etc/hosts entry that makes `hostname -f` answer the
name, and the instance description with the name recorded in it.

The description is written the way confconsole writes it (keelcli.py),
since keel has no writer of its own: the new document goes to a file
beside the old one, `keel spec validate --no-secret-files` is asked about
that file when keel is installed, and only then does it replace the old
one, so a description that would not load never replaces one that does.
PyYAML writes it, as confconsole does, so comments do not survive; the
keys keep their order, and the file keeps its mode. A description the
answer does not change is not written at all.
"""

import os
import re
import shutil
import stat
import subprocess
import tempfile
from collections.abc import Callable, Mapping
from typing import Any

import yaml

from libinithooks import declarative

# RFC 1123 labels: letters, digits and dashes, not at either end
LABEL_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
MAX_LENGTH = 253
# the address of the entry, Debian's for a name the network does not fix,
# unless the file already gives the host an address of its own
LOOPBACK = "127.0.1.1"
HOSTS_MODE = 0o644
# a new description: it holds references to secrets, and root reads it
SPEC_MODE = 0o600
STAGED = ".fqdn-new"
KEEL = "keel"
VALIDATE = ("spec", "validate", "--no-secret-files", "--spec")
INVALID = (
    '"{typed}" is not a domain name. Use labels of letters, digits and'
    " dashes separated by dots, as in blog.example.org."
)


class FqdnError(Exception):
    pass


def normalize(typed: str) -> tuple[str, str | None]:
    """The name as the files will hold it, or what is wrong with it

    Returns (name, None) for a domain name or a single label, ("", None)
    for nothing typed, and ("", message) for anything else. Whitespace
    and one trailing dot (the root, as DNS writes an absolute name) are
    dropped and the name is lower cased: DNS compares names without
    case, and the files hold one spelling.
    """
    name = typed.strip()
    if name.endswith("."):
        name = name[:-1]
    name = name.lower()
    if not name:
        return "", None
    labels = name.split(".")
    if len(name) > MAX_LENGTH or not all(LABEL_RE.match(l) for l in labels):
        return "", INVALID.format(typed=typed.strip())
    return name, None


def split(name: str) -> tuple[str, str]:
    """(hostname, fqdn): the first label, and the name when it has a domain

    A single label is a hostname without a domain: ("blog", "").
    """
    hostname, dot, _ = name.partition(".")
    return hostname, name if dot else ""


def declared(document: Mapping[str, Any]) -> tuple[str, str]:
    """(hostname, fqdn) as the description declares them, "" for none"""
    instance = document.get("instance")
    if not isinstance(instance, Mapping):
        return "", ""
    return (str(instance.get("hostname") or ""),
            str(instance.get("fqdn") or ""))


def prefill(current: str, document: Mapping[str, Any]) -> str:
    """What the box is prefilled with: the declared fqdn, else the name
    the machine has, a dotted one as it is"""
    return declared(document)[1] or current


def hostname_for(name: str, document: Mapping[str, Any]) -> str:
    """The hostname that goes with NAME: the first label, unless NAME is
    the fqdn the description declares beside a hostname of its own, which
    is then kept (09hostname set it from the same description)"""
    hostname, fqdn = declared(document)
    if name and name == fqdn and hostname:
        return hostname
    return split(name)[0]


def hosts_with_name(text: str, hostname: str, fqdn: str) -> str:
    """/etc/hosts TEXT with the entry for HOSTNAME, FQDN first when given

    A line is the host's when its names are all the host's, as a whole
    name or as the first label of a dotted name: the `127.0.1.1 blog`
    line 09hostname leaves, and the `192.0.2.10 blog.example.org blog`
    line a container manager writes for a static address. The first such
    line is rewritten where it stands, keeping its address, since a
    resolver answers from the first line that carries a name and a line
    left before the entry would keep `hostname -f` on the old name; the
    others go. A line at LOOPBACK that names the host beside other names
    is rewritten too, since that address is the entry's own. A line that
    names the host beside another name elsewhere (`127.0.0.1 localhost
    blog`) is kept, as keel apply keeps it. Every other line, comments and
    blanks included, stays as it was; without a line to rewrite the entry
    is appended, at LOOPBACK.
    """
    names = [fqdn, hostname] if fqdn and fqdn != hostname else [hostname]
    lines = text.splitlines()
    address = next((line.split()[0] for line in lines
                    if _superseded(line, hostname)), LOOPBACK)
    entry = " ".join([address, *names])
    kept: list[str] = []
    written = False
    for line in lines:
        if not _superseded(line, hostname):
            kept.append(line)
            continue
        if not written:
            kept.append(entry)
            written = True
    if not written:
        kept.append(entry)
    return "".join(f"{line}\n" for line in kept)


def in_hosts(text: str, hostname: str) -> str:
    """The dotted name /etc/hosts TEXT gives HOSTNAME, "" for none

    Read from the first line that names the host, as a whole name or as
    the first label of a dotted one, as keel inspect reads it
    (keel.inspect.hostname.fqdn_in_hosts): a resolver answers from the
    first line that carries the name, so a later line does not give the
    host a name `hostname -f` answers.
    """
    for line in text.splitlines():
        fields = line.split()
        if line.strip().startswith("#") or len(fields) < 2:
            continue
        names = [one.lower() for one in fields[1:]]
        if not any(one.split(".")[0] == hostname.lower() for one in names):
            continue
        return next((one for one in names if "." in one), "")
    return ""


def machine(current: str, hosts_text: str) -> tuple[str, str]:
    """(hostname, fqdn): the name the machine has, for a first boot that
    keeps it (nobody can answer, or FQDN=SKIP)

    CURRENT is what `hostname` answers, the name pct create --hostname
    gave a container. A dotted one is the fqdn, and its first label the
    hostname; otherwise the fqdn is the dotted name the host's line in
    /etc/hosts gives it (pct writes `127.0.1.1 name.domain name` with the
    host's search domain), else none. A name that is not a domain name
    gives no fqdn, and the hostname is kept as it is.
    """
    name, problem = normalize(current)
    if problem or not name:
        return current, ""
    hostname, fqdn = split(name)
    if fqdn:
        return hostname, fqdn
    found, problem = normalize(in_hosts(hosts_text, hostname))
    return hostname, "" if problem else found


def read_hosts(path: str) -> str:
    """The hosts file at PATH, "" when there is none"""
    if not os.path.exists(path):
        return ""
    try:
        with open(path) as fob:
            return fob.read()
    except OSError as error:
        raise FqdnError(f"{path}: {error.strerror}")


def _superseded(line: str, hostname: str) -> bool:
    fields = line.split()
    if line.strip().startswith("#") or len(fields) < 2:
        return False
    hosts = [one.split(".")[0].lower() == hostname.lower()
             for one in fields[1:]]
    if not any(hosts):
        return False
    return fields[0] == LOOPBACK or all(hosts)


def updated(document: Mapping[str, Any], hostname: str, fqdn: str) -> dict:
    """A new description with the name recorded; the given one is not
    changed, and one the answer does not change comes back equal

    instance.fqdn is set (removed when the name has no domain), and
    instance.hostname when it is absent or the answer is not the name
    the description declares, so a hostname declared beside an unchanged
    fqdn is kept. tls.acme.domains is set to [fqdn] only when the
    description declares no domain yet; tls.acme.enabled is never
    touched, and a tls section of another shape is left alone.
    """
    after = dict(document)
    instance = dict(document.get("instance") or {}) if isinstance(
        document.get("instance"), Mapping) else {}
    before_hostname, before_fqdn = declared(document)
    changed = (fqdn or hostname) != (before_fqdn or before_hostname)
    if changed or not before_hostname:
        instance["hostname"] = hostname
    if fqdn:
        instance["fqdn"] = fqdn
    else:
        instance.pop("fqdn", None)
    after["instance"] = instance
    if not fqdn:
        return after

    tls = document.get("tls")
    if tls is None:
        tls = {}
    if not isinstance(tls, Mapping):
        return after
    acme = tls.get("acme")
    if acme is None:
        acme = {}
    if not isinstance(acme, Mapping):
        return after
    domains = acme.get("domains")
    if domains is None:
        domains = []
    if not isinstance(domains, list):
        return after
    if not domains:
        after["tls"] = {**tls, "acme": {**acme, "domains": [fqdn]}}
    return after


def spec_path(
    env: Mapping[str, str] | None = None,
    exists: Callable[[str], bool] = os.path.exists,
) -> str:
    """The description 31fqdn records into: the one 00declarative read
    (INITHOOKS_DECL, else the first of its paths that exists), or
    /etc/keel/instance.yaml for a machine that has none yet"""
    found, _ = declarative.resolve_path(env, exists)
    return found or declarative.DECL_PATHS[0]


def load(path: str) -> dict:
    """The description at PATH, or the smallest one when there is none"""
    if not os.path.lexists(path):
        return {"version": declarative.SCHEMA_VERSION}
    return declarative.load(path)


def write_spec(path: str, document: Mapping[str, Any]) -> None:
    """Write DOCUMENT to PATH, validated by keel when keel is installed

    Staged beside PATH, checked, given the mode PATH has (SPEC_MODE for
    a new file), then moved into place; a document keel refuses, or a
    file that cannot be written, raises FqdnError and leaves PATH as it
    was.
    """
    text = yaml.safe_dump(dict(document), sort_keys=False,
                          default_flow_style=False)
    staged = _write_beside(path, text, STAGED)
    keel = shutil.which(KEEL)
    if keel is not None:
        proc = subprocess.run([keel, *VALIDATE, staged], capture_output=True,
                              text=True, check=False)
        if proc.returncode != 0:
            os.unlink(staged)
            raise FqdnError(
                f"{path} was NOT changed: keel spec validate exited"
                f" {proc.returncode}\n{(proc.stdout + proc.stderr).strip()}"
            )
    os.chmod(staged, _mode(path, SPEC_MODE))
    _replace(staged, path)


def write_hosts(path: str, hostname: str, fqdn: str) -> None:
    """Write the entry for HOSTNAME and FQDN into the hosts file at PATH"""
    text = read_hosts(path)
    staged = _write_beside(path, hosts_with_name(text, hostname, fqdn),
                           ".fqdn-tmp")
    os.chmod(staged, _mode(path, HOSTS_MODE))
    _replace(staged, path)


def _mode(path: str, default: int) -> int:
    """The permission bits of PATH, DEFAULT when there is no file"""
    try:
        return stat.S_IMODE(os.stat(path).st_mode)
    except OSError:
        return default


def _write_beside(path: str, text: str, suffix: str) -> str:
    """TEXT in a new file beside PATH (mkstemp, 0600); its path"""
    directory = os.path.dirname(path) or "."
    try:
        descriptor, staged = tempfile.mkstemp(
            prefix=os.path.basename(path) + ".", suffix=suffix, dir=directory)
    except OSError as error:
        raise FqdnError(f"{path}: {error.strerror}")
    with os.fdopen(descriptor, "w") as fob:
        fob.write(text)
    return staged


def _replace(staged: str, path: str) -> None:
    try:
        os.replace(staged, path)
    except OSError as error:
        os.unlink(staged)
        raise FqdnError(f"{path}: {error.strerror}")
