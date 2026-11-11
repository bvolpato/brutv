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
            upload=overrides.get("upload", True),
            preflight=False,
            skip_simulator_build=False,
            app=overrides.get("app"),
            testflight_group=overrides.get("testflight_group"),
            external_testflight_group=overrides.get("external_testflight_group"),
            whats_new=overrides.get("whats_new"),
            tester=overrides.get("tester", []),
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

    def test_native_app_is_signed_without_requiring_linux_sdk_or_rebuilding(self):
        app = self.directory / "Native.app"
        app.mkdir()
        with patch.object(release_linux, "run", side_effect=self.command):
            release_linux.release(self.options(platform="ios", app=app))
        self.assertFalse(any("linux-build.sh" in " ".join(call) for call in self.calls))
        signature = next(call for call in self.calls if "--app" in call)
        self.assertEqual(signature[signature.index("--app") + 1], str(app))
        self.assertEqual(len(self.uploads()), 1)

    def test_testflight_options_are_forwarded_only_to_delivery(self):
        with patch.object(release_linux, "run", side_effect=self.command):
            release_linux.release(
                self.options(
                    platform="ios",
                    testflight_group="Internal",
                    whats_new="Check playback.",
                    tester=["tester@example.com"],
                )
            )
        delivery = self.uploads()[0]
        self.assertEqual(delivery[delivery.index("--testflight-group") + 1], "Internal")
        self.assertEqual(delivery[delivery.index("--whats-new") + 1], "Check playback.")
        self.assertEqual(delivery[delivery.index("--tester") + 1], "tester@example.com")
        self.assertFalse(
            any(
                "--testflight-group" in call
                for call in self.calls
                if call is not delivery
            )
        )

    def test_testflight_without_upload_is_rejected_before_work(self):
        with (
            patch.object(release_linux, "run", side_effect=self.command),
            self.assertRaisesRegex(ValueError, "requires --upload"),
        ):
            release_linux.release(
                self.options(upload=False, testflight_group="Internal")
            )
        self.assertFalse(self.calls)

    def test_empty_notes_are_forwarded_to_clear_existing_testflight_notes(self):
        with patch.object(release_linux, "run", side_effect=self.command):
            release_linux.release(
                self.options(platform="ios", testflight_group="Internal", whats_new="")
            )
        delivery = self.uploads()[0]
        self.assertEqual(delivery[delivery.index("--whats-new") + 1], "")

    def test_native_app_cannot_be_reused_for_multiple_platforms(self):
        with (
            patch.object(release_linux, "run", side_effect=self.command),
            self.assertRaisesRegex(ValueError, "one selected platform"),
        ):
            release_linux.release(self.options(app=self.directory / "Native.app"))
        self.assertFalse(self.calls)

    def test_external_delivery_forwards_review_options_without_inviting_testers(self):
        with patch.object(release_linux, "run", side_effect=self.command):
            release_linux.release(
                self.options(
                    platform="ios",
                    external_testflight_group="Public Beta",
                    whats_new="Check adaptive navigation.",
                )
            )
        delivery = self.uploads()[0]
        self.assertEqual(
            delivery[delivery.index("--external-testflight-group") + 1], "Public Beta"
        )
        self.assertNotIn("--testflight-group", delivery)
        self.assertEqual(
            delivery[delivery.index("--whats-new") + 1], "Check adaptive navigation."
        )
        self.assertFalse(
            any(
                "--external-testflight-group" in call
                for call in self.calls
                if call is not delivery
            )
        )

    def test_external_tester_options_fail_before_building_or_uploading(self):
        with (
            patch.object(release_linux, "run", side_effect=self.command),
            self.assertRaisesRegex(ValueError, "only supported"),
        ):
            release_linux.release(
                self.options(
                    external_testflight_group="Public Beta",
                    tester=["tester@example.com"],
                )
            )
        self.assertFalse(self.calls)


if __name__ == "__main__":
    unittest.main()
