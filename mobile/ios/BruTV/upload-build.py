#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "requests>=2.32,<3",
#     "PyJWT[crypto]>=2.10,<3",
# ]
# ///
"""Upload a signed Apple app package and wait for App Store Connect processing.

API contract: https://developer.apple.com/documentation/appstoreconnectapi/post-v1-builduploads
Apple describes this platform-independent flow in WWDC25 session 324.
"""

from __future__ import annotations

import argparse
import hashlib
import math
import os
import plistlib
import re
import struct
import sys
import time
import uuid
import zipfile
from pathlib import Path, PurePosixPath
from urllib.parse import quote, urlsplit

import jwt
import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

API_BASE = "https://api.appstoreconnect.apple.com/v1"


class UploadError(Exception):
    """An actionable packaging, upload, or processing failure."""


def inspect_ipa(path: Path, platform: str = "IOS") -> dict[str, str]:
    if not path.is_file() or path.suffix.lower() != ".ipa":
        raise UploadError("Provide an existing signed .ipa file.")
    if not 1 <= path.stat().st_size <= 9007199254740991:
        raise UploadError("IPA size is outside the Build Upload API's supported range.")
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)):
                raise UploadError("IPA contains duplicate ZIP entries.")
            if any(
                PurePosixPath(name).is_absolute()
                or ".." in PurePosixPath(name).parts
                or "\\" in name
                for name in names
            ):
                raise UploadError("IPA contains unsafe ZIP entry paths.")
            plists = [
                name
                for name in names
                if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)
            ]
            if len(plists) != 1:
                raise UploadError(
                    "IPA must contain exactly one Payload/*.app/Info.plist."
                )
            plist_name = plists[0]
            if archive.getinfo(plist_name).file_size > 1024 * 1024:
                raise UploadError("IPA Info.plist is unexpectedly large.")
            info = plistlib.loads(archive.read(plist_name))
            if not isinstance(info, dict):
                raise UploadError("IPA Info.plist must contain a dictionary.")
            root = plist_name.removesuffix("Info.plist")
            for key in (
                "CFBundleIdentifier",
                "CFBundleVersion",
                "CFBundleShortVersionString",
                "CFBundleExecutable",
            ):
                if not isinstance(info.get(key), str) or not info[key].strip():
                    raise UploadError(f"IPA Info.plist is missing {key}.")
            executable = info["CFBundleExecutable"]
            if "/" in executable or "\\" in executable or executable in (".", ".."):
                raise UploadError("IPA CFBundleExecutable must be a file name.")
            for name in (
                executable,
                "embedded.mobileprovision",
                "_CodeSignature/CodeResources",
            ):
                member = root + name
                if member not in names or archive.getinfo(member).file_size == 0:
                    raise UploadError(f"Signed IPA is missing {name}.")
            target, families = (
                ("AppleTVOS", [3]) if platform == "TV_OS" else ("iPhoneOS", [1, 2])
            )
            if info.get("CFBundleSupportedPlatforms") != [target]:
                raise UploadError(
                    f"IPA must target {target}, not a simulator or another Apple platform."
                )
            actual_families = info.get("UIDeviceFamily")
            if (
                not isinstance(actual_families, list)
                or not actual_families
                or any(
                    type(family) is not int or family not in families
                    for family in actual_families
                )
            ):
                raise UploadError(
                    f"IPA UIDeviceFamily does not match platform {platform}."
                )
            bad_member = archive.testzip()
            if bad_member:
                raise UploadError(f"IPA ZIP checksum failed for {bad_member}.")
    except (
        zipfile.BadZipFile,
        plistlib.InvalidFileException,
        ValueError,
        RuntimeError,
        OSError,
    ) as error:
        raise UploadError(f"Cannot read IPA: {error}") from error
    return {
        "bundle_id": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
    }


