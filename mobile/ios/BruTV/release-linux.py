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
    if args.app is not None and len(platforms) != 1:
        raise ValueError("--app requires one selected platform")
    selected_group = args.testflight_group or args.external_testflight_group
    if selected_group and not args.upload:
        raise ValueError("TestFlight distribution requires --upload")
    if args.external_testflight_group and args.tester:
        raise ValueError("--tester is only supported with --testflight-group")
    if (args.tester or args.whats_new is not None) and not selected_group:
        raise ValueError("--tester and --whats-new require a TestFlight group")
    native_app = args.app.expanduser().resolve() if args.app is not None else None
    if native_app is not None and (
        native_app.suffix != ".app" or not native_app.is_dir()
    ):
        raise ValueError("--app must select an existing unsigned .app directory")
    build = Path(os.environ.get("IOS_RELEASE_DIR", ROOT / "build/release")).resolve()
    export = build / "export"
    env = dict(os.environ)
    env.setdefault("SWIFT_BINARY", str(ROOT / "swift-linux.sh"))
    env.setdefault("XTOOL_BINARY", str(ROOT / "xtool-linux.sh"))

    # Validate every requested target before producing or uploading a release.
    if native_app is None:
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
        if native_app is None:
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
        app = native_app or destination / "xtool/BruTV.app"
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
        testflight_arguments = []
        if selected_group:
            group_option = (
                "--external-testflight-group"
                if args.external_testflight_group
                else "--testflight-group"
            )
            testflight_arguments = [group_option, selected_group]
            if args.whats_new is not None:
                testflight_arguments.extend(["--whats-new", args.whats_new])
            for email in args.tester:
                testflight_arguments.extend(["--tester", email])
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
                    *testflight_arguments,
                ],
                env,
            )
        if selected_group:
            print(
                f"All requested builds are available to {selected_group} in TestFlight."
            )
        else:
            print(
                "All requested builds were uploaded and processed by App Store Connect."
            )
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
        "--app",
        type=Path,
        help="sign an existing native .app instead of compiling with xtool",
    )
    distribution = parser.add_mutually_exclusive_group()
    distribution.add_argument(
        "--testflight-group", help="release to an existing internal TestFlight group"
    )
    distribution.add_argument(
        "--external-testflight-group",
        help="submit beta review and release to an existing external TestFlight group",
    )
    parser.add_argument("--whats-new", help="TestFlight What to Test notes")
    parser.add_argument(
        "--tester",
        action="append",
        default=[],
        help="invite a tester by email (repeatable)",
    )
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
