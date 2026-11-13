#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["cryptography>=44,<47"]
# ///
"""Sign a Catalyst app and build its Mac App Store product archive on Linux."""

import argparse
import base64
import gzip
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
import xml.etree.ElementTree as ET
import zlib
from datetime import UTC, datetime
from pathlib import Path

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.serialization import pkcs7, pkcs12
from cryptography.x509.oid import NameOID, ObjectIdentifier

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
SCRIPT_DIR = Path(__file__).resolve().parent


class ReleaseError(Exception):
    pass


def run(command, **kwargs):
    result = subprocess.run(command, check=False, capture_output=True, **kwargs)
    if result.returncode:
        message = result.stderr.decode(errors="replace").strip()
        raise ReleaseError(f"{Path(command[0]).name} failed: {message}")
    return result.stdout


def tool(name):
    private = (
        Path(os.environ.get("BRUTV_MAC_TOOLS_DIR", SCRIPT_DIR / "build/tools"))
        / "bin"
        / name
    )
    value = os.environ.get(name.upper(), str(private) if private.is_file() else name)
    path = shutil.which(value)
    if not path:
        raise ReleaseError(
            f"required command not found: {value}; set {name.upper()} to its executable path"
        )
    return path


def private_file(path, data):
    with path.open("xb") as stream:
        path.chmod(0o600)
        stream.write(data)
    return path


def signing_input(prefix, suffix, directory):
    path_value = os.environ.get(f"{prefix}_PATH")
    base64_value = os.environ.get(f"{prefix}_BASE64")
    if path_value and base64_value:
        raise ReleaseError(f"set only one of {prefix}_PATH and {prefix}_BASE64")
    if path_value:
        path = Path(path_value).expanduser().resolve()
        if not path.is_file():
            raise ReleaseError(f"{prefix}_PATH does not name a file")
        return path
    if base64_value:
        try:
            data = base64.b64decode("".join(base64_value.split()), validate=True)
        except ValueError as exc:
            raise ReleaseError(f"{prefix}_BASE64 is invalid base64") from exc
        return private_file(directory / f"{prefix}{suffix}", data)
    raise ReleaseError(f"set {prefix}_PATH or {prefix}_BASE64")


def root_ca_file(directory):
    override = os.environ.get("MACOS_APPLE_ROOT_CA_PATH")
    if override:
        path = Path(override).expanduser().resolve()
        if not path.is_file():
            raise ReleaseError(
                "MACOS_APPLE_ROOT_CA_PATH does not name a PEM root CA file"
            )
        return path
    certificates = []
    for url, expected in APPLE_ROOTS:
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read(1024 * 1024)
        if hashlib.sha256(data).hexdigest() != expected:
            raise ReleaseError("Apple root certificate checksum mismatch")
        certificates.append(
            x509.load_der_x509_certificate(data).public_bytes(
                serialization.Encoding.PEM
            )
        )
    return private_file(directory / "apple-roots.pem", b"".join(certificates))


def load_identity(path, password_name, kind, directory):
    if password_name not in os.environ:
        raise ReleaseError(
            f"set {password_name}; an empty value is permitted for an unencrypted P12"
        )
    try:
        key, cert, chain = pkcs12.load_key_and_certificates(
            path.read_bytes(), os.environ[password_name].encode()
        )
    except ValueError as exc:
        raise ReleaseError(
            f"cannot open {kind} P12; check its password and PKCS12 format"
        ) from exc
    if key is None or cert is None:
        raise ReleaseError(f"{kind} P12 must contain a private key and its certificate")
    now = datetime.now(UTC)
    if not cert.not_valid_before_utc <= now < cert.not_valid_after_utc:
        raise ReleaseError(f"{kind} signing certificate is not currently valid")
    extensions = {extension.oid.dotted_string for extension in cert.extensions}
    if kind == "application":
        if "1.2.840.113635.100.6.1.7" not in extensions:
            raise ReleaseError(
                "application certificate must be Apple Distribution or Mac App Distribution; Developer ID and development certificates cannot release to the Mac App Store"
            )
    else:
        try:
            usage = cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value
        except x509.ExtensionNotFound as exc:
            raise ReleaseError(
                "installer certificate is missing its Mac Installer Distribution extended key usage"
            ) from exc
        # Apple WWDR CPS 4.11.6 identifies third-party installer submissions.
        if (
            ObjectIdentifier("1.2.840.113635.100.4.9") not in usage
            or "1.2.840.113635.100.6.1.8" not in extensions
        ):
            raise ReleaseError(
                "installer certificate must be Mac Installer Distribution (3rd Party Mac Developer Installer), not Developer ID Installer"
            )
    teams = cert.subject.get_attributes_for_oid(NameOID.ORGANIZATIONAL_UNIT_NAME)
    if len(teams) != 1:
        raise ReleaseError(
            f"{kind} signing certificate has no unambiguous team identifier"
        )
    # rcodesign reads an owner-only PEM file so no password is exposed in argv.
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    pem += cert.public_bytes(serialization.Encoding.PEM)
    pem += b"".join(
        item.public_bytes(serialization.Encoding.PEM) for item in chain or []
    )
    return cert, teams[0].value, private_file(directory / f"{kind}.pem", pem)


