"""bin/cloud-drive.py (run by firstboot.d/02cloud-drive and
everyboot.d/02cloud-drive)

The drive is a scratch directory (CLOUD_DRIVE_ROOT) or a device found
and mounted through a faked run(); chpasswd is faked at the same
boundary, and every path the command writes is a scratch file.
"""

import importlib.util
import io
import os
import pwd
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from os.path import abspath, dirname, exists, join
from unittest import mock

import helpers  # noqa: F401  (puts the repository on sys.path)
from test_cloud_drive import ED, PROXMOX, RSA, SHA256

CLI_PY = join(dirname(dirname(abspath(__file__))), "bin", "cloud-drive.py")


def load_cli():
    spec = importlib.util.spec_from_file_location("cloud_drive_cli", CLI_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def done(code=0, out=b"", err=b""):
    return subprocess.CompletedProcess([], code, out, err)


class CliCase(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.dir = scratch.name
        self.drive = join(self.dir, "drive")
        self.home = join(self.dir, "root")
        os.makedirs(self.drive)
        os.makedirs(self.home)
        self.conf = join(self.dir, "inithooks.conf")
        self.answer = join(self.dir, "run", "ssh-answer")
        self.state = join(self.dir, "state", "instance-id")
        self.password = join(self.dir, "state", "root-password")
        self.calls = []
        self.write("user-data", PROXMOX)
        self.write("meta-data", "instance-id: 4c2a6f\n")
        # /sys/class/block: the Proxmox drive on the IDE bus, a USB stick
        self.sysfs = join(self.dir, "sys-class-block")
        os.makedirs(self.sysfs)
        os.symlink("/sys/devices/pci0000:00/0000:00:01.1/ata2/host1/target1:0:0/1:0:0:0/block/sr0", join(self.sysfs, "sr0"))
        os.symlink("/sys/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1:1.0/host6/target6:0:0/6:0:0:0/block/sdb", join(self.sysfs, "sdb"))

    def write(self, name, text):
        with open(join(self.drive, name), "w") as fob:
            fob.write(text)

    def environ(self, **extra):
        values = {
            "INITHOOKS_CONF": self.conf,
            "INITHOOKS_SSH_ANSWER": self.answer,
            "CLOUD_DRIVE_STATE": self.state,
            "CLOUD_DRIVE_PASSWORD": self.password,
            "CLOUD_DRIVE_CONTAINER": join(self.dir, "no-container"),
            "CLOUD_DRIVE_ROOT": self.drive,
            "CLOUD_DRIVE_HOME": self.home,
            "CLOUD_DRIVE_SYSFS": self.sysfs,
        }
        values.update(extra)
        return values

    def fake_run(self, answers=None):
        # a Proxmox VM unless the test says otherwise
        answers = {"systemd-detect-virt": done(0, b"kvm\n"),
                   **(answers or {})}

        def run(cmd, data=None):
            self.calls.append((cmd, data))
            return answers.get(cmd[0], done())

        return run

    def account(self, name):
        if name not in ("root", "admin"):
            raise KeyError(name)
        return pwd.struct_passwd((name, "x", os.getuid(), os.getgid(), "",
                                  "/nonexistent", "/bin/bash"))

    def cli(self, *argv, environ=None, answers=None, unset=()):
        """(status, stdout, stderr) of cloud-drive.py ARGV"""
        cli = load_cli()
        out, err = io.StringIO(), io.StringIO()
        status = 0
        env = {k: v for k, v in os.environ.items()
               if k not in ("_TURNKEY_INIT", "CLOUD_DRIVE_KIND")}
        env.update(environ if environ is not None else self.environ())
        for name in unset:
            env.pop(name, None)
        with (
            mock.patch.dict(os.environ, env, clear=True),
            mock.patch.object(cli, "run", self.fake_run(answers)),
            mock.patch.object(cli.pwd, "getpwnam", self.account),
            mock.patch.object(cli.sys, "argv", ["cloud-drive.py", *argv]),
            redirect_stdout(out),
            redirect_stderr(err),
        ):
            try:
                cli.main()
            except SystemExit as e:
                status = e.code
        return status, out.getvalue(), err.getvalue()

    def commands(self):
        return [call[0][0] for call in self.calls]

    def read(self, path):
        with open(path) as fob:
            return fob.read()


class Firstboot(CliCase):
    def test_proxmox_drive(self):
        status, out, err = self.cli("--firstboot")
        self.assertEqual(status, 0, err)
        self.assertEqual(out, "")
        self.assertEqual(self.read(join(self.home, ".ssh", "authorized_keys")),
                         f"{ED}\n{RSA}\n")
        self.assertEqual(self.calls, [
            (["systemd-detect-virt", "--vm"], None),
            (["chpasswd", "-e"], f"root:{SHA256}\n".encode())])
        self.assertEqual(self.read(self.conf),
                         "export ROOT_PASS=KEEP\n"
                         "export FQDN='blog.example.org'\n")
        self.assertIn("keel-init asks", self.read(self.answer))
        # nothing asks the root password again, keel-init neither
        self.assertEqual(self.read(self.password).splitlines()[0], "4c2a6f")
        self.assertIn("cloud-init drive", self.read(self.password))
        self.assertEqual(self.read(self.state), "4c2a6f\nblog.example.org\n")
        self.assertNotIn(SHA256, err)
        self.assertIn("package_upgrade", err)

    def test_plain_password_no_key(self):
        self.write("user-data", "#cloud-config\npassword: s3cret\n"
                   "user: debian\n")
        status, _, err = self.cli("--firstboot")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.calls[1:], [(["chpasswd"], b"root:s3cret\n")])
        self.assertFalse(exists(self.answer))
        self.assertIn("user debian: no account is made", err)
        self.assertEqual(self.read(self.conf), "export ROOT_PASS=KEEP\n")

    def test_preseed_wins(self):
        with open(self.conf, "w") as fob:
            fob.write("export ROOT_PASS='x'\nexport HOSTNAME=web\n")
        status, _, err = self.cli("--firstboot")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.commands(), ["systemd-detect-virt"])
        self.assertIn("ROOT_PASS is preseeded", err)
        self.assertFalse(exists(self.password))
        self.assertIn("already preseeded or described", err)
        self.assertEqual(self.read(self.conf),
                         "export ROOT_PASS='x'\nexport HOSTNAME=web\n")

    def test_sudoadmin_sets_no_password(self):
        status, _, err = self.cli("--firstboot", "--sudoadmin")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.commands(), ["systemd-detect-virt"])
        self.assertIn("SUDOADMIN is on", err)
        self.assertFalse(exists(self.password))
        # root's keys, which 29sudoadmin copies to admin
        self.assertTrue(exists(join(self.home, ".ssh", "authorized_keys")))

    def test_chpasswd_fails(self):
        status, _, err = self.cli("--firstboot",
                                  answers={"chpasswd": done(1)})
        self.assertEqual(status, 1)
        self.assertIn("chpasswd failed for root", err)
        self.assertFalse(exists(self.password))
        self.assertFalse(exists(self.state))

    def test_applied_id_does_nothing(self):
        os.makedirs(dirname(self.state))
        with open(self.state, "w") as fob:
            fob.write("4c2a6f\n")
        status, _, err = self.cli("--firstboot")
        self.assertEqual(status, 0)
        self.assertIn("already applied", err)
        self.assertFalse(exists(self.conf))

    def test_nothing_to_do(self):
        container = join(self.dir, "container")
        open(container, "w").close()
        env = self.environ(CLOUD_DRIVE_CONTAINER=container)
        self.assertEqual(self.cli("--firstboot", environ=env), (0, "", ""))
        env = self.environ(_TURNKEY_INIT="1")
        self.assertEqual(self.cli("--firstboot", environ=env), (0, "", ""))
        self.assertFalse(exists(self.conf))

    def test_no_drive(self):
        status, out, err = self.cli(
            "--firstboot", unset=("CLOUD_DRIVE_ROOT",),
            answers={"blkid": done(2)})
        self.assertEqual((status, out, err), (0, "", ""))
        self.assertEqual(self.commands(),
                         ["systemd-detect-virt"] + ["blkid"] * 3)

    def test_not_a_qemu_vm_reads_nothing(self):
        # bare metal, or another hypervisor: a stick with the label is
        # not a Proxmox drive
        for answer in (done(1, b"none\n"), done(0, b"vmware\n")):
            self.calls = []
            status, out, err = self.cli(
                "--firstboot", unset=("CLOUD_DRIVE_ROOT",),
                answers={"systemd-detect-virt": answer,
                         "blkid": done(0, b"/dev/sr0\n")})
            self.assertEqual((status, out, err), (0, "", ""))
            self.assertEqual(self.commands(), ["systemd-detect-virt"])
        self.assertFalse(exists(self.conf))

    def test_usb_device_is_refused(self):
        status, _, err = self.cli(
            "--firstboot", unset=("CLOUD_DRIVE_ROOT",),
            answers={"blkid": done(0, b"/dev/sdb\n")})
        self.assertEqual(status, 1)
        self.assertIn("/dev/sdb is not read: a USB device", err)
        self.assertNotIn("mount", self.commands())

    def test_unknown_device_is_refused(self):
        status, _, err = self.cli(
            "--firstboot", unset=("CLOUD_DRIVE_ROOT",),
            answers={"blkid": done(0, b"/dev/sdz\n")})
        self.assertEqual(status, 1)
        self.assertIn("not a block device", err)

    def test_two_devices_are_refused(self):
        status, _, err = self.cli(
            "--firstboot", unset=("CLOUD_DRIVE_ROOT",),
            answers={"blkid": done(0, b"/dev/sr0\n/dev/sdb\n")})
        self.assertEqual(status, 1)
        self.assertIn("none is read", err)
        self.assertNotIn("mount", self.commands())

    def test_device_is_mounted_read_only(self):
        def run(cmd, data=None):
            self.calls.append((cmd, data))
            if cmd[0] == "systemd-detect-virt":
                return done(0, b"qemu\n")
            if cmd[0] == "blkid":
                return done(0, b"/dev/sr0\n") if "LABEL=cidata" in cmd \
                    else done(2)
            if cmd[0] == "mount":
                for name in ("user-data", "meta-data"):
                    with open(join(cmd[-1], name), "w") as fob:
                        fob.write(self.read(join(self.drive, name)))
            elif cmd[0] == "umount":
                for name in os.listdir(cmd[-1]):
                    os.remove(join(cmd[-1], name))
            return done()

        cli = load_cli()
        env = dict(self.environ())
        del env["CLOUD_DRIVE_ROOT"]
        with (
            mock.patch.dict(os.environ, env),
            mock.patch.object(cli, "run", run),
            mock.patch.object(cli.pwd, "getpwnam", self.account),
            mock.patch.object(cli.sys, "argv",
                              ["cloud-drive.py", "--firstboot"]),
            redirect_stderr(io.StringIO()) as err,
        ):
            cli.main()
        mount = next(c[0] for c in self.calls if c[0][0] == "mount")
        self.assertEqual(mount[1:6], ["-t", "iso9660,vfat", "-o",
                                      "ro,nosuid,nodev,noexec", "/dev/sr0"])
        self.assertIn(["umount", mount[-1]], [c[0] for c in self.calls])
        self.assertFalse(exists(mount[-1]))
        self.assertIn("reading the cloud-init drive /dev/sr0 (nocloud)",
                      err.getvalue())

    def test_mount_fails(self):
        status, _, err = self.cli(
            "--firstboot", unset=("CLOUD_DRIVE_ROOT",),
            answers={"blkid": done(0, b"/dev/sr0\n"),
                     "mount": done(32, err=b"wrong fs type")})
        self.assertEqual(status, 1)
        self.assertIn("cannot mount /dev/sr0: wrong fs type", err)

    def test_config_drive_kind(self):
        os.makedirs(join(self.drive, "openstack", "latest"))
        self.write("openstack/latest/meta_data.json", '{"uuid": "c2"}')
        env = self.environ(CLOUD_DRIVE_KIND="configdrive")
        status, _, err = self.cli("--firstboot", environ=env)
        self.assertEqual(status, 0, err)
        self.assertEqual(self.read(self.state), "c2\n\n")


