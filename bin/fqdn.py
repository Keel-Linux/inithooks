#!/usr/bin/python3
# Copyright (c) 2026 Keel Linux maintainers
"""Ask the machine's fully qualified domain name, and record it

Run by firstboot.d/31fqdn, three times: to ask, to record the answer in
the instance description, and, once the machine is renamed, to write the
/etc/hosts entry.

Options:
    --fqdn=         the name; if not provided, will ask interactively,
                    prefilled with --current (or the fqdn the instance
                    description declares)
    --current=      the name the machine has, as `hostname` answers
    --record        write the name given with --hostname and --fqdn into
                    the instance description, and ask nothing; a
                    description the name does not change is left alone
    --hosts         write the name given with --hostname and --fqdn into
                    the hosts file, and ask nothing
    --hostname=     with --record or --hosts: the hostname

Asked or preseeded, the answer is printed as two lines for the hook:
HOSTNAME=<the hostname> and FQDN=<the name, empty without a domain>. The
hostname is the first label of the name, or the one the description
declares beside that very name. Nothing is printed when the machine
keeps its name.

Environment:
    INITHOOKS_DECL  the instance description (default: the one
                    00declarative reads, else /etc/keel/instance.yaml)
    INITHOOKS_HOSTS the hosts file (default: /etc/hosts)
"""

import getopt
import os
import signal
import sys
from typing import NoReturn

from libinithooks import declarative, fqdn

HOSTS = "/etc/hosts"
HOSTS_VAR = "INITHOOKS_HOSTS"

TITLE = "Domain name"
TEXT = (
    "The name this machine is reached by, with its domain, for example"
    " blog.example.org. It becomes the hostname, the name /etc/hosts"
    " answers for this machine, and the domain a TLS certificate is"
    " requested for in confconsole.\n\n"
    "Leave the field empty to keep the name the machine has.\n\n"
    "Fully qualified domain name:"
)
NO_DOMAIN = (
    "{name} has no domain, so it is kept as the hostname only. No"
    " certificate can be requested without a domain.\n\n"
    "Continue with the hostname alone, or go back and add the domain?"
)


def fatal(msg: object) -> NoReturn:
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def usage(msg: str | getopt.GetoptError = "") -> NoReturn:
    if msg:
        print(f"Error: {msg}", file=sys.stderr)
    print(f"Syntax: {sys.argv[0]} [options]", file=sys.stderr)
    print(__doc__, file=sys.stderr)
    sys.exit(1)


def hosts_path() -> str:
    return os.environ.get(HOSTS_VAR, HOSTS)


def load_description() -> tuple[str, dict]:
    path = fqdn.spec_path()
    try:
        return path, fqdn.load(path)
    except declarative.DeclarativeError as e:
        fatal(e)


def ask(current: str, document: dict) -> str:
    """The name the operator confirmed, or "" to keep the machine's"""
    from libinithooks.dialog_wrapper import Dialog

    d = Dialog("Keel Linux - First boot configuration")
    init = fqdn.prefill(current, document)
    while True:
        _, typed = d.inputbox(TITLE, TEXT, init, "Apply", "")
        name, problem = fqdn.normalize(typed)
        if problem:
            d.error(problem)
            init = typed
            continue
        if not name or "." in name:
            return name
        if d.yesno(TITLE, NO_DOMAIN.format(name=name), "Continue", "Back"):
            return name
        init = name


def record(hostname: str, name: str) -> None:
    """The description with the name in it, unless it holds it already"""
    path, document = load_description()
    after = fqdn.updated(document, hostname, name)
    if after == document:
        print(f"fqdn: {path} already declares the name, not written",
              file=sys.stderr)
        return
    try:
        fqdn.write_spec(path, after)
    except fqdn.FqdnError as e:
        fatal(e)


def hosts(hostname: str, name: str) -> None:
    try:
        fqdn.write_hosts(hosts_path(), hostname, name)
    except fqdn.FqdnError as e:
        fatal(e)


def main():
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        l_opts = ["help", "fqdn=", "current=", "record", "hosts",
                  "hostname="]
        opts, args = getopt.gnu_getopt(sys.argv[1:], "h", l_opts)
    except getopt.GetoptError as e:
        usage(e)

    if args:
        usage()

    preseeded = current = hostname = ""
    action = ""
    for opt, val in opts:
        if opt in ("-h", "--help"):
            usage()
        elif opt == "--fqdn":
            preseeded = val
        elif opt == "--current":
            current = val
        elif opt == "--hostname":
            hostname = val
        else:  # --record or --hosts, the writes
            action = opt

    if action:
        if not hostname:
            usage(f"{action} needs --hostname")
        (record if action == "--record" else hosts)(hostname, preseeded)
        return

    _, document = load_description()
    if preseeded:
        name, problem = fqdn.normalize(preseeded)
        if problem:
            fatal(problem)
    else:
        name = ask(current, document)
    if not name:
        return
    print(f"HOSTNAME={fqdn.hostname_for(name, document)}")
    print(f"FQDN={fqdn.split(name)[1]}")


if __name__ == "__main__":
    main()