def inspect_package(
    path: Path, platform: str, metadata: dict[str, str] | None = None
) -> dict[str, str]:
    if platform not in ("IOS", "TV_OS", "MAC_OS"):
        raise UploadError(f"Unsupported upload platform: {platform}.")
    if platform != "MAC_OS":
        actual = inspect_ipa(path, platform)
        if metadata and any(
            metadata.get(key) and metadata[key] != actual[key] for key in actual
        ):
            raise UploadError(
                "Explicit bundle metadata disagrees with the IPA Info.plist."
            )
        return actual
    if not path.is_file() or path.suffix.lower() != ".pkg":
        raise UploadError("MAC_OS uploads require an existing signed .pkg installer.")
    size = path.stat().st_size
    if not 28 <= size <= 9007199254740991:
        raise UploadError("macOS package size is outside the supported range.")
    with path.open("rb") as file:
        magic, header_size, version, toc_length, _, _ = struct.unpack(
            ">4sHHQQI", file.read(28)
        )
    if (
        magic != b"xar!"
        or header_size < 28
        or version != 1
        or not toc_length
        or header_size + toc_length > size
    ):
        raise UploadError("macOS .pkg must be a valid XAR installer package.")
    if not metadata or any(
        not isinstance(metadata.get(key), str) or not metadata[key].strip()
        for key in ("bundle_id", "version", "build")
    ):
        raise UploadError(
            "MAC_OS requires --bundle-id, --short-version, and --bundle-version from the verified signed app."
        )
    return metadata


def required_env(name: str, alias: str) -> str:
    value = os.environ.get(name) or os.environ.get(alias)
    if not value:
        raise UploadError(
            f"Set {name} (or {alias}) for App Store Connect API authentication."
        )
    return value


class Token:
    def __init__(self, key_id: str, issuer_id: str, private_key: bytes):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.private_key = private_key
        self.value = ""
        self.expires = 0

    @classmethod
    def from_environment(cls) -> Token:
        key_id = required_env("IOS_ASC_KEY_ID", "ASC_KEY_ID")
        issuer = required_env("IOS_ASC_ISSUER_ID", "ASC_ISSUER_ID")
        if not re.fullmatch(r"[A-Z0-9]{10}", key_id):
            raise UploadError(
                "App Store Connect API key ID must contain 10 uppercase letters or digits."
            )
        try:
            uuid.UUID(issuer)
        except ValueError as error:
            raise UploadError(
                "App Store Connect API issuer ID must be a UUID."
            ) from error
        path = Path(
            required_env("IOS_ASC_PRIVATE_KEY_PATH", "ASC_PRIVATE_KEY_PATH")
        ).expanduser()
        try:
            private_key = path.read_bytes()
        except OSError as error:
            raise UploadError(
                "Cannot read the App Store Connect .p8 private key file."
            ) from error
        try:
            key = serialization.load_pem_private_key(private_key, password=None)
        except (TypeError, ValueError) as error:
            raise UploadError(
                "App Store Connect private key must be an unencrypted PEM .p8 key."
            ) from error
        if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(
            key.curve, ec.SECP256R1
        ):
            raise UploadError(
                "App Store Connect private key must use the P-256 curve required for ES256."
            )
        return cls(key_id, issuer, private_key)

    def __call__(self) -> str:
        now = int(time.time())
        if now >= self.expires - 30:
            self.expires = now + 19 * 60
            try:
                self.value = jwt.encode(
                    {
                        "iss": self.issuer_id,
                        "iat": now,
                        "exp": self.expires,
                        "aud": "appstoreconnect-v1",
                    },
                    self.private_key,
                    algorithm="ES256",
                    headers={"kid": self.key_id, "typ": "JWT"},
                )
            except Exception as error:
                raise UploadError(
                    "Cannot sign API token. Check the ES256 App Store Connect .p8 key."
                ) from error
        return self.value


def details(items: list[dict]) -> str:
    return "; ".join(
        ": ".join(
            str(item[key])
            for key in ("code", "title", "detail", "description")
            if item.get(key)
        )
        for item in items
        if isinstance(item, dict)
    )


class FileRange:
    """Stream exactly one server-requested part without loading it into memory."""

    def __init__(self, file, offset: int, length: int):
        self.file = file
        self.file.seek(offset)
        self.remaining = length
        self.length = length

    def __len__(self):
        return self.length

    def read(self, size: int = -1) -> bytes:
        size = self.remaining if size < 0 else min(size, self.remaining)
        chunk = self.file.read(size)
        self.remaining -= len(chunk)
        if size and not chunk:
            raise UploadError("Package changed or became unreadable during upload.")
        return chunk


