#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Catalyst preflight must reject an unusable linker before building."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

BUILD = Path(__file__).resolve().parents[1] / "linux-build.sh"


class LinkerPreflightTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.sdk = self.root / "sdk"
        self.swift = self.executable("swift", 'echo "Swift version 6.4.0"')
        self.xtool = self.executable(
            "xtool",
            'if [[ "$*" == "dev build --print-supported-platforms" ]]; then\n'
            '  echo "iOS macCatalyst"\n'
            "else\n"
            '  printf "Darwin SDK is installed\\n  Path: %s\\n" "$TEST_SDK"\n'
            "fi",
        )

    def executable(self, name, body):
        executable = self.root / name
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        executable.chmod(0o755)
        return executable

    def preflight(self, override=None):
        environment = dict(os.environ)
        environment.pop("XTOOL_LD64_LLD", None)
        environment.update(
            SWIFT_BINARY=str(self.swift),
            XTOOL_BINARY=str(self.xtool),
            TEST_SDK=str(self.sdk),
            DSYMUTIL="/usr/bin/true",
            RCODESIGN="/usr/bin/true",
            BRUTV_LLVM_TOOLS_DIR=str(self.root / "private-llvm"),
        )
        if override is not None:
            environment["XTOOL_LD64_LLD"] = str(override)
        return subprocess.run(
            [
                str(BUILD),
                "--platform",
                "macos",
                "--configuration",
                "release",
                "--check",
            ],
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_missing_linker_stops_preflight(self):
        result = self.preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("linker", result.stderr)

    def test_old_sdk_linker_stops_preflight(self):
        self.executable("sdk/toolset/bin/ld64.lld", 'echo "LLD 22.1.0"')
        result = self.preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LLD 23", result.stderr)

    def test_current_sdk_linker_passes_preflight(self):
        self.executable("sdk/toolset/bin/ld64.lld", 'echo "LLD 23.1.3"')
        result = self.preflight()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_override_does_not_fall_back_to_valid_sdk_linker(self):
        self.executable("sdk/toolset/bin/ld64.lld", 'echo "LLD 23.1.3"')
        result = self.preflight(self.root / "missing-linker")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("linker", result.stderr)

    def test_private_linker_takes_precedence_over_old_sdk_linker(self):
        self.executable("sdk/toolset/bin/ld64.lld", 'echo "LLD 22.1.0"')
        self.executable("private-llvm/bin/ld64.lld", 'echo "LLD 23.1.3"')
        result = self.preflight()
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