def read_profile(path, roots):
    with tempfile.TemporaryDirectory(prefix="brutv-mac-profile-") as temporary:
        signer_path = Path(temporary) / "signer.pem"
        content = run(
            [
                tool("openssl"),
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
                "-signer",
                str(signer_path),
            ]
        )
        signers = x509.load_pem_x509_certificates(signer_path.read_bytes())
        if len(signers) != 1:
            raise ReleaseError("Mac profile signing requires one verified signer")
        signer = signers[0]
        try:
            signer.extensions.get_extension_for_oid(
                ObjectIdentifier("1.2.840.113635.100.4.11")
            )
            usage = signer.extensions.get_extension_for_class(x509.KeyUsage).value
            if not usage.digital_signature:
                raise ReleaseError("Mac profile signing certificate cannot sign")
        except x509.ExtensionNotFound as exc:
            raise ReleaseError(
                "Mac profile signing certificate has the wrong purpose"
            ) from exc
        # Apple's SecPolicyCreateOSXProvisioningProfileSigning additionally pins
        # the issuing WWDR CA marker. Generic Apple-root trust is insufficient.
        issuer = None
        for candidate in pkcs7.load_der_pkcs7_certificates(path.read_bytes()):
            if candidate.subject != signer.issuer:
                continue
            try:
                candidate.extensions.get_extension_for_oid(
                    ObjectIdentifier("1.2.840.113635.100.6.2.1")
                )
                signer.verify_directly_issued_by(candidate)
                issuer = candidate
                break
            except (x509.ExtensionNotFound, InvalidSignature, ValueError):
                continue
        if issuer is None:
            raise ReleaseError(
                "Mac profile signing certificate does not chain through the WWDR signing CA"
            )
    try:
        return plistlib.loads(content)
    except (plistlib.InvalidFileException, ValueError) as exc:
        raise ReleaseError(
            "Mac provisioning profile is not a CMS-signed property list"
        ) from exc


def has_wildcard(value):
    if isinstance(value, str):
        return "*" in value
    if isinstance(value, list):
        return any(has_wildcard(item) for item in value)
    if isinstance(value, dict):
        return any(has_wildcard(item) for item in value.values())
    return False


def profile_authorizes(allowed, requested):
    if type(allowed) is not type(requested):
        return False
    if isinstance(requested, str):
        if "*" not in allowed:
            return requested == allowed
        return (
            allowed.endswith("*")
            and allowed.count("*") == 1
            and requested.startswith(allowed[:-1])
        )
    if isinstance(requested, list):
        return all(
            any(profile_authorizes(grant, item) for grant in allowed)
            for item in requested
        )
    if isinstance(requested, dict):
        return all(
            name in allowed and profile_authorizes(allowed[name], value)
            for name, value in requested.items()
        )
    return requested == allowed


