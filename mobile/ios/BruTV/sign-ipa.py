#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "cryptography>=45,<47",
# ]
# ///
"""Sign xtool iOS/tvOS bundles with App Store distribution credentials on Linux."""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from datetime import UTC, datetime
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID, ObjectIdentifier


class SigningError(Exception):
    pass


APPLE_ROOTS = (
    (
        "https://www.apple.com/appleca/AppleIncRootCertificate.cer",
        "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
    ),
    (
        "https://www.apple.com/certificateauthority/AppleRootCA-G2.cer",
        "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",
    ),
    (
        "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer",
        "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
    ),
)
DISTRIBUTION_OID = ObjectIdentifier("1.2.840.113635.100.6.1.4")
MACHO_MAGICS = {
    b"\xcf\xfa\xed\xfe",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
}


def run(command: list[str], label: str, **kwargs) -> bytes:
    result = subprocess.run(command, capture_output=True, check=False, **kwargs)
    if result.returncode:
        # OpenSSL and signer output can include credential details. Do not echo it.
        raise SigningError(f"{label} failed (exit {result.returncode})")
    return result.stdout


def write_private(path: Path, data: bytes) -> Path:
    path.write_bytes(data)
    path.chmod(0o600)
    return path


def credentials_file(
    prefix: str, kind: str, work: Path, *, fallback: str | None = None
) -> Path:
    for scope in (prefix, fallback):
        if scope is None:
            continue
        path = os.environ.get(f"{scope}_{kind}_PATH")
        encoded = os.environ.get(f"{scope}_{kind}_BASE64")
        if path and encoded:
            raise SigningError(
                f"set only one of {scope}_{kind}_PATH and {scope}_{kind}_BASE64"
            )
        if path:
            source = Path(path).expanduser()
            if not source.is_file():
                raise SigningError(f"{scope}_{kind}_PATH is not a readable file")
            return write_private(work / f"{prefix}_{kind}", source.read_bytes())
        if encoded:
            try:
                data = base64.b64decode("".join(encoded.split()), validate=True)
            except ValueError as exc:
                raise SigningError(f"{scope}_{kind}_BASE64 is invalid base64") from exc
            return write_private(work / f"{prefix}_{kind}", data)
    if prefix == "IOS" and kind in {"CERTIFICATE", "PROVISIONING_PROFILE"}:
        suffix = ".p12" if kind == "CERTIFICATE" else ".mobileprovision"
        local = list((Path(__file__).resolve().parent / "signing").glob(f"*{suffix}"))
        if len(local) == 1:
            return write_private(work / f"{prefix}_{kind}", local[0].read_bytes())
    raise SigningError(f"set {prefix}_{kind}_PATH or {prefix}_{kind}_BASE64")


def apple_roots(work: Path) -> Path:
    local = os.environ.get("IOS_APPLE_ROOT_CA_PATH")
    if local:
        path = Path(local).expanduser()
        if not path.is_file():
            raise SigningError("IOS_APPLE_ROOT_CA_PATH is not a readable PEM CA bundle")
        return path
    pem = bytearray()
    for url, fingerprint in APPLE_ROOTS:
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                der = response.read(64 * 1024)
        except OSError as exc:
            raise SigningError(
                "cannot fetch Apple's signing roots; set IOS_APPLE_ROOT_CA_PATH for offline use"
            ) from exc
        if hashlib.sha256(der).hexdigest() != fingerprint:
            raise SigningError("downloaded Apple root certificate fingerprint changed")
        pem.extend(
            x509.load_der_x509_certificate(der).public_bytes(serialization.Encoding.PEM)
        )
    return write_private(work / "apple-roots.pem", pem)


