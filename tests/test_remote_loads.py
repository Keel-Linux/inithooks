# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""tests/remote_loads.py: every way a page can fetch from another host

The script is loaded as a module and driven in process through its main()
so that coverage sees it. Each case is a page a browser would make fetch
something from another host on its own, before anybody clicks; each must be
reported. The cases that must not be reported are the ones the fence page
really carries: local resources, inline script, and links.
"""

import contextlib
import importlib.util
import io
import os
import tempfile
import unittest
from os.path import abspath, dirname, join

ROOT = dirname(dirname(abspath(__file__)))
SCRIPT = join(ROOT, "tests", "remote_loads.py")
PACKAGED = join(ROOT, "turnkey-init-fence", "htdocs", "index.html")

_spec = importlib.util.spec_from_file_location("remote_loads", SCRIPT)
remote_loads = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(remote_loads)

# every one of these makes a browser fetch from evil.example on load
HOSTILE = {
    "double quoted script": '<script src="https://evil.example/x.js"></script>',
    "single quoted script": "<script src='https://evil.example/x.js'></script>",
    "unquoted script": "<script src=https://evil.example/x.js></script>",
    "upper case": '<SCRIPT SRC="HTTPS://EVIL.EXAMPLE/X.JS"></SCRIPT>',
    "script with a body": '<script src="https://evil.example/x.js">var a;</script>',
    "protocol relative": '<script src="//evil.example/x.js"></script>',
    "backslashes": '<script src="\\\\evil.example/x.js"></script>',
    "slash backslash": '<script src="/\\evil.example/x.js"></script>',
    "scheme without slashes": '<script src="http:evil.example/x.js"></script>',
    "tab in the scheme": '<script src="ht\ttps://evil.example/x.js"></script>',
    "leading space": '<script src="  https://evil.example/x.js"></script>',
    "entity encoded": '<script src="https&#58;//evil.example/x.js"></script>',
    "stylesheet": '<link rel="stylesheet" href="https://evil.example/x.css">',
    "preload": '<link rel="preload" as="script" href="https://evil.example/x">',
    "icon": '<link rel="icon" href="//evil.example/favicon.ico">',
    "image": '<img src="https://evil.example/x.png">',
    "srcset": '<img src="/a.png" srcset="/a.png 1x, https://evil.example/b.png 2x">',
    "picture source": '<picture><source srcset="https://evil.example/x.webp"></picture>',
    "iframe": '<iframe src="https://evil.example/"></iframe>',
    "object": '<object data="https://evil.example/x.swf"></object>',
    "embed": '<embed src="https://evil.example/x">',
    "video poster": '<video poster="https://evil.example/p.png"></video>',
    "audio": '<audio src="https://evil.example/a.ogg"></audio>',
    "track": '<video><track src="https://evil.example/t.vtt"></video>',
    "input image": '<input type="image" src="https://evil.example/b.png">',
    "body background": '<body background="https://evil.example/bg.png">',
    "svg image": '<svg><image href="https://evil.example/x.svg"/></svg>',
    "svg xlink": '<svg><use xlink:href="https://evil.example/s.svg#a"/></svg>',
    "base": '<base href="https://evil.example/">',
    "meta refresh": '<meta http-equiv="refresh" content="0; url=https://evil.example/">',
    "style attribute": '<div style="background:url(https://evil.example/x.png)"></div>',
    "style element url": "<style>body { background: url('//evil.example/x.png') }</style>",
    "style element import": '<style>@import "https://evil.example/x.css";</style>',
    "style import url": "<style>@import url(https://evil.example/x.css);</style>",
    "font face": "<style>@font-face { src: url(https://evil.example/f.woff2) }</style>",
}

# none of these fetches from another host on its own
BENIGN = {
    "local script": '<script src="/local.js"></script>',
    "relative script": '<script src="local.js"></script>',
    "inline script": '<script>var u = "https://" + document.domain;</script>',
    "local stylesheet": '<link rel="stylesheet" href="/style.css">',
    "local image": '<img src="/turnkey-init-root.png">',
    "data image": '<img src="data:image/png;base64,AAAA">',
    "link": '<a href="https://www.debian.org">Debian</a>',
    "area": '<map><area href="https://www.debian.org"></map>',
    "form": '<form action="https://evil.example/"></form>',
    "text": "<p>https://example.com</p>",
    "local style url": '<div style="background:url(/bg.png)"></div>',
    "meta charset": '<meta charset="utf-8">',
    "meta refresh local": '<meta http-equiv="refresh" content="5">',
}


class Hostile(unittest.TestCase):
    def test_every_hostile_page_is_reported(self):
        for name, page in HOSTILE.items():
            with self.subTest(name=name):
                found = remote_loads.remote_loads(page)
                self.assertTrue(found, f"not reported: {page}")
                self.assertTrue(
                    any("evil.example" in url.lower() for url in found), found
                )

    def test_a_hostile_element_among_benign_ones_is_reported(self):
        page = "".join(BENIGN.values()) + HOSTILE["unquoted script"]
        self.assertEqual(remote_loads.remote_loads(page),
                         ["https://evil.example/x.js"])


class Benign(unittest.TestCase):
    def test_no_benign_page_is_reported(self):
        for name, page in BENIGN.items():
            with self.subTest(name=name):
                self.assertEqual(remote_loads.remote_loads(page), [])

    def test_the_packaged_page_loads_nothing_remote(self):
        with open(PACKAGED, encoding="utf-8") as fob:
            self.assertEqual(remote_loads.remote_loads(fob.read()), [])


class Main(unittest.TestCase):
    def run_main(self, *argv):
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = remote_loads.main(list(argv))
        return status, out.getvalue(), err.getvalue()

    def page(self, text):
        fd, path = tempfile.mkstemp(suffix=".html")
        with os.fdopen(fd, "w", encoding="utf-8") as fob:
            fob.write(text)
        self.addCleanup(os.remove, path)
        return path

    def test_a_clean_page_exits_0_and_prints_nothing(self):
        self.assertEqual(self.run_main(self.page(BENIGN["local script"])),
                         (0, "", ""))

    def test_a_remote_load_exits_1_and_prints_each_url(self):
        page = self.page(HOSTILE["image"] + HOSTILE["iframe"])
        self.assertEqual(
            self.run_main(page),
            (1, "https://evil.example/x.png\nhttps://evil.example/\n", ""))

    def test_an_unreadable_page_exits_2(self):
        status, out, err = self.run_main(join(ROOT, "no", "such", "page"))
        self.assertEqual((status, out), (2, ""))
        self.assertIn("remote_loads.py:", err)

    def test_undecodable_bytes_are_not_a_way_past_it(self):
        path = self.page("")
        with open(path, "wb") as fob:
            fob.write(b"\xff\xfe<script src=//evil.example/x.js></script>")
        status, out, _ = self.run_main(path)
        self.assertEqual((status, out), (1, "//evil.example/x.js\n"))

    def test_wrong_usage_exits_2(self):
        status, out, err = self.run_main()
        self.assertEqual((status, out), (2, ""))
        self.assertIn("usage", err)


if __name__ == "__main__":
    unittest.main()
