# Copyright (c) 2026 Keel Linux maintainers
"""Read a cloud-init drive without cloud-init

A Proxmox VM with a cloud-init drive gets a small read-only disk: NoCloud
(file system label cidata, files user-data, meta-data, network-config) or
ConfigDrive (label config-2, files openstack/latest/user_data,
openstack/latest/meta_data.json, openstack/content/0000). Keel images do
not install the cloud-init package; bin/cloud-drive.py reads the drive
with this module, so the operator can log in over SSH with a key on the
first boot.

Only these settings are read, and each is validated:

- ssh_authorized_keys (and public_keys of ConfigDrive): public key lines
  of a known type whose blob decodes; no options, no control characters;
- password: a crypt hash ($5$, $6$, $y$, $gy$, $2b$, $2y$, $7$) or a
  plain password, with no control characters;
- hostname and fqdn (and local-hostname, or hostname of ConfigDrive):
  RFC 1123 names, as firstboot.d/31fqdn takes them (libinithooks/fqdn.py);
- the instance-id (uuid of ConfigDrive), which says when the drive
  changed.

Nothing from the drive is run or applied as it is: runcmd, bootcmd,
write_files, packages and every other key are ignored, and the notes say
which. A user-data that is not #cloud-config (a script) is ignored as a
whole. The network configuration is not applied, because keel owns the
network: the notes say what it asks for, for the journal.
"""

import base64
import binascii
import json
import os
import re
import struct
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

import yaml

from libinithooks import fqdn

NOCLOUD = "nocloud"
CONFIGDRIVE = "configdrive"
# blkid labels, in the order they are looked for
LABELS = (("cidata", NOCLOUD), ("CIDATA", NOCLOUD), ("config-2", CONFIGDRIVE))
# systemd-detect-virt --vm of a Proxmox VM
VM_KINDS = frozenset({"qemu", "kvm"})
# Proxmox keeps the sum of the files below 3 MiB; one file is never more
MAX_FILE = 3 * 1024 * 1024
MAX_KEY = 16 * 1024
CLOUD_CONFIG = "#cloud-config"
INSTANCE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
KEY_TYPES = frozenset({
    "ssh-ed25519",
    "ssh-rsa",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com",
    "sk-ecdsa-sha2-nistp256@openssh.com",
})
# crypt(5) prefixes chpasswd -e takes: sha256, sha512, yescrypt,
# gost-yescrypt, bcrypt, scrypt. md5crypt ($1$) and DES are refused.
HASH_RE = re.compile(r"^\$([a-z0-9]+)\$")
HASH_IDS = frozenset({"5", "6", "y", "gy", "2b", "2y", "7"})
HASH_CHARS_RE = re.compile(r"^[A-Za-z0-9./$=+-]+$")
# the keys of #cloud-config that are read, or accepted as having no effect
READ_KEYS = frozenset({
    "ssh_authorized_keys", "password", "chpasswd", "user", "hostname",
    "fqdn",
})
NO_EFFECT_KEYS = frozenset({
    # Proxmox writes these; Keel does what they ask in its own way
    "manage_etc_hosts",  # 31fqdn writes the /etc/hosts entry
    "users",  # only "default" is accepted, see users_note()
    "disable_root",  # root logs in over SSH with a key on Keel
})
NOCLOUD_FILES = ("user-data", "meta-data", "network-config")
CONFIGDRIVE_FILES = (
    "openstack/latest/user_data",
    "openstack/latest/meta_data.json",
    "openstack/content/0000",
)


class DriveError(Exception):
    pass


@dataclass(frozen=True)
class Settings:
    """What the drive asks for, validated"""

    instance_id: str
    keys: tuple[str, ...] = ()
    password: str = ""
    hashed: bool = False
    user: str = ""
    hostname: str = ""
    fqdn: str = ""
    notes: tuple[str, ...] = field(default=())


def control(text: str) -> bool:
    """Whether TEXT holds a control character (a newline among them)"""
    return any(ord(c) < 32 or ord(c) == 127 for c in text)