def distribution_entitlements(profile, cert, team, bundle_id, requested):
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime) or expiry.replace(tzinfo=UTC) <= datetime.now(
        UTC
    ):
        raise ReleaseError(
            "Mac provisioning profile has expired or has no expiration date"
        )
    if "OSX" not in profile.get("Platform", []):
        raise ReleaseError(
            "Mac Catalyst needs a Mac App Store provisioning profile with Platform OSX"
        )
    if profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
        raise ReleaseError(
            "Mac provisioning profile must be App Store distribution, not development or direct distribution"
        )
    if profile.get("TeamIdentifier") != [team]:
        raise ReleaseError(
            "Mac provisioning profile and signing certificates belong to different teams"
        )
    if cert.public_bytes(serialization.Encoding.DER) not in profile.get(
        "DeveloperCertificates", []
    ):
        raise ReleaseError(
            "Mac provisioning profile does not authorize the application signing certificate"
        )
    allowed = profile.get("Entitlements", {})
    if allowed.get("get-task-allow") or allowed.get(
        "com.apple.security.get-task-allow"
    ):
        raise ReleaseError(
            "Mac provisioning profile enables debugger access; use App Store distribution"
        )
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    identifiers = ("com.apple.application-identifier", "application-identifier")
    app_id = f"{prefixes[0]}.{bundle_id}" if len(prefixes) == 1 else None
    profile_ids = [allowed[name] for name in identifiers if name in allowed]
    if not app_id or not profile_ids or any(value != app_id for value in profile_ids):
        raise ReleaseError(
            "Mac App Store profile must explicitly match the app bundle identifier"
        )
    for name in identifiers:
        if name in requested and requested[name] != app_id:
            raise ReleaseError(f"requested {name} does not match the app identifier")
    if (
        "com.apple.developer.team-identifier" in allowed
        and allowed["com.apple.developer.team-identifier"] != team
    ):
        raise ReleaseError(
            "profile entitlement team identifier does not match its team"
        )
    result = dict(requested)
    if result.get("com.apple.security.app-sandbox") is not True:
        raise ReleaseError(
            "Mac App Store release requires com.apple.security.app-sandbox=true"
        )
    if result.get("get-task-allow") or result.get("com.apple.security.get-task-allow"):
        raise ReleaseError("release entitlements must not enable debugger access")
    for name, value in requested.items():
        if has_wildcard(value):
            raise ReleaseError(f"signed entitlement {name} must not contain wildcards")
        # TN3125 permits macOS sandbox and hardened runtime entitlements without
        # profile grants. All other requested capabilities use its allowlist.
        if name in identifiers or name.startswith("com.apple.security."):
            continue
        if name not in allowed or not profile_authorizes(allowed[name], value):
            raise ReleaseError(
                f"Mac provisioning profile does not authorize entitlement {name}"
            )
    for name in identifiers:
        result[name] = app_id
    result["com.apple.developer.team-identifier"] = team
    return result


def macho_slices(data):
    if data[:4] == b"\xca\xfe\xba\xbe":
        count = struct.unpack_from(">I", data, 4)[0]
        if count > 16 or len(data) < 8 + count * 20:
            raise ReleaseError("invalid universal Mach-O header")
        return [
            data[offset : offset + size]
            for _, _, offset, size, _ in (
                struct.unpack_from(">IIIII", data, 8 + index * 20)
                for index in range(count)
            )
        ]
    return [data]


def validate_app(app, bundle_id):
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != bundle_id:
            raise ReleaseError(
                "Catalyst app bundle identifier does not match --bundle-id"
            )
        if info.get("CFBundleSupportedPlatforms") != ["MacOSX"]:
            raise ReleaseError(
                "Catalyst Info.plist must declare CFBundleSupportedPlatforms=[MacOSX]"
            )
        if not isinstance(info.get("LSMinimumSystemVersion"), str) or not re.fullmatch(
            r"\d+\.\d+(?:\.\d+)?", info["LSMinimumSystemVersion"]
        ):
            raise ReleaseError(
                "Catalyst Info.plist has an invalid LSMinimumSystemVersion"
            )
        for name in (
            "DTPlatformName",
            "DTPlatformVersion",
            "DTPlatformBuild",
            "DTSDKName",
            "DTSDKBuild",
            "DTXcode",
            "DTXcodeBuild",
        ):
            if (
                not isinstance(info.get(name), str)
                or not info[name]
                or "$(" in info[name]
            ):
                raise ReleaseError(
                    f"Catalyst Info.plist is missing recorded SDK provenance {name}"
                )
        if (
            info["DTPlatformName"] != "macosx"
            or info["DTSDKName"] != f"macosx{info['DTPlatformVersion']}"
            or info["DTSDKBuild"] != info["DTPlatformBuild"]
        ):
            raise ReleaseError("Catalyst SDK provenance fields are inconsistent")
        if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", info["DTPlatformVersion"]):
            raise ReleaseError("Catalyst SDK version is invalid")
        sdk_parts = [int(part) for part in info["DTPlatformVersion"].split(".")]
        sdk_parts += [0] * (3 - len(sdk_parts))
        if sdk_parts[0] > 65535 or any(part > 255 for part in sdk_parts[1:]):
            raise ReleaseError("Catalyst SDK version is outside Mach-O version bounds")
        expected_sdk = (sdk_parts[0] << 16) | (sdk_parts[1] << 8) | sdk_parts[2]
        for name in (
            "CFBundleVersion",
            "CFBundleShortVersionString",
            "CFBundleExecutable",
        ):
            if not isinstance(info.get(name), str) or not info[name]:
                raise ReleaseError(f"Catalyst Info.plist is missing {name}")
        executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
        if executable.parent != app / "Contents/MacOS" or not os.access(
            executable, os.X_OK
        ):
            raise ReleaseError("Catalyst app executable is missing or not executable")
        architectures = set()
        for data in macho_slices(executable.read_bytes()):
            if data[:4] != b"\xcf\xfa\xed\xfe" or len(data) < 32:
                raise ReleaseError(
                    "Catalyst app executable is not a 64-bit Mach-O binary"
                )
            architectures.add(struct.unpack_from("<I", data, 4)[0])
            ncmds = struct.unpack_from("<I", data, 16)[0]
            offset, platforms, sdk_versions = 32, [], []
            for _ in range(ncmds):
                command, size = struct.unpack_from("<II", data, offset)
                if size < 8 or offset + size > len(data):
                    raise ReleaseError("invalid Mach-O load command")
                if command == 0x32:
                    platforms.append(struct.unpack_from("<I", data, offset + 8)[0])
                    sdk_versions.append(struct.unpack_from("<I", data, offset + 16)[0])
                offset += size
            if platforms != [6]:
                raise ReleaseError(
                    "all Mac app architectures must target Mac Catalyst (Mach-O platform 6)"
                )
            if sdk_versions != [expected_sdk]:
                raise ReleaseError(
                    "Catalyst Mach-O SDK version does not match recorded SDK provenance"
                )
        if architectures != {0x01000007, 0x0100000C}:
            raise ReleaseError(
                "Mac release parity requires both x86_64 and arm64 Catalyst architectures"
            )
        return info
    except (OSError, plistlib.InvalidFileException, struct.error) as exc:
        raise ReleaseError(f"invalid Catalyst application bundle: {exc}") from exc


