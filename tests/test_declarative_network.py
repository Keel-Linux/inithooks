# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""Network validation and rendering, IPv6 first"""

import unittest

from helpers import declarative, doc, env, errors


class TestNetwork(unittest.TestCase):
    def test_rejects_link_local_address(self):
        found = errors(
            "version: 1\n"
            "network:\n"
            "  managed_by: host\n"
            "  interfaces:\n"
            "    eth0:\n"
            "      ipv6:\n"
            "        method: static\n"
            "        address: fe80::10/64\n"
        )
        self.assertTrue(any("unicast" in error for error in found))

    def test_rejects_nameserver_that_is_not_an_address(self):
        found = errors(
            "version: 1\nnetwork:\n  nameservers:\n    - ns.example.org\n"
        )
        self.assertTrue(found)

    def test_ipv6_nameservers_are_left_out_of_the_ipv4_only_variables(self):
        exported = env(
            "version: 1\n"
            "network:\n"
            "  managed_by: file\n"
            "  nameservers:\n"
            "    - 2001:db8:1::53\n"
            "    - 192.0.2.53\n"
        )
        self.assertEqual(exported, {"IP_DNS1": "192.0.2.53"})

    def test_rendering_skips_a_nameserver_that_is_not_an_address(self):
        # render_env does not validate, so the address check must not raise
        rendered = declarative.render_env(
            doc(
                "version: 1\n"
                "network:\n"
                "  managed_by: file\n"
                "  nameservers: [ns.example.org]\n"
            ),
            {},
        )
        self.assertEqual(rendered, "")


class TestNetworkMapping(unittest.TestCase):
    def file_managed(self, ipv4: str, ipv6: str = "auto") -> dict:
        return env(
            "version: 1\n"
            "network:\n"
            "  managed_by: file\n"
            "  interfaces:\n"
            "    eth0:\n"
            "      ipv4:\n"
            f"        method: {ipv4}\n"
            "      ipv6:\n"
            f"        method: {ipv6}\n"
        )

    def test_ipv4_none_still_exports_the_ipv6_method(self):
        # an ipv6 block exports its variables from this version on
        # (inithooks#21): the hook reads IP6_* on its own
        self.assertEqual(
            self.file_managed("none"), {"IP6_CONFIG": "dhcp"}
        )

    def test_ipv4_none_ipv6_none_exports_nothing(self):
        self.assertEqual(self.file_managed("none", "none"), {})

    def test_ipv4_dhcp_exports_both_methods(self):
        self.assertEqual(
            self.file_managed("dhcp"),
            {"IP_CONFIG": "dhcp", "IP6_CONFIG": "dhcp"},
        )

    def test_ipv6_method_maps_to_what_the_hook_reads(self):
        # ifupdown has no SLAAC method of its own: auto is dhcp to the hook
        for declared, exported in (("auto", "dhcp"), ("dhcp", "dhcp"),
                                   ("manual", "manual")):
            with self.subTest(method=declared):
                self.assertEqual(
                    self.file_managed("none", declared),
                    {"IP6_CONFIG": exported},
                )

    def test_static_ipv6_exports_its_variables(self):
        exported = env(
            "version: 1\n"
            "network:\n"
            "  managed_by: file\n"
            "  interfaces:\n"
            "    eth0:\n"
            "      ipv6:\n"
            "        method: static\n"
            "        address: 2001:db8:1::10/64\n"
            "        gateway: fe80::1\n"
        )
        self.assertEqual(
            exported,
            {
                "IP6_CONFIG": "static",
                # the prefix length stays: an inet6 stanza has no netmask
                "IP6_ADDRESS": "2001:db8:1::10/64",
                "IP6_GW": "fe80::1",
            },
        )

    def test_static_ipv6_with_slaac_off_exports_the_flag(self):
        exported = env(
            "version: 1\n"
            "network:\n"
            "  managed_by: file\n"
            "  interfaces:\n"
            "    eth0:\n"
            "      ipv6:\n"
            "        method: static\n"
            "        address: 2001:db8:1::10/64\n"
            "        slaac: false\n"
        )
        self.assertEqual(exported["IP6_SLAAC"], "no")
        self.assertNotIn("IP6_GW", exported)

    def test_dual_static_exports_both_families(self):
        exported = env(
            "version: 1\n"
            "network:\n"
            "  managed_by: file\n"
            "  interfaces:\n"
            "    eth0:\n"
            "      ipv4:\n"
            "        method: static\n"
            "        address: 192.0.2.10/24\n"
            "        gateway: 192.0.2.1\n"
            "      ipv6:\n"
            "        method: static\n"
            "        address: 2001:db8:1::10/64\n"
            "        gateway: fe80::1\n"
        )
        self.assertEqual(
            exported,
            {
                "IP_CONFIG": "static",
                "IP_ADDRESS": "192.0.2.10",
                "IP_NETMASK": "255.255.255.0",
                "IP_GW": "192.0.2.1",
                "IP6_CONFIG": "static",
                "IP6_ADDRESS": "2001:db8:1::10/64",
                "IP6_GW": "fe80::1",
            },
        )

    def test_the_last_ipv6_block_wins_as_a_whole(self):
        exported = env(
            "version: 1\n"
            "network:\n"
            "  managed_by: file\n"
            "  interfaces:\n"
            "    eth0:\n"
            "      ipv6:\n"
            "        method: static\n"
            "        address: 2001:db8:1::10/64\n"
            "    eth1:\n"
            "      ipv6:\n"
            "        method: auto\n"
        )
        # a whole block replaces the earlier one: no address next to the
        # other interface's method
        self.assertEqual(exported, {"IP6_CONFIG": "dhcp"})

    def test_interface_without_families_exports_nothing(self):
        exported = env(
            "version: 1\nnetwork:\n  managed_by: file\n  interfaces:\n"
            "    eth0:\n"
        )
        self.assertEqual(exported, {})


