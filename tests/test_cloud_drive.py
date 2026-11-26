"""libinithooks/cloud_drive.py: reading a cloud-init drive without
cloud-init

The drives are scratch directories laid out as Proxmox writes them
(PVE/QemuServer/Cloudinit.pm): NoCloud with user-data, meta-data and
network-config, ConfigDrive with openstack/latest/user_data,
meta_data.json and openstack/content/0000. Nothing touches the live
system.
"""

import base64
import json
import os
import stat
import struct
import tempfile
import unittest
from os.path import join

import helpers  # noqa: F401  (puts the repository on sys.path)

from libinithooks import cloud_drive as cd


def key(kind="ssh-ed25519", comment="ops@example.org"):
    """A public key line of KIND whose blob names KIND, as a real one does"""
    name = kind.encode()
    blob = struct.pack(">I", len(name)) + name + b"\x00" * 36
    line = f"{kind} {base64.b64encode(blob).decode()}"
    return f"{line} {comment}" if comment else line


ED = key()
RSA = key("ssh-rsa", "laptop")
SHA256 = "$5$rounds=5000$abcdefgh$" + "A" * 43
SHA512 = "$6$saltsalt$" + "b" * 86

# what Proxmox writes for ciuser unset, cipassword, sshkeys and a
# searchdomain (cloudinit_userdata)
PROXMOX = f"""#cloud-config
hostname: blog
manage_etc_hosts: true
fqdn: blog.example.org
password: {SHA256}
ssh_authorized_keys:
  - {ED}
  - {RSA}
chpasswd:
  expire: False
users:
  - default
package_upgrade: true
"""