def validate_special_resource_slots(code_directory, info_bytes, resources_bytes):
    try:
        magic, length = struct.unpack_from(">II", code_directory)
        hash_offset = struct.unpack_from(">I", code_directory, 16)[0]
        special_slots = struct.unpack_from(">I", code_directory, 24)[0]
        hash_size, hash_type = struct.unpack_from(">BB", code_directory, 36)
        if (
            magic != 0xFADE0C02
            or length != len(code_directory)
            or hash_size != 32
            or hash_type != 2
        ):
            raise ReleaseError("Catalyst release requires a SHA-256 code directory")
        for slot, content, name in (
            (1, info_bytes, "Info.plist"),
            (3, resources_bytes, "CodeResources"),
        ):
            start = hash_offset - slot * hash_size
            if (
                special_slots < slot
                or start < 0
                or code_directory[start : start + hash_size]
                != hashlib.sha256(content).digest()
            ):
                raise ReleaseError(f"Catalyst {name} code signature seal is invalid")
    except struct.error as exc:
        raise ReleaseError("malformed Catalyst code directory") from exc


def validate_resource_files(app, info, resources_bytes):
    contents = app / "Contents"
    try:
        resources = plistlib.loads(resources_bytes)["files2"]
        if not isinstance(resources, dict):
            raise ReleaseError("Catalyst CodeResources files2 is not a dictionary")
        for name, seal in resources.items():
            relative = Path(name)
            if (
                relative.is_absolute()
                or ".." in relative.parts
                or not isinstance(seal, dict)
            ):
                raise ReleaseError(
                    "Catalyst resource seal has an invalid path or metadata"
                )
            path = contents / relative
            if path.is_symlink():
                if seal.get("symlink") != os.readlink(
                    path
                ) or not path.resolve().is_relative_to(app.resolve()):
                    raise ReleaseError(
                        f"Catalyst resource symlink seal is invalid: {name}"
                    )
            elif "hash2" in seal:
                if (
                    not path.is_file()
                    or hashlib.sha256(path.read_bytes()).digest() != seal["hash2"]
                ):
                    raise ReleaseError(
                        f"Catalyst resource signature seal is invalid: {name}"
                    )
            else:
                raise ReleaseError(
                    f"Catalyst resource seal requires unsupported nested code validation: {name}"
                )
        excluded = {"Info.plist", "PkgInfo", f"MacOS/{info['CFBundleExecutable']}"}
        for path in contents.rglob("*"):
            name = path.relative_to(contents).as_posix()
            if (
                (path.is_file() or path.is_symlink())
                and name not in excluded
                and not name.startswith("_CodeSignature/")
                and name not in resources
            ):
                raise ReleaseError(
                    f"Catalyst app contains an unsealed resource: {name}"
                )
    except (KeyError, OSError, plistlib.InvalidFileException) as exc:
        raise ReleaseError(f"invalid Catalyst resource signature: {exc}") from exc