class TestNameserverPlacement(unittest.TestCase):
    """The keel#45 rule, ported with the renderer (inithooks#21)"""

    def env_with(self, ipv4: str, ipv6: str, nameservers: str) -> dict:
        return env(
            "version: 1\n"
            "network:\n"
            "  managed_by: file\n"
            f"  nameservers: {nameservers}\n"
            "  interfaces:\n"
            "    eth0:\n"
            "      ipv4:\n"
            f"        method: {ipv4}\n"
            "        address: 192.0.2.10/24\n"
            "      ipv6:\n"
            f"        method: {ipv6}\n"
            "        address: 2001:db8:1::10/64\n"
        )

    def test_only_ipv6_static_carries_one_resolver_of_each_family(self):
        exported = self.env_with(
            "dhcp", "static",
            "[2001:db8:1::53, 192.0.2.53, 2001:db8:2::53]",
        )
        self.assertEqual(exported["IP6_DNS1"], "2001:db8:1::53")
        self.assertEqual(exported["IP6_DNS2"], "192.0.2.53")
        self.assertNotIn("IP_DNS1", exported)

    def test_only_ipv4_static_carries_one_resolver_of_each_family(self):
        exported = self.env_with(
            "static", "auto",
            "[2001:db8:1::53, 2001:db8:2::53, 192.0.2.53]",
        )
        self.assertEqual(exported["IP_DNS1"], "2001:db8:1::53")
        self.assertEqual(exported["IP_DNS2"], "192.0.2.53")
        self.assertNotIn("IP6_DNS1", exported)

    def test_both_static_split_the_servers_by_family(self):
        exported = self.env_with(
            "static", "static",
            "[192.0.2.53, 2001:db8:1::53, 192.0.2.54, 2001:db8:2::53]",
        )
        self.assertEqual(exported["IP_DNS1"], "192.0.2.53")
        self.assertEqual(exported["IP_DNS2"], "192.0.2.54")
        self.assertEqual(exported["IP6_DNS1"], "2001:db8:1::53")
        self.assertEqual(exported["IP6_DNS2"], "2001:db8:2::53")

    def test_neither_static_exports_each_family_to_its_own_variables(self):
        # the hook only writes dns-nameservers into a static stanza, so
        # these reach the conf but not the interfaces file; keel renders
        # the same variables (parity, inithooks#21)
        exported = self.env_with(
            "dhcp", "auto", "[192.0.2.53, 2001:db8:1::53]"
        )
        self.assertEqual(exported["IP_DNS1"], "192.0.2.53")
        self.assertEqual(exported["IP6_DNS1"], "2001:db8:1::53")