def decode_profile(path: Path, roots: Path) -> dict:
    # Match Apple's SecPolicyCreateiPhoneProvisioningProfileSigning policy.
    # Apple-anchored ordinary developer certificates cannot issue profiles.
    with tempfile.TemporaryDirectory(prefix="brutv-profile-cms-") as temporary:
        signer_path = Path(temporary) / "signer.pem"
        raw = run(
            [
                "openssl",
                "cms",
                "-verify",
                "-binary",
                "-inform",
                "DER",
                "-in",
                str(path),
                "-CAfile",
                str(roots),
                "-purpose",
                "any",
                "-verify_depth",
                "1",
                "-signer",
                str(signer_path),
            ],
            "provisioning profile CMS verification",
        )
        signers = x509.load_pem_x509_certificates(signer_path.read_bytes())
        if len(signers) != 1:
            raise SigningError(
                "provisioning profile must have exactly one authorized Apple profile signer"
            )
        signer = signers[0]
        common_name = lambda name: [
            item.value for item in name.get_attributes_for_oid(NameOID.COMMON_NAME)
        ]
        if common_name(signer.subject) != [
            "Apple iPhone OS Provisioning Profile Signing"
        ] or common_name(signer.issuer) != ["Apple iPhone Certification Authority"]:
            raise SigningError(
                "provisioning profile was not signed by Apple's authorized provisioning profile signer"
            )
    try:
        profile = plistlib.loads(raw)
    except (ValueError, plistlib.InvalidFileException) as exc:
        raise SigningError("provisioning profile CMS content is not a plist") from exc
    if not isinstance(profile, dict):
        raise SigningError("provisioning profile CMS content is not a dictionary")
    return profile


def utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def validate_profile(
    profile: dict,
    bundle_id: str,
    team_id: str,
    platform: str,
    certificate: x509.Certificate,
) -> dict:
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime) or utc(expiration) <= datetime.now(UTC):
        raise SigningError(
            "App Store provisioning profile has expired or has no ExpirationDate"
        )
    if (
        "ProvisionedDevices" in profile
        or profile.get("ProvisionsAllDevices", False) is not False
    ):
        raise SigningError(
            "release requires an App Store profile, not development, ad-hoc, or enterprise provisioning"
        )
    entitlements = profile.get("Entitlements", {})
    if entitlements.get("get-task-allow") is not False:
        raise SigningError("App Store profile must set get-task-allow to false")
    if (
        team_id not in profile.get("TeamIdentifier", [])
        or entitlements.get("com.apple.developer.team-identifier") != team_id
    ):
        raise SigningError("provisioning profile team does not match IOS_TEAM_ID")
    prefixes = profile.get("ApplicationIdentifierPrefix", [team_id])
    if not any(
        entitlements.get("application-identifier") == f"{prefix}.{bundle_id}"
        for prefix in prefixes
    ):
        raise SigningError(
            f"provisioning profile must authorize the exact bundle identifier {bundle_id}"
        )
    apple_platform = "iOS" if platform == "ios" else "tvOS"
    if apple_platform not in profile.get("Platform", []):
        raise SigningError(f"provisioning profile does not authorize {apple_platform}")
    certificate_der = certificate.public_bytes(serialization.Encoding.DER)
    if certificate_der not in profile.get("DeveloperCertificates", []):
        raise SigningError(
            "distribution certificate is not included in provisioning profile DeveloperCertificates"
        )
    return entitlements


def resolve_entitlements(
    allowed: dict, requested: dict, bundle_id: str, team_id: str
) -> dict:
    """Claim app capabilities, using the profile only as an authorization list."""
    application_id = allowed["application-identifier"]
    replacements = {
        "$(AppIdentifierPrefix)": application_id.removesuffix(bundle_id),
        "$(TeamIdentifierPrefix)": f"{team_id}.",
        "$(PRODUCT_BUNDLE_IDENTIFIER)": bundle_id,
        "$(CFBundleIdentifier)": bundle_id,
    }

    def expand(value: object) -> object:
        if isinstance(value, str):
            for variable, replacement in replacements.items():
                value = value.replace(variable, replacement)
            if "$(" in value or "${" in value:
                raise SigningError(
                    "requested entitlements contain unresolved build variables"
                )
        elif isinstance(value, list):
            return [expand(item) for item in value]
        elif isinstance(value, dict):
            return {key: expand(item) for key, item in value.items()}
        return value

    def authorized(value: object, permission: object) -> bool:
        if isinstance(value, str) and isinstance(permission, str):
            return value == permission or (
                permission.endswith("*") and value.startswith(permission[:-1])
            )
        if isinstance(value, list) and isinstance(permission, list):
            return all(
                any(authorized(item, entry) for entry in permission) for item in value
            )
        if isinstance(value, dict) and isinstance(permission, dict):
            return all(
                key in permission and authorized(item, permission[key])
                for key, item in value.items()
            )
        return type(value) is type(permission) and value == permission

    managed = {
        "application-identifier": application_id,
        "com.apple.developer.team-identifier": team_id,
        "get-task-allow": False,
    }
    resolved = {**managed, "keychain-access-groups": [application_id]}
    if allowed.get("beta-reports-active") is True:
        resolved["beta-reports-active"] = True
    resolved.update(expand(requested))
    for key, value in managed.items():
        if resolved[key] != value:
            raise SigningError(
                f"requested entitlement {key} must match the release identity"
            )
    groups = resolved.get("keychain-access-groups")
    if not isinstance(groups, list) or any(
        not isinstance(group, str) or "*" in group for group in groups
    ):
        raise SigningError(
            "signed keychain-access-groups must contain concrete identifiers"
        )
    validate_entitlement_types(resolved)
    for key, value in resolved.items():
        if key not in allowed or not authorized(value, allowed[key]):
            raise SigningError(
                f"provisioning profile does not authorize requested entitlement {key}"
            )
    return resolved