def validate_signed_app(app, info, certificate, entitlements, roots, directory):
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    info_bytes = (app / "Contents/Info.plist").read_bytes()
    resources_bytes = (app / "Contents/_CodeSignature/CodeResources").read_bytes()
    run([tool("rcodesign"), "-C", "/dev/null", "verify", str(executable)])
    for index, data in enumerate(macho_slices(executable.read_bytes())):
        offset = 32
        signature = None
        for _ in range(struct.unpack_from("<I", data, 16)[0]):
            command, size = struct.unpack_from("<II", data, offset)
            if command == 0x1D:
                start, length = struct.unpack_from("<II", data, offset + 8)
                signature = data[start : start + length]
            offset += size
        if signature is None:
            raise ReleaseError(
                "signed Catalyst executable is missing LC_CODE_SIGNATURE"
            )
        blobs = {}
        for item in range(struct.unpack_from(">I", signature, 8)[0]):
            slot, start = struct.unpack_from(">II", signature, 12 + item * 8)
            length = struct.unpack_from(">I", signature, start + 4)[0]
            blobs[slot] = signature[start : start + length]
        validate_special_resource_slots(blobs[0], info_bytes, resources_bytes)
        if (
            5 not in blobs
            or 7 not in blobs
            or plistlib.loads(blobs[5][8:]) != entitlements
        ):
            raise ReleaseError(
                "Catalyst executable is missing the requested XML or DER entitlements"
            )
        content = private_file(directory / f"app-{index}-code-directory", blobs[0])
        cms = private_file(directory / f"app-{index}-signature.der", blobs[0x10000][8:])
        signer_path = directory / f"app-{index}-signer.pem"
        run(
            [
                tool("openssl"),
                "cms",
                "-verify",
                "-binary",
                "-inform",
                "DER",
                "-in",
                str(cms),
                "-content",
                str(content),
                "-CAfile",
                str(roots),
                "-purpose",
                "any",
                *code_cms_extension_options(
                    cms,
                    roots,
                    {"1.2.840.113635.100.6.1.7", "1.2.840.113635.100.6.1.4"},
                ),
                "-signer",
                str(signer_path),
            ]
        )
        signer = x509.load_pem_x509_certificate(signer_path.read_bytes())
        if signer.public_bytes(serialization.Encoding.DER) != certificate.public_bytes(
            serialization.Encoding.DER
        ):
            raise ReleaseError(
                "Catalyst executable signature uses the wrong distribution certificate"
            )
    validate_resource_files(app, info, resources_bytes)


def code_cms_extension_options(cms, roots, markers):
    # OpenSSL cannot interpret Apple's critical role markers. Validate them
    # explicitly before permitting it to verify the signature and trust chain.
    standard = {"2.5.29.19", "2.5.29.15", "2.5.29.37"}
    certificates = pkcs7.load_der_pkcs7_certificates(cms.read_bytes())
    certificates.extend(x509.load_pem_x509_certificates(roots.read_bytes()))
    for certificate in certificates:
        try:
            is_ca = certificate.extensions.get_extension_for_class(
                x509.BasicConstraints
            ).value.ca
        except x509.ExtensionNotFound:
            is_ca = False
        for extension in certificate.extensions:
            if not extension.critical or extension.oid.dotted_string in standard:
                continue
            if (
                not is_ca
                and extension.oid.dotted_string in markers
                and isinstance(extension.value, x509.UnrecognizedExtension)
                and extension.value.value == b"\x05\x00"
            ):
                continue
            raise ReleaseError(
                f"unsupported critical code-signing certificate extension: {extension.oid.dotted_string}"
            )
    return ["-ignore_critical", "-no-CApath", "-no-CAstore"]


def xml_file(path, element):
    ET.indent(element)
    ET.ElementTree(element).write(path, encoding="utf-8", xml_declaration=True)


