#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Native release command contracts without Apple credentials or Xcode."""

import json
import os
import plistlib
import subprocess
import sys
import tempfile
import textwrap
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "release.sh"
TEAM = "TESTTEAM01"
BUNDLE = "com.bvolpato.brutv"
MOCK = r'''
import hashlib, json, os, plistlib, shlex, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
def argument(flag): return args[args.index(flag) + 1]
def record(value):
    with Path(os.environ['COMMANDS']).open('a') as stream: stream.write(json.dumps(value) + '\n')
if name == 'uname':
    print('Darwin'); raise SystemExit()
if name == 'sips':
    print('pixelWidth: 1024\npixelHeight: 1024\nhasAlpha: no'); raise SystemExit()
if name == 'xcrun':
    if '--show-sdk-version' in args:
        record({'action': 'sdk', 'sdk': argument('--sdk')})
        print(os.environ.get('MOCK_SDK_VERSION', '27.2'))
    raise SystemExit()
if name == 'security':
    if args[:2] == ['cms', '-D']:
        sys.stdout.buffer.write(Path(argument('-i')).read_bytes())
    elif args[0] == 'find-identity':
        certificate = Path(os.environ['CERTIFICATE_DER']).read_bytes() if os.environ.get('CERTIFICATE_DER') else b'test distribution certificate'
        fingerprint = hashlib.sha1(certificate).hexdigest().upper()
        print('1) ' + fingerprint + ' "Apple Distribution: Test (TESTTEAM01)"')
        print('2) EFGH "3rd Party Mac Developer Installer: Test (TESTTEAM01)"')
    elif args[0] == 'list-keychains' and '-s' not in args:
        print('"/tmp/test-login.keychain-db"')
    elif args[0] == 'import':
        assert '-P' not in args, 'P12 passwords must not be passed in process arguments'
        assert argument('-t') == 'agg' and argument('-f') == 'pemseq'
        pem = Path(args[1])
        assert b'PRIVATE KEY' in pem.read_bytes()
        assert pem.read_bytes().count(b'BEGIN CERTIFICATE') == 2, 'P12 certificate chain must be preserved'
        assert pem.stat().st_mode & 0o777 == 0o600
        assert pem.parent.stat().st_mode & 0o777 == 0o700
        record({'action': 'import', 'args': args})
    raise SystemExit()
if name == 'PlistBuddy':
    command, path = argument('-c'), Path(args[-1])
    parts = shlex.split(command)
    data = plistlib.loads(path.read_bytes())
    keys = parts[1].strip(':').split(':')
    cursor = data
    try:
        for key in keys[:-1]: cursor = cursor[int(key)] if isinstance(cursor, list) else cursor[key]
        key = int(keys[-1]) if isinstance(cursor, list) else keys[-1]
        if parts[0] == 'Print':
            value = cursor[key]
            if '-x' in args: sys.stdout.buffer.write(plistlib.dumps(value))
            elif isinstance(value, bool): print(str(value).lower())
            elif isinstance(value, list): print('Array {\n' + '\n'.join(map(str, value)) + '\n}')
            else: print(value)
        else:
            kind, value = parts[2], ' '.join(parts[3:])
            cursor[key] = {} if kind == 'dict' else (value == 'true' if kind == 'bool' else value)
            path.write_bytes(plistlib.dumps(data))
    except (KeyError, IndexError): raise SystemExit(1)
    raise SystemExit()
if name != 'xcodebuild': raise SystemExit(90)
assert '' not in args, 'empty array expansion produced an empty Xcode argument'
if '-showBuildSettings' in args:
    settings = dict(line.split(' = ', 1) for line in Path(argument('-xcconfig')).read_text().splitlines())
    target = argument('-target')
    profile = settings['BRUTV_PROFILE_' + target.replace('-', '_')]
    bundle = settings['BRUTV_BUNDLE_' + target.replace('-', '_')]
    if os.environ.get('BAD_MAPPING'): profile = 'incorrect-profile'
    record({'action': 'settings', 'target': target, 'profile': profile, 'bundle': bundle})
    print('    PROVISIONING_PROFILE_SPECIFIER = ' + profile)
    print('    PRODUCT_BUNDLE_IDENTIFIER = ' + bundle)
elif 'archive' in args:
    archive = Path(argument('-archivePath')); archive.mkdir(parents=True)
    record({'action': 'archive', 'platform': archive.parent.name, 'args': args})
elif '-exportArchive' in args:
    archive = Path(argument('-archivePath'))
    options = plistlib.loads(Path(argument('-exportOptionsPlist')).read_bytes())
    action = 'upload' if options.get('destination') == 'upload' else 'export'
    record({'action': action, 'platform': archive.parent.name, 'options': options})
    if os.environ.get('FAIL_EXPORT') == archive.parent.name: raise SystemExit(65)
    if action == 'export':
        output = Path(argument('-exportPath')); output.mkdir(parents=True, exist_ok=True)
        suffix = 'pkg' if archive.parent.name == 'macos' else 'ipa'
        (output / ('BruTV.' + suffix)).write_bytes(b'signed test package')
else:
    record({'action': 'simulator', 'args': args})
'''


