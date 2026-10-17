#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "cryptography>=45,<47",
# ]
# ///
"""Focused distribution guards and optional real-zsign signing round trips."""

from __future__ import annotations

import argparse
import copy
import importlib.util
import os
import plistlib
import shutil
import struct
import tempfile
import unittest
import zipfile
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs7, pkcs12
from cryptography.x509.oid import NameOID

SPEC = importlib.util.spec_from_file_location(
    "sign_ipa", Path(__file__).resolve().parents[1] / "sign-ipa.py"
)
SIGN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGN)
TEAM = "83BXSDT7QC"
BUNDLE = "com.bvolpato.brutv"


def issue_certificate(
    key, subject, issuer, issuer_key, *, ca=False, distribution=False
):
    now = datetime.now(UTC)
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=30))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
        .add_extension(
            x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False
        )
        .add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_key.public_key()),
            critical=False,
        )
    )
    if distribution:
        builder = builder.add_extension(
            x509.UnrecognizedExtension(SIGN.DISTRIBUTION_OID, b"\x05\x00"),
            critical=False,
        )
    return builder.sign(issuer_key, hashes.SHA256())


def unsigned_macho(platform="ios", sdk=0x1B0100):
    text = struct.pack(
        "<II16sQQQQiiII", 0x19, 152, b"__TEXT", 0x100000000, 4096, 0, 4096, 7, 5, 1, 0
    )
    text += struct.pack(
        "<16s16sQQIIIIIIII",
        b"__text",
        b"__TEXT",
        0x100000400,
        4,
        1024,
        2,
        0,
        0,
        0x80000400,
        0,
        0,
        0,
    )
    link = struct.pack(
        "<II16sQQQQiiII", 0x19, 72, b"__LINKEDIT", 0x100001000, 0, 4096, 0, 7, 1, 0, 0
    )
    target = struct.pack(
        "<IIIIII", 0x32, 24, 2 if platform == "ios" else 3, 0x110000, sdk, 0
    )
    header = struct.pack(
        "<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 2, 3, len(text + link + target), 0, 0
    )
    data = bytearray((header + text + link + target).ljust(4096, b"\0"))
    data[1024:1028] = b"\xc0\x03\x5f\xd6"
    return bytes(data)


class SigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        root_name = x509.Name(
            [x509.NameAttribute(NameOID.COMMON_NAME, "BruTV signing test root")]
        )
        cls.root = issue_certificate(
            cls.root_key, root_name, root_name, cls.root_key, ca=True
        )
        cls.profile_ca_key = rsa.generate_private_key(
            public_exponent=65537, key_size=2048
        )
        profile_ca_name = x509.Name(
            [
                x509.NameAttribute(
                    NameOID.COMMON_NAME, "Apple iPhone Certification Authority"
                )
            ]
        )
        cls.profile_ca = issue_certificate(
            cls.profile_ca_key, profile_ca_name, root_name, cls.root_key, ca=True
        )
        cls.profile_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        profile_name = x509.Name(
            [
                x509.NameAttribute(
                    NameOID.COMMON_NAME, "Apple iPhone OS Provisioning Profile Signing"
                )
            ]
        )
        cls.profile_signer = issue_certificate(
            cls.profile_key, profile_name, profile_ca_name, cls.profile_ca_key
        )
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        leaf_name = x509.Name(
            [
                x509.NameAttribute(
                    NameOID.COMMON_NAME, "Apple Distribution: BruTV test"
                ),
                x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, TEAM),
            ]
        )
        cls.cert = issue_certificate(
            cls.key, leaf_name, root_name, cls.root_key, distribution=True
        )

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="brutv-sign-test-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.roots = self.work / "test-root.pem"
        self.roots.write_bytes(self.root.public_bytes(serialization.Encoding.PEM))
        self.p12 = self.work / "distribution.p12"
        self.p12.write_bytes(
            pkcs12.serialize_key_and_certificates(
                b"BruTV test",
                self.key,
                self.cert,
                [self.root],
                serialization.BestAvailableEncryption(b"private-test-password"),
            )
        )

    def profile(self, bundle=BUNDLE, platform="ios"):
        return {
            "UUID": "TEST-PROFILE-UUID",
            "Name": "BruTV App Store test",
            "ExpirationDate": datetime.now(UTC).replace(tzinfo=None)
            + timedelta(days=10),
            "TeamIdentifier": [TEAM],
            "ApplicationIdentifierPrefix": [TEAM],
            "Platform": ["iOS" if platform == "ios" else "tvOS"],
            "DeveloperCertificates": [
                self.cert.public_bytes(serialization.Encoding.DER)
            ],
            "Entitlements": {
                "application-identifier": f"{TEAM}.{bundle}",
                "com.apple.developer.team-identifier": TEAM,
                "get-task-allow": False,
                "beta-reports-active": True,
                "keychain-access-groups": [f"{TEAM}.*", "com.apple.token"],
            },
        }

    def write_profile(self, profile, name="profile.mobileprovision"):
        result = self.work / name
        raw = plistlib.dumps(profile)
        signed = (
            pkcs7.PKCS7SignatureBuilder()
            .set_data(raw)
            .add_signer(self.profile_signer, self.profile_key, hashes.SHA256())
            .add_certificate(self.profile_ca)
            .add_certificate(self.root)
            .sign(serialization.Encoding.DER, [pkcs7.PKCS7Options.Binary])
        )
        result.write_bytes(signed)
        return result

    def app(self, platform="ios"):
        app = self.work / "BruTV.app"
        app.mkdir()
        info = {
            "CFBundleIdentifier": BUNDLE,
            "CFBundleExecutable": "BruTV",
            "CFBundleVersion": "20",
            "CFBundleShortVersionString": "1.0.2",
            "MinimumOSVersion": "17.0",
            "CFBundleSupportedPlatforms": [
                "iPhoneOS" if platform == "ios" else "AppleTVOS"
            ],
            "CFBundlePackageType": "APPL",
            "UIDeviceFamily": [1, 2] if platform == "ios" else [3],
            "DTSDKName": "iphoneos27.1" if platform == "ios" else "appletvos27.1",
            "DTSDKBuild": "24B80",
            "DTPlatformName": "iphoneos" if platform == "ios" else "appletvos",
            "DTPlatformVersion": "27.1",
            "DTPlatformBuild": "24B80",
            "DTXcode": "2710",
            "DTXcodeBuild": "18B81",
        }
        if platform == "ios":
            for field in ("CFBundleIcons", "CFBundleIcons~ipad"):
                info[field] = {
                    "CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon"]}
                }
            (app / "AppIcon@2x.png").write_bytes(b"test icon resource")
        else:
            info["CFBundleIcons"] = {
                "CFBundlePrimaryIcon": {
                    "CFBundleIconName": "App Icon & Top Shelf Image"
                }
            }
            (app / "Assets.car").write_bytes(b"test compiled asset resource")
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        (app / "BruTV").write_bytes(unsigned_macho(platform))
        (app / "BruTV").chmod(0o755)
        (app / "PrivacyInfo.xcprivacy").write_bytes(
            plistlib.dumps({"NSPrivacyTracking": False})
        )
        (app / "PkgInfo").write_bytes(b"APPL????")
        return app

    def environment(self, profile, signer):
        return {
            "PATH": os.environ["PATH"],
            "IOS_CERTIFICATE_PATH": str(self.p12),
            "IOS_PROVISIONING_PROFILE_PATH": str(profile),
            "IOS_P12_PASSWORD": "private-test-password",
            "IOS_APPLE_ROOT_CA_PATH": str(self.roots),
            "IOS_ZSIGN": signer,
        }

    def test_accepts_exact_app_store_profile(self):
        profile = self.profile()
        self.assertEqual(
            SIGN.validate_profile(profile, BUNDLE, TEAM, "ios", self.cert),
            profile["Entitlements"],
        )

    def test_resolves_wildcard_allowlist_to_requested_concrete_claims(self):
        allowed = self.profile()["Entitlements"]
        allowed["com.apple.developer.networking.multicast"] = True
        claims = SIGN.resolve_entitlements(allowed, {}, BUNDLE, TEAM)
        self.assertEqual(claims["keychain-access-groups"], [f"{TEAM}.{BUNDLE}"])
        self.assertNotIn("com.apple.developer.networking.multicast", claims)
        self.assertNotIn("com.apple.token", claims["keychain-access-groups"])
        with self.assertRaisesRegex(
            SIGN.SigningError, "does not authorize requested entitlement"
        ):
            SIGN.resolve_entitlements(
                allowed, {"com.apple.developer.healthkit": True}, BUNDLE, TEAM
            )
        with self.assertRaisesRegex(SIGN.SigningError, "concrete identifiers"):
            SIGN.resolve_entitlements(
                allowed, {"keychain-access-groups": [f"{TEAM}.*"]}, BUNDLE, TEAM
            )

    def test_rejects_non_store_and_mismatched_profiles(self):
        cases = {
            "development": lambda p: p["Entitlements"].update({"get-task-allow": True}),
            "ad-hoc": lambda p: p.update({"ProvisionedDevices": ["test-device"]}),
            "enterprise": lambda p: p.update({"ProvisionsAllDevices": True}),
            "expired": lambda p: p.update(
                {"ExpirationDate": datetime.now(UTC) - timedelta(days=1)}
            ),
            "wrong team": lambda p: p.update({"TeamIdentifier": ["WRONGTEAM"]}),
            "wildcard app": lambda p: p["Entitlements"].update(
                {"application-identifier": f"{TEAM}.*"}
            ),
            "wrong cert": lambda p: p.update({"DeveloperCertificates": []}),
            "wrong platform": lambda p: p.update({"Platform": ["tvOS"]}),
        }
        for name, mutate in cases.items():
            with self.subTest(name=name):
                profile = self.profile()
                mutate(profile)
                with self.assertRaises(SIGN.SigningError):
                    SIGN.validate_profile(profile, BUNDLE, TEAM, "ios", self.cert)

    def test_checks_cms_signature_and_trust(self):
        profile = self.profile()
        path = self.write_profile(profile)
        self.assertEqual(
            SIGN.decode_profile(path, self.roots),
            plistlib.loads(plistlib.dumps(profile)),
        )
        unrelated_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        unrelated_name = x509.Name(
            [x509.NameAttribute(NameOID.COMMON_NAME, "untrusted test root")]
        )
        unrelated = issue_certificate(
            unrelated_key, unrelated_name, unrelated_name, unrelated_key, ca=True
        )
        untrusted_roots = self.work / "untrusted-roots.pem"
        untrusted_roots.write_bytes(unrelated.public_bytes(serialization.Encoding.PEM))
        with self.assertRaisesRegex(SIGN.SigningError, "CMS verification"):
            SIGN.decode_profile(path, untrusted_roots)
        tampered = bytearray(path.read_bytes())
        position = tampered.index(b"BruTV App Store test")
        tampered[position] ^= 1
        path.write_bytes(tampered)
        with self.assertRaisesRegex(SIGN.SigningError, "CMS verification"):
            SIGN.decode_profile(path, self.roots)

    def test_wrong_p12_password_does_not_leak(self):
        with (
            patch.dict(os.environ, {"IOS_P12_PASSWORD": "secret-wrong-password"}),
            self.assertRaises(SIGN.SigningError) as error,
        ):
            SIGN.load_identity(self.p12, TEAM, self.work)
        self.assertNotIn("secret-wrong-password", str(error.exception))

    def test_rejects_ordinary_distribution_certificate_as_profile_issuer(self):
        path = self.work / "forged.mobileprovision"
        path.write_bytes(
            pkcs7.PKCS7SignatureBuilder()
            .set_data(plistlib.dumps(self.profile()))
            .add_signer(self.cert, self.key, hashes.SHA256())
            .add_certificate(self.root)
            .sign(serialization.Encoding.DER, [pkcs7.PKCS7Options.Binary])
        )
        with self.assertRaisesRegex(
            SIGN.SigningError, "authorized provisioning profile signer"
        ):
            SIGN.decode_profile(path, self.roots)

    def test_p12_private_copy_preserves_ca_chain_without_password_argv(self):
        with patch.dict(os.environ, {"IOS_P12_PASSWORD": "private-test-password"}):
            certificate, private, _ = SIGN.load_identity(self.p12, TEAM, self.work)
        key, leaf, chain = pkcs12.load_key_and_certificates(private.read_bytes(), b"")
        self.assertEqual(leaf, certificate)
        self.assertEqual(chain, [self.root])
        self.assertEqual(private.stat().st_mode & 0o777, 0o600)
        self.assertIsNotNone(key)

    def test_rejects_missing_icons_and_wrong_binary_platform(self):
        app = self.app()
        SIGN.bundle_info(app, BUNDLE, "ios")
        (app / "AppIcon@2x.png").unlink()
        with self.assertRaisesRegex(SIGN.SigningError, "icons"):
            SIGN.bundle_info(app, BUNDLE, "ios")
        (app / "BruTV").write_bytes(unsigned_macho("tvos"))
        with self.assertRaisesRegex(SIGN.SigningError, "physical ios"):
            SIGN.bundle_info(app, BUNDLE, "ios")

    def test_rejects_unresolved_xcode_values(self):
        app = self.app()
        info = plistlib.loads((app / "Info.plist").read_bytes())
        info["CFBundleVersion"] = "$(CURRENT_PROJECT_VERSION)"
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(SIGN.SigningError, "CFBundleVersion"):
            SIGN.bundle_info(app, BUNDLE, "ios")

    def test_rejects_empty_fat_binary_instead_of_skipping_signature_verification(self):
        with self.assertRaisesRegex(SIGN.SigningError, "architecture table"):
            SIGN.macho_slices(struct.pack(">II", 0xCAFEBABE, 0))

    def test_rejects_old_linker_sdk_disguised_by_new_bundle_metadata(self):
        app = self.app()
        (app / "BruTV").write_bytes(unsigned_macho(sdk=0x110000))
        with self.assertRaisesRegex(SIGN.SigningError, "Mach-O SDK version"):
            SIGN.bundle_info(app, BUNDLE, "ios")
        (app / "BruTV").write_bytes(unsigned_macho())
        info = plistlib.loads((app / "Info.plist").read_bytes())
        info["DTXcodeBuild"] = "$(XCODE_PRODUCT_BUILD_VERSION)"
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(
            SIGN.SigningError, "unresolved Apple build metadata"
        ):
            SIGN.bundle_info(app, BUNDLE, "ios")

    def test_packaging_preserves_executable_mode_and_payload_layout(self):
        app = self.app()
        output = self.work / "release.ipa"
        SIGN.package_ipa(app, output)
        with zipfile.ZipFile(output) as archive:
            item = archive.getinfo("Payload/BruTV.app/BruTV")
            self.assertEqual((item.external_attr >> 16) & 0o777, 0o755)
            self.assertIsNone(archive.testzip())

    def test_real_zsign_round_trip_and_tampering(self):
        signer = os.environ.get("IOS_ZSIGN") or shutil.which("zsign")
        if not signer:
            self.skipTest("set IOS_ZSIGN for the real Linux signer integration")
        app = self.app()
        profile = self.write_profile(self.profile())
        output = self.work / "release.ipa"
        with patch.dict(os.environ, self.environment(profile, signer), clear=True):
            unauthorized = self.work / "unauthorized.entitlements"
            unauthorized.write_bytes(
                plistlib.dumps({"com.apple.developer.healthkit": True})
            )
            with self.assertRaisesRegex(
                SIGN.SigningError, "does not authorize requested entitlement"
            ):
                SIGN.sign(
                    argparse.Namespace(
                        platform="ios",
                        app=app,
                        output=output,
                        preflight=False,
                        entitlements=unauthorized,
                    )
                )
            self.assertFalse(output.exists())
            SIGN.sign(
                argparse.Namespace(
                    platform="ios", app=app, output=output, preflight=False
                )
            )
        extracted = self.work / "extracted"
        with zipfile.ZipFile(output) as archive:
            archive.extractall(extracted)
            self.assertEqual(
                archive.read("Payload/BruTV.app/embedded.mobileprovision"),
                profile.read_bytes(),
            )
        signed = extracted / "Payload/BruTV.app"
        claims = plistlib.loads(
            SIGN.signature_slots((signed / "BruTV").read_bytes())[0][5][8:]
        )
        self.assertEqual(claims["keychain-access-groups"], [f"{TEAM}.{BUNDLE}"])
        certificate = self.work / "leaf.pem"
        certificate.write_bytes(self.cert.public_bytes(serialization.Encoding.PEM))
        changed = bytearray((signed / "BruTV").read_bytes())
        changed[1024] ^= 1
        (signed / "BruTV").write_bytes(changed)
        with self.assertRaisesRegex(SIGN.SigningError, "page hash"):
            SIGN.verify_binary(
                signed / "BruTV",
                certificate,
                TEAM,
                self.work,
                bundle=signed,
                expected_entitlements=SIGN.resolve_entitlements(
                    self.profile()["Entitlements"], {}, BUNDLE, TEAM
                ),
            )
        (signed / "PrivacyInfo.xcprivacy").write_bytes(b"tampered")
        with self.assertRaisesRegex(SIGN.SigningError, "resource hash"):
            SIGN.verify_resources(signed)

    def test_real_zsign_tvos_and_topshelf_profiles(self):
        signer = os.environ.get("IOS_ZSIGN") or shutil.which("zsign")
        if not signer:
            self.skipTest("set IOS_ZSIGN for the real Linux signer integration")
        app = self.app("tvos")
        extension = app / "PlugIns" / "BruTVTopShelf.appex"
        extension.mkdir(parents=True)
        extension_info = copy.deepcopy(
            plistlib.loads((app / "Info.plist").read_bytes())
        )
        extension_info.update(
            {
                "CFBundleIdentifier": f"{BUNDLE}.TopShelf",
                "CFBundleExecutable": "BruTVTopShelf",
                "CFBundlePackageType": "XPC!",
                "NSExtension": {"NSExtensionPointIdentifier": "com.apple.tv-services"},
            }
        )
        (extension / "Info.plist").write_bytes(plistlib.dumps(extension_info))
        (extension / "BruTVTopShelf").write_bytes(unsigned_macho("tvos"))
        (extension / "BruTVTopShelf").chmod(0o755)
        group = "group.com.bvolpato.brutv"
        profile = self.profile(platform="tvos")
        profile["Entitlements"]["com.apple.security.application-groups"] = [group]
        top_profile = self.profile(bundle=f"{BUNDLE}.TopShelf", platform="tvos")
        top_profile["Entitlements"]["com.apple.security.application-groups"] = [group]
        app_profile = self.write_profile(profile, "tv.mobileprovision")
        top_path = self.write_profile(top_profile, "top.mobileprovision")
        environment = self.environment(app_profile, signer)
        environment.update(
            {
                "TVOS_PROVISIONING_PROFILE_PATH": str(app_profile),
                "TVOS_TOPSHELF_PROVISIONING_PROFILE_PATH": str(top_path),
            }
        )
        output = self.work / "tv.ipa"
        with patch.dict(os.environ, environment, clear=True):
            SIGN.sign(
                argparse.Namespace(
                    platform="tvos", app=app, output=output, preflight=False
                )
            )
        with zipfile.ZipFile(output) as archive:
            embedded = archive.read(
                "Payload/BruTV.app/PlugIns/BruTVTopShelf.appex/embedded.mobileprovision"
            )
            for executable, bundle_id in (
                ("Payload/BruTV.app/BruTV", BUNDLE),
                (
                    "Payload/BruTV.app/PlugIns/BruTVTopShelf.appex/BruTVTopShelf",
                    f"{BUNDLE}.TopShelf",
                ),
            ):
                claims = plistlib.loads(
                    SIGN.signature_slots(archive.read(executable))[0][5][8:]
                )
                self.assertEqual(
                    claims["application-identifier"], f"{TEAM}.{bundle_id}"
                )
                self.assertEqual(
                    claims["keychain-access-groups"], [f"{TEAM}.{bundle_id}"]
                )
                self.assertEqual(
                    claims["com.apple.security.application-groups"], [group]
                )
        self.assertEqual(embedded, top_path.read_bytes())


if __name__ == "__main__":
    unittest.main()
