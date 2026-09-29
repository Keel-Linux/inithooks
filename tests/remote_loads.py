#!/usr/bin/python3
# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""Print every URL on another host that an HTML page fetches on its own

    remote_loads.py PAGE

Exit status: 0 the page fetches nothing from another host, 1 it does (each
URL printed on a line of its own), 2 the page could not be read.

"On its own" is what a browser does while it renders the page, before
anybody clicks: scripts, stylesheets and every other link element, images
and srcsets, frames, objects, media and their posters and tracks, a base
URL, a meta refresh, and url() and @import in style attributes and style
elements. A link (<a>, <area>) and a form action are somewhere the operator
may choose to go, and are not reported. Inline script is not parsed.

"Another host" is any URL with a scheme other than data, or with no scheme
and two leading slashes. A browser strips tabs and newlines from a URL and
reads a backslash as a slash, and so does this, so neither is a way past
it. When in doubt, a URL is reported.

It is a test instrument, not a defence: tests/test-tagid.bats asks it about
every page the fence serves. It is built on Python's HTMLParser, which does
not parse malformed markup the way a browser does (an abruptly closed
comment such as '<!-->' hides what follows from it, and not from a
browser), so it says what a well formed page loads, and the hook does not
rely on it: firstboot.d/29tagid serves the packaged page and nothing else.
"""

import re
import sys
from html.parser import HTMLParser

# attributes that make the element fetch, whatever the element is
FETCHING = {"src", "srcset", "poster", "data", "background", "lowsrc"}
# href fetches on every element but these, which navigate on a click
NAVIGATING = {"a", "area"}
# a scheme that does not reach a host
LOCAL_SCHEMES = {"data", "about", "blob", "javascript"}

CSS_URL = re.compile(r"""url\(\s*(['"]?)(.*?)\1\s*\)""", re.I | re.S)
CSS_IMPORT = re.compile(r"""@import\s+(['"])(.*?)\1""", re.I | re.S)
REFRESH_URL = re.compile(r"""^\s*\d*\s*[;,]?\s*url\s*=\s*['"]?([^'"]*)""",
                         re.I)
SCHEME = re.compile(r"^([a-z][a-z0-9+.-]*):", re.I)


def is_remote(url: str) -> bool:
    """Whether a browser would reach another host for URL"""
    url = re.sub(r"[\t\n\r]", "", url).strip().replace("\\", "/")
    if url.startswith("//"):
        return True
    match = SCHEME.match(url)
    return bool(match) and match.group(1).lower() not in LOCAL_SCHEMES


def srcset_urls(value: str) -> list:
    """The URLs of a srcset: each candidate is a URL and a descriptor"""
    return [part.split()[0] for part in value.split(",") if part.split()]


def css_urls(text: str) -> list:
    """The URLs a stylesheet or a style attribute fetches"""
    return ([m.group(2) for m in CSS_URL.finditer(text)]
            + [m.group(2) for m in CSS_IMPORT.finditer(text)])


class _Finder(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.found = []
        self._in_style = False

    def _check(self, urls):
        self.found.extend(url for url in urls if is_remote(url))

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        values = {}
        for name, value in attrs:
            values[name.lower()] = value or ""
        for name, value in values.items():
            if name in FETCHING:
                self._check(srcset_urls(value) if name == "srcset"
                            else [value])
            elif name in ("href", "xlink:href") and tag not in NAVIGATING:
                self._check([value])
            elif name == "style":
                self._check(css_urls(value))
        if tag == "meta" and values.get("http-equiv", "").lower() == "refresh":
            match = REFRESH_URL.match(values.get("content", ""))
            if match:
                self._check([match.group(1)])
        if tag == "style":
            self._in_style = True

    handle_startendtag = handle_starttag

    def handle_endtag(self, tag):
        if tag.lower() == "style":
            self._in_style = False

    def handle_data(self, data):
        if self._in_style:
            self._check(css_urls(data))


def remote_loads(page: str) -> list:
    """Every URL on another host PAGE fetches on its own, in page order"""
    finder = _Finder()
    finder.feed(page)
    finder.close()
    return [url.strip() for url in finder.found]


def main(argv: list) -> int:
    if len(argv) != 1:
        print("usage: remote_loads.py PAGE", file=sys.stderr)
        return 2
    try:
        with open(argv[0], "rb") as fob:
            page = fob.read().decode("utf-8", errors="replace")
    except OSError as exc:
        print(f"remote_loads.py: {exc}", file=sys.stderr)
        return 2
    found = remote_loads(page)
    for url in found:
        print(url)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