def validate_entitlement_types(value: object) -> None:
    if isinstance(value, (str, bool)):
        return
    if isinstance(value, list):
        for item in value:
            validate_entitlement_types(item)
        return
    if isinstance(value, dict) and all(isinstance(key, str) for key in value):
        for item in value.values():
            validate_entitlement_types(item)
        return
    raise SigningError(
        "profile contains entitlement types unsupported by zsign's DER encoder"
    )


def load_identity(
    path: Path, team_id: str, work: Path
) -> tuple[x509.Certificate, Path, Path]:
    if "IOS_P12_PASSWORD" not in os.environ:
        raise SigningError(
            "set IOS_P12_PASSWORD (an empty value is allowed for an unencrypted P12)"
        )
    try:
        key, certificate, chain = pkcs12.load_key_and_certificates(
            path.read_bytes(), os.environ["IOS_P12_PASSWORD"].encode()
        )
    except ValueError as exc:
        raise SigningError(
            "cannot load distribution P12; check IOS_P12_PASSWORD"
        ) from exc
    if key is None or certificate is None:
        raise SigningError(
            "distribution P12 must contain both a private key and its certificate"
        )
    now = datetime.now(UTC)
    if not certificate.not_valid_before_utc <= now < certificate.not_valid_after_utc:
        raise SigningError(
            "distribution signing certificate is expired or not yet valid"
        )
    units = certificate.subject.get_attributes_for_oid(NameOID.ORGANIZATIONAL_UNIT_NAME)
    if team_id not in [unit.value for unit in units]:
        raise SigningError(
            "distribution signing certificate team does not match IOS_TEAM_ID"
        )
    try:
        certificate.extensions.get_extension_for_oid(DISTRIBUTION_OID)
    except x509.ExtensionNotFound as exc:
        raise SigningError(
            "P12 must contain an Apple Distribution/iPhone Distribution certificate"
        ) from exc
    public_key = lambda value: value.public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    if public_key(key.public_key()) != public_key(certificate.public_key()):
        raise SigningError("P12 private key does not match distribution certificate")
    # zsign accepts an unencrypted P12 without a password argument and preserves
    # the original WWDR chain. Its PEM-key mode discards the supplied CA chain.
    key_path = write_private(
        work / "distribution.p12",
        pkcs12.serialize_key_and_certificates(
            b"BruTV", key, certificate, chain, serialization.NoEncryption()
        ),
    )
    certificate_path = write_private(
        work / "distribution-certificate.pem",
        certificate.public_bytes(serialization.Encoding.PEM),
    )
    return certificate, key_path, certificate_path


def read_plist(path: Path) -> dict:
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as exc:
        raise SigningError(f"missing or invalid plist: {path.name}") from exc
    if not isinstance(value, dict):
        raise SigningError(f"plist must contain a dictionary: {path.name}")
    return value


def sdk_version(value: str) -> int:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", value):
        raise SigningError(
            "bundle DTPlatformVersion must identify the actual Apple SDK version"
        )
    major, minor, patch = (list(map(int, value.split("."))) + [0])[:3]
    if major > 65535 or minor > 255 or patch > 255:
        raise SigningError("Apple SDK version is out of range")
    return major << 16 | minor << 8 | patch