def build_product_archive(app, info, output, directory):
    payload_root = directory / "payload"
    payload_root.mkdir()
    shutil.copytree(app, payload_root / app.name, symlinks=True)
    component_name = f"{app.stem}.pkg"
    component = directory / component_name
    component.mkdir()
    files = [payload_root, *sorted(payload_root.rglob("*"))]
    file_names = [
        ".",
        *("./" + str(path.relative_to(payload_root)) for path in files[1:]),
    ]
    size_kb = (
        sum(path.lstat().st_size for path in files if not path.is_dir()) + 1023
    ) // 1024
    with tempfile.TemporaryFile() as archive:
        result = subprocess.run(
            [tool("cpio"), "--null", "-o", "--format=odc", "--owner=0:80"],
            check=False,
            cwd=payload_root,
            input=b"\0".join(os.fsencode(name) for name in file_names) + b"\0",
            stdout=archive,
            stderr=subprocess.PIPE,
        )
        if result.returncode:
            raise ReleaseError(
                "cpio failed while creating the installer payload: "
                + result.stderr.decode(errors="replace")
            )
        archive.seek(0)
        with gzip.open(component / "Payload", "wb") as compressed:
            shutil.copyfileobj(archive, compressed)
    run(
        [
            tool("mkbom"),
            "-u",
            "0",
            "-g",
            "80",
            str(payload_root),
            str(component / "Bom"),
        ]
    )
    bundle_id, version = info["CFBundleIdentifier"], info["CFBundleShortVersionString"]
    package = ET.Element(
        "pkg-info",
        {
            "format-version": "2",
            "identifier": bundle_id,
            "version": version,
            "install-location": "/Applications",
            "auth": "root",
            "postinstall-action": "none",
            "preserve-xattr": "false",
        },
    )
    ET.SubElement(
        package,
        "payload",
        {"numberOfFiles": str(len(files)), "installKBytes": str(size_kb)},
    )
    bundle_attributes = {
        "path": f"./{app.name}",
        "id": bundle_id,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": info["CFBundleVersion"],
    }
    ET.SubElement(package, "bundle", bundle_attributes)
    for tag in ("bundle-version", "upgrade-bundle", "strict-identifier"):
        ET.SubElement(ET.SubElement(package, tag), "bundle", {"id": bundle_id})
    ET.SubElement(package, "update-bundle")
    ET.SubElement(package, "atomic-update-bundle")
    xml_file(component / "PackageInfo", package)
    distribution = ET.Element("installer-gui-script", {"minSpecVersion": "2"})
    ET.SubElement(distribution, "title").text = info.get(
        "CFBundleDisplayName", app.stem
    )
    ET.SubElement(
        distribution,
        "options",
        {
            "customize": "never",
            "require-scripts": "false",
            "hostArchitectures": "x86_64,arm64",
        },
    )
    ET.SubElement(
        distribution,
        "domains",
        {
            "enable_anywhere": "false",
            "enable_currentUserHome": "false",
            "enable_localSystem": "true",
        },
    )
    ET.SubElement(
        ET.SubElement(distribution, "choices-outline"), "line", {"choice": bundle_id}
    )
    ET.SubElement(
        ET.SubElement(distribution, "choice", {"id": bundle_id, "visible": "false"}),
        "pkg-ref",
        {"id": bundle_id},
    )
    reference = ET.SubElement(
        distribution,
        "pkg-ref",
        {
            "id": bundle_id,
            "version": version,
            "onConclusion": "none",
            "installKBytes": str(size_kb),
        },
    )
    reference.text = f"#{component_name}"
    ET.SubElement(distribution, "product", {"id": bundle_id, "version": version})
    ET.SubElement(
        ET.SubElement(
            ET.SubElement(distribution, "volume-check"), "allowed-os-versions"
        ),
        "os-version",
        {"min": info["LSMinimumSystemVersion"]},
    )
    xml_file(directory / "Distribution", distribution)
    run(
        [
            tool("xar"),
            "--compression",
            "none",
            "-cf",
            str(output),
            "Distribution",
            component_name,
        ],
        cwd=directory,
    )