def find_device(blkid: Callable[[str], list[str]]) -> tuple[str, str] | None:
    """(device, kind) of the one drive with a cloud-init label, or None

    BLKID gives the devices that carry a label, [] for none. Every label
    is asked: when two devices carry one, a second drive (a USB stick
    beside the Proxmox drive) could win by the order blkid answers in, so
    both are refused.
    """
    found: dict[str, str] = {}
    for label, kind in LABELS:
        for device in blkid(label):
            found.setdefault(device, kind)
    if len(found) > 1:
        raise DriveError(
            "more than one device has a cloud-init label: "
            + ", ".join(found) + "; none is read")
    return next(iter(found.items()), None)


def qemu_vm(virt: str) -> bool:
    """Whether systemd-detect-virt --vm answered a QEMU or KVM machine,
    the machines Proxmox runs"""
    return virt.strip() in VM_KINDS


def bus_refusal(sysfs: str) -> str | None:
    """Why the block device at the sysfs path SYSFS (the resolved
    /sys/class/block/NAME) is not read as a cloud-init drive, None when
    it is on the VM's own bus (IDE/SATA, SCSI, virtio). A USB device is
    refused: anybody with a stick and a power button could give root an
    SSH key."""
    if not sysfs:
        return "not a block device in /sys/class/block"
    if "/usb" in sysfs:
        return "a USB device"
    return None


def read_file(root: str, name: str) -> str | None:
    """The text of NAME under ROOT, None when it is not there

    A symbolic link is not followed, in any part of NAME: each part is
    opened with O_NOFOLLOW relative to the one before, so nothing is read
    from outside the drive. A file larger than MAX_FILE is refused: the
    drive is data from outside the machine.
    """
    *dirs, last = name.split("/")
    fds = [os.open(root, os.O_RDONLY | os.O_DIRECTORY)]
    try:
        for part in dirs:
            fds.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY
                               | os.O_NOFOLLOW, dir_fd=fds[-1]))
        fd = os.open(last, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fds[-1])
    except FileNotFoundError:
        return None
    except OSError as e:
        raise DriveError(f"{name}: cannot be read: {e.strerror}") from e
    finally:
        for opened in fds:
            os.close(opened)
    with os.fdopen(fd, "rb") as fob:
        data = fob.read(MAX_FILE + 1)
    if len(data) > MAX_FILE:
        raise DriveError(f"{name}: larger than {MAX_FILE} bytes, not read")
    return data.decode("utf-8", "replace")


def read_drive(root: str, kind: str) -> Settings:
    """The settings of the drive mounted at ROOT"""
    if kind == CONFIGDRIVE:
        user, meta, network = (read_file(root, n) for n in CONFIGDRIVE_FILES)
        return configdrive_settings(user, meta, network)
    user, meta, network = (read_file(root, n) for n in NOCLOUD_FILES)
    return nocloud_settings(user, meta, network)


def load_yaml(text: str, name: str, notes: list[str]) -> Any:
    """TEXT as YAML data (safe_load builds no object), None when it is
    not YAML; NOTES says why

    A document with an anchor or an alias is refused before it is built:
    aliases expand, and a few hundred bytes become many megabytes (an
    alias bomb). Proxmox writes neither.
    """
    try:
        for event in yaml.parse(text, Loader=yaml.SafeLoader):
            if isinstance(event, yaml.AliasEvent) or getattr(
                    event, "anchor", None):
                notes.append(f"{name} has YAML anchors or aliases, ignored")
                return None
        return yaml.safe_load(text)
    except yaml.YAMLError:
        notes.append(f"{name} is not valid YAML, ignored")
        return None


def user_config(text: str | None, notes: list[str]) -> dict:
    """The #cloud-config mapping of TEXT, {} for none"""
    if text is None or not text.strip():
        return {}
    if text.splitlines()[0].strip() != CLOUD_CONFIG:
        notes.append(
            "user-data is not #cloud-config (a script or another format),"
            " ignored: nothing from it is run"
        )
        return {}
    doc = load_yaml(text, "user-data", notes)
    if doc is None:
        return {}
    if not isinstance(doc, dict):
        notes.append("user-data is not a mapping, ignored")
        return {}
    return doc


