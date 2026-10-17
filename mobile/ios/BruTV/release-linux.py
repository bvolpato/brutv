#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Build all requested Apple packages before uploading any of them."""

from __future__ import annotations

import argparse
import os
import plistlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PLATFORMS = ("ios", "macos", "tvos")
OUTPUTS = {"ios": "BruTV.ipa", "macos": "BruTV.pkg", "tvos": "BruTV-tvOS.ipa"}
UPLOAD_PLATFORMS = {"ios": "IOS", "macos": "MAC_OS", "tvos": "TV_OS"}


def run(command: list[str], env: dict[str, str]) -> None:
    subprocess.run(command, env=env, check=True)


def signer(platform: str) -> list[str]:
    if platform == "macos":
        return ["uv", "run", str(ROOT / "sign-mac.py")]
    return ["uv", "run", str(ROOT / "sign-ipa.py"), "--platform", platform]


def mac_metadata(app: Path) -> list[str]:
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    arguments = []
    for option, key in (
        ("--bundle-id", "CFBundleIdentifier"),
        ("--bundle-version", "CFBundleVersion"),
        ("--short-version", "CFBundleShortVersionString"),
    ):
        value = info.get(key)
        if not isinstance(value, str) or not value or "$(" in value:
            raise ValueError(f"Mac app has invalid {key}")
        arguments.extend([option, value])
    return arguments


def release(args: argparse.Namespace) -> None:
    platforms = PLATFORMS if args.platform == "all" else (args.platform,)
    build = Path(os.environ.get("IOS_RELEASE_DIR", ROOT / "build/release")).resolve()
    export = build / "export"
    env = dict(os.environ)
    env.setdefault("SWIFT_BINARY", str(ROOT / "swift-linux.sh"))
    env.setdefault("XTOOL_BINARY", str(ROOT / "xtool-linux.sh"))

    # Validate every requested target before producing or uploading a release.
    for platform in platforms:
        run(
            [
                str(ROOT / "linux-build.sh"),
                "--platform",
                platform,
                "--configuration",
                "release",
                "--check",
            ],
            env,
        )
    for platform in platforms:
        run(signer(platform) + ["--preflight"], env)
    if args.upload:
        run(["uv", "run", str(ROOT / "upload-build.py"), "--preflight"], env)
    if args.preflight:
        print("All requested release prerequisites passed.")
        return

    artifacts: list[tuple[str, Path, list[str]]] = []
    for platform in platforms:
        destination = build / "linux" / platform
        run(
            [
                str(ROOT / "linux-build.sh"),
                "--platform",
                platform,
                "--configuration",
                "release",
                "--output",
                str(destination),
            ],
            env,
        )
        app = destination / "xtool/BruTV.app"
        output = export / OUTPUTS[platform]
        run(signer(platform) + ["--app", str(app), "--output", str(output)], env)
        if not output.is_file() or output.stat().st_size == 0:
            raise ValueError(f"Signer did not produce {output}")
        metadata = mac_metadata(app) if platform == "macos" else []
        run(
            [
                "uv",
                "run",
                str(ROOT / "upload-build.py"),
                str(output),
                "--platform",
                UPLOAD_PLATFORMS[platform],
                "--validate-only",
                *metadata,
            ],
            env,
        )
        artifacts.append((platform, output, metadata))

    if args.upload:
        for platform, output, metadata in artifacts:
            run(
                [
                    "uv",
                    "run",
                    str(ROOT / "upload-build.py"),
                    str(output),
                    "--platform",
                    UPLOAD_PLATFORMS[platform],
                    *metadata,
                ],
                env,
            )
        print("All requested builds were uploaded and processed by App Store Connect.")
    else:
        for platform, output, _ in artifacts:
            print(f"{platform}: {output}")
        print(
            "All requested packages were built and signed. Use --upload to deliver them."
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("all", *PLATFORMS), default="all")
    parser.add_argument(
        "--upload", action="store_true", help="upload and wait for Apple processing"
    )
    parser.add_argument(
        "--preflight", action="store_true", help="check prerequisites without building"
    )
    parser.add_argument(
        "--skip-simulator-build",
        action="store_true",
        help="accepted for Mac command compatibility; Linux uses device builds",
    )
    args = parser.parse_args()
    try:
        release(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: Linux release stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