class Drive(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.dir = scratch.name

    def write(self, name, text):
        path = join(self.dir, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fob:
            fob.write(text)
        return path


class FindDevice(unittest.TestCase):
    def test_every_label_is_asked(self):
        seen = []

        def blkid(label):
            seen.append(label)
            return ["/dev/sr0"] if label == "cidata" else []

        self.assertEqual(cd.find_device(blkid), ("/dev/sr0", cd.NOCLOUD))
        self.assertEqual(seen, ["cidata", "CIDATA", "config-2"])

    def test_one_device_under_two_labels_is_one(self):
        self.assertEqual(cd.find_device(lambda l: ["/dev/sr0"]),
                         ("/dev/sr0", cd.NOCLOUD))

    def test_two_devices_are_both_refused(self):
        # a second drive (a USB stick beside the Proxmox drive) must not
        # win by the order blkid answers in
        with self.assertRaisesRegex(cd.DriveError,
                                    "/dev/sr0, /dev/sdb.*none is read"):
            cd.find_device(lambda l: {"cidata": ["/dev/sr0"],
                                      "config-2": ["/dev/sdb"]}.get(l, []))
        with self.assertRaisesRegex(cd.DriveError, "none is read"):
            cd.find_device(lambda l: ["/dev/sr0", "/dev/sr1"]
                           if l == "cidata" else [])

    def test_upper_case_and_config_drive(self):
        self.assertEqual(
            cd.find_device(lambda l: ["/dev/vdb"] if l == "CIDATA" else []),
            ("/dev/vdb", cd.NOCLOUD))
        self.assertEqual(
            cd.find_device(lambda l: ["/dev/sr1"] if l == "config-2" else []),
            ("/dev/sr1", cd.CONFIGDRIVE))

    def test_no_drive(self):
        self.assertIsNone(cd.find_device(lambda l: []))


class NoCloud(Drive):
    def test_proxmox_drive(self):
        self.write("user-data", PROXMOX)
        self.write("meta-data", "instance-id: 4c2a6f\n")
        s = cd.read_drive(self.dir, cd.NOCLOUD)
        self.assertEqual(s.instance_id, "4c2a6f")
        self.assertEqual(s.keys, (ED, RSA))
        self.assertEqual((s.password, s.hashed), (SHA256, True))
        self.assertEqual((s.hostname, s.fqdn), ("blog", "blog.example.org"))
        self.assertEqual(s.user, "")
        self.assertIn("ignored, Keel does not run or apply them:"
                      " package_upgrade", s.notes)
        # the password is never in a note
        self.assertFalse(any(SHA256 in n for n in s.notes))

    def test_dangerous_keys_are_ignored_and_named(self):
        self.write("user-data", "#cloud-config\nruncmd: [reboot]\n"
                   "bootcmd: [id]\nwrite_files: []\npackages: [nmap]\n")
        self.write("meta-data", "instance-id: a\n")
        s = cd.read_drive(self.dir, cd.NOCLOUD)
        self.assertEqual(s.notes[0], "ignored, Keel does not run or apply"
                         " them: bootcmd, packages, runcmd, write_files")
        self.assertEqual(s.keys, ())

    def test_a_script_is_not_read(self):
        self.write("user-data", f"#!/bin/sh\nrm -rf /\n# {ED}\n")
        self.write("meta-data", "instance-id: a\n")
        s = cd.read_drive(self.dir, cd.NOCLOUD)
        self.assertIn("not #cloud-config", s.notes[0])
        self.assertEqual(s.keys, ())

    def test_bad_yaml_and_not_a_mapping(self):
        self.write("meta-data", "instance-id: a\n")
        self.write("user-data", "#cloud-config\n: [\n")
        self.assertIn("user-data is not valid YAML, ignored",
                      cd.read_drive(self.dir, cd.NOCLOUD).notes)
        self.write("user-data", "#cloud-config\n- a\n")
        self.assertIn("user-data is not a mapping, ignored",
                      cd.read_drive(self.dir, cd.NOCLOUD).notes)

    def test_anchors_and_aliases_are_refused(self):
        # an alias bomb: 305 bytes that expand to many megabytes
        bomb = "a: &a ['x','x','x','x','x','x','x','x','x']\n" + "".join(
            f"{chr(98 + i)}: &{chr(98 + i)} [*{chr(97 + i)},*{chr(97 + i)},"
            f"*{chr(97 + i)},*{chr(97 + i)},*{chr(97 + i)},*{chr(97 + i)},"
            f"*{chr(97 + i)},*{chr(97 + i)},*{chr(97 + i)}]\n"
            for i in range(8))
        self.write("meta-data", "instance-id: a\n")
        self.write("network-config", "version: 2\nethernets:\n" + "".join(
            "  " + line + "\n" for line in bomb.splitlines()))
        notes = cd.read_drive(self.dir, cd.NOCLOUD).notes
        self.assertIn("network-config has YAML anchors or aliases, ignored",
                      notes)
        self.write("user-data", "#cloud-config\nhostname: &h blog\n"
                   "fqdn: *h\n")
        s = cd.read_drive(self.dir, cd.NOCLOUD)
        self.assertIn("user-data has YAML anchors or aliases, ignored",
                      s.notes)
        self.assertEqual(s.hostname, "")

    def test_network_values_that_are_not_text_are_skipped(self):
        self.write("meta-data", "instance-id: a\n")
        self.write("network-config", """version: 1
config:
  - type: physical
    name: [eth0]
    subnets:
      - type: static
        address: {a: 1}
      - type: static
        address: '192.0.2.10'
""")
        notes = cd.read_drive(self.dir, cd.NOCLOUD).notes
        self.assertIn("static addresses ? 192.0.2.10: declare", notes[-1])
        self.write("network-config", "version: 2\nethernets:\n"
                   "  eth0:\n    addresses: [[1, 2], '192.0.2.11/24']\n")
        notes = cd.read_drive(self.dir, cd.NOCLOUD).notes
        self.assertIn("static addresses eth0 192.0.2.11/24: declare",
                      notes[-1])

    def test_python_tags_are_not_built(self):
        self.write("meta-data", "instance-id: a\n")
        self.write("user-data", "#cloud-config\nhostname: !!python/object/"
                   "apply:os.system ['true']\n")
        s = cd.read_drive(self.dir, cd.NOCLOUD)
        self.assertIn("user-data is not valid YAML, ignored", s.notes)

    def test_empty_user_data_and_local_hostname(self):
        self.write("user-data", "\n")
        self.write("meta-data", "instance-id: a\nlocal-hostname: Web\n")
        s = cd.read_drive(self.dir, cd.NOCLOUD)
        self.assertEqual((s.hostname, s.fqdn), ("web", ""))

    def test_no_user_data(self):
        self.write("meta-data", "instance-id: a\n")
        self.assertEqual(cd.read_drive(self.dir, cd.NOCLOUD).keys, ())

    def test_no_instance_id(self):
        self.write("meta-data", "- a\n")
        with self.assertRaisesRegex(cd.DriveError, "instance-id"):
            cd.read_drive(self.dir, cd.NOCLOUD)
        self.write("meta-data", "instance-id: 'a b'\n")
        with self.assertRaisesRegex(cd.DriveError, "instance-id"):
            cd.read_drive(self.dir, cd.NOCLOUD)

    def test_network_v1_static(self):
        self.write("meta-data", "instance-id: a\n")
        self.write("network-config", """version: 1
config:
  - type: physical
    name: eth0
    subnets:
      - type: static
        address: '192.0.2.10'
        netmask: '255.255.255.0'
      - type: static6
        address: '2001:db8::10/64'
      - type: dhcp4
  - type: nameserver
    address: ['192.0.2.1']
  - nothing
""")
        notes = cd.read_drive(self.dir, cd.NOCLOUD).notes
        self.assertIn("it asks for static addresses eth0 192.0.2.10, eth0"
                      " 2001:db8::10/64: declare", notes[-1])

    def test_network_v2_and_dhcp(self):
        self.write("meta-data", "instance-id: a\n")
        self.write("network-config", """version: 2
ethernets:
  eth0:
    addresses: ['192.0.2.10/24']
  eth1: {dhcp4: true}
""")
        notes = cd.read_drive(self.dir, cd.NOCLOUD).notes
        self.assertIn("eth0 192.0.2.10/24", notes[-1])
        self.write("network-config", "version: 1\nconfig:\n  - type:"
                   " physical\n    name: eth0\n    subnets:\n"
                   "      - type: dhcp\n")
        notes = cd.read_drive(self.dir, cd.NOCLOUD).notes
        self.assertIn("it asks for no static address", notes[-1])

    def test_network_not_a_mapping(self):
        self.write("meta-data", "instance-id: a\n")
        self.write("network-config", "- a\n")
        self.assertEqual(cd.read_drive(self.dir, cd.NOCLOUD).notes, ())


class ConfigDrive(Drive):
    def test_proxmox_config_drive(self):
        self.write("openstack/latest/user_data", PROXMOX)
        self.write("openstack/latest/meta_data.json", json.dumps({
            "uuid": "9f1e", "network_config": {"content_path":
                                               "/content/0000"},
            "public_keys": {"key-0": key(comment="")}}))
        self.write("openstack/content/0000",
                   "auto eth0\niface eth0 inet static\n"
                   "        address 192.0.2.10/24\n")
        s = cd.read_drive(self.dir, cd.CONFIGDRIVE)
        self.assertEqual(s.instance_id, "9f1e")
        self.assertEqual(s.keys, (ED, RSA, key(comment="")))
        self.assertTrue(any("192.0.2.10/24" in n for n in s.notes))

    def test_hostname_and_bad_json(self):
        self.write("openstack/latest/meta_data.json",
                   '{"uuid": "a", "hostname": "db.example.org"}')
        s = cd.read_drive(self.dir, cd.CONFIGDRIVE)
        self.assertEqual((s.hostname, s.fqdn), ("db", "db.example.org"))
        self.write("openstack/latest/meta_data.json", "{")
        with self.assertRaises(cd.DriveError):
            cd.read_drive(self.dir, cd.CONFIGDRIVE)
        self.write("openstack/latest/meta_data.json", "[]")
        with self.assertRaises(cd.DriveError):
            cd.read_drive(self.dir, cd.CONFIGDRIVE)

    def test_no_static_address(self):
        self.write("openstack/latest/meta_data.json", '{"uuid": "a"}')
        self.write("openstack/content/0000", "iface eth0 inet dhcp\n")
        notes = cd.read_drive(self.dir, cd.CONFIGDRIVE).notes
        self.assertIn("no static address", notes[-1])


class ReadFile(Drive):
    def test_symbolic_link_is_not_followed(self):
        target = self.write("secret", "x")
        os.symlink(target, join(self.dir, "user-data"))
        with self.assertRaisesRegex(cd.DriveError, "cannot be read"):
            cd.read_file(self.dir, "user-data")

    def test_symbolic_link_in_a_directory_is_not_followed(self):
        outside = tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)
        with open(join(outside.name, "user_data"), "w") as fob:
            fob.write("#cloud-config\n")
        os.makedirs(join(self.dir, "openstack"))
        os.symlink(outside.name, join(self.dir, "openstack", "latest"))
        with self.assertRaisesRegex(cd.DriveError, "cannot be read"):
            cd.read_file(self.dir, "openstack/latest/user_data")

    def test_missing_directory(self):
        self.assertIsNone(cd.read_file(self.dir,
                                       "openstack/latest/user_data"))

    def test_nested_file(self):
        self.write("openstack/latest/user_data", "x")
        self.assertEqual(cd.read_file(self.dir,
                                      "openstack/latest/user_data"), "x")

    def test_too_large(self):
        with open(join(self.dir, "user-data"), "wb") as fob:
            fob.truncate(cd.MAX_FILE + 1)
        with self.assertRaisesRegex(cd.DriveError, "larger"):
            cd.read_file(self.dir, "user-data")


class Machine(unittest.TestCase):
    def test_qemu_vm(self):
        self.assertTrue(cd.qemu_vm("kvm\n"))
        self.assertTrue(cd.qemu_vm("qemu"))
        for answer in ("none", "", "vmware", "lxc", "oracle"):
            self.assertFalse(cd.qemu_vm(answer), answer)

    def test_bus_refusal(self):
        self.assertIsNone(cd.bus_refusal(
            "/sys/devices/pci0000:00/0000:00:01.1/ata2/host1/target1:0:0/"
            "1:0:0:0/block/sr0"))
        self.assertIsNone(cd.bus_refusal(
            "/sys/devices/pci0000:00/0000:00:0a.0/virtio3/block/vdb"))
        self.assertIn("USB", cd.bus_refusal(
            "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1:1.0/host6/"
            "target6:0:0/6:0:0:0/block/sdb"))
        self.assertIn("not a block device", cd.bus_refusal(""))


class Keys(unittest.TestCase):
    def test_valid(self):
        for kind in sorted(cd.KEY_TYPES):
            self.assertEqual(cd.valid_key(key(kind)), key(kind))
        self.assertEqual(cd.valid_key("  " + ED + "  "), ED)

    def test_refused(self):
        name = b"ssh-rsa"
        wrong = base64.b64encode(struct.pack(">I", len(name)) + name).decode()
        for line in [
            None, 3, "", "ssh-ed25519", "ssh-dss AAAA",
            f'command="id" {ED}', ED + "\nssh-rsa x", f"ssh-ed25519 {wrong}",
            "ssh-ed25519 not*base64", "ssh-ed25519 AAA=",
            "ssh-ed25519 " + "A" * cd.MAX_KEY,
        ]:
            self.assertIsNone(cd.valid_key(line), line)

    def test_list_forms(self):
        notes = []
        self.assertEqual(cd.valid_keys(ED, [], notes), (ED,))
        self.assertEqual(cd.valid_keys([ED, ED, "x"], [], notes), (ED,))
        self.assertEqual(notes, [("SSH key 3 is not a valid public key line,"
                                  " ignored")])
        self.assertEqual(cd.valid_keys({"a": ED}, [], notes), ())
        self.assertIn("ssh_authorized_keys is not a list, ignored", notes)


class Password(unittest.TestCase):
    def test_forms(self):
        notes = []
        self.assertEqual(cd.valid_password(None, notes), ("", False))
        self.assertEqual(cd.valid_password("", notes), ("", False))
        self.assertEqual(cd.valid_password("s3cret:x", notes),
                         ("s3cret:x", False))
        self.assertEqual(cd.valid_password(SHA512, notes), (SHA512, True))
        self.assertEqual(notes, [])

    def test_refused(self):
        notes = []
        self.assertEqual(cd.valid_password("a\nroot:x", notes), ("", False))
        self.assertEqual(cd.valid_password(1234, notes), ("", False))
        self.assertEqual(cd.valid_password("$1$salt$hash", notes),
                         ("", False))
        self.assertEqual(cd.valid_password("$6$salt$h ash", notes),
                         ("", False))
        self.assertEqual(len(notes), 4)
        self.assertFalse(any("salt" in n for n in notes))


class Notes(unittest.TestCase):
    def test_chpasswd(self):
        self.assertEqual(cd.chpasswd_notes(None), [])
        self.assertEqual(cd.chpasswd_notes({"expire": False}), [])
        self.assertEqual(cd.chpasswd_notes("x"),
                         ["chpasswd is not a mapping, ignored"])
        self.assertEqual(
            cd.chpasswd_notes({"expire": True, "list": "root:x"}),
            [("chpasswd: expire is not applied, the password does not"
              " expire"), "chpasswd: ignored: list"])

    def test_users_and_user(self):
        self.assertEqual(cd.users_note(None), [])
        self.assertEqual(cd.users_note(["default"]), [])
        self.assertEqual(len(cd.users_note([{"name": "eve"}])), 1)
        notes = []
        self.assertEqual(cd.user_name(None, notes), "")
        self.assertEqual(cd.user_name("debian", notes), "debian")
        self.assertEqual(cd.user_name({"name": "root"}, notes), "root")
        self.assertEqual(cd.user_name("Bad Name", notes), "")
        self.assertEqual(cd.user_name(["x"], notes), "")
        self.assertEqual(len(notes), 2)

    def test_names(self):
        notes = []
        self.assertEqual(cd.valid_names("blog", "blog", None, notes),
                         ("blog", ""))
        self.assertEqual(cd.valid_names("web", "blog.example.org", None,
                                        notes), ("blog", "blog.example.org"))
        self.assertIn("is not the first label", notes[-1])
        self.assertEqual(cd.valid_names(None, None, None, notes), ("", ""))
        self.assertEqual(cd.valid_names("bad_name", 5, "x.example.org",
                                        notes), ("x", "x.example.org"))
        self.assertIn("hostname is not a valid host name, ignored", notes)
        self.assertIn("fqdn is not a valid host name, ignored", notes)


class AuthorizedKeys(Drive):
    def ids(self):
        return os.getuid(), os.getgid()

    def test_new_file(self):
        uid, gid = self.ids()
        self.assertEqual(cd.authorized_keys(self.dir, uid, gid, (ED, RSA)), 2)
        path = join(self.dir, ".ssh", "authorized_keys")
        with open(path) as fob:
            self.assertEqual(fob.read(), f"{ED}\n{RSA}\n")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(
            stat.S_IMODE(os.stat(join(self.dir, ".ssh")).st_mode), 0o700)

    def test_keeps_lines_and_adds_once(self):
        uid, gid = self.ids()
        self.write(".ssh/authorized_keys", f"# mine\n{ED}\n")
        os.chmod(join(self.dir, ".ssh"), 0o755)
        self.assertEqual(cd.authorized_keys(self.dir, uid, gid, (ED, RSA)), 1)
        self.assertEqual(cd.authorized_keys(self.dir, uid, gid, (ED, RSA)), 0)
        with open(join(self.dir, ".ssh", "authorized_keys")) as fob:
            self.assertEqual(fob.read(), f"# mine\n{ED}\n{RSA}\n")
        self.assertEqual(
            stat.S_IMODE(os.stat(join(self.dir, ".ssh")).st_mode), 0o700)

    def test_no_keys(self):
        self.assertEqual(cd.authorized_keys(self.dir, 0, 0, ()), 0)
        self.assertFalse(os.path.exists(join(self.dir, ".ssh")))

    def test_symbolic_links_refused(self):
        uid, gid = self.ids()
        os.symlink("/tmp", join(self.dir, ".ssh"))
        with self.assertRaisesRegex(cd.DriveError, "symbolic link"):
            cd.authorized_keys(self.dir, uid, gid, (ED,))
        os.remove(join(self.dir, ".ssh"))
        os.mkdir(join(self.dir, ".ssh"))
        os.symlink("/etc/passwd", join(self.dir, ".ssh", "authorized_keys"))
        with self.assertRaisesRegex(cd.DriveError, "symbolic link"):
            cd.authorized_keys(self.dir, uid, gid, (ED,))


class Conf(Drive):
    def test_conf_sets(self):
        self.assertTrue(cd.conf_sets("export ROOT_PASS='x'\n", "ROOT_PASS"))
        self.assertTrue(cd.conf_sets("A=1\n  FQDN=a\n", "FQDN"))
        self.assertFalse(cd.conf_sets("#FQDN=a\nXFQDN=a\n", "FQDN"))

    def test_lines(self):
        s = cd.Settings(instance_id="a", hostname="blog",
                        fqdn="blog.example.org")
        notes = []
        self.assertEqual(cd.conf_lines(s, "", True, notes),
                         ["export ROOT_PASS=KEEP",
                          "export FQDN='blog.example.org'"])
        s = cd.Settings(instance_id="a", hostname="blog")
        self.assertEqual(cd.conf_lines(s, "", False, notes),
                         ["export HOSTNAME='blog'"])
        self.assertEqual(cd.conf_lines(s, "export FQDN=x\n", False, notes),
                         [])
        self.assertIn("already preseeded or described", notes[0])
        self.assertEqual(cd.conf_lines(cd.Settings(instance_id="a"), "",
                                       False, notes), [])

    def test_append_and_text(self):
        path = join(self.dir, "inithooks.conf")
        cd.append_conf(path, [])
        self.assertFalse(os.path.exists(path))
        cd.append_conf(path, ["export A=1"])
        cd.append_conf(path, ["export B=2"])
        self.assertEqual(cd.read_text(path), "export A=1\nexport B=2\n")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(cd.read_text(join(self.dir, "none")), "")
        cd.write_text(join(self.dir, "state", "id"), "a\n")
        self.assertEqual(cd.read_text(join(self.dir, "state", "id")), "a\n")

    def test_chpasswd_input(self):
        self.assertEqual(cd.chpasswd_input("root", "a:b"), b"root:a:b\n")


if __name__ == "__main__":
    unittest.main()