class BuildUploader:
    def __init__(
        self, token, *, api_base: str = API_BASE, allow_local_http: bool = False
    ):
        self.token = token
        self.api_base = api_base.rstrip("/")
        self.allow_local_http = allow_local_http
        self.api = requests.Session()
        self.api.trust_env = False
        self.transfer = requests.Session()
        # Upload URLs have their own credentials. Never send API tokens or netrc credentials to them.
        self.transfer.trust_env = False

    def request(self, method: str, path: str, *, body=None) -> dict:
        try:
            response = self.api.request(
                method,
                self.api_base + path,
                json=body,
                headers={
                    "Authorization": "Bearer " + self.token(),
                    "Accept": "application/json",
                },
                timeout=(10, 120),
                allow_redirects=False,
            )
        except requests.RequestException as error:
            raise UploadError(
                f"App Store Connect {method} {path.split('?')[0]} failed ({type(error).__name__}). "
                "A write may have succeeded; check App Store Connect before retrying."
            ) from error
        try:
            payload = response.json()
        except ValueError as error:
            raise UploadError(
                f"App Store Connect returned HTTP {response.status_code} without JSON."
            ) from error
        if not isinstance(payload, dict):
            raise UploadError("App Store Connect returned an invalid JSON response.")
        if not 200 <= response.status_code < 300:
            message = (
                details(payload.get("errors", [])) or "No API error details returned."
            )
            raise UploadError(
                f"App Store Connect HTTP {response.status_code}: {message}"
            )
        if not isinstance(payload.get("data"), dict):
            raise UploadError(
                "App Store Connect returned an invalid resource response."
            )
        return payload

    def operations(self, operations: list[dict], size: int) -> list[dict]:
        if not isinstance(operations, list) or not operations:
            raise UploadError("App Store Connect did not return uploadOperations.")
        expected_offset = 0
        valid = []
        for operation in operations:
            if not isinstance(operation, dict):
                raise UploadError(
                    "App Store Connect returned an invalid upload operation."
                )
            offset, length = operation.get("offset"), operation.get("length")
            if (
                type(offset) is not int
                or type(length) is not int
                or offset < 0
                or length <= 0
                or offset + length > size
            ):
                raise UploadError(
                    "App Store Connect returned an invalid upload byte range."
                )
            if operation.get("method") != "PUT":
                raise UploadError(
                    "App Store Connect returned an unsupported upload HTTP method."
                )
            if not isinstance(operation.get("url"), str):
                raise UploadError("App Store Connect returned an invalid upload URL.")
            try:
                target = urlsplit(operation["url"])
            except ValueError as error:
                raise UploadError(
                    "App Store Connect returned an invalid upload URL."
                ) from error
            local_http = (
                self.allow_local_http
                and target.scheme == "http"
                and target.hostname in ("localhost", "127.0.0.1", "::1")
            )
            if (
                (target.scheme != "https" and not local_http)
                or not target.hostname
                or target.username
                or target.password
            ):
                raise UploadError("App Store Connect returned an unsafe upload URL.")
            headers = {}
            request_headers = operation.get("requestHeaders", [])
            if not isinstance(request_headers, list) or any(
                not isinstance(header, dict) for header in request_headers
            ):
                raise UploadError("App Store Connect returned invalid upload headers.")
            for header in request_headers:
                name, value = header.get("name"), header.get("value")
                if (
                    not isinstance(name, str)
                    or not isinstance(value, str)
                    or not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name)
                    or "\r" in value
                    or "\n" in value
                ):
                    raise UploadError(
                        "App Store Connect returned an invalid upload header."
                    )
                if name.lower() in {key.lower() for key in headers}:
                    raise UploadError(
                        "App Store Connect returned duplicate upload headers."
                    )
                if name.lower() == "content-length" and value != str(length):
                    raise UploadError(
                        "Upload Content-Length disagrees with the requested byte range."
                    )
                if (
                    name.lower() == "content-range"
                    and value != f"bytes {offset}-{offset + length - 1}/{size}"
                ):
                    raise UploadError(
                        "Upload Content-Range disagrees with the requested byte range."
                    )
                headers[name] = value
            valid.append({**operation, "headers": headers})
        for operation in sorted(valid, key=lambda item: item["offset"]):
            if operation["offset"] != expected_offset:
                raise UploadError(
                    "Upload operations contain overlapping ranges or missing bytes."
                )
            expected_offset += operation["length"]
        if expected_offset != size:
            raise UploadError("Upload operations do not cover the complete IPA.")
        return valid

    def upload(
        self,
        path: Path,
        app_id: str,
        *,
        platform: str = "IOS",
        metadata: dict[str, str] | None = None,
        poll_interval: float = 15,
        timeout: float = 1800,
    ) -> str:
        metadata = inspect_package(path, platform, metadata)
        app = self.request("GET", "/apps/" + quote(app_id, safe=""))["data"]
        if app.get("attributes", {}).get("bundleId") != metadata["bundle_id"]:
            raise UploadError(
                "Package bundle identifier does not match the selected App Store Connect app."
            )
        print(
            f"Uploading {metadata['bundle_id']} {metadata['version']} ({metadata['build']}).",
            flush=True,
        )
        upload = self.request(
            "POST",
            "/buildUploads",
            body={
                "data": {
                    "type": "buildUploads",
                    "attributes": {
                        "cfBundleShortVersionString": metadata["version"],
                        "cfBundleVersion": metadata["build"],
                        "platform": platform,
                    },
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )["data"]
        upload_id = upload.get("id")
        if not isinstance(upload_id, str) or not upload_id:
            raise UploadError("App Store Connect did not return a build upload ID.")
        print(f"Build upload ID: {upload_id}", flush=True)
        size = path.stat().st_size
        with path.open("rb") as file:
            checksum = hashlib.file_digest(file, "md5").hexdigest()
            reservation = self.request(
                "POST",
                "/buildUploadFiles",
                body={
                    "data": {
                        "type": "buildUploadFiles",
                        "attributes": {
                            "assetType": "ASSET",
                            "fileName": path.name,
                            "fileSize": size,
                            "uti": "com.apple.pkg"
                            if platform == "MAC_OS"
                            else "com.apple.ipa",
                        },
                        "relationships": {
                            "buildUpload": {
                                "data": {"type": "buildUploads", "id": upload_id}
                            }
                        },
                    }
                },
            )["data"]
            file_id = reservation.get("id")
            if not isinstance(file_id, str) or not file_id:
                raise UploadError(
                    "App Store Connect did not return a build upload file ID."
                )
            operations = self.operations(
                reservation.get("attributes", {}).get("uploadOperations"), size
            )
            for index, operation in enumerate(operations, 1):
                part = FileRange(file, operation["offset"], operation["length"])
                try:
                    response = self.transfer.put(
                        operation["url"],
                        data=part,
                        headers=operation["headers"],
                        timeout=(10, 120),
                        allow_redirects=False,
                    )
                except requests.RequestException as error:
                    raise UploadError(
                        f"Upload part {index} failed ({type(error).__name__}); upload ID {upload_id}."
                    ) from error
                if not 200 <= response.status_code < 300:
                    raise UploadError(
                        f"Upload part {index} returned HTTP {response.status_code}; upload ID {upload_id}."
                    )
                if part.remaining:
                    raise UploadError(
                        f"Upload part {index} did not send all requested bytes."
                    )
                print(f"Uploaded part {index}/{len(operations)}.", flush=True)
            if path.stat().st_size != size:
                raise UploadError(
                    "Package size changed during upload; refusing to commit it."
                )
        committed = self.request(
            "PATCH",
            "/buildUploadFiles/" + quote(file_id, safe=""),
            body={
                "data": {
                    "type": "buildUploadFiles",
                    "id": file_id,
                    "attributes": {
                        "uploaded": True,
                        "sourceFileChecksums": {
                            "file": {"algorithm": "MD5", "hash": checksum}
                        },
                    },
                }
            },
        )["data"]
        delivery = committed.get("attributes", {}).get("assetDeliveryState", {})
        if delivery.get("state") == "FAILED":
            raise UploadError(
                "Apple rejected the uploaded file: "
                + details(delivery.get("errors", []))
            )
        return self.wait_for_processing(upload_id, poll_interval, timeout)

    def wait_for_processing(
        self, upload_id: str, interval: float, timeout: float
    ) -> str:
        deadline = time.monotonic() + timeout
        previous_state = None
        while time.monotonic() < deadline:
            payload = self.request(
                "GET", "/buildUploads/" + quote(upload_id, safe="") + "?include=build"
            )
            upload = payload["data"]
            state = upload.get("attributes", {}).get("state", {})
            current = state.get("state")
            if current not in ("AWAITING_UPLOAD", "PROCESSING", "FAILED", "COMPLETE"):
                raise UploadError(
                    f"Unknown Apple build upload state: {current!r}; upload ID {upload_id}."
                )
            if current != previous_state:
                print(f"Apple build upload state: {current}.", flush=True)
                previous_state = current
            if current == "FAILED" or state.get("errors"):
                raise UploadError(
                    f"Apple build processing failed; upload ID {upload_id}: "
                    + details(state.get("errors", []))
                )
            build = upload.get("relationships", {}).get("build", {}).get("data")
            if current == "COMPLETE" and isinstance(build, dict) and build.get("id"):
                resource = next(
                    (
                        item
                        for item in payload.get("included", [])
                        if item.get("type") == "builds"
                        and item.get("id") == build["id"]
                    ),
                    None,
                )
                if resource is None:
                    resource = self.request(
                        "GET", "/builds/" + quote(build["id"], safe="")
                    )["data"]
                processing = resource.get("attributes", {}).get("processingState")
                if processing in ("FAILED", "INVALID"):
                    raise UploadError(
                        f"Apple build {build['id']} has processingState {processing}; upload ID {upload_id}."
                    )
                if processing == "VALID":
                    if state.get("warnings"):
                        print(
                            "Apple processing warnings: " + details(state["warnings"]),
                            flush=True,
                        )
                    print(
                        f"Build {build['id']} processed successfully in App Store Connect.",
                        flush=True,
                    )
                    return build["id"]
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(interval, remaining))
        raise UploadError(
            f"Timed out waiting for Apple build processing; upload ID {upload_id}. Check this upload in App Store Connect before uploading again."
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "package", nargs="?", type=Path, help="Signed App Store .ipa or .pkg"
    )
    parser.add_argument(
        "--app-id", default=os.environ.get("IOS_APP_STORE_ID", "6821989154")
    )
    parser.add_argument("--platform", choices=("IOS", "TV_OS", "MAC_OS"), default="IOS")
    parser.add_argument(
        "--bundle-id", help="Bundle ID from the signed app (required for MAC_OS)"
    )
    parser.add_argument(
        "--bundle-version",
        help="CFBundleVersion from the signed app (required for MAC_OS)",
    )
    parser.add_argument(
        "--short-version",
        help="CFBundleShortVersionString from the signed app (required for MAC_OS)",
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=15,
        help="Processing poll seconds (default: 15)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=1800,
        help="Processing timeout seconds (default: 1800)",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--validate-only",
        action="store_true",
        help="Check package structure and metadata without credentials or network",
    )
    mode.add_argument(
        "--preflight",
        action="store_true",
        help="Validate API credentials and app ID without a package or network requests",
    )
    args = parser.parse_args()
    if not args.preflight and args.package is None:
        parser.error("package is required unless --preflight is selected")
    if not re.fullmatch(r"[1-9][0-9]*", args.app_id):
        parser.error("--app-id must be a positive App Store Connect numeric app ID")
    if not all(
        math.isfinite(value) and value > 0
        for value in (args.poll_interval, args.timeout)
    ):
        parser.error("--poll-interval and --timeout must be finite positive numbers")
    metadata = {
        "bundle_id": args.bundle_id,
        "build": args.bundle_version,
        "version": args.short_version,
    }
    try:
        if args.preflight:
            Token.from_environment()()
            print(
                "App Store Connect API credentials and app ID passed offline preflight."
            )
        elif args.validate_only:
            metadata = inspect_package(args.package, args.platform, metadata)
            print(
                f"Validated {args.platform} package structure: {metadata['bundle_id']} {metadata['version']} ({metadata['build']})."
            )
        else:
            BuildUploader(Token.from_environment()).upload(
                args.package,
                args.app_id,
                platform=args.platform,
                metadata=metadata,
                poll_interval=args.poll_interval,
                timeout=args.timeout,
            )
    except (UploadError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
