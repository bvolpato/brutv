#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["qrcode[pil]>=7.4"]
# ///
"""Make a BruTV sign-in QR code.

Scanning the code with the iPhone or iPad Camera opens BruTV and signs in.
The code contains the password in plain text. Share it only with people you trust.

Examples:
  uv run tools/brutv-login-qr.py --server http://host:80 --username USER --password PASS
  uv run tools/brutv-login-qr.py --m3u "https://host/playlist.m3u" -o friend.png
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

import qrcode
from qrcode.constants import ERROR_CORRECT_M


def _escape(value: str) -> str:
    # Matches LoginLink.escape in the app: keep URL-safe chars, escape & = + ? #.
    return quote(value, safe="-._~!$'()*,;:@/")


def build_link(server: str | None, username: str | None, password: str | None, m3u: str | None) -> str:
    if m3u:
        parsed = urlparse(m3u)
        query = parse_qs(parsed.query)
        # Xtream get.php playlists sign in through the Xtream API, like the app does.
        if parsed.path.lower().endswith("get.php") and query.get("username") and query.get("password"):
            server = f"{parsed.scheme}://{parsed.netloc}"
            username, password = query["username"][0], query["password"][0]
        else:
            return f"brutv://login?m3u={_escape(m3u)}"

    if not (server and username and password):
        raise SystemExit("error: pass --server, --username, and --password, or --m3u")
    return f"brutv://login?server={_escape(server)}&username={_escape(username)}&password={_escape(password)}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--server", help="Xtream server, for example http://host:80")
    parser.add_argument("--username")
    parser.add_argument("--password")
    parser.add_argument("--m3u", help="M3U playlist URL")
    parser.add_argument("-o", "--output", default="brutv-login-qr.png", help="PNG path (default: %(default)s)")
    args = parser.parse_args()

    link = build_link(args.server, args.username, args.password, args.m3u)

    qr = qrcode.QRCode(error_correction=ERROR_CORRECT_M, box_size=12, border=4)
    qr.add_data(link)
    qr.make(fit=True)
    out = Path(args.output).expanduser()
    qr.make_image(fill_color="black", back_color="white").save(out)

    print(link)
    print(f"saved {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