class Clone(CliCase):
    def setUp(self):
        super().setUp()
        # the machine was born from a drive at its first boot
        self.recorded("0ld\nblog.example.org\n")

    def recorded(self, text):
        os.makedirs(dirname(self.state), exist_ok=True)
        with open(self.state, "w") as fob:
            fob.write(text)

    def test_new_name_prints_the_names(self):
        self.recorded("0ld\ndb.example.org\n")
        status, out, err = self.cli("--clone")
        self.assertEqual(status, 0, err)
        self.assertEqual(out, "HOSTNAME=blog\nFQDN=blog.example.org\n"
                         "INSTANCE_ID=4c2a6f\nNAME=blog.example.org\n")
        self.assertEqual(self.commands(), ["systemd-detect-virt"])
        self.assertFalse(exists(self.conf))
        self.assertEqual(self.read(self.state), "0ld\ndb.example.org\n")
        self.assertTrue(exists(join(self.home, ".ssh", "authorized_keys")))

    def test_same_name_keeps_the_name(self):
        # a new key changes the instance-id, not the name: a name the
        # operator gave since stays
        self.recorded("0ld\nblog.example.org\n")
        status, out, err = self.cli("--clone")
        self.assertEqual(status, 0, err)
        self.assertEqual(out, "HOSTNAME=\nFQDN=\nINSTANCE_ID=4c2a6f\n"
                         "NAME=blog.example.org\n")
        self.assertIn("keeps its name", err)

    def test_not_born_from_a_drive_reads_nothing(self):
        # bare metal, an ISO install, a VM first booted without a drive:
        # a drive that comes later gives no key
        os.remove(self.state)
        status, out, err = self.cli("--clone", unset=("CLOUD_DRIVE_ROOT",),
                                    answers={"blkid": done(0, b"/dev/sr0\n")})
        self.assertEqual((status, out, err), (0, "", ""))
        self.assertEqual(self.calls, [])
        self.assertFalse(exists(join(self.home, ".ssh")))

    def test_not_a_qemu_vm_reads_nothing(self):
        status, out, _ = self.cli(
            "--clone", answers={"systemd-detect-virt": done(1, b"none\n")})
        self.assertEqual((status, out), (0, ""))
        self.assertFalse(exists(join(self.home, ".ssh")))

    def test_usb_device_is_refused(self):
        status, _, err = self.cli("--clone", unset=("CLOUD_DRIVE_ROOT",),
                                  answers={"blkid": done(0, b"/dev/sdb\n")})
        self.assertEqual(status, 1)
        self.assertIn("a USB device", err)
        self.assertFalse(exists(join(self.home, ".ssh")))

    def test_sudoadmin_keys_go_to_admin(self):
        _, _, err = self.cli("--clone", "--sudoadmin")
        self.assertIn("for admin", err)

    def test_sudoadmin_without_admin(self):
        cli_account = self.account

        def no_admin(name):
            if name == "admin":
                raise KeyError(name)
            return cli_account(name)

        self.account = no_admin
        _, _, err = self.cli("--clone", "--sudoadmin")
        self.assertIn("for root", err)

    def test_unknown_user(self):
        cli_account = self.account
        self.account = lambda name: (_ for _ in ()).throw(KeyError(name))
        status, _, err = self.cli("--clone")
        self.account = cli_account
        self.assertEqual(status, 1)
        self.assertIn("error", err)


