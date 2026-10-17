#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Select the configured xtool fork and keep native Swift available on Linux."""

import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(
    os.environ.get(
        "BRUTV_TOOLCHAIN_SCRIPT",
        Path(__file__).resolve().parents[1] / "linux-toolchain.sh",
    )
)


class LinuxToolchainTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls.log"
        self.tools = self.root / "tool cache"
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "PATH": f"{self.bin}:{os.environ['PATH']}",
                "TOOL_CALLS": str(self.calls),
                "BRUTV_TOOLS_DIR": str(self.tools),
                "BRUTV_BUILD_JOBS": "1",
            }
        )
        self.write_tool(
            "docker",
            """
            import os
            from pathlib import Path
            Path(os.environ["TOOL_CALLS"]).open("a").write("docker\\n")
            raise SystemExit(97)
            """,
        )

    def write_tool(self, name, body):
        executable = self.bin / name
        executable.write_text(f"#!{sys.executable}\n{textwrap.dedent(body).strip()}\n")
        executable.chmod(0o755)
        return executable

    def read_calls(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def install_swift_mock(self):
        self.write_tool(
            "swift",
            """
            import os
            import sys
            from pathlib import Path

            with Path(os.environ["TOOL_CALLS"]).open("a") as calls:
                calls.write("swift " + " ".join(sys.argv[1:]) + "\\n")
            if len(sys.argv) > 1 and sys.argv[1] == "build":
                package = Path(sys.argv[sys.argv.index("--package-path") + 1])
                executable = package / ".build/debug/xtool"
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_text(
                    "#!" + sys.executable + "\\n"
                    "import os, sys\\n"
                    "from pathlib import Path\\n"
                    "Path(os.environ['TOOL_CALLS']).open('a').write("
                    "'fork xtool ' + ' '.join(sys.argv[1:]) + '\\\\n')\\n"
                )
                executable.chmod(0o755)
            elif len(sys.argv) > 1 and sys.argv[1] == "--version":
                print("Swift version 6.4.0")
            """,
        )

    def test_configured_fork_takes_precedence_over_xtool_on_path(self):
        self.install_swift_mock()
        self.write_tool(
            "xtool",
            """
            import os
            import sys
            from pathlib import Path
            Path(os.environ["TOOL_CALLS"]).open("a").write(
                "generic xtool " + " ".join(sys.argv[1:]) + "\\n"
            )
            """,
        )
        checkout = self.root / "configured xtool fork"
        checkout.mkdir()
        (checkout / "Package.swift").write_text("// mock Swift package\n")
        self.environment["XTOOL_SOURCE_DIR"] = str(checkout)

        result = subprocess.run(
            [str(SCRIPT), "xtool", "sdk", "status"],
            env=self.environment,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.read_calls()
        self.assertTrue(any(call.startswith("swift build ") for call in calls), calls)
        self.assertTrue(
            any(f"--package-path {checkout}" in call for call in calls), calls
        )
        self.assertIn("fork xtool sdk status", calls)
        self.assertFalse(any(call.startswith("generic xtool") for call in calls), calls)
        self.assertFalse(any(call == "docker" for call in calls), calls)

    def test_invalid_configured_fork_does_not_fall_back_to_path_xtool(self):
        self.install_swift_mock()
        self.write_tool(
            "xtool",
            """
            import os
            import sys
            from pathlib import Path
            Path(os.environ["TOOL_CALLS"]).open("a").write("generic xtool\\n")
            """,
        )
        invalid_checkout = self.root / "incomplete fork"
        invalid_checkout.mkdir()
        self.environment["XTOOL_SOURCE_DIR"] = str(invalid_checkout)

        result = subprocess.run(
            [str(SCRIPT), "xtool", "sdk", "status"],
            env=self.environment,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("XTOOL_SOURCE_DIR does not contain Package.swift", result.stderr)
        self.assertEqual(self.read_calls(), [])

    def test_swift_uses_native_binary_without_requiring_xtool_on_path(self):
        self.install_swift_mock()
        self.environment["PATH"] = (
            f"{self.bin}:{os.path.dirname(sys.executable)}:/usr/bin:/bin"
        )
        self.environment["XTOOL_SOURCE_DIR"] = str(self.root / "missing fork")

        result = subprocess.run(
            [str(SCRIPT), "swift", "--version"],
            env=self.environment,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Swift version 6.4.0", result.stdout)
        self.assertIn("swift --version", self.read_calls())
        self.assertFalse(any(call.startswith("docker") for call in self.read_calls()))


if __name__ == "__main__":
    unittest.main()
