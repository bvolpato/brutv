#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Release ordering prevents incomplete platform sets from being uploaded."""

import argparse
import importlib.util
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "release_linux", Path(__file__).resolve().parents[1] / "release-linux.py"
)
release_linux = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_linux)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.calls = []
        self.environment = patch.dict(
            os.environ, {"IOS_RELEASE_DIR": str(self.directory)}
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def command(self, arguments, env):
        self.calls.append(arguments)
        if "--output" in arguments:
            output = Path(arguments[arguments.index("--output") + 1])
            if output.suffix in (".ipa", ".pkg"):
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(b"signed fixture")
            else:
                info = output / "xtool/BruTV.app/Contents/Info.plist"
                info.parent.mkdir(parents=True, exist_ok=True)
                info.write_bytes(
                    plistlib.dumps(
                        {
                            "CFBundleIdentifier": "com.bvolpato.brutv",
                            "CFBundleVersion": "15",
                            "CFBundleShortVersionString": "1.0.1",
                        }
                    )
                )

    def options(self, **overrides):
        return argparse.Namespace(
            platform=overrides.get("platform", "all"),
            upload=True,
            preflight=False,
            skip_simulator_build=False,
        )

    def uploads(self):
        return [
            call
            for call in self.calls
            if "upload-build.py" in " ".join(call)
            and "--validate-only" not in call
            and "--preflight" not in call
        ]

    def test_all_packages_are_signed_before_any_upload(self):
        with patch.object(release_linux, "run", side_effect=self.command):
            release_linux.release(self.options())
        uploads = self.uploads()
        self.assertEqual(len(uploads), 3)
        last_signature = max(
            index for index, call in enumerate(self.calls) if "--app" in call
        )
        self.assertTrue(
            all(self.calls.index(call) > last_signature for call in uploads)
        )
        self.assertEqual(
            [call[call.index("--platform") + 1] for call in uploads],
            ["IOS", "MAC_OS", "TV_OS"],
        )

    def test_unsupported_requested_platform_prevents_build_and_upload(self):
        def command(arguments, env):
            self.calls.append(arguments)
            if "macos" in arguments and "--check" in arguments:
                raise subprocess.CalledProcessError(1, arguments)

        with (
            patch.object(release_linux, "run", side_effect=command),
            self.assertRaises(subprocess.CalledProcessError),
        ):
            release_linux.release(self.options())
        self.assertFalse(any("--output" in call for call in self.calls))
        self.assertFalse(self.uploads())

    def test_later_signing_failure_does_not_upload_earlier_ipa(self):
        def command(arguments, env):
            self.command(arguments, env)
            if "--app" in arguments and "sign-mac.py" in " ".join(arguments):
                raise subprocess.CalledProcessError(1, arguments)

        with (
            patch.object(release_linux, "run", side_effect=command),
            self.assertRaises(subprocess.CalledProcessError),
        ):
            release_linux.release(self.options())
        self.assertFalse(self.uploads())


if __name__ == "__main__":
    unittest.main()
