#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Read the selected xtool SDK's real platform metadata."""

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

PLATFORMS = {
    "ios": ("iPhoneOS", "iphoneos"),
    "tvos": ("AppleTVOS", "appletvos"),
    "macos": ("MacOSX", "macosx"),
}


def sdk_version(root: Path, platform: str) -> tuple[str, str]:
    name, sdk = PLATFORMS[platform]
    directory = root / "Developer/Platforms" / f"{name}.platform/Developer/SDKs/{name}.sdk"
    metadata = directory / "SDKSettings.json"
    if metadata.is_file():
        settings = json.loads(metadata.read_text())
    else:
        metadata = directory / "SDKSettings.plist"
        with metadata.open("rb") as handle:
            settings = plistlib.load(handle)
    if not isinstance(settings, dict):
        raise ValueError(f"{metadata} must contain an SDK settings dictionary")
    version = settings.get("Version")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]{1,3}\.[0-9]{1,3}(\.[0-9]{1,3})?", version):
        raise ValueError(f"{metadata} does not declare a valid SDK Version")
    target = "iosmac" if platform == "macos" else sdk
    targets = settings.get("SupportedTargets", {})
    if not isinstance(targets, dict) or target not in targets:
        raise ValueError(f"{metadata} does not support the {target} target")
    return sdk, version


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-root", type=Path, required=True)
    parser.add_argument("--platform", choices=PLATFORMS, required=True)
    arguments = parser.parse_args()
    try:
        sdk, version = sdk_version(arguments.sdk_root, arguments.platform)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"error: cannot read selected Apple SDK metadata: {error}", file=sys.stderr)
        return 1
    print(sdk, version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