def nocloud_settings(user: str | None, meta: str | None,
                     network: str | None) -> Settings:
    notes: list[str] = []
    metadata = load_yaml(meta or "", "meta-data", notes)
    if not isinstance(metadata, dict):
        metadata = {}
    config = user_config(user, notes)
    if network is not None:
        notes.extend(network_notes(load_yaml(network, "network-config",
                                             notes)))
    return settings(
        metadata.get("instance-id"), config, notes,
        local_hostname=metadata.get("local-hostname"),
    )


def configdrive_settings(user: str | None, meta: str | None,
                         network: str | None) -> Settings:
    notes: list[str] = []
    try:
        metadata = json.loads(meta or "{}")
    except ValueError:
        notes.append("meta_data.json is not valid JSON, ignored")
        metadata = {}
    if not isinstance(metadata, dict):
        metadata = {}
    config = user_config(user, notes)
    public = metadata.get("public_keys")
    extra = list(public.values()) if isinstance(public, dict) else []
    if network is not None:
        notes.extend(interfaces_notes(network))
    return settings(
        metadata.get("uuid"), config, notes,
        local_hostname=metadata.get("hostname"), extra_keys=extra,
    )


def settings(instance_id: Any, config: dict, notes: list[str],
             local_hostname: Any = None,
             extra_keys: list[Any] | None = None) -> Settings:
    """Settings from the #cloud-config CONFIG and the metadata values"""
    if not isinstance(instance_id, str) or not INSTANCE_ID_RE.match(
            instance_id):
        raise DriveError("the drive has no valid instance-id, not read")
    ignored = sorted(str(k) for k in config
                     if k not in READ_KEYS and k not in NO_EFFECT_KEYS)
    if ignored:
        notes.append(
            "ignored, Keel does not run or apply them: " + ", ".join(ignored)
        )
    notes.extend(users_note(config.get("users")))
    keys = valid_keys(config.get("ssh_authorized_keys"), extra_keys or [],
                      notes)
    password, hashed = valid_password(config.get("password"), notes)
    notes.extend(chpasswd_notes(config.get("chpasswd")))
    hostname, name = valid_names(config.get("hostname"), config.get("fqdn"),
                                 local_hostname, notes)
    return Settings(
        instance_id=instance_id,
        keys=keys,
        password=password,
        hashed=hashed,
        user=user_name(config.get("user"), notes),
        hostname=hostname,
        fqdn=name,
        notes=tuple(notes),
    )


def users_note(users: Any) -> list[str]:
    """users: only the image's default user (Proxmox writes "- default")
    is accepted; no account is made from the drive"""
    if users is None or users == ["default"]:
        return []
    return ["users: no account is made from the drive, ignored"]


def user_name(user: Any, notes: list[str]) -> str:
    """The account the drive names (Proxmox ciuser), "" for none"""
    if isinstance(user, dict):
        user = user.get("name")
    if user is None:
        return ""
    if not isinstance(user, str) or not re.match(r"^[a-z_][a-z0-9_-]{0,31}$",
                                                 user):
        notes.append("user is not a valid account name, ignored")
        return ""
    return user


def valid_key(line: Any) -> str | None:
    """LINE as an authorized_keys line, or None when it is not a plain
    public key: a known type, a blob that decodes and names that type,
    and an optional comment. Options (command=, from=) are refused."""
    if not isinstance(line, str) or len(line) > MAX_KEY or control(line):
        return None
    parts = line.strip().split(None, 2)
    if len(parts) < 2 or parts[0] not in KEY_TYPES:
        return None
    try:
        blob = base64.b64decode(parts[1], validate=True)
    except (binascii.Error, ValueError):
        return None
    if len(blob) < 4:
        return None
    (length,) = struct.unpack(">I", blob[:4])
    if blob[4:4 + length] != parts[0].encode():
        return None
    return " ".join(parts)