class RecordAndUsage(CliCase):
    def test_a_new_id_with_the_same_name_keeps_the_password_record(self):
        # a key added in Proxmox: the same machine, a new instance-id
        os.makedirs(dirname(self.state))
        with open(self.state, "w") as fob:
            fob.write("0ld\nblog\n")
        with open(self.password, "w") as fob:
            fob.write("0ld\nset from the drive\n")
        self.assertEqual(self.cli("--record-id=n3w", "--name=blog")[0], 0)
        self.assertEqual(self.read(self.password), "n3w\nset from the drive\n")

    def test_a_clone_does_not_carry_the_password_record(self):
        os.makedirs(dirname(self.state))
        with open(self.state, "w") as fob:
            fob.write("0ld\nblog\n")
        with open(self.password, "w") as fob:
            fob.write("0ld\nset from the drive\n")
        self.assertEqual(self.cli("--record-id=n3w", "--name=db")[0], 0)
        self.assertEqual(self.read(self.password), "0ld\nset from the drive\n")

    def test_record_id(self):
        self.assertEqual(self.cli("--record-id=9f1e")[0], 0)
        self.assertEqual(self.read(self.state), "9f1e\n\n")
        self.assertEqual(self.cli("--record-id=9f1e", "--name=db")[0], 0)
        self.assertEqual(self.read(self.state), "9f1e\ndb\n")
        status, _, err = self.cli("--record-id=a b")
        self.assertEqual(status, 1)
        self.assertIn("not an instance-id", err)
        status, _, err = self.cli("--record-id=a", "--name=x\ny")
        self.assertEqual(status, 1)
        self.assertIn("not a host name", err)

    def test_usage(self):
        for argv in [(), ("--bogus",), ("--clone", "extra"), ("-h",)]:
            status, _, err = self.cli(*argv)
            self.assertEqual(status, 1, argv)
            self.assertIn("Syntax:", err)


class RealRun(unittest.TestCase):
    def test_run_and_blkid(self):
        cli = load_cli()
        self.assertEqual(cli.run(["true"]).returncode, 0)
        with mock.patch.object(cli, "run", return_value=done(0, b"/dev/a\n")):
            self.assertEqual(cli.blkid("cidata"), ["/dev/a"])
        with mock.patch.object(cli, "run", return_value=done(2)):
            self.assertEqual(cli.blkid("cidata"), [])


if __name__ == "__main__":
    unittest.main()