def validate_product_archive(path, roots, directory, bundle_id):
    """Check the XAR digest, CMS trust, file checksums, and product structure."""
    with path.open("rb") as stream:
        header = stream.read(28)
        if len(header) != 28:
            raise ReleaseError("Mac product archive has a truncated XAR header")
        magic, header_size, version, compressed_size, xml_size, algorithm = (
            struct.unpack(">4sHHQQI", header)
        )
        if (
            magic != b"xar!"
            or version != 1
            or header_size != 28
            or compressed_size > 64 * 1024 * 1024
            or xml_size > 64 * 1024 * 1024
        ):
            raise ReleaseError("Mac product archive is not a supported XAR archive")
        compressed = stream.read(compressed_size)
        try:
            xml = zlib.decompress(compressed)
            toc = ET.fromstring(xml).find("toc")
        except (zlib.error, ET.ParseError) as exc:
            raise ReleaseError(
                "Mac product archive has an invalid XAR table of contents"
            ) from exc
        if len(xml) != xml_size or toc is None:
            raise ReleaseError(
                "Mac product archive has an invalid XAR table of contents length"
            )
        digest_name = {1: "sha1", 3: "sha256", 4: "sha512"}.get(algorithm)
        if digest_name is None:
            raise ReleaseError("Mac product archive has an unsupported XAR checksum")
        digest = hashlib.new(digest_name, compressed).digest()
        heap_start = header_size + compressed_size
        checksum = toc.find("checksum")
        stream.seek(heap_start + int(checksum.findtext("offset")))
        if stream.read(int(checksum.findtext("size"))) != digest:
            raise ReleaseError(
                "Mac product archive XAR table of contents checksum is invalid"
            )
        signature = toc.find("x-signature")
        if signature is None or signature.get("style") != "CMS":
            raise ReleaseError(
                "Mac product archive is missing its installer CMS signature"
            )
        stream.seek(heap_start + int(signature.findtext("offset")))
        cms = private_file(
            directory / "pkg-signature.der",
            stream.read(int(signature.findtext("size"))),
        )
        content = private_file(directory / "pkg-toc-digest", digest)
        verified = run(
            [
                tool("openssl"),
                "cms",
                "-verify",
                "-binary",
                "-inform",
                "DER",
                "-in",
                str(cms),
                "-content",
                str(content),
                "-CAfile",
                str(roots),
                "-purpose",
                "any",
                *code_cms_extension_options(cms, roots, {"1.2.840.113635.100.6.1.8"}),
                "-signer",
                str(directory / "pkg-signer.pem"),
            ]
        )
        if verified != digest:
            raise ReleaseError(
                "Mac product archive CMS signature has the wrong content"
            )
        signer = x509.load_pem_x509_certificate(
            (directory / "pkg-signer.pem").read_bytes()
        )
        try:
            usage = signer.extensions.get_extension_for_class(
                x509.ExtendedKeyUsage
            ).value
        except x509.ExtensionNotFound as exc:
            raise ReleaseError(
                "Mac product archive signer is not a Mac Installer Distribution certificate"
            ) from exc
        extensions = {extension.oid.dotted_string for extension in signer.extensions}
        if (
            ObjectIdentifier("1.2.840.113635.100.4.9") not in usage
            or "1.2.840.113635.100.6.1.8" not in extensions
        ):
            raise ReleaseError(
                "Mac product archive signer is not a Mac Installer Distribution certificate"
            )
        entries = toc.findall("file")
        directories = [item for item in entries if item.findtext("type") == "directory"]
        distributions = [
            item
            for item in entries
            if item.findtext("name") == "Distribution"
            and item.findtext("type") == "file"
        ]
        if len(entries) != 2 or len(directories) != 1 or len(distributions) != 1:
            raise ReleaseError(
                "Mac product archive must contain only Distribution and one app component"
            )
        component_name = directories[0].findtext("name", "")
        if Path(component_name).name != component_name or not component_name.endswith(
            ".pkg"
        ):
            raise ReleaseError("Mac product archive has an invalid component name")
        children = directories[0].findall("file")
        if (
            {item.findtext("name") for item in children}
            != {"Bom", "Payload", "PackageInfo"}
            or len(children) != 3
            or any(
                item.findtext("type") != "file" or item.findall("file")
                for item in children
            )
        ):
            raise ReleaseError(
                "Mac product archive component must contain Bom, Payload, and PackageInfo files"
            )
    # Extraction verifies every archived file checksum after the CMS check.
    extraction = directory / "expanded"
    extraction.mkdir()
    run([tool("xar"), "-xf", str(path)], cwd=extraction)
    distribution = ET.parse(extraction / "Distribution").getroot()
    references = [
        item
        for item in distribution.findall("pkg-ref")
        if item.text and item.text.startswith("#")
    ]
    if len(references) != 1 or references[0].get("id") != bundle_id:
        raise ReleaseError(
            "Mac product archive must contain the expected single app component"
        )
    component_name = references[0].text[1:]
    if Path(component_name).name != component_name:
        raise ReleaseError("Mac product archive has an invalid component path")
    component = extraction / component_name
    package = ET.parse(component / "PackageInfo").getroot()
    if (
        package.get("identifier") != bundle_id
        or package.get("install-location") != "/Applications"
    ):
        raise ReleaseError(
            "Mac product archive must install the expected app into /Applications"
        )
    if (component / "Bom").read_bytes()[:8] != b"BOMStore":
        raise ReleaseError(
            "Mac product archive is missing its installer Bill of Materials"
        )
    run([tool("lsbom"), str(component / "Bom")])
    with gzip.open(component / "Payload", "rb") as payload:
        contents = run([tool("cpio"), "-it", "--quiet"], input=payload.read()).decode()
    bundle = package.find("bundle")
    payload_names = {name.removeprefix("./") for name in contents.splitlines()}
    if (
        bundle is None
        or bundle.get("id") != bundle_id
        or f"{bundle.get('path', '').removeprefix('./')}/Contents/Info.plist"
        not in payload_names
    ):
        raise ReleaseError(
            "Mac product archive payload does not contain the declared app"
        )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--bundle-id", default=os.environ.get("IOS_BUNDLE_ID", "com.bvolpato.brutv")
    )
    parser.add_argument(
        "--entitlements",
        type=Path,
        default=SCRIPT_DIR / "BruTV/BruTVCatalyst.entitlements",
    )
    parser.add_argument(
        "--preflight",
        action="store_true",
        help="validate tools and signing inputs without signing",
    )
    parser.add_argument(
        "--validate-only", action="store_true", help="validate an existing --output PKG"
    )
    args = parser.parse_args(argv)
    if args.preflight and args.validate_only:
        parser.error("--preflight and --validate-only are mutually exclusive")
    if not args.preflight and not args.output:
        parser.error("--output is required")
    if not args.preflight and not args.validate_only and not args.app:
        parser.error("--app is required")
    try:
        for name in ("rcodesign", "mkbom", "lsbom", "xar", "cpio", "openssl"):
            tool(name)
        with tempfile.TemporaryDirectory(prefix="brutv-mac-release-") as temporary:
            directory = Path(temporary)
            roots = root_ca_file(directory)
            if args.validate_only:
                validate_product_archive(
                    args.output.resolve(), roots, directory, args.bundle_id
                )
                print("Mac product archive signatures and structure verified")
                return 0
            application_path = signing_input(
                "MACOS_APPLICATION_CERTIFICATE", ".p12", directory
            )
            installer_path = signing_input(
                "MACOS_INSTALLER_CERTIFICATE", ".p12", directory
            )
            profile_path = signing_input(
                "MACOS_PROVISIONING_PROFILE", ".provisionprofile", directory
            )
            certificate, team, application_pem = load_identity(
                application_path,
                "MACOS_APPLICATION_P12_PASSWORD",
                "application",
                directory,
            )
            _, installer_team, installer_pem = load_identity(
                installer_path, "MACOS_INSTALLER_P12_PASSWORD", "installer", directory
            )
            if installer_team != team:
                raise ReleaseError(
                    "Mac application and installer signing certificates belong to different teams"
                )
            profile = read_profile(profile_path, roots)
            requested = plistlib.loads(args.entitlements.read_bytes())
            entitlements = distribution_entitlements(
                profile, certificate, team, args.bundle_id, requested
            )
            if args.app:
                info = validate_app(args.app.resolve(), args.bundle_id)
            if args.preflight:
                print(
                    "Mac release tools, certificates, and distribution profile verified"
                )
                return 0
            output = args.output.resolve()
            if output.suffix != ".pkg":
                raise ReleaseError(
                    "Mac product archive output must have a .pkg extension"
                )
            output.parent.mkdir(parents=True, exist_ok=True)
            staging = directory / "signed"
            staging.mkdir()
            app = staging / args.app.name
            shutil.copytree(args.app.resolve(), app, symlinks=True)
            shutil.copyfile(profile_path, app / "Contents/embedded.provisionprofile")
            entitlements_path = private_file(
                directory / "entitlements.plist", plistlib.dumps(entitlements)
            )
            run(
                [
                    tool("rcodesign"),
                    "-C",
                    "/dev/null",
                    "sign",
                    "--pem-file",
                    str(application_pem),
                    "--team-name",
                    team,
                    "--entitlements-xml-file",
                    str(entitlements_path),
                    "--timestamp-url",
                    "none",
                    str(app),
                ]
            )
            validate_signed_app(app, info, certificate, entitlements, roots, directory)
            package_directory = directory / "product"
            package_directory.mkdir()
            unsigned = directory / "unsigned.pkg"
            signed = directory / "signed.pkg"
            build_product_archive(app, info, unsigned, package_directory)
            run(
                [
                    tool("rcodesign"),
                    "-C",
                    "/dev/null",
                    "sign",
                    "--pem-file",
                    str(installer_pem),
                    "--timestamp-url",
                    "none",
                    str(unsigned),
                    str(signed),
                ]
            )
            validation = directory / "validation"
            validation.mkdir()
            validate_product_archive(signed, roots, validation, args.bundle_id)
            # Keep the previous artifact intact until a fully verified replacement exists.
            with tempfile.NamedTemporaryFile(
                dir=output.parent, prefix=f".{output.name}.", delete=False
            ) as stream:
                replacement = Path(stream.name)
                with signed.open("rb") as source:
                    shutil.copyfileobj(source, stream)
            os.replace(replacement, output)
            print(f"Mac App Store product archive: {output}")
            print(
                "App Store Connect processing must accept this build before release compatibility is confirmed."
            )
            return 0
    except (ReleaseError, OSError, ValueError, ET.ParseError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