def valid_keys(keys: Any, extra: list[Any], notes: list[str]
               ) -> tuple[str, ...]:
    if keys is None:
        keys = []
    if isinstance(keys, str):
        keys = [keys]
    if not isinstance(keys, list):
        notes.append("ssh_authorized_keys is not a list, ignored")
        keys = []
    accepted: list[str] = []
    for number, line in enumerate([*keys, *extra], start=1):
        key = valid_key(line)
        if key is None:
            notes.append(f"SSH key {number} is not a valid public key line,"
                         " ignored")
        elif key not in accepted:
            accepted.append(key)
    return tuple(accepted)


def valid_password(password: Any, notes: list[str]) -> tuple[str, bool]:
    """(password, hashed), ("", False) for none. The value is never put
    in a note."""
    if password is None or password == "":
        return "", False
    if not isinstance(password, str) or control(password):
        notes.append("password holds a control character or is not text,"
                     " ignored")
        return "", False
    match = HASH_RE.match(password)
    if not match:
        return password, False
    if match.group(1) not in HASH_IDS or not HASH_CHARS_RE.match(password):
        notes.append(f"password is a ${match.group(1)}$ hash, which is not"
                     " accepted (sha256, sha512, yescrypt or bcrypt are),"
                     " ignored")
        return "", False
    return password, True


def chpasswd_notes(chpasswd: Any) -> list[str]:
    """chpasswd: expire is not applied, list and users are ignored"""
    if chpasswd is None:
        return []
    if not isinstance(chpasswd, dict):
        return ["chpasswd is not a mapping, ignored"]
    notes = []
    if chpasswd.get("expire") not in (None, False):
        notes.append("chpasswd: expire is not applied, the password does"
                     " not expire")
    other = sorted(str(k) for k in chpasswd if k != "expire")
    if other:
        notes.append("chpasswd: ignored: " + ", ".join(other))
    return notes


def one_name(value: Any, key: str, notes: list[str]) -> str:
    if value is None:
        return ""
    name, problem = fqdn.normalize(value) if isinstance(value, str) else (
        "", "not text")
    if problem:
        notes.append(f"{key} is not a valid host name, ignored")
        return ""
    return name


def valid_names(hostname: Any, name: Any, local: Any,
                notes: list[str]) -> tuple[str, str]:
    """(hostname, fqdn), "" for each the drive does not give

    A dotted fqdn wins: the hostname is its first label, as 31fqdn takes
    it. Proxmox writes fqdn equal to hostname when the VM has no search
    domain; then there is a hostname alone.
    """
    host = one_name(hostname, "hostname", notes)
    full = one_name(name, "fqdn", notes)
    if "." in full:
        first, full = fqdn.split(full)
        if host and host != first:
            notes.append(f"hostname {host} is not the first label of fqdn"
                         f" {full}: {first} is used")
        return first, full
    host = host or full or one_name(local, "local-hostname", notes)
    # a dotted hostname alone is a name with a domain
    return fqdn.split(host) if host else ("", "")


def network_notes(doc: Any) -> list[str]:
    """What a NoCloud network-config (version 1 or 2) asks for"""
    if not isinstance(doc, dict):
        return []
    static: list[str] = []
    if doc.get("version") == 1 and isinstance(doc.get("config"), list):
        for entry in doc["config"]:
            if not isinstance(entry, dict):
                continue
            subnets = entry.get("subnets")
            for subnet in subnets if isinstance(subnets, list) else []:
                if (isinstance(subnet, dict)
                        and text(subnet.get("type")).startswith("static")
                        and text(subnet.get("address"))):
                    static.append(f"{text(entry.get('name')) or '?'}"
                                  f" {subnet['address']}")
    elif doc.get("version") == 2 and isinstance(doc.get("ethernets"), dict):
        for name, iface in doc["ethernets"].items():
            addresses = iface.get("addresses") if isinstance(iface, dict) \
                else None
            for address in addresses if isinstance(addresses, list) else []:
                if text(address):
                    static.append(f"{text(name) or '?'} {address}")
    return [network_note(static)]