@unittest.skipUnless(sys.platform.startswith("linux"), "Command mocks require Linux; macOS must validate real Xcode signing separately")
class NativeReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.jsonl"
        mock = self.bin / "mock"
        mock.write_text(f"#!{sys.executable}\n{textwrap.dedent(MOCK)}")
        mock.chmod(0o755)
        for name in ("uname", "security", "sips", "xcrun", "PlistBuddy", "xcodebuild"):
            (self.bin / name).symlink_to(mock)
        self.environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("IOS_", "TVOS_", "MACOS_", "BRUTV_"))
        }
        self.environment.update(
            PATH=f"{self.bin}:{os.environ['PATH']}",
            COMMANDS=str(self.log),
            IOS_RELEASE_DIR=str(self.root / "release"),
            BRUTV_PROVISIONING_PROFILE_DIR=str(self.root / "profiles"),
            PLIST_BUDDY=str(self.bin / "PlistBuddy"),
            IOS_TEAM_ID=TEAM,
            IOS_SIGNING="automatic",
        )

    def run_release(self, *arguments, **environment):
        return subprocess.run(
            ["bash", str(SCRIPT), "--skip-simulator-build", *arguments],
            env=self.environment | environment, capture_output=True, text=True,
        )

    def calls(self, action=None):
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return [call for call in calls if call["action"] == action] if action else calls

    def manual_profiles(self):
        self.environment["IOS_SIGNING"] = "manual"
        certificate = self.root / "certificate.p12"
        self.environment.update(IOS_CERTIFICATE_PATH=str(certificate), IOS_P12_PASSWORD="private-test-password")
        private_key, public_cert = self.root / "key.pem", self.root / "certificate.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
                        "-subj", f"/CN=Apple Distribution Test/OU={TEAM}", "-keyout", str(private_key),
                        "-out", str(public_cert)], check=True, capture_output=True)
        chain = self.root / "chain.pem"
        subprocess.run(["openssl", "req", "-x509", "-key", str(private_key), "-days", "30",
                        "-subj", "/CN=Fixture Root", "-out", str(chain)], check=True, capture_output=True)
        subprocess.run(["openssl", "pkcs12", "-export", "-in", str(public_cert), "-inkey", str(private_key),
                        "-certfile", str(chain),
                        "-out", str(certificate), "-passout", "env:IOS_P12_PASSWORD"],
                       env=self.environment, check=True, capture_output=True)
        encoded = subprocess.check_output(["openssl", "x509", "-in", str(public_cert), "-outform", "DER"])
        certificate_der = self.root / "certificate.der"
        certificate_der.write_bytes(encoded)
        self.environment["CERTIFICATE_DER"] = str(certificate_der)
        for index, (prefix, platform, bundle) in enumerate((
            ("IOS", "iOS", BUNDLE), ("MACOS", "OSX", BUNDLE),
            ("TVOS", "tvOS", BUNDLE), ("TVOS_TOPSHELF", "tvOS", BUNDLE + ".TopShelf"),
        ), start=1):
            profile = self.root / (prefix + ".mobileprovision")
            profile.write_bytes(plistlib.dumps({
                "UUID": f"00000000-0000-0000-0000-{index:012d}", "Name": prefix + " Store",
                "TeamIdentifier": [TEAM], "Platform": [platform],
                "ExpirationDate": datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=30),
                "DeveloperCertificates": [encoded],
                "Entitlements": {"application-identifier": TEAM + "." + bundle, "get-task-allow": False,
                                 "com.apple.security.application-groups": ["group.com.bvolpato.brutv"]},
            }))
            self.environment[prefix + "_PROVISIONING_PROFILE_PATH"] = str(profile)

    def test_subset_exports_only_requested_platform_and_accepts_generic_ipa_name(self):
        result = self.run_release("--platform", "tvos")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call["platform"] for call in self.calls("archive")], ["tvos"])
        self.assertIn("CODE_SIGNING_ALLOWED=YES", self.calls("archive")[0]["args"])
        self.assertEqual(len(list((self.root / "release").glob("run.*/tvos/export/BruTV.ipa"))), 1)
        self.assertEqual(self.calls("upload"), [])

    def test_all_exports_finish_before_first_upload(self):
        result = self.run_release("--upload")
        self.assertEqual(result.returncode, 0, result.stderr)
        actions = [call["action"] for call in self.calls()]
        self.assertGreater(actions.index("upload"), max(i for i, action in enumerate(actions) if action == "export"))
        self.assertEqual([call["platform"] for call in self.calls("upload")], ["ios", "macos", "tvos"])
        self.assertTrue(all(call["options"]["manageAppVersionAndBuildNumber"] is False for call in self.calls("export")))

    def test_failed_export_preserves_old_artifacts_and_prevents_every_upload(self):
        previous = self.root / "release" / "export" / "BruTV.ipa"
        previous.parent.mkdir(parents=True)
        previous.write_bytes(b"previous signed release")
        result = self.run_release("--upload", FAIL_EXPORT="macos")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(previous.read_bytes(), b"previous signed release")
        self.assertEqual(self.calls("upload"), [])

    def test_manual_tvos_maps_app_and_extension_to_distinct_profiles(self):
        self.manual_profiles()
        result = self.run_release("--platform", "tvos")
        self.assertEqual(result.returncode, 0, result.stderr)
        profiles = self.calls("export")[0]["options"]["provisioningProfiles"]
        self.assertEqual(profiles, {BUNDLE: "00000000-0000-0000-0000-000000000003",
                                    BUNDLE + ".TopShelf": "00000000-0000-0000-0000-000000000004"})
        settings = self.calls("settings")
        self.assertTrue(any(call["target"] == "BruTVTopShelf" and call["bundle"] == BUNDLE + ".TopShelf" for call in settings))
        self.assertFalse(any(arg.startswith("PRODUCT_BUNDLE_IDENTIFIER=") for arg in self.calls("archive")[0]["args"]))
        self.assertNotIn("private-test-password", result.stdout + result.stderr)
        self.assertTrue(self.calls("import"))
        self.assertNotIn("private-test-password", self.log.read_text())

    def test_missing_extension_profile_stops_all_builds(self):
        self.manual_profiles()
        self.environment.pop("TVOS_TOPSHELF_PROVISIONING_PROFILE_PATH")
        result = self.run_release("--platform", "all", "--upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TVOS_TOPSHELF", result.stderr)
        self.assertEqual(self.calls("archive"), [])
        self.assertEqual(self.calls("upload"), [])

    def test_wrong_platform_or_unresolved_mapping_stops_archive(self):
        self.manual_profiles()
        self.environment["TVOS_PROVISIONING_PROFILE_PATH"] = self.environment["IOS_PROVISIONING_PROFILE_PATH"]
        result = self.run_release("--platform", "tvos")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wrong platform", result.stderr)
        self.assertEqual(self.calls("archive"), [])
        self.environment["TVOS_PROVISIONING_PROFILE_PATH"] = str(self.root / "TVOS.mobileprovision")
        result = self.run_release("--platform", "tvos", BAD_MAPPING="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not resolve", result.stderr)
        self.assertEqual(self.calls("archive"), [])

    def test_preflight_checks_selected_target_without_build_or_upload(self):
        self.manual_profiles()
        result = self.run_release("--platform", "ios", "--preflight", "--upload")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(len(self.calls("settings")), 0)
        self.assertEqual(self.calls("archive"), [])
        self.assertEqual(self.calls("upload"), [])

    def test_preflight_rejects_expired_profile_and_unauthorized_certificate(self):
        self.manual_profiles()
        path = self.root / "IOS.mobileprovision"
        profile = plistlib.loads(path.read_bytes())
        profile["ExpirationDate"] = datetime(2020, 1, 1)
        path.write_bytes(plistlib.dumps(profile))
        result = self.run_release("--platform", "ios", "--preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expired", result.stderr)
        profile["ExpirationDate"] = datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=30)
        profile["DeveloperCertificates"] = [b"another same-team certificate"]
        path.write_bytes(plistlib.dumps(profile))
        result = self.run_release("--platform", "ios", "--preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not authorize an available", result.stderr)
        self.assertEqual(self.calls("archive"), [])

    def test_wrong_password_does_not_reach_import_or_expose_password(self):
        self.manual_profiles()
        result = self.run_release("--platform", "ios", IOS_P12_PASSWORD="wrong-private-password")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls("import"), [])
        self.assertEqual(self.calls("archive"), [])
        self.assertNotIn("wrong-private-password", result.stdout + result.stderr)
        self.assertFalse(list((self.root / "release").glob("run.*/signing")))

    def test_legacy_pkcs12_import_keeps_chain_without_password_argv(self):
        help_result = subprocess.run(["openssl", "pkcs12", "-help"], capture_output=True, text=True)
        if "-legacy" not in help_result.stdout + help_result.stderr:
            self.skipTest("This OpenSSL has no legacy provider option")
        self.manual_profiles()
        subprocess.run(["openssl", "pkcs12", "-export", "-legacy", "-in", str(self.root / "certificate.pem"),
                        "-inkey", str(self.root / "key.pem"), "-certfile", str(self.root / "chain.pem"),
                        "-out", self.environment["IOS_CERTIFICATE_PATH"], "-passout", "env:IOS_P12_PASSWORD"],
                       env=self.environment, check=True, capture_output=True)
        result = self.run_release("--platform", "ios", "--preflight")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("import")), 1)

    def test_explicit_empty_password_is_supported_but_missing_password_is_rejected(self):
        self.manual_profiles()
        self.environment["IOS_P12_PASSWORD"] = ""
        subprocess.run(["openssl", "pkcs12", "-export", "-in", str(self.root / "certificate.pem"),
                        "-inkey", str(self.root / "key.pem"), "-certfile", str(self.root / "chain.pem"),
                        "-out", self.environment["IOS_CERTIFICATE_PATH"], "-passout", "env:IOS_P12_PASSWORD"],
                       env=self.environment, check=True, capture_output=True)
        result = self.run_release("--platform", "ios", "--preflight")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("import")), 1)
        self.log.unlink()
        self.environment.pop("IOS_P12_PASSWORD")
        result = self.run_release("--platform", "ios", "--preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("IOS_P12_PASSWORD", result.stderr)
        self.assertEqual(self.calls("import"), [])

    def test_old_sdk_stops_release_before_signing_or_artifact_changes(self):
        result = self.run_release("--platform", "ios", "--preflight", MOCK_SDK_VERSION="27.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SDK 27.2 or later is required; selected SDK is 27.1", result.stderr)
        self.assertEqual(self.calls("import"), [])
        self.assertEqual(self.calls("archive"), [])
        self.assertFalse((self.root / "release").exists())

    def test_native_build_and_test_wrappers_reject_old_simulator_sdk(self):
        derived = self.root / "derived"
        derived.mkdir()
        for wrapper in ("build.sh", "test.sh"):
            with self.subTest(wrapper=wrapper):
                result = subprocess.run(["bash", str(SCRIPT.with_name(wrapper))], capture_output=True, text=True,
                                        env=self.environment | {"MOCK_SDK_VERSION": "27.1", "IOS_DERIVED_DATA_PATH": str(derived)})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("iphonesimulator SDK 27.2 or later is required", result.stderr)
        self.assertEqual(self.calls("simulator"), [])

    def test_native_catalyst_build_uses_macos_sdk_and_destination(self):
        derived = self.root / "derived"
        derived.mkdir()
        result = subprocess.run(["bash", str(SCRIPT.with_name("build.sh")), "macos"], capture_output=True, text=True,
                                env=self.environment | {"MACOS_DERIVED_DATA_PATH": str(derived)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("sdk"), [{"action": "sdk", "sdk": "macosx"}])
        self.assertIn("generic/platform=macOS,variant=Mac Catalyst", self.calls("simulator")[0]["args"])


if __name__ == "__main__":
    unittest.main()