def validate_build_metadata(info: dict, platform: str) -> int:
    platform_name = "iphoneos" if platform == "ios" else "appletvos"
    required = (
        "DTSDKName",
        "DTSDKBuild",
        "DTPlatformName",
        "DTPlatformVersion",
        "DTPlatformBuild",
        "DTXcode",
        "DTXcodeBuild",
    )
    for field in required:
        value = info.get(field)
        if not isinstance(value, str) or not value or "$" in value:
            raise SigningError(
                f"release bundle has missing or unresolved Apple build metadata: {field}"
            )
    version = sdk_version(info["DTPlatformVersion"])
    if info["DTPlatformName"] != platform_name or not info["DTSDKName"].startswith(
        platform_name
    ):
        raise SigningError(
            "bundle Apple SDK metadata does not match its target platform"
        )
    if sdk_version(info["DTSDKName"].removeprefix(platform_name)) != version:
        raise SigningError("bundle DTSDKName does not match DTPlatformVersion")
    if not re.fullmatch(r"[0-9]{4}", info["DTXcode"]):
        raise SigningError(
            "bundle DTXcode must contain the actual four-digit Xcode version"
        )
    for field in ("DTSDKBuild", "DTPlatformBuild", "DTXcodeBuild"):
        if not re.fullmatch(r"[0-9]+[A-Z][0-9]+[a-z]?", info[field]):
            raise SigningError(
                f"bundle {field} must contain the actual Apple build number"
            )
    return version


def bundle_info(
    bundle: Path, expected_id: str, platform: str, *, extension: bool = False
) -> dict:
    info = read_plist(bundle / "Info.plist")
    if info.get("CFBundleIdentifier") != expected_id:
        raise SigningError(f"bundle identifier does not match {expected_id}")
    for field in ("CFBundleVersion", "CFBundleShortVersionString", "MinimumOSVersion"):
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", str(info.get(field, ""))):
            raise SigningError(f"bundle has unresolved or invalid {field}")
    executable = info.get("CFBundleExecutable", "")
    if (
        not executable
        or Path(executable).name != executable
        or not (bundle / executable).is_file()
    ):
        raise SigningError("bundle has a missing or invalid CFBundleExecutable")
    if not os.access(bundle / executable, os.X_OK):
        raise SigningError("bundle executable is not executable")
    sdk = validate_build_metadata(info, platform)
    validate_macho_target(
        bundle / executable, platform, executable=True, expected_sdk=sdk
    )
    expected_platform = "iPhoneOS" if platform == "ios" else "AppleTVOS"
    if info.get("CFBundleSupportedPlatforms") != [expected_platform]:
        raise SigningError(
            f"release bundle must target {expected_platform}, not a simulator or another platform"
        )
    if set(info.get("UIDeviceFamily", [])) != ({1, 2} if platform == "ios" else {3}):
        raise SigningError(
            "release bundle UIDeviceFamily does not cover its intended devices"
        )
    privacy = read_plist(bundle / "PrivacyInfo.xcprivacy")
    if "NSPrivacyTracking" not in privacy:
        raise SigningError("PrivacyInfo.xcprivacy is missing NSPrivacyTracking")
    if extension:
        if info.get("CFBundlePackageType") != "XPC!":
            raise SigningError("TopShelf extension must have CFBundlePackageType XPC!")
        point = info.get("NSExtension", {}).get("NSExtensionPointIdentifier")
        if point != "com.apple.tv-top-shelf":
            raise SigningError(
                "TopShelf extension has an invalid NSExtensionPointIdentifier"
            )
        return info
    if info.get("CFBundlePackageType") != "APPL":
        raise SigningError("release bundle CFBundlePackageType must be APPL")
    if platform == "ios":
        for field in ("CFBundleIcons", "CFBundleIcons~ipad"):
            icon = info.get(field, {}).get("CFBundlePrimaryIcon", {})
            files = icon.get("CFBundleIconFiles", [])
            compiled = (
                bool(icon.get("CFBundleIconName")) and (bundle / "Assets.car").is_file()
            )
            loose = bool(files) and all(
                any(bundle.glob(f"{Path(name).stem}*.png")) for name in files
            )
            if not compiled and not loose:
                raise SigningError(
                    f"release bundle is missing packaged icons for {field}"
                )
    else:
        primary_icon = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon")
        top_shelf = info.get("TVTopShelfImage", {})
        if (
            not (bundle / "Assets.car").is_file()
            or not isinstance(primary_icon, str)
            or not primary_icon
            or not isinstance(top_shelf, dict)
            or any(
                not isinstance(top_shelf.get(role), str) or not top_shelf[role]
                for role in ("TVTopShelfPrimaryImage", "TVTopShelfPrimaryImageWide")
            )
        ):
            raise SigningError(
                "tvOS release requires compiled app icon and Top Shelf assets with their plist roles"
            )
    return info


def validate_tree(app: Path) -> list[Path]:
    binaries = []
    for path in app.rglob("*"):
        if path.is_symlink():
            raise SigningError("symlinks in iOS/tvOS bundles are unsupported")
        if path.is_dir() and path.suffix in {".app", ".xctest"}:
            raise SigningError(
                f"unsupported nested code bundle: {path.relative_to(app)}"
            )
        if path.is_file():
            with path.open("rb") as handle:
                if handle.read(4) in MACHO_MAGICS:
                    binaries.append(path)
    return binaries