def text(value: Any) -> str:
    """VALUE when it is a plain string with no control character, else
    "": a note never carries a structure or a line break"""
    if isinstance(value, str) and not control(value) and len(value) < 256:
        return value
    return ""


def interfaces_notes(content: str) -> list[str]:
    """What a ConfigDrive network file (ifupdown interfaces) asks for"""
    static = [text(line.split()[1]) or "?" for line in content.splitlines()
              if line.strip().startswith("address") and len(line.split()) > 1]
    return [network_note(static)]


def network_note(static: list[str]) -> str:
    if not static:
        return ("network configuration: not applied, keel owns the network;"
                " it asks for no static address")
    return ("network configuration: not applied, keel owns the network;"
            " it asks for static addresses " + ", ".join(static)
            + ": declare them in the instance description (network) to use"
            " them")


def authorized_keys(home: str, uid: int, gid: int,
                    keys: tuple[str, ...]) -> int:
    """Adds KEYS to HOME/.ssh/authorized_keys, the lines it already holds
    kept; returns how many were added. .ssh is 0700, the file 0600, both
    owned by UID:GID. A symbolic link in either place is refused."""
    if not keys:
        return 0
    ssh = os.path.join(home, ".ssh")
    if os.path.islink(ssh):
        raise DriveError(f"{ssh} is a symbolic link, no key written")
    if not os.path.isdir(ssh):
        os.mkdir(ssh, 0o700)
    os.chown(ssh, uid, gid)
    os.chmod(ssh, 0o700)
    path = os.path.join(ssh, "authorized_keys")
    if os.path.islink(path):
        raise DriveError(f"{path} is a symbolic link, no key written")
    try:
        with open(path) as fob:
            lines = fob.read().splitlines()
    except FileNotFoundError:
        lines = []
    present = {line.strip() for line in lines}
    new = [key for key in keys if key not in present]
    if not new:
        return 0
    staged = path + ".cloud-drive"
    fd = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW,
                 0o600)
    with os.fdopen(fd, "w") as fob:
        fob.write("".join(f"{line}\n" for line in [*lines, *new]))
        os.fchown(fob.fileno(), uid, gid)
        os.fchmod(fob.fileno(), 0o600)
    os.replace(staged, path)
    return len(new)


def chpasswd_input(user: str, password: str) -> bytes:
    """The one line chpasswd reads for USER"""
    return f"{user}:{password}\n".encode()


def conf_sets(text: str, key: str) -> bool:
    """Whether the inithooks conf TEXT sets KEY (KEY= or export KEY=)"""
    return re.search(rf"^\s*(export\s+)?{re.escape(key)}=", text,
                     re.MULTILINE) is not None


def conf_lines(settings: Settings, conf: str, password_set: bool,
               notes: list[str]) -> list[str]:
    """The lines to add to the inithooks conf: ROOT_PASS=KEEP when the
    password was set, FQDN= or HOSTNAME= for the name. What the conf
    already sets (a preseed, or 00declarative from the instance
    description) wins. The values are validated names, quoted anyway."""
    lines = []
    if password_set:
        lines.append("export ROOT_PASS=KEEP")
    if settings.fqdn:
        key, value = "FQDN", settings.fqdn
    else:
        key, value = "HOSTNAME", settings.hostname
    if value and (conf_sets(conf, "FQDN") or conf_sets(conf, "HOSTNAME")):
        notes.append("the name is already preseeded or described, the"
                     " drive's name is not used")
    elif value:
        lines.append(f"export {key}='{value}'")
    return lines


def append_conf(path: str, lines: list[str]) -> None:
    """Adds LINES to the conf at PATH, readable by root only"""
    if not lines:
        return
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a") as fob:
        fob.write("".join(f"{line}\n" for line in lines))
    os.chmod(path, 0o600)


def read_text(path: str) -> str:
    try:
        with open(path) as fob:
            return fob.read()
    except FileNotFoundError:
        return ""


def write_text(path: str, text: str, mode: int = 0o644) -> None:
    """TEXT into PATH, written beside it and moved in place"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    staged = path + ".new"
    fd = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as fob:
        fob.write(text)
    os.replace(staged, path)
