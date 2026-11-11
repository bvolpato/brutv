#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""SDK guards use selected SDK metadata rather than deployment targets."""

import importlib.util
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("read_sdk_version", ROOT / "read-sdk-version.py")
reader = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reader)


class SDKRequirementsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def metadata(self, platform, value, *, plist=False):
        name, _ = reader.PLATFORMS[platform]
        path = self.root / "Developer/Platforms" / f"{name}.platform/Developer/SDKs/{name}.sdk" / ("SDKSettings.plist" if plist else "SDKSettings.json")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value) if plist else json.dumps(value).encode())
        return path

    def test_version_floor_rejects_old_and_invalid_sdk_versions(self):
        for version, passed in (("27.1", False), ("26.9", False), ("27.2", True), ("27.2.1", True), ("28.0", True), ("27.2-beta", False), ("", False)):
            with self.subTest(version=version):
                result = subprocess.run(["bash", "-c", 'source "$1"; brutv_require_sdk_version iphoneos "$2"',
                                         "sdk-test", str(ROOT / "apple-sdk.sh"), version], capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, passed, result.stderr)

    def test_actual_version_wins_over_deployment_settings(self):
        self.metadata("ios", {"Version": "27.1", "SupportedTargets": {"iphoneos": {}},
                              "DefaultProperties": {"IPHONEOS_DEPLOYMENT_TARGET": "99.0"}})
        self.assertEqual(reader.sdk_version(self.root, "ios"), ("iphoneos", "27.1"))

    def test_plist_fallback_and_platform_selection(self):
        self.metadata("tvos", {"Version": "27.2", "SupportedTargets": {"appletvos": {}}}, plist=True)
        self.metadata("ios", {"Version": "27.1", "SupportedTargets": {"iphoneos": {}}})
        self.assertEqual(reader.sdk_version(self.root, "tvos"), ("appletvos", "27.2"))

    def test_missing_version_and_catalyst_target_are_rejected(self):
        self.metadata("macos", {"Version": "27.2", "SupportedTargets": {"macosx": {}}})
        with self.assertRaisesRegex(ValueError, "iosmac"):
            reader.sdk_version(self.root, "macos")
        self.metadata("ios", {"SupportedTargets": {"iphoneos": {}}, "DefaultDeploymentTarget": "27.2"})
        with self.assertRaisesRegex(ValueError, "SDK Version"):
            reader.sdk_version(self.root, "ios")
        self.metadata("ios", {"Version": "27.2\n27.1", "SupportedTargets": {"iphoneos": {}}})
        with self.assertRaisesRegex(ValueError, "SDK Version"):
            reader.sdk_version(self.root, "ios")

    def test_prepare_only_does_not_require_an_installed_sdk(self):
        swift = self.root / "swift"
        swift.write_text('#!/bin/bash\nif [[ "$1" == --version ]]; then echo "Swift version 6.4.0"; else echo prepared; fi\n')
        swift.chmod(0o755)
        result = subprocess.run([str(ROOT / "linux-build.sh"), "--prepare-only", "--output", str(self.root / "prepared")],
                                env=os.environ | {"SWIFT_BINARY": str(swift), "XTOOL_BINARY": str(self.root / "missing-xtool")},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("prepared", result.stdout)


if __name__ == "__main__":
    unittest.main()