def macho_slices(data: bytes) -> list[bytes]:
    if data[:4] in {b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}:
        endian = ">" if data[:4] == b"\xca\xfe\xba\xbe" else "<"
        count = struct.unpack_from(endian + "I", data, 4)[0]
        if count < 1 or count > 16 or 8 + count * 20 > len(data):
            raise SigningError("invalid fat Mach-O architecture table")
        result = []
        for index in range(count):
            _, _, offset, size, _ = struct.unpack_from(
                endian + "IIIII", data, 8 + index * 20
            )
            if offset < 8 + count * 20 or size < 32 or offset + size > len(data):
                raise SigningError("invalid fat Mach-O architecture bounds")
            result.append(data[offset : offset + size])
        return result
    return [data]


def validate_macho_target(
    path: Path,
    platform: str,
    *,
    executable: bool = False,
    expected_sdk: int | None = None,
) -> None:
    try:
        for data in macho_slices(path.read_bytes()):
            if data[:4] != b"\xcf\xfa\xed\xfe":
                raise SigningError("release binaries must use the arm64 Mach-O format")
            cpu, _, filetype, ncmds, command_size = struct.unpack_from("<5I", data, 4)
            if cpu != 0x100000C or (executable and filetype != 2):
                raise SigningError(
                    "release app/extension must contain an arm64 executable"
                )
            offset = 32
            platforms = set()
            sdks = set()
            for _ in range(ncmds):
                command, size = struct.unpack_from("<II", data, offset)
                if size < 8 or offset + size > 32 + command_size:
                    raise SigningError("invalid Mach-O load command")
                if command == 0x32:
                    platforms.add(struct.unpack_from("<I", data, offset + 8)[0])
                    sdks.add(struct.unpack_from("<I", data, offset + 16)[0])
                elif command in {0x25, 0x2F}:
                    platforms.add(2 if command == 0x25 else 3)
                    sdks.add(struct.unpack_from("<I", data, offset + 12)[0])
                offset += size
            if platforms != ({2} if platform == "ios" else {3}):
                raise SigningError(
                    f"Mach-O binary does not target physical {platform} devices"
                )
            if expected_sdk is not None and sdks != {expected_sdk}:
                raise SigningError(
                    "Mach-O SDK version does not match bundle DTPlatformVersion"
                )
    except struct.error as exc:
        raise SigningError("malformed Mach-O executable") from exc


