#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["cryptography>=44,<47"]
# ///
"""Exercise Catalyst release guards and real Linux installer tools."""

import contextlib
import gzip
import importlib.util
import io
import os
import plistlib
import struct
import subprocess
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs7, pkcs12
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID, ObjectIdentifier

spec = importlib.util.spec_from_file_location(
    "sign_mac", Path(__file__).parents[1] / "sign-mac.py"
)
sign_mac = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sign_mac)
TEAM = "TESTTEAM01"
BUNDLE_ID = "com.bvolpato.brutv"


def certificate(
    kind,
    issuer=None,
    issuer_key=None,
    *,
    installer_eku="1.2.840.113635.100.4.9",
    installer_marker="1.2.840.113635.100.6.1.8",
    marker_critical=True,
    extra_critical=None,
):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name(
        [
            x509.NameAttribute(NameOID.COMMON_NAME, kind),
            x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, TEAM),
        ]
    )
    now = datetime.now(UTC)
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer.subject if issuer else subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=30))
    )
    if kind in {"root", "profile-issuer"}:
        builder = builder.add_extension(
            x509.BasicConstraints(ca=True, path_length=None), critical=True
        )
        if kind == "profile-issuer":
            builder = builder.add_extension(
                x509.UnrecognizedExtension(
                    ObjectIdentifier("1.2.840.113635.100.6.2.1"), b"\x05\x00"
                ),
                critical=False,
            )
    elif kind == "profile-signer":
        builder = builder.add_extension(
            x509.BasicConstraints(ca=False, path_length=None), critical=True
        )
        builder = builder.add_extension(
            x509.KeyUsage(True, False, False, False, False, False, False, False, False),
            critical=True,
        )
        builder = builder.add_extension(
            x509.UnrecognizedExtension(
                ObjectIdentifier("1.2.840.113635.100.4.11"), b"\x05\x00"
            ),
            critical=False,
        )
    elif kind == "application":
        builder = builder.add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CODE_SIGNING]), critical=True
        )
        for oid in ("1.2.840.113635.100.6.1.7", "1.2.840.113635.100.6.1.4"):
            builder = builder.add_extension(
                x509.UnrecognizedExtension(ObjectIdentifier(oid), b"\x05\x00"),
                critical=marker_critical,
            )
    elif kind == "installer":
        builder = builder.add_extension(
            x509.ExtendedKeyUsage([ObjectIdentifier(installer_eku)]),
            critical=True,
        )
        if installer_marker is not None:
            builder = builder.add_extension(
                x509.UnrecognizedExtension(
                    ObjectIdentifier(installer_marker), b"\x05\x00"
                ),
                critical=marker_critical,
            )
    if extra_critical is not None:
        builder = builder.add_extension(extra_critical, critical=True)
    return key, builder.sign(issuer_key or key, hashes.SHA256())


class MacReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root_key, self.root = certificate("root")
        self.app_key, self.app_cert = certificate(
            "application", self.root, self.root_key
        )
        self.installer_key, self.installer_cert = certificate(
            "installer", self.root, self.root_key
        )
        self.profile_issuer_key, self.profile_issuer = certificate(
            "profile-issuer", self.root, self.root_key
        )
        self.profile_signer_key, self.profile_signer = certificate(
            "profile-signer", self.profile_issuer, self.profile_issuer_key
        )
        self.profile = {
            "Platform": ["OSX"],
            "TeamIdentifier": [TEAM],
            "ApplicationIdentifierPrefix": [TEAM],
            "ExpirationDate": datetime.now(UTC).replace(tzinfo=None)
            + timedelta(days=5),
            "DeveloperCertificates": [
                self.app_cert.public_bytes(serialization.Encoding.DER)
            ],
            "Entitlements": {
                "com.apple.application-identifier": f"{TEAM}.{BUNDLE_ID}",
                "com.apple.developer.team-identifier": TEAM,
            },
        }
        self.requested = {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.network.client": True,
        }

    def entitlements(self):
        return sign_mac.distribution_entitlements(
            self.profile, self.app_cert, TEAM, BUNDLE_ID, self.requested
        )

    def signed_profile_bytes(self):
        return (
            pkcs7.PKCS7SignatureBuilder()
            .set_data(plistlib.dumps(self.profile))
            .add_signer(self.profile_signer, self.profile_signer_key, hashes.SHA256())
            .add_certificate(self.profile_issuer)
            .add_certificate(self.root)
            .sign(serialization.Encoding.DER, [pkcs7.PKCS7Options.Binary])
        )

    def test_distribution_entitlements(self):
        self.assertEqual(
            self.entitlements(),
            self.requested
            | {
                "com.apple.application-identifier": f"{TEAM}.{BUNDLE_ID}",
                "application-identifier": f"{TEAM}.{BUNDLE_ID}",
                "com.apple.developer.team-identifier": TEAM,
            },
        )

    def test_keychain_allowlist_wildcard_requires_concrete_authorized_groups(self):
        self.profile["Entitlements"]["keychain-access-groups"] = [f"{TEAM}.*"]
        self.requested["keychain-access-groups"] = [f"{TEAM}.{BUNDLE_ID}"]
        self.assertEqual(
            self.entitlements()["keychain-access-groups"], [f"{TEAM}.{BUNDLE_ID}"]
        )
        for group in (f"{TEAM}.*", f"WRONGTEAM.{BUNDLE_ID}"):
            with (
                self.subTest(group=group),
                patch.dict(self.requested, {"keychain-access-groups": [group]}),
                self.assertRaises(sign_mac.ReleaseError),
            ):
                self.entitlements()
        del self.requested["keychain-access-groups"]
        self.assertNotIn("keychain-access-groups", self.entitlements())

    def test_conflicting_identifier_aliases_are_rejected(self):
        for key in ("application-identifier", "com.apple.application-identifier"):
            with (
                self.subTest(key=key),
                patch.dict(self.requested, {key: f"{TEAM}.other-app"}),
                self.assertRaisesRegex(sign_mac.ReleaseError, "identifier"),
            ):
                self.entitlements()
        with (
            patch.dict(
                self.profile["Entitlements"],
                {"application-identifier": f"{TEAM}.other-app"},
            ),
            self.assertRaisesRegex(sign_mac.ReleaseError, "identifier"),
        ):
            self.entitlements()

    def test_non_developer_entitlement_requires_profile_permission(self):
        self.requested["aps-environment"] = "production"
        with self.assertRaisesRegex(sign_mac.ReleaseError, "does not authorize"):
            self.entitlements()
        self.profile["Entitlements"]["aps-environment"] = "production"
        self.assertEqual(self.entitlements()["aps-environment"], "production")

    def test_profile_rejects_development_wrong_platform_and_certificate(self):
        for key, value in (
            ("ProvisionedDevices", ["device"]),
            ("Platform", ["iOS"]),
            ("DeveloperCertificates", []),
            ("TeamIdentifier", ["WRONGTEAM"]),
        ):
            with (
                self.subTest(key=key),
                patch.dict(self.profile, {key: value}),
                self.assertRaises(sign_mac.ReleaseError),
            ):
                self.entitlements()
        for key in ("get-task-allow", "com.apple.security.get-task-allow"):
            with (
                self.subTest(key=key),
                patch.dict(self.profile["Entitlements"], {key: True}),
                self.assertRaisesRegex(sign_mac.ReleaseError, "debugger"),
            ):
                self.entitlements()

    def test_profile_rejects_wildcard_and_unauthorized_capability(self):
        with (
            patch.dict(
                self.profile["Entitlements"],
                {"com.apple.application-identifier": f"{TEAM}.*"},
            ),
            self.assertRaisesRegex(sign_mac.ReleaseError, "explicitly match"),
        ):
            self.entitlements()
        self.requested["com.apple.developer.icloud-container-identifiers"] = [
            "icloud.test"
        ]
        with self.assertRaisesRegex(
            sign_mac.ReleaseError, "does not authorize entitlement"
        ):
            self.entitlements()

    def test_certificate_type_and_password_guards(self):
        path = self.directory / "identity.p12"
        path.write_bytes(
            pkcs12.serialize_key_and_certificates(
                b"fixture",
                self.app_key,
                self.app_cert,
                [self.root],
                serialization.BestAvailableEncryption(b"secret"),
            )
        )
        with (
            patch.dict(os.environ, {"MACOS_INSTALLER_P12_PASSWORD": "secret"}),
            self.assertRaisesRegex(sign_mac.ReleaseError, "Mac Installer Distribution"),
        ):
            sign_mac.load_identity(
                path, "MACOS_INSTALLER_P12_PASSWORD", "installer", self.directory
            )

    def test_installer_submission_certificate_role(self):
        for label, eku, marker, accepted in (
            ("submission", "1.2.840.113635.100.4.9", "1.2.840.113635.100.6.1.8", True),
            ("store", "1.2.840.113635.100.4.10", "1.2.840.113635.100.6.1.10", False),
            (
                "developer-id",
                "1.2.840.113635.100.4.13",
                "1.2.840.113635.100.6.1.14",
                False,
            ),
            ("missing-marker", "1.2.840.113635.100.4.9", None, False),
        ):
            with self.subTest(role=label):
                key, cert = certificate(
                    "installer",
                    self.root,
                    self.root_key,
                    installer_eku=eku,
                    installer_marker=marker,
                )
                directory = self.directory / label
                directory.mkdir()
                path = directory / "identity.p12"
                path.write_bytes(
                    pkcs12.serialize_key_and_certificates(
                        b"fixture",
                        key,
                        cert,
                        [self.root],
                        serialization.BestAvailableEncryption(b"secret"),
                    )
                )
                with patch.dict(os.environ, {"MACOS_INSTALLER_P12_PASSWORD": "secret"}):
                    if accepted:
                        loaded, team, pem = sign_mac.load_identity(
                            path, "MACOS_INSTALLER_P12_PASSWORD", "installer", directory
                        )
                        self.assertEqual(loaded.serial_number, cert.serial_number)
                        self.assertEqual(team, TEAM)
                        self.assertEqual(pem.stat().st_mode & 0o777, 0o600)
                    else:
                        with self.assertRaisesRegex(
                            sign_mac.ReleaseError, "Mac Installer Distribution"
                        ):
                            sign_mac.load_identity(
                                path,
                                "MACOS_INSTALLER_P12_PASSWORD",
                                "installer",
                                directory,
                            )

    def test_code_cms_rejects_unsupported_critical_extensions(self):
        marker = "1.2.840.113635.100.6.1.8"
        for label, target, oid, value in (
            ("leaf", "leaf", "1.2.3.4", b"\x05\x00"),
            ("issuer", "issuer", "1.2.3.4", b"\x05\x00"),
            ("root", "root", "1.2.3.4", b"\x05\x00"),
            ("ca-marker", "issuer", marker, b"\x05\x00"),
            ("malformed-marker", "leaf", marker, b"\x04\x00"),
        ):
            with self.subTest(case=label):
                extra = x509.UnrecognizedExtension(ObjectIdentifier(oid), value)
                root_key, root = certificate(
                    "root", extra_critical=extra if target == "root" else None
                )
                issuer_key, issuer = certificate(
                    "profile-issuer",
                    root,
                    root_key,
                    extra_critical=extra if target == "issuer" else None,
                )
                key, cert = certificate(
                    "installer",
                    issuer,
                    issuer_key,
                    installer_marker=None
                    if oid == marker and target == "leaf"
                    else marker,
                    extra_critical=extra if target == "leaf" else None,
                )
                cms = self.directory / f"{label}.der"
                cms.write_bytes(
                    pkcs7.PKCS7SignatureBuilder()
                    .set_data(b"signed content")
                    .add_signer(cert, key, hashes.SHA256())
                    .add_certificate(issuer)
                    .sign(serialization.Encoding.DER, [pkcs7.PKCS7Options.Binary])
                )
                roots = self.directory / f"{label}-roots.pem"
                roots.write_bytes(root.public_bytes(serialization.Encoding.PEM))
                with self.assertRaisesRegex(
                    sign_mac.ReleaseError, "unsupported critical"
                ):
                    sign_mac.code_cms_extension_options(cms, roots, {marker})

    def test_signed_profile_requires_trust(self):
        profile_path = self.directory / "profile.provisionprofile"
        profile_path.write_bytes(self.signed_profile_bytes())
        roots = self.directory / "roots.pem"
        roots.write_bytes(self.root.public_bytes(serialization.Encoding.PEM))
        self.assertEqual(
            sign_mac.read_profile(profile_path, roots)["TeamIdentifier"], [TEAM]
        )
        _, other = certificate("root")
        roots.write_bytes(other.public_bytes(serialization.Encoding.PEM))
        with self.assertRaisesRegex(sign_mac.ReleaseError, "CMS Verification failure"):
            sign_mac.read_profile(profile_path, roots)

    def test_application_certificate_cannot_sign_a_provisioning_profile(self):
        key, cert = certificate(
            "application", self.root, self.root_key, marker_critical=False
        )
        profile_path = self.directory / "forged.provisionprofile"
        profile_path.write_bytes(
            pkcs7.PKCS7SignatureBuilder()
            .set_data(plistlib.dumps(self.profile))
            .add_signer(cert, key, hashes.SHA256())
            .add_certificate(self.root)
            .sign(serialization.Encoding.DER, [pkcs7.PKCS7Options.Binary])
        )
        roots = self.directory / "roots.pem"
        roots.write_bytes(self.root.public_bytes(serialization.Encoding.PEM))
        with self.assertRaisesRegex(sign_mac.ReleaseError, "profile signing"):
            sign_mac.read_profile(profile_path, roots)

    def require_packaging_tools(self):
        for name in ("rcodesign", "xar", "mkbom", "lsbom", "cpio", "openssl"):
            try:
                sign_mac.tool(name)
            except sign_mac.ReleaseError:
                self.skipTest(f"real Linux packaging integration needs {name}")

    def make_app(self):
        app = self.directory / "BruTV.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        info = {
            "CFBundleIdentifier": BUNDLE_ID,
            "CFBundleExecutable": "BruTV",
            "CFBundleVersion": "42",
            "CFBundleShortVersionString": "1.2",
            "CFBundleSupportedPlatforms": ["MacOSX"],
            "DTPlatformName": "macosx",
            "DTPlatformVersion": "27.0",
            "DTPlatformBuild": "26A425",
            "DTSDKName": "macosx27.0",
            "DTSDKBuild": "26A425",
            "DTXcode": "2710",
            "DTXcodeBuild": "27A9275",
        }
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        slices = []
        for arch in ("aarch64", "x86-64"):
            path = self.directory / arch
            subprocess.run(
                [
                    sign_mac.tool("rcodesign"),
                    "-C",
                    "/dev/null",
                    "debug-create-macho",
                    "--architecture",
                    arch,
                    "--sdk-version",
                    "27.0.0",
                    str(path),
                ],
                check=True,
                capture_output=True,
            )
            data = bytearray(path.read_bytes())
            offset = 32
            for _ in range(struct.unpack_from("<I", data, 16)[0]):
                command, size = struct.unpack_from("<II", data, offset)
                if command == 0x32:
                    struct.pack_into("<I", data, offset + 8, 6)
                offset += size
            path.write_bytes(data)
            slices.append(path)
        executable = app / "Contents/MacOS/BruTV"
        subprocess.run(
            [
                sign_mac.tool("rcodesign"),
                "-C",
                "/dev/null",
                "macho-universal-create",
                "--output",
                str(executable),
                *(str(path) for path in slices),
            ],
            check=True,
            capture_output=True,
        )
        executable.chmod(0o755)
        return app

    def test_macho_sdk_version_must_match_recorded_sdk(self):
        self.require_packaging_tools()
        app = self.make_app()
        sign_mac.validate_app(app, BUNDLE_ID)
        path = app / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["DTPlatformVersion"] = "28.0"
        info["DTSDKName"] = "macosx28.0"
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(sign_mac.ReleaseError, "SDK version"):
            sign_mac.validate_app(app, BUNDLE_ID)
        del info["DTXcodeBuild"]
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(sign_mac.ReleaseError, "DTXcodeBuild"):
            sign_mac.validate_app(app, BUNDLE_ID)

    def test_resource_and_metadata_tampering_is_rejected(self):
        self.require_packaging_tools()
        app = self.make_app()
        resource = app / "Contents/Resources/probe.txt"
        resource.parent.mkdir()
        resource.write_bytes(b"signed resource")
        roots = self.directory / "roots.pem"
        roots.write_bytes(self.root.public_bytes(serialization.Encoding.PEM))
        pem = self.directory / "application.pem"
        pem.write_bytes(
            self.app_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
            + self.app_cert.public_bytes(serialization.Encoding.PEM)
            + self.root.public_bytes(serialization.Encoding.PEM)
        )
        entitlements = self.entitlements()
        entitlements_path = self.directory / "entitlements.plist"
        entitlements_path.write_bytes(plistlib.dumps(entitlements))
        sign_mac.run(
            [
                sign_mac.tool("rcodesign"),
                "-C",
                "/dev/null",
                "sign",
                "--pem-file",
                str(pem),
                "--team-name",
                TEAM,
                "--entitlements-xml-file",
                str(entitlements_path),
                "--timestamp-url",
                "none",
                str(app),
            ]
        )
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        for index, path in enumerate(
            (
                resource,
                app / "Contents/Info.plist",
                app / "Contents/_CodeSignature/CodeResources",
            )
        ):
            original = path.read_bytes()
            path.write_bytes(original + b"tampered")
            validation = self.directory / f"tamper-{index}"
            validation.mkdir()
            with self.subTest(path=path), self.assertRaises(sign_mac.ReleaseError):
                sign_mac.validate_signed_app(
                    app, info, self.app_cert, entitlements, roots, validation
                )
            path.write_bytes(original)
        added = app / "Contents/Resources/added.txt"
        added.write_bytes(b"unsealed")
        validation = self.directory / "added-resource"
        validation.mkdir()
        with self.assertRaisesRegex(sign_mac.ReleaseError, "unsealed resource"):
            sign_mac.validate_signed_app(
                app, info, self.app_cert, entitlements, roots, validation
            )

    def test_real_signed_installer_round_trip_and_tampering(self):
        self.require_packaging_tools()
        self.profile["Entitlements"]["keychain-access-groups"] = [f"{TEAM}.*"]
        self.requested["keychain-access-groups"] = [f"{TEAM}.{BUNDLE_ID}"]
        app = self.make_app()
        roots = self.directory / "roots.pem"
        roots.write_bytes(self.root.public_bytes(serialization.Encoding.PEM))
        environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("MACOS_")
        }
        environment.update(
            {"MACOS_APPLE_ROOT_CA_PATH": str(roots), "IOS_BUNDLE_ID": BUNDLE_ID}
        )
        for kind, key, cert in (
            ("APPLICATION", self.app_key, self.app_cert),
            ("INSTALLER", self.installer_key, self.installer_cert),
        ):
            path = self.directory / f"{kind}.p12"
            path.write_bytes(
                pkcs12.serialize_key_and_certificates(
                    b"fixture",
                    key,
                    cert,
                    [self.root],
                    serialization.BestAvailableEncryption(b"secret"),
                )
            )
            environment[f"MACOS_{kind}_CERTIFICATE_PATH"] = str(path)
            environment[f"MACOS_{kind}_P12_PASSWORD"] = "secret"
        profile_path = self.directory / "profile.provisionprofile"
        profile_path.write_bytes(self.signed_profile_bytes())
        environment["MACOS_PROVISIONING_PROFILE_PATH"] = str(profile_path)
        entitlements = self.directory / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps(self.requested))
        output = self.directory / "BruTV.pkg"
        with patch.dict(os.environ, environment, clear=True):
            self.assertEqual(
                sign_mac.main(
                    [
                        "--app",
                        str(app),
                        "--output",
                        str(output),
                        "--entitlements",
                        str(entitlements),
                    ]
                ),
                0,
            )
            self.assertEqual(
                sign_mac.main(["--validate-only", "--output", str(output)]), 0
            )
            _, other_root = certificate("root")
            other_roots = self.directory / "other-roots.pem"
            other_roots.write_bytes(other_root.public_bytes(serialization.Encoding.PEM))
            errors = io.StringIO()
            with (
                patch.dict(os.environ, {"MACOS_APPLE_ROOT_CA_PATH": str(other_roots)}),
                contextlib.redirect_stderr(errors),
            ):
                self.assertEqual(
                    sign_mac.main(["--validate-only", "--output", str(output)]), 1
                )
            self.assertIn("certificate verify error", errors.getvalue())
            expanded = self.directory / "expanded-product"
            expanded.mkdir()
            sign_mac.run([sign_mac.tool("xar"), "-xf", str(output)], cwd=expanded)
            payload = gzip.decompress((expanded / "BruTV.pkg/Payload").read_bytes())
            sign_mac.run(
                [sign_mac.tool("cpio"), "-id", "--no-absolute-filenames"],
                input=payload,
                cwd=expanded,
            )
            executable = expanded / "BruTV.app/Contents/MacOS/BruTV"
            for data in sign_mac.macho_slices(executable.read_bytes()):
                offset = 32
                for _ in range(struct.unpack_from("<I", data, 16)[0]):
                    command, size = struct.unpack_from("<II", data, offset)
                    if command == 0x1D:
                        start, length = struct.unpack_from("<II", data, offset + 8)
                        signature = data[start : start + length]
                    offset += size
                for index in range(struct.unpack_from(">I", signature, 8)[0]):
                    slot, start = struct.unpack_from(">II", signature, 12 + index * 8)
                    if slot == 5:
                        length = struct.unpack_from(">I", signature, start + 4)[0]
                        claimed = plistlib.loads(signature[start + 8 : start + length])
                self.assertEqual(
                    claimed["com.apple.application-identifier"], f"{TEAM}.{BUNDLE_ID}"
                )
                self.assertEqual(
                    claimed["application-identifier"], f"{TEAM}.{BUNDLE_ID}"
                )
                self.assertEqual(
                    claimed["keychain-access-groups"], [f"{TEAM}.{BUNDLE_ID}"]
                )
            original = output.read_bytes()
            with patch.dict(os.environ, {"MACOS_INSTALLER_P12_PASSWORD": "wrong"}):
                errors = io.StringIO()
                with contextlib.redirect_stderr(errors):
                    self.assertEqual(
                        sign_mac.main(["--app", str(app), "--output", str(output)]), 1
                    )
                self.assertIn("cannot open installer P12", errors.getvalue())
                self.assertEqual(output.read_bytes(), original)
            data = bytearray(original)
            data[-8] ^= 1
            output.write_bytes(data)
            errors = io.StringIO()
            with contextlib.redirect_stderr(errors):
                self.assertEqual(
                    sign_mac.main(["--validate-only", "--output", str(output)]), 1
                )
            self.assertIn("hash values do not match", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
