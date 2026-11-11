#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "requests>=2.32,<3",
#     "PyJWT[crypto]>=2.10,<3",
# ]
# ///
"""Upload a signed Apple app package and optionally distribute it to TestFlight.

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
from urllib.parse import quote, urlencode, urljoin, urlsplit

import jwt
import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

API_BASE = "https://api.appstoreconnect.apple.com/v1"


class UploadError(Exception):
    """An actionable packaging, upload, or processing failure."""


class APIError(UploadError):
    """An API rejection with its structured status and error codes preserved."""

    def __init__(self, status: int, errors: list[dict]):
        self.status = status
        self.codes = {
            item["code"]
            for item in errors
            if isinstance(item, dict) and isinstance(item.get("code"), str)
        }
        super().__init__(
            f"App Store Connect HTTP {status}: "
            + (details(errors) or "No API error details returned.")
        )


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

    def api_url(self, path: str) -> str:
        try:
            url = path if urlsplit(path).scheme else self.api_base + path
            base, target = urlsplit(self.api_base), urlsplit(url)
        except ValueError as error:
            raise UploadError(
                "App Store Connect returned an invalid API URL."
            ) from error
        if (
            (target.scheme, target.netloc) != (base.scheme, base.netloc)
            or target.username
            or target.password
            or target.fragment
            or not target.path.startswith(base.path + "/")
            or any(part in (".", "..") for part in target.path.split("/"))
        ):
            raise UploadError("App Store Connect returned an unsafe API URL.")
        return url

    def request(
        self,
        method: str,
        path: str,
        *,
        body=None,
        collection: bool = False,
        allow_no_content: bool = False,
        allow_null: bool = False,
    ) -> dict:
        url = self.api_url(path)
        try:
            response = self.api.request(
                method,
                url,
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
        if response.status_code == 204 and allow_no_content:
            return {}
        try:
            payload = response.json()
        except ValueError as error:
            raise UploadError(
                f"App Store Connect returned HTTP {response.status_code} without JSON."
            ) from error
        if not isinstance(payload, dict):
            raise UploadError("App Store Connect returned an invalid JSON response.")
        if not 200 <= response.status_code < 300:
            errors = payload.get("errors", [])
            raise APIError(
                response.status_code, errors if isinstance(errors, list) else []
            )
        data = payload.get("data")
        if allow_null and "data" in payload and data is None:
            return payload
        if not isinstance(data, list if collection else dict) or (
            collection and any(not isinstance(item, dict) for item in data)
        ):
            raise UploadError(
                "App Store Connect returned an invalid resource response."
            )
        return payload

    def collection(self, path: str) -> list[dict]:
        items = []
        seen = set()
        url = self.api_url(path)
        endpoint = urlsplit(url).path
        while url:
            if url in seen or len(seen) >= 1000:
                raise UploadError(
                    "App Store Connect returned cyclic or excessive pagination."
                )
            seen.add(url)
            payload = self.request("GET", url, collection=True)
            items.extend(payload["data"])
            links = payload.get("links", {})
            if not isinstance(links, dict):
                raise UploadError(
                    "App Store Connect returned invalid pagination links."
                )
            next_page = links.get("next")
            if next_page is None:
                break
            if not isinstance(next_page, str) or not next_page:
                raise UploadError(
                    "App Store Connect returned an invalid pagination link."
                )
            url = self.api_url(urljoin(url, next_page))
            if urlsplit(url).path != endpoint:
                raise UploadError(
                    "App Store Connect pagination changed the requested endpoint."
                )
        return items

    @staticmethod
    def resource_id(resource: dict, kind: str) -> str:
        identity = resource.get("id")
        if (
            resource.get("type") != kind
            or not isinstance(identity, str)
            or not identity
        ):
            raise UploadError(f"App Store Connect returned an invalid {kind} resource.")
        return identity

    def update_test_notes(self, build_id: str, notes: str) -> None:
        localizations = self.collection(
            "/builds/" + quote(build_id, safe="") + "/betaBuildLocalizations"
        )
        english = [
            item
            for item in localizations
            if item.get("attributes", {}).get("locale") == "en-US"
        ]
        if len(english) > 1:
            raise UploadError(
                "App Store Connect returned multiple en-US build localizations."
            )
        if english:
            localization = english[0]
            localization_id = self.resource_id(localization, "betaBuildLocalizations")
            if localization.get("attributes", {}).get("whatsNew") == notes:
                return
            self.request(
                "PATCH",
                "/betaBuildLocalizations/" + quote(localization_id, safe=""),
                body={
                    "data": {
                        "type": "betaBuildLocalizations",
                        "id": localization_id,
                        "attributes": {"whatsNew": notes},
                    }
                },
            )
        else:
            self.request(
                "POST",
                "/betaBuildLocalizations",
                body={
                    "data": {
                        "type": "betaBuildLocalizations",
                        "attributes": {"locale": "en-US", "whatsNew": notes},
                        "relationships": {
                            "build": {"data": {"type": "builds", "id": build_id}}
                        },
                    }
                },
            )

    def distribute(
        self,
        build_id: str,
        app_id: str,
        group_name: str,
        *,
        whats_new: str | None = None,
        testers: list[str] | None = None,
        poll_interval: float = 15,
        timeout: float = 1800,
    ) -> None:
        """Distribute a valid build to an existing internal group and verify availability."""
        emails = list(dict.fromkeys(email.casefold() for email in (testers or [])))
        if any(not re.fullmatch(r"[^@\s]+@[^@\s]+", email) for email in emails):
            raise UploadError(
                "Each --tester must be an email address without whitespace."
            )
        build_path = "/builds/" + quote(build_id, safe="")
        build = self.request("GET", build_path)["data"]
        if self.resource_id(build, "builds") != build_id:
            raise UploadError("App Store Connect returned a different build.")
        attributes = build.get("attributes", {})
        if (
            attributes.get("processingState") != "VALID"
            or attributes.get("expired") is not False
        ):
            raise UploadError("TestFlight requires a VALID, nonexpired build.")
        app = self.request("GET", build_path + "/app")["data"]
        if self.resource_id(app, "apps") != app_id:
            raise UploadError(
                "Build does not belong to the selected App Store Connect app."
            )
        named_groups = [
            group
            for group in self.collection(
                "/apps/" + quote(app_id, safe="") + "/betaGroups"
            )
            if group.get("attributes", {}).get("name") == group_name
        ]
        groups = [
            group
            for group in named_groups
            if group.get("attributes", {}).get("isInternalGroup") is True
        ]
        if named_groups and not groups:
            raise UploadError(
                "The selected TestFlight group must be an internal group."
            )
        if len(groups) != 1:
            raise UploadError(
                "Select exactly one existing TestFlight group by its exact name."
            )
        group = groups[0]
        group_id = self.resource_id(group, "betaGroups")
        if group.get("attributes", {}).get("isInternalGroup") is not True:
            raise UploadError(
                "The selected TestFlight group must be an internal group."
            )
        group_path = "/betaGroups/" + quote(group_id, safe="") + "/relationships/"
        build_ids = {
            self.resource_id(item, "builds")
            for item in self.collection(group_path + "builds")
        }
        tester_ids = (
            {
                self.resource_id(item, "betaTesters")
                for item in self.collection(group_path + "betaTesters")
            }
            if emails
            else set()
        )
        resolved = []
        for email in emails:
            matches = [
                item
                for item in self.collection(
                    "/betaTesters?"
                    + urlencode({"filter[email]": email, "filter[apps]": app_id})
                )
                if item.get("attributes", {}).get("email", "").casefold() == email
            ]
            if len(matches) > 1:
                raise UploadError(
                    "App Store Connect returned multiple testers for an email address."
                )
            resolved.append(
                (
                    email,
                    self.resource_id(matches[0], "betaTesters") if matches else None,
                )
            )
        # Complete build ownership and group checks before any TestFlight write.
        if whats_new is not None:
            self.update_test_notes(build_id, whats_new)
        if build_id not in build_ids:
            self.request(
                "POST",
                group_path + "builds",
                body={"data": [{"type": "builds", "id": build_id}]},
                allow_no_content=True,
            )
        requested_ids = set()
        for email, tester_id in resolved:
            if tester_id is None:
                created = self.request(
                    "POST",
                    "/betaTesters",
                    body={
                        "data": {
                            "type": "betaTesters",
                            "attributes": {"email": email},
                            "relationships": {
                                "betaGroups": {
                                    "data": [{"type": "betaGroups", "id": group_id}]
                                }
                            },
                        }
                    },
                )["data"]
                tester_id = self.resource_id(created, "betaTesters")
            elif tester_id not in tester_ids:
                self.request(
                    "POST",
                    group_path + "betaTesters",
                    body={"data": [{"type": "betaTesters", "id": tester_id}]},
                    allow_no_content=True,
                )
            requested_ids.add(tester_id)
            try:
                self.request(
                    "POST",
                    "/betaTesterInvitations",
                    body={
                        "data": {
                            "type": "betaTesterInvitations",
                            "relationships": {
                                "app": {"data": {"type": "apps", "id": app_id}},
                                "betaTester": {
                                    "data": {"type": "betaTesters", "id": tester_id}
                                },
                            },
                        }
                    },
                )
            except APIError as error:
                if error.status != 409 or error.codes != {
                    "STATE_ERROR.TESTER_INVITE.ALREADY_ACCEPTED"
                }:
                    raise
                print(
                    "A requested tester has already accepted the app invitation.",
                    flush=True,
                )
        deadline = time.monotonic() + timeout
        state = None
        while True:
            assigned = {
                self.resource_id(item, "builds")
                for item in self.collection(group_path + "builds")
            }
            members = (
                {
                    self.resource_id(item, "betaTesters")
                    for item in self.collection(group_path + "betaTesters")
                }
                if requested_ids
                else set()
            )
            detail = self.request("GET", build_path + "/buildBetaDetail")["data"]
            state = detail.get("attributes", {}).get("internalBuildState")
            if (
                build_id in assigned
                and requested_ids <= members
                and state == "IN_BETA_TESTING"
            ):
                print(
                    f"Build {build_id} is available in TestFlight group {group_name!r}.",
                    flush=True,
                )
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise UploadError(
                    f"Timed out verifying TestFlight group membership and availability; build {build_id}, internalBuildState {state!r}. Resume with --build-id instead of uploading again."
                )
            time.sleep(min(poll_interval, remaining))

    def beta_review(self, build_path: str) -> dict | None:
        try:
            review = self.request(
                "GET", build_path + "/betaAppReviewSubmission", allow_null=True
            )["data"]
        except APIError as error:
            if error.status != 404:
                raise
            return None
        if review is not None:
            self.resource_id(review, "betaAppReviewSubmissions")
            state = review.get("attributes", {}).get("betaReviewState")
            if state not in ("WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED", "REJECTED"):
                raise UploadError(f"Unknown TestFlight beta review state: {state!r}.")
        return review

    def check_beta_review_fields(
        self, app_id: str, build_path: str, whats_new: str | None
    ) -> None:
        try:
            detail = self.request(
                "GET",
                "/apps/" + quote(app_id, safe="") + "/betaAppReviewDetail",
                allow_null=True,
            )["data"]
        except APIError as error:
            if error.status != 404:
                raise
            detail = None
        attributes = detail.get("attributes", {}) if detail else {}
        missing = [
            field
            for field in (
                "contactFirstName",
                "contactLastName",
                "contactPhone",
                "contactEmail",
            )
            if not isinstance(attributes.get(field), str)
            or not attributes[field].strip()
        ]
        if type(attributes.get("demoAccountRequired")) is not bool:
            missing.append("demoAccountRequired")
        elif attributes["demoAccountRequired"]:
            missing.extend(
                field
                for field in ("demoAccountName", "demoAccountPassword")
                if not isinstance(attributes.get(field), str)
                or not attributes[field].strip()
            )
        if whats_new is None:
            notes = self.collection(build_path + "/betaBuildLocalizations")
            has_notes = any(
                isinstance(item.get("attributes", {}).get("whatsNew"), str)
                and item["attributes"]["whatsNew"].strip()
                for item in notes
            )
        else:
            has_notes = bool(whats_new.strip())
        if not has_notes:
            missing.append("betaBuildLocalizations.whatsNew")
        if missing:
            raise UploadError(
                "Complete these TestFlight beta review fields in App Store Connect before submitting: "
                + ", ".join(missing)
                + "."
            )

    def distribute_external(
        self,
        build_id: str,
        app_id: str,
        group_name: str,
        *,
        whats_new: str | None = None,
        poll_interval: float = 15,
        timeout: float = 1800,
    ) -> None:
        """Submit beta review when needed and verify an existing external group's build."""
        build_path = "/builds/" + quote(build_id, safe="")
        build = self.request("GET", build_path)["data"]
        if self.resource_id(build, "builds") != build_id:
            raise UploadError("App Store Connect returned a different build.")
        attributes = build.get("attributes", {})
        if (
            attributes.get("processingState") != "VALID"
            or attributes.get("expired") is not False
        ):
            raise UploadError("TestFlight requires a VALID, nonexpired build.")
        if attributes.get("buildAudienceType") != "APP_STORE_ELIGIBLE":
            raise UploadError(
                "External TestFlight requires buildAudienceType APP_STORE_ELIGIBLE. "
                "An INTERNAL_ONLY build cannot be promoted; upload a build eligible for external testing."
            )
        app = self.request("GET", build_path + "/app")["data"]
        if self.resource_id(app, "apps") != app_id:
            raise UploadError(
                "Build does not belong to the selected App Store Connect app."
            )
        groups = [
            group
            for group in self.collection(
                "/apps/" + quote(app_id, safe="") + "/betaGroups"
            )
            if group.get("attributes", {}).get("name") == group_name
            and group.get("attributes", {}).get("isInternalGroup") is False
        ]
        if len(groups) != 1:
            raise UploadError(
                "Select exactly one existing external TestFlight group by its exact name."
            )
        group_id = self.resource_id(groups[0], "betaGroups")
        group_builds = (
            "/betaGroups/" + quote(group_id, safe="") + "/relationships/builds"
        )
        assigned = {
            self.resource_id(item, "builds") for item in self.collection(group_builds)
        }
        detail = self.request("GET", build_path + "/buildBetaDetail")["data"]
        state = detail.get("attributes", {}).get("externalBuildState")
        review = self.beta_review(build_path)
        review_state = (
            review.get("attributes", {}).get("betaReviewState") if review else None
        )
        if state == "BETA_REJECTED" or review_state == "REJECTED":
            raise UploadError(
                "TestFlight beta review was rejected. Review Apple's feedback in App Store Connect; human review is required before another submission."
            )
        if (
            state == "READY_FOR_BETA_TESTING"
            and detail.get("attributes", {}).get("autoNotifyEnabled") is False
        ):
            raise UploadError(
                "This build is ready for external testing with automatic tester notifications disabled. "
                "Choose Start Testing for the build in App Store Connect, then resume with --build-id. "
                "The helper will not override this hold or notify testers."
            )
        ready_states = ("BETA_APPROVED", "READY_FOR_BETA_TESTING", "IN_BETA_TESTING")
        pending_states = ("WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW")
        if state not in ready_states + pending_states + ("READY_FOR_BETA_SUBMISSION",):
            raise UploadError(
                f"Build is not ready for external TestFlight distribution: externalBuildState {state!r}. Resolve this in App Store Connect, then resume with --build-id."
            )
        submit = review is None and state == "READY_FOR_BETA_SUBMISSION"
        if submit:
            self.check_beta_review_fields(app_id, build_path, whats_new)
        if whats_new is not None:
            self.update_test_notes(build_id, whats_new)
        if submit:
            review = self.request(
                "POST",
                "/betaAppReviewSubmissions",
                body={
                    "data": {
                        "type": "betaAppReviewSubmissions",
                        "relationships": {
                            "build": {"data": {"type": "builds", "id": build_id}}
                        },
                    }
                },
            )["data"]
            self.resource_id(review, "betaAppReviewSubmissions")
            print(f"Submitted TestFlight beta review for build {build_id}.", flush=True)
        deadline = time.monotonic() + timeout
        previous = None
        attached = False
        while True:
            detail = self.request("GET", build_path + "/buildBetaDetail")["data"]
            state = detail.get("attributes", {}).get("externalBuildState")
            review = self.beta_review(build_path)
            review_state = (
                review.get("attributes", {}).get("betaReviewState") if review else None
            )
            if state == "BETA_REJECTED" or review_state == "REJECTED":
                raise UploadError(
                    "TestFlight beta review was rejected. Review Apple's feedback in App Store Connect; human review is required before another submission."
                )
            if (
                state == "READY_FOR_BETA_TESTING"
                and detail.get("attributes", {}).get("autoNotifyEnabled") is False
            ):
                raise UploadError(
                    "This build is ready for external testing with automatic tester notifications disabled. "
                    "Choose Start Testing for the build in App Store Connect, then resume with --build-id. "
                    "The helper will not override this hold or notify testers."
                )
            if (state, review_state) != previous:
                print(
                    f"External TestFlight state: {state}; beta review state: {review_state}.",
                    flush=True,
                )
                previous = (state, review_state)
            if (
                build_id not in assigned
                and not attached
                and state in ready_states
                and review_state not in ("WAITING_FOR_REVIEW", "IN_REVIEW")
            ):
                self.request(
                    "POST",
                    group_builds,
                    body={"data": [{"type": "builds", "id": build_id}]},
                    allow_no_content=True,
                )
                attached = True
            assigned = {
                self.resource_id(item, "builds")
                for item in self.collection(group_builds)
            }
            if build_id in assigned and state == "IN_BETA_TESTING":
                print(
                    f"Build {build_id} is available in external TestFlight group {group_name!r}.",
                    flush=True,
                )
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise UploadError(
                    f"External TestFlight distribution is still pending; build {build_id}, externalBuildState {state!r}, betaReviewState {review_state!r}. Resume with --build-id; the build is not confirmed available to this group."
                )
            time.sleep(min(poll_interval, remaining))

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
    parser.add_argument(
        "--build-id",
        help="Distribute an existing processed build without uploading a package",
    )
    distribution = parser.add_mutually_exclusive_group()
    distribution.add_argument(
        "--testflight-group", help="Exact name of an existing internal TestFlight group"
    )
    distribution.add_argument(
        "--external-testflight-group",
        help="Exact name of an existing external TestFlight group; submit beta review when needed",
    )
    parser.add_argument("--whats-new", help="Set en-US TestFlight notes for this build")
    parser.add_argument(
        "--tester",
        action="append",
        default=[],
        metavar="EMAIL",
        help="Add and invite a tester to the internal group (repeatable)",
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
    if args.build_id is not None and not args.build_id.strip():
        parser.error("--build-id must not be empty")
    selected_group = args.testflight_group or args.external_testflight_group
    if any(
        group is not None and not group.strip()
        for group in (
            args.testflight_group,
            args.external_testflight_group,
        )
    ):
        parser.error("TestFlight group names must not be empty")
    if args.external_testflight_group and args.tester:
        parser.error("--tester is only supported with an internal --testflight-group")
    if any(not re.fullmatch(r"[^@\s]+@[^@\s]+", email) for email in args.tester):
        parser.error("each --tester must be an email address without whitespace")
    if args.build_id and (
        args.package is not None or args.preflight or args.validate_only
    ):
        parser.error(
            "--build-id cannot be combined with a package, --preflight, or --validate-only"
        )
    if args.build_id and not selected_group:
        parser.error(
            "--build-id requires --testflight-group or --external-testflight-group"
        )
    if (args.whats_new is not None or args.tester) and not selected_group:
        parser.error("--whats-new and --tester require a TestFlight group")
    if selected_group and (args.preflight or args.validate_only):
        parser.error(
            "TestFlight distribution cannot be combined with --preflight or --validate-only"
        )
    if not args.preflight and not args.build_id and args.package is None:
        parser.error("package is required unless --preflight or --build-id is selected")
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
            uploader = BuildUploader(Token.from_environment())
            build_id = args.build_id or uploader.upload(
                args.package,
                args.app_id,
                platform=args.platform,
                metadata=metadata,
                poll_interval=args.poll_interval,
                timeout=args.timeout,
            )
            if args.testflight_group:
                uploader.distribute(
                    build_id,
                    args.app_id,
                    args.testflight_group,
                    whats_new=args.whats_new,
                    testers=args.tester,
                    poll_interval=args.poll_interval,
                    timeout=args.timeout,
                )
            elif args.external_testflight_group:
                uploader.distribute_external(
                    build_id,
                    args.app_id,
                    args.external_testflight_group,
                    whats_new=args.whats_new,
                    poll_interval=args.poll_interval,
                    timeout=args.timeout,
                )
    except (UploadError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
