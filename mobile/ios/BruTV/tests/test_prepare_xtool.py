#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Check generated Apple bundle metadata and Xcode source parity."""

import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / "swift-linux.sh"
PACKAGE = ROOT / "linux-tools"
SCRATCH = ROOT / "build/asset-compiler"


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(
            [
                str(SWIFT),
                "build",
                "--package-path",
                str(PACKAGE),
                "--scratch-path",
                str(SCRATCH),
                "--configuration",
                "release",
                "--jobs",
                "2",
                "--product",
                "prepare-xtool",
            ],
            check=True,
        )

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="brutv-preparation-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.output = self.directory / "prepared"
        self.output.mkdir()

    def prepare(self, platform, source=ROOT, **environment):
        return subprocess.run(
            [
                str(SWIFT),
                "run",
                "--skip-build",
                "--package-path",
                str(PACKAGE),
                "--scratch-path",
                str(SCRATCH),
                "--configuration",
                "release",
                "prepare-xtool",
                str(source),
                str(self.output),
                platform,
            ],
            env={**os.environ, **environment},
            text=True,
            capture_output=True,
            check=False,
        )

    def plist(self, name):
        with (self.output / name).open("rb") as handle:
            return plistlib.load(handle)

    def test_tvos_contains_matching_app_and_extension_metadata(self):
        result = self.prepare(
            "tvos",
            TVOS_BUNDLE_ID="com.example.tv",
            TVOS_TOPSHELF_BUNDLE_ID="com.example.tv.shelf",
            IOS_BUILD_NUMBER="42",
            IOS_MARKETING_VERSION="2.0.1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.plist("Info.plist")
        extension = self.plist("TopShelf-Info.plist")
        self.assertEqual(app["CFBundleIdentifier"], "com.example.tv")
        self.assertEqual(app["UIDeviceFamily"], [3])
        self.assertNotIn("UIBackgroundModes", app)
        self.assertEqual(
            app["CFBundleIcons"]["CFBundlePrimaryIcon"], "App Icon - Small"
        )
        self.assertEqual(
            app["TVTopShelfImage"]["TVTopShelfPrimaryImageWide"], "Top Shelf Image Wide"
        )
        self.assertEqual(extension["CFBundleIdentifier"], "com.example.tv.shelf")
        self.assertEqual(extension["UIDeviceFamily"], [3])
        self.assertEqual(
            extension["NSExtension"]["NSExtensionPrincipalClass"],
            "BruTVTopShelf.ContentProvider",
        )
        self.assertEqual(
            extension["NSExtension"]["NSExtensionPointIdentifier"],
            "com.apple.tv-top-shelf",
        )
        for info in (app, extension):
            self.assertEqual(info["CFBundleVersion"], "42")
            self.assertEqual(info["CFBundleShortVersionString"], "2.0.1")
            self.assertEqual(info["MinimumOSVersion"], "17.0")
        manifest = subprocess.run(
            [str(SWIFT), "package", "dump-package", "--package-path", str(self.output)],
            env={**os.environ, "BRUTV_XTOOL": "1", "BRUTV_XTOOL_PLATFORM": "tvos"},
            check=True,
            capture_output=True,
            text=True,
        )
        targets = {
            target["name"]: target for target in json.loads(manifest.stdout)["targets"]
        }
        self.assertIn(
            {"kind": {"define": {"_0": "TOPSHELF_EXTENSION"}}, "tool": "swift"},
            targets["BruTVTopShelf"]["settings"],
        )
        if sys.platform == "darwin":
            parsed = subprocess.run(
                ["xcrun", "assetutil", "--info", str(self.output / "Assets.car")],
                check=True,
                capture_output=True,
                text=True,
            )
            entries = json.loads(parsed.stdout)
            self.assertEqual(entries[0]["Platform"], "atv")
            names = {entry.get("Name") for entry in entries}
            self.assertTrue(
                {"App Icon - Small", "Top Shelf Image", "Top Shelf Image Wide"} <= names
            )

    def test_ios_retains_phone_and_tablet_icon_metadata(self):
        result = self.prepare("ios")
        self.assertEqual(result.returncode, 0, result.stderr)
        info = self.plist("Info.plist")
        self.assertEqual(info["UIDeviceFamily"], [1, 2])
        self.assertEqual(info["UIBackgroundModes"], ["audio"])
        self.assertNotIn("TVTopShelfImage", info)
        self.assertTrue(
            info["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconFiles"]
        )

    def test_missing_extension_source_is_rejected_before_packaging(self):
        source = self.directory / "source"
        source.mkdir()
        for name in ("BruTV", "BruTVTopShelf", "BruTV.xcodeproj"):
            shutil.copytree(ROOT / name, source / name)
        shutil.copy2(ROOT / "Package.swift", source / "Package.swift")
        (source / "BruTVTopShelf/ContentProvider.swift").unlink()
        result = self.prepare("tvos", source=source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SwiftPM/Xcode source mismatch", result.stderr)
        self.assertIn("ContentProvider.swift", result.stderr)


if __name__ == "__main__":
    unittest.main()
