#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "requests>=2.32,<3",
#     "PyJWT[crypto]>=2.10,<3",
# ]
# ///
"""Exercise the Build Upload API protocol against a local HTTP server."""

import contextlib
import hashlib
import importlib.util
import io
import json
import plistlib
import struct
import tempfile
import threading
import unittest
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

spec = importlib.util.spec_from_file_location(
    "upload_build", Path(__file__).parents[1] / "upload-build.py"
)
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)


class UploadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ipa = Path(self.directory.name) / "BruTV.ipa"
        self.make_ipa()
        self.requests = []
        self.parts = []
        self.polls = 0
        self.failure = False
        self.pending = False
        self.invalid_ranges = False
        self.wrong_app = False
        self.part_status = 200
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, data, status=200):
                body = json.dumps(data).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                outer.requests.append(("GET", self.path, dict(self.headers), None))
                if self.path == "/v1/apps/6821989154":
                    bundle = "wrong.bundle" if outer.wrong_app else "com.bvolpato.brutv"
                    self.reply(
                        {
                            "data": {
                                "type": "apps",
                                "id": "6821989154",
                                "attributes": {"bundleId": bundle},
                            }
                        }
                    )
                elif self.path == "/v1/buildUploads/upload-1?include=build":
                    outer.polls += 1
                    state = (
                        "FAILED"
                        if outer.failure
                        else "PROCESSING"
                        if outer.pending or outer.polls == 1
                        else "COMPLETE"
                    )
                    attrs = {"state": state}
                    if outer.failure:
                        attrs["errors"] = [
                            {"code": "ITMS-90035", "description": "Invalid Signature"}
                        ]
                    self.reply(
                        {
                            "data": {
                                "type": "buildUploads",
                                "id": "upload-1",
                                "attributes": {"state": attrs},
                                "relationships": {
                                    "build": {
                                        "data": {"type": "builds", "id": "build-1"}
                                    }
                                },
                            },
                            "included": [
                                {
                                    "type": "builds",
                                    "id": "build-1",
                                    "attributes": {"processingState": "VALID"},
                                }
                            ],
                        }
                    )
                else:
                    self.reply({"errors": [{"code": "NOT_FOUND"}]}, 404)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                outer.requests.append(("POST", self.path, dict(self.headers), body))
                if self.path == "/v1/buildUploads":
                    self.reply(
                        {"data": {"id": "upload-1", "type": "buildUploads"}}, 201
                    )
                elif self.path == "/v1/buildUploadFiles":
                    size = outer.ipa.stat().st_size
                    cut = size // 2
                    operations = []
                    for index, (offset, length) in enumerate(
                        ((0, cut), (cut, size - cut))
                    ):
                        operations.append(
                            {
                                "method": "PUT",
                                "url": f"{outer.base}/part/{index}?signature=private-upload-token",
                                "offset": offset,
                                "length": length,
                                "requestHeaders": [
                                    {
                                        "name": "Content-Type",
                                        "value": "application/octet-stream",
                                    },
                                    {
                                        "name": "Content-Range",
                                        "value": f"bytes {offset}-{offset + length - 1}/{size}",
                                    },
                                    {"name": "X-Apple-Upload", "value": str(index)},
                                ],
                            }
                        )
                    if outer.invalid_ranges:
                        operations[1]["offset"] += 1
                    self.reply(
                        {
                            "data": {
                                "id": "file-1",
                                "type": "buildUploadFiles",
                                "attributes": {"uploadOperations": operations},
                            }
                        },
                        201,
                    )
                else:
                    self.reply({"errors": [{"code": "NOT_FOUND"}]}, 404)

            def do_PUT(self):
                data = self.rfile.read(int(self.headers["Content-Length"]))
                outer.parts.append((self.path, dict(self.headers), data))
                self.reply({}, outer.part_status)

            def do_PATCH(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                outer.requests.append(("PATCH", self.path, dict(self.headers), body))
                self.reply(
                    {
                        "data": {
                            "type": "buildUploadFiles",
                            "id": "file-1",
                            "attributes": {"assetDeliveryState": {"state": "COMPLETE"}},
                        }
                    }
                )

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.client = upload.BuildUploader(
            lambda: "secret-api-token",
            api_base=self.base + "/v1",
            allow_local_http=True,
        )

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def make_ipa(self, **overrides):
        info = {
            "CFBundleIdentifier": "com.bvolpato.brutv",
            "CFBundleVersion": "123",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleExecutable": "BruTV",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "UIDeviceFamily": [1, 2],
        }
        info.update(overrides)
        with zipfile.ZipFile(self.ipa, "w") as archive:
            root = "Payload/BruTV.app/"
            archive.writestr(root + "Info.plist", plistlib.dumps(info))
            archive.writestr(root + "BruTV", b"fake-signed-arm64-binary")
            archive.writestr(root + "embedded.mobileprovision", b"fake-profile")
            archive.writestr(
                root + "_CodeSignature/CodeResources", b"fake-signature-resources"
            )

    def perform(self, **options):
        with contextlib.redirect_stdout(io.StringIO()):
            return self.client.upload(
                self.ipa, "6821989154", poll_interval=0.001, timeout=2, **options
            )

    def test_full_upload_sends_exact_parts_commits_checksum_and_waits_for_processing(
        self,
    ):
        self.assertEqual(self.perform(), "build-1")
        self.assertEqual(self.polls, 2)
        self.assertEqual(
            b"".join(part[2] for part in self.parts), self.ipa.read_bytes()
        )
        for index, (_, headers, data) in enumerate(self.parts):
            self.assertNotIn("Authorization", headers)
            self.assertEqual(headers["X-Apple-Upload"], str(index))
            self.assertEqual(int(headers["Content-Length"]), len(data))
        create = next(
            item[3]
            for item in self.requests
            if item[:2] == ("POST", "/v1/buildUploads")
        )
        self.assertEqual(
            create["data"]["attributes"],
            {
                "cfBundleShortVersionString": "1.2.3",
                "cfBundleVersion": "123",
                "platform": "IOS",
            },
        )
        commit = next(item[3] for item in self.requests if item[0] == "PATCH")
        self.assertTrue(commit["data"]["attributes"]["uploaded"])
        self.assertEqual(
            commit["data"]["attributes"]["sourceFileChecksums"]["file"],
            {
                "algorithm": "MD5",
                "hash": hashlib.md5(self.ipa.read_bytes()).hexdigest(),
            },
        )
        self.assertTrue(
            all(
                item[2]["Authorization"] == "Bearer secret-api-token"
                for item in self.requests
            )
        )

    def test_apple_processing_rejection_is_a_failure_with_diagnostic(self):
        self.failure = True
        with self.assertRaisesRegex(
            upload.UploadError, "ITMS-90035: Invalid Signature"
        ):
            self.perform()

    def test_file_transfer_failure_does_not_commit_or_expose_upload_credentials(self):
        self.part_status = 403
        with self.assertRaisesRegex(
            upload.UploadError, "part 1 returned HTTP 403"
        ) as error:
            self.perform()
        self.assertNotIn("private-upload-token", str(error.exception))
        self.assertFalse(any(item[0] == "PATCH" for item in self.requests))

    def test_invalid_server_ranges_are_rejected_before_any_file_bytes_are_sent(self):
        self.invalid_ranges = True
        with self.assertRaisesRegex(upload.UploadError, "invalid upload byte range"):
            self.perform()
        self.assertEqual(self.parts, [])

    def test_timeout_never_reports_a_processing_build_as_success(self):
        self.pending = True
        with (
            self.assertRaisesRegex(upload.UploadError, "Timed out.*upload-1"),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.client.upload(
                self.ipa, "6821989154", poll_interval=0.005, timeout=0.02
            )

    def test_wrong_app_is_rejected_before_a_build_upload_is_created(self):
        self.wrong_app = True
        with self.assertRaisesRegex(
            upload.UploadError, "bundle identifier does not match"
        ):
            self.perform()
        self.assertEqual([item[0] for item in self.requests], ["GET"])

    def test_simulator_ipa_is_rejected_without_api_calls(self):
        self.make_ipa(CFBundleSupportedPlatforms=["iPhoneSimulator"])
        with self.assertRaisesRegex(upload.UploadError, "must target iPhoneOS"):
            self.perform()
        self.assertEqual(self.requests, [])

    def test_tvos_ipa_uses_tv_platform_and_rejects_ios_upload(self):
        self.make_ipa(CFBundleSupportedPlatforms=["AppleTVOS"], UIDeviceFamily=[3])
        with self.assertRaisesRegex(upload.UploadError, "must target iPhoneOS"):
            self.perform()
        self.assertEqual(self.perform(platform="TV_OS"), "build-1")
        create = next(
            item[3]
            for item in self.requests
            if item[:2] == ("POST", "/v1/buildUploads")
        )
        self.assertEqual(create["data"]["attributes"]["platform"], "TV_OS")

    def test_mac_package_requires_explicit_verified_metadata_and_uses_pkg_uti(self):
        self.ipa = Path(self.directory.name) / "BruTV.pkg"
        self.ipa.write_bytes(
            struct.pack(">4sHHQQI", b"xar!", 28, 1, 4, 4, 1)
            + b"TOC!"
            + b"signed-payload"
        )
        with self.assertRaisesRegex(upload.UploadError, "requires --bundle-id"):
            self.perform(platform="MAC_OS")
        self.assertEqual(self.requests, [])
        self.assertEqual(
            self.perform(
                platform="MAC_OS",
                metadata={
                    "bundle_id": "com.bvolpato.brutv",
                    "build": "123",
                    "version": "1.2.3",
                },
            ),
            "build-1",
        )
        create = next(
            item[3]
            for item in self.requests
            if item[:2] == ("POST", "/v1/buildUploads")
        )
        reserve = next(
            item[3]
            for item in self.requests
            if item[:2] == ("POST", "/v1/buildUploadFiles")
        )
        self.assertEqual(create["data"]["attributes"]["platform"], "MAC_OS")
        self.assertEqual(reserve["data"]["attributes"]["uti"], "com.apple.pkg")

    def test_token_is_an_apple_compatible_es256_jwt(self):
        key = ec.generate_private_key(ec.SECP256R1())
        pem = key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        token = upload.Token("KEY123", "issuer-id", pem)()
        claims = jwt.decode(
            token, key.public_key(), algorithms=["ES256"], audience="appstoreconnect-v1"
        )
        self.assertEqual(claims["iss"], "issuer-id")
        self.assertLessEqual(claims["exp"] - claims["iat"], 1200)
        self.assertEqual(jwt.get_unverified_header(token)["kid"], "KEY123")

    def api_environment(self, curve=None):
        key = ec.generate_private_key(curve or ec.SECP256R1())
        path = Path(self.directory.name) / "AuthKey_TEST123456.p8"
        path.write_bytes(
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )
        return {
            "IOS_ASC_KEY_ID": "TEST123456",
            "IOS_ASC_ISSUER_ID": "830fb3c3-72dd-4006-94af-3ca20de372a9",
            "IOS_ASC_PRIVATE_KEY_PATH": str(path),
        }

    def test_preflight_requires_no_package_and_makes_no_network_requests(self):
        env = self.api_environment()
        output = io.StringIO()
        with (
            mock.patch.dict("os.environ", env, clear=True),
            mock.patch("sys.argv", ["upload-build.py", "--preflight"]),
            mock.patch.object(upload, "BuildUploader") as uploader,
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(upload.main(), 0)
        uploader.assert_not_called()
        self.assertIn("offline preflight", output.getvalue())
        self.assertNotIn("TEST123456", output.getvalue())

    def test_preflight_rejects_private_key_with_wrong_curve(self):
        env = self.api_environment(ec.SECP384R1())
        error = io.StringIO()
        with (
            mock.patch.dict("os.environ", env, clear=True),
            mock.patch("sys.argv", ["upload-build.py", "--preflight"]),
            contextlib.redirect_stderr(error),
        ):
            self.assertEqual(upload.main(), 1)
        self.assertIn("P-256", error.getvalue())

    def test_preflight_rejects_invalid_app_id_before_loading_credentials(self):
        with (
            mock.patch(
                "sys.argv",
                ["upload-build.py", "--preflight", "--app-id", "invalid-app"],
            ),
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit) as error,
        ):
            upload.main()
        self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