class TestNetworkErrors(unittest.TestCase):
    """Every mistake in the network section names the field"""

    def interface(self, body: str, managed_by: str = "host") -> str:
        return (
            "version: 1\n"
            "network:\n"
            f"  managed_by: {managed_by}\n"
            "  interfaces:\n"
            "    eth0:\n" + body
        )

    def assert_one_error(self, text: str, fragment: str) -> None:
        found = errors(text)
        matching = [error for error in found if fragment in error]
        self.assertEqual(
            len(matching), 1, f"expected one error with {fragment!r}: {found}"
        )

    def test_rejects_unknown_network_key(self):
        self.assert_one_error(
            "version: 1\nnetwork:\n  dns: []\n", "network.dns: unknown key"
        )

    def test_rejects_interfaces_that_are_not_a_mapping(self):
        self.assert_one_error(
            "version: 1\nnetwork:\n  interfaces: [eth0]\n",
            "network.interfaces: must be a mapping",
        )

    def test_rejects_interface_that_is_not_a_mapping(self):
        self.assert_one_error(
            "version: 1\nnetwork:\n  interfaces:\n    eth0: dhcp\n",
            "network.interfaces.eth0: must be a mapping",
        )

    def test_accepts_interface_without_any_family(self):
        self.assertEqual(
            errors("version: 1\nnetwork:\n  interfaces:\n    eth0:\n"), []
        )

    def test_rejects_unknown_family(self):
        self.assert_one_error(
            self.interface("      ipx:\n        method: auto\n"),
            "network.interfaces.eth0.ipx: unknown key",
        )

    def test_rejects_family_that_is_not_a_mapping(self):
        self.assert_one_error(
            self.interface("      ipv6: auto\n"),
            "network.interfaces.eth0.ipv6: must be a mapping",
        )

    def test_rejects_unknown_family_key(self):
        self.assert_one_error(
            self.interface(
                "      ipv6:\n        method: auto\n        mtu: 1280\n"
            ),
            "network.interfaces.eth0.ipv6.mtu: unknown key",
        )

    def test_accepts_slaac_beside_a_static_ipv6_address(self):
        """Keel-Linux/keel#45, the same rule as the instance tooling"""
        for value in ("true", "false"):
            with self.subTest(value=value):
                self.assertEqual(errors(self.interface(
                    "      ipv6:\n        method: static\n"
                    "        address: 2001:db8:1::10/64\n"
                    f"        slaac: {value}\n")), [])

    def test_rejects_slaac_with_another_method(self):
        for method in ("auto", "dhcp", "manual", "none"):
            with self.subTest(method=method):
                self.assert_one_error(
                    self.interface(f"      ipv6:\n        method: {method}\n"
                                   "        slaac: false\n"),
                    "network.interfaces.eth0.ipv6.slaac: only valid when"
                    " method is static",
                )

    def test_rejects_slaac_that_is_not_a_boolean(self):
        for value in ("0", "'false'", "sometimes"):
            with self.subTest(value=value):
                self.assert_one_error(
                    self.interface(
                        "      ipv6:\n        method: static\n"
                        "        address: 2001:db8:1::10/64\n"
                        f"        slaac: {value}\n"),
                    "network.interfaces.eth0.ipv6.slaac: must be true or"
                    " false",
                )

    def test_rejects_slaac_on_ipv4(self):
        self.assert_one_error(
            self.interface("      ipv4:\n        method: static\n"
                           "        address: 192.0.2.10/24\n"
                           "        slaac: false\n"),
            "network.interfaces.eth0.ipv4.slaac: unknown key",
        )

    def test_rejects_family_without_a_method(self):
        self.assert_one_error(
            self.interface("      ipv6:\n        gateway: fe80::1\n"),
            "network.interfaces.eth0.ipv6.method: must be one of",
        )

    def test_rejects_method_of_the_other_family(self):
        self.assert_one_error(
            self.interface("      ipv4:\n        method: auto\n"),
            "network.interfaces.eth0.ipv4.method: must be one of",
        )

    def test_rejects_static_method_without_an_address(self):
        self.assert_one_error(
            self.interface("      ipv6:\n        method: static\n"),
            "network.interfaces.eth0.ipv6.address: required when method"
            " is static",
        )

    def test_rejects_address_that_is_not_an_address(self):
        self.assert_one_error(
            self.interface(
                "      ipv6:\n        method: static\n"
                "        address: 2001:db8::zz/64\n"
            ),
            "network.interfaces.eth0.ipv6.address: ",
        )

    def test_rejects_address_of_the_other_family(self):
        self.assert_one_error(
            self.interface(
                "      ipv6:\n        method: static\n"
                "        address: 192.0.2.10/24\n"
            ),
            "network.interfaces.eth0.ipv6.address: not an IPv6 address",
        )

    def test_rejects_gateway_that_is_not_an_address(self):
        self.assert_one_error(
            self.interface(
                "      ipv6:\n        method: auto\n        gateway: router\n"
            ),
            "network.interfaces.eth0.ipv6.gateway: ",
        )

    def test_rejects_gateway_of_the_other_family(self):
        self.assert_one_error(
            self.interface(
                "      ipv4:\n        method: dhcp\n        gateway: fe80::1\n"
            ),
            "network.interfaces.eth0.ipv4.gateway: not an IPv4 address",
        )

    def test_accepts_dhcp_with_a_gateway_and_no_address(self):
        text = self.interface(
            "      ipv4:\n        method: dhcp\n        gateway: 192.0.2.1\n"
            "      ipv6:\n        method: auto\n        gateway: fe80::1\n",
            managed_by="file",
        )
        self.assertEqual(errors(text), [])

    def test_accepts_ipv4_static_with_a_link_local_ipv6_gateway(self):
        text = self.interface(
            "      ipv4:\n        method: static\n"
            "        address: 192.0.2.10/24\n"
            "      ipv6:\n        method: static\n"
            "        address: 2001:db8:1::10/64\n"
            "        gateway: fe80::1\n"
        )
        self.assertEqual(errors(text), [])


if __name__ == "__main__":
    unittest.main()