def der_entitlements(value: object) -> bytes:
    def tlv(tag: int, body: bytes) -> bytes:
        length = len(body)
        if length < 128:
            encoded_length = bytes([length])
        else:
            raw = length.to_bytes((length.bit_length() + 7) // 8, "big")
            encoded_length = bytes([0x80 | len(raw)]) + raw
        return bytes([tag]) + encoded_length + body

    def encode(item: object) -> bytes:
        if isinstance(item, bool):
            return tlv(1, b"\xff" if item else b"\x00")
        if isinstance(item, str):
            return tlv(0x0C, item.encode())
        if isinstance(item, list):
            return tlv(0x30, b"".join(encode(child) for child in item))
        if isinstance(item, dict):
            return tlv(
                0xB0,
                b"".join(
                    tlv(0x30, encode(key) + encode(item[key])) for key in sorted(item)
                ),
            )
        raise SigningError("unsupported DER entitlement type")

    return tlv(0x70, b"\x02\x01\x01" + encode(value))


def signature_slots(data: bytes) -> tuple[dict[int, bytes], int]:
    if data[:4] not in {
        b"\xcf\xfa\xed\xfe",
        b"\xce\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf",
        b"\xfe\xed\xfa\xce",
    }:
        raise SigningError("unsupported Mach-O format")
    endian = "<" if data[0] in {0xCF, 0xCE} else ">"
    ncmds = struct.unpack_from(endian + "I", data, 16)[0]
    offset = 32 if data[:4] in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"} else 28
    for _ in range(ncmds):
        command, size = struct.unpack_from(endian + "II", data, offset)
        if size < 8:
            raise SigningError("invalid Mach-O load command")
        if command == 0x1D:
            start, length = struct.unpack_from(endian + "II", data, offset + 8)
            blob = data[start : start + length]
            magic, declared, count = struct.unpack_from(">III", blob)
            if magic != 0xFADE0CC0 or declared > len(blob):
                raise SigningError("invalid embedded code signature")
            slots = {}
            for index in range(count):
                slot, position = struct.unpack_from(">II", blob, 12 + index * 8)
                blob_length = struct.unpack_from(">I", blob, position + 4)[0]
                if blob_length < 8 or position + blob_length > declared:
                    raise SigningError("invalid code signature slot")
                slots[slot] = blob[position : position + blob_length]
            return slots, start
        offset += size
    raise SigningError("Mach-O binary is missing its code signature")


def verify_binary(
    path: Path,
    cert_path: Path,
    team_id: str,
    work: Path,
    *,
    bundle: Path | None = None,
    expected_entitlements: dict | None = None,
) -> None:
    for index, data in enumerate(macho_slices(path.read_bytes())):
        try:
            slots, signature_offset = signature_slots(data)
            directory = slots[0]
            (
                magic,
                _,
                version,
                flags,
                hash_offset,
                _,
                special_count,
                code_count,
                code_limit,
            ) = struct.unpack_from(">9I", directory)
            hash_size, hash_type, _, page_power = struct.unpack_from(
                "4B", directory, 36
            )
            if (
                magic != 0xFADE0C02
                or flags & 2
                or hash_type != 2
                or hash_size != 32
                or version < 0x20200
            ):
                raise SigningError(
                    "release requires a certificate-backed SHA256 code signature with team identifier"
                )
            team_offset = struct.unpack_from(">I", directory, 48)[0]
            team = directory[team_offset:].split(b"\0", 1)[0].decode()
            if team != team_id or code_limit != signature_offset or page_power > 20:
                raise SigningError(
                    "signed binary team or code limit does not match release"
                )
            page_size = 1 << page_power
            if code_count != (code_limit + page_size - 1) // page_size:
                raise SigningError("signed binary page count is invalid")
            for page in range(code_count):
                digest = hashlib.sha256(
                    data[page * page_size : min((page + 1) * page_size, code_limit)]
                ).digest()
                if (
                    digest
                    != directory[
                        hash_offset + page * hash_size : hash_offset
                        + (page + 1) * hash_size
                    ]
                ):
                    raise SigningError("signed binary page hash verification failed")
            special = {2: slots.get(2), 5: slots.get(5), 7: slots.get(7)}
            if bundle:
                special.update(
                    {
                        1: (bundle / "Info.plist").read_bytes(),
                        3: (bundle / "_CodeSignature/CodeResources").read_bytes(),
                    }
                )
            for slot, content in special.items():
                if content is not None and (
                    special_count < slot
                    or hashlib.sha256(content).digest()
                    != directory[
                        hash_offset - slot * hash_size : hash_offset
                        - (slot - 1) * hash_size
                    ]
                ):
                    raise SigningError(
                        "signed binary special slot hash verification failed"
                    )
            if expected_entitlements is not None:
                if (
                    5 not in slots
                    or 7 not in slots
                    or plistlib.loads(slots[5][8:]) != expected_entitlements
                ):
                    raise SigningError(
                        "signed bundle must contain matching distribution XML and DER entitlements"
                    )
                if slots[7][8:] != der_entitlements(expected_entitlements):
                    raise SigningError(
                        "distribution DER entitlements do not match the provisioning profile"
                    )
            cms = slots[0x10000]
            if struct.unpack_from(">I", cms)[0] != 0xFADE0B01:
                raise SigningError("missing certificate-backed CMS signature")
            cms_path = write_private(work / f"verify-{index}.cms", cms[8:])
            cd_path = write_private(work / f"verify-{index}.cd", directory)
            run(
                [
                    "openssl",
                    "cms",
                    "-verify",
                    "-binary",
                    "-inform",
                    "DER",
                    "-in",
                    str(cms_path),
                    "-content",
                    str(cd_path),
                    "-nointern",
                    "-certfile",
                    str(cert_path),
                    "-noverify",
                ],
                "Mach-O distribution CMS verification",
            )
        except (KeyError, struct.error, UnicodeError, ValueError) as exc:
            raise SigningError(f"invalid signature in {path.name}") from exc


def verify_resources(bundle: Path) -> None:
    resources = read_plist(bundle / "_CodeSignature/CodeResources")
    files = resources.get("files2", {})
    if not files:
        raise SigningError("signed bundle has an empty resource seal")
    for name, value in files.items():
        path = bundle / name
        if not path.resolve().is_relative_to(bundle.resolve()) or not path.is_file():
            raise SigningError(
                "signed bundle resource seal references a missing or unsafe resource"
            )
        digest = value.get("hash2") if isinstance(value, dict) else None
        if digest is None or hashlib.sha256(path.read_bytes()).digest() != digest:
            raise SigningError(f"signed bundle resource hash mismatch: {name}")
    executable = read_plist(bundle / "Info.plist")["CFBundleExecutable"]
    for path in bundle.rglob("*"):
        if not path.is_file():
            continue
        name = path.relative_to(bundle).as_posix()
        if (
            name in {"Info.plist", "PkgInfo", executable}
            or "_CodeSignature" in path.relative_to(bundle).parts
        ):
            continue
        if name not in files:
            raise SigningError(f"signed bundle has an unsealed resource: {name}")


def package_ipa(app: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{output.name}.", suffix=".tmp", dir=output.parent
    )
    os.close(descriptor)
    try:
        with zipfile.ZipFile(
            temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
        ) as archive:
            for path in sorted(app.rglob("*")):
                if path.is_file():
                    archive.write(
                        path, f"Payload/{app.name}/{path.relative_to(app).as_posix()}"
                    )
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise SigningError("IPA archive integrity verification failed")
            if not archive.getinfo(f"Payload/{app.name}/Info.plist"):
                raise SigningError("IPA is missing its app bundle")
        os.replace(temporary, output)
    finally:
        Path(temporary).unlink(missing_ok=True)


def sign(args: argparse.Namespace) -> None:
    if not shutil.which("openssl"):
        raise SigningError("required command not found: openssl")
    private_tools = Path(
        os.environ.get(
            "BRUTV_SIGNING_TOOLS_DIR",
            str(Path(__file__).resolve().parent / "build/tools"),
        )
    ).expanduser()
    private_signer = private_tools / "bin/zsign"
    signer = os.environ.get("IOS_ZSIGN") or (
        str(private_signer) if private_signer.is_file() else "zsign"
    )
    signer = shutil.which(signer)
    if signer is None:
        raise SigningError(
            "required Linux distribution signer not found: run setup-zsign.sh or set IOS_ZSIGN to its executable"
        )
    signer = str(Path(signer).resolve())
    if args.platform == "tvos" and b"-brutv1" not in run(
        [signer, "--version"], "zsign version check"
    ):
        raise SigningError(
            "tvOS requires per-profile entitlement support; run setup-zsign.sh to install the patched signer"
        )
    prefix = args.platform.upper()
    team_id = os.environ.get(
        f"{prefix}_TEAM_ID", os.environ.get("IOS_TEAM_ID", "83BXSDT7QC")
    )
    bundle_id = os.environ.get(
        f"{prefix}_BUNDLE_ID", os.environ.get("IOS_BUNDLE_ID", "com.bvolpato.brutv")
    )
    topshelf_id = os.environ.get("TVOS_TOPSHELF_BUNDLE_ID", f"{bundle_id}.TopShelf")
    with tempfile.TemporaryDirectory(prefix="brutv-distribution-") as temporary:
        work = Path(temporary)
        certificate_input = credentials_file("IOS", "CERTIFICATE", work)
        certificate, key_path, cert_path = load_identity(
            certificate_input, team_id, work
        )
        roots = apple_roots(work)
        profile_path = credentials_file(prefix, "PROVISIONING_PROFILE", work)
        profile = decode_profile(profile_path, roots)
        allowed = validate_profile(
            profile, bundle_id, team_id, args.platform, certificate
        )
        source_root = Path(__file__).resolve().parent
        default_entitlements = (
            source_root
            / "BruTV"
            / (
                "BruTV.entitlements"
                if args.platform == "ios"
                else "BruTV-tvOS.entitlements"
            )
        )
        requested_path = getattr(args, "entitlements", None) or Path(
            os.environ.get(f"{prefix}_ENTITLEMENTS_PATH", str(default_entitlements))
        )
        entitlements = resolve_entitlements(
            allowed, read_plist(requested_path), bundle_id, team_id
        )
        profiles = [(bundle_id, profile_path, entitlements)]
        if args.platform == "tvos":
            extension_profile_path = credentials_file(
                "TVOS_TOPSHELF", "PROVISIONING_PROFILE", work
            )
            extension_profile = decode_profile(extension_profile_path, roots)
            extension_allowed = validate_profile(
                extension_profile, topshelf_id, team_id, args.platform, certificate
            )
            extension_requested_path = getattr(
                args, "extension_entitlements", None
            ) or Path(
                os.environ.get(
                    "TVOS_TOPSHELF_ENTITLEMENTS_PATH",
                    str(source_root / "BruTVTopShelf/BruTVTopShelf.entitlements"),
                )
            )
            extension_entitlements = resolve_entitlements(
                extension_allowed,
                read_plist(extension_requested_path),
                topshelf_id,
                team_id,
            )
            profiles.append(
                (topshelf_id, extension_profile_path, extension_entitlements)
            )
        if args.preflight:
            print(
                f"Validated {args.platform} App Store distribution credentials and zsign availability"
            )
            return
        if args.app is None or args.output is None:
            raise SigningError(
                "--app and --output are required unless --preflight is used"
            )
        source = args.app.expanduser().resolve()
        if source.suffix != ".app" or not source.is_dir():
            raise SigningError("--app must point to the unsigned xtool .app directory")
        app = work / "Payload" / source.name
        shutil.copytree(source, app, symlinks=True)
        bundle_info(app, bundle_id, args.platform)
        validate_tree(app)
        nested = list(app.rglob("*.appex"))
        if args.platform == "ios" and nested:
            raise SigningError(
                "iOS extensions require separate profiles and are not configured for BruTV"
            )
        bundles = [(app, entitlements)]
        if args.platform == "tvos":
            if len(nested) != 1 or nested[0].parent != app / "PlugIns":
                raise SigningError(
                    "tvOS release requires exactly one TopShelf extension under PlugIns"
                )
            info = bundle_info(nested[0], topshelf_id, args.platform, extension=True)
            main_info = read_plist(app / "Info.plist")
            if any(
                info.get(key) != main_info.get(key)
                for key in ("CFBundleVersion", "CFBundleShortVersionString")
            ):
                raise SigningError("TopShelf extension version must match the app")
            group = "group.com.bvolpato.brutv"
            if any(
                group not in item.get("com.apple.security.application-groups", [])
                for _, _, item in profiles
            ):
                raise SigningError(
                    f"tvOS app and TopShelf profiles must authorize shared app group {group}"
                )
            bundles.append((nested[0], profiles[1][2]))
        command = [signer, "-q", "-f", "-2", "-k", str(key_path)]
        for identifier, path, claims in profiles:
            claims_path = write_private(
                work / f"{identifier}.entitlements", plistlib.dumps(claims)
            )
            command.extend(["-m", str(path), "-e", str(claims_path)])
        command.append(str(app))
        # The temporary P12 avoids putting the original password in argv.
        run(command, "zsign distribution signing", cwd=work)
        for bundle, expected in reversed(bundles):
            embedded = decode_profile(bundle / "embedded.mobileprovision", roots)
            expected_id = read_plist(bundle / "Info.plist")["CFBundleIdentifier"]
            validate_profile(embedded, expected_id, team_id, args.platform, certificate)
            verify_resources(bundle)
            executable = read_plist(bundle / "Info.plist")["CFBundleExecutable"]
            verify_binary(
                bundle / executable,
                cert_path,
                team_id,
                work,
                bundle=bundle,
                expected_entitlements=expected,
            )
        bundle_executables = {
            bundle / read_plist(bundle / "Info.plist")["CFBundleExecutable"]
            for bundle, _ in bundles
        }
        for binary in validate_tree(app):
            validate_macho_target(binary, args.platform)
            if binary not in bundle_executables:
                owner = (
                    binary.parent
                    if (binary.parent / "Info.plist").is_file()
                    and binary.parent.suffix == ".framework"
                    else None
                )
                if owner:
                    verify_resources(owner)
                verify_binary(binary, cert_path, team_id, work, bundle=owner)
        package_ipa(app, args.output.expanduser().resolve())
        print(f"Signed and verified {args.platform} App Store IPA: {args.output}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="unsigned xtool app bundle")
    parser.add_argument("--output", type=Path, help="output App Store IPA")
    parser.add_argument("--platform", choices=("ios", "tvos"), default="ios")
    parser.add_argument(
        "--entitlements",
        type=Path,
        help="requested app entitlements plist (default: platform source entitlements)",
    )
    parser.add_argument(
        "--extension-entitlements",
        type=Path,
        help="requested TopShelf entitlements plist (default: source entitlements)",
    )
    parser.add_argument(
        "--preflight",
        action="store_true",
        help="validate release credentials and signer before building",
    )
    args = parser.parse_args()
    try:
        sign(args)
    except (SigningError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
