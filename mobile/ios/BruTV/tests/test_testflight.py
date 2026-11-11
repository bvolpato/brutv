#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "requests>=2.32,<3",
#     "PyJWT[crypto]>=2.10,<3",
# ]
# ///
"""Exercise internal TestFlight distribution against a local App Store Connect API."""

import contextlib
import importlib.util
import io
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlsplit

spec = importlib.util.spec_from_file_location(
    "upload_build", Path(__file__).parents[1] / "upload-build.py"
)
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)


class TestFlightTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.build_app = "1234"
        self.processing = "VALID"
        self.expired = False
        self.groups = [
            self.resource("betaGroups", "group-1", name="Team", isInternalGroup=True)
        ]
        self.builds = set()
        self.members = set()
        self.testers = {"existing@example.com": "tester-1"}
        self.localizations = []
        self.invite_errors = {}
        self.states = ["IN_BETA_TESTING"]
        self.persist_members = True
        self.next_page = None
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, data=None, status=200):
                body = json.dumps(data).encode() if data is not None else b""
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def record(self, body=None):
                outer.requests.append(
                    (self.command, self.path, dict(self.headers), body)
                )

            def do_GET(self):
                self.record()
                path = urlsplit(self.path).path
                query = parse_qs(urlsplit(self.path).query)
                if path == "/v1/builds/build-1":
                    self.reply(
                        {
                            "data": outer.resource(
                                "builds",
                                "build-1",
                                processingState=outer.processing,
                                expired=outer.expired,
                            )
                        }
                    )
                elif path == "/v1/builds/build-1/app":
                    self.reply({"data": outer.resource("apps", outer.build_app)})
                elif path == "/v1/apps/1234/betaGroups":
                    if outer.next_page and not query:
                        self.reply({"data": [], "links": {"next": outer.next_page}})
                    else:
                        self.reply({"data": outer.groups})
                elif path == "/v1/betaGroups/group-1/relationships/builds":
                    self.reply(
                        {
                            "data": [
                                outer.resource("builds", identity)
                                for identity in outer.builds
                            ]
                        }
                    )
                elif path == "/v1/betaGroups/group-1/relationships/betaTesters":
                    self.reply(
                        {
                            "data": [
                                outer.resource("betaTesters", identity)
                                for identity in outer.members
                            ]
                        }
                    )
                elif path == "/v1/betaTesters":
                    email = query["filter[email]"][0]
                    identity = outer.testers.get(email)
                    if query.get("filter[apps]") != ["1234"]:
                        self.reply({"errors": [{"code": "WRONG_APP_SCOPE"}]}, 400)
                        return
                    self.reply(
                        {
                            "data": [
                                outer.resource("betaTesters", identity, email=email)
                            ]
                            if identity
                            else []
                        }
                    )
                elif path == "/v1/builds/build-1/betaBuildLocalizations":
                    self.reply({"data": outer.localizations})
                elif path == "/v1/builds/build-1/buildBetaDetail":
                    state = (
                        outer.states.pop(0)
                        if len(outer.states) > 1
                        else outer.states[0]
                    )
                    self.reply(
                        {
                            "data": outer.resource(
                                "buildBetaDetails", "detail-1", internalBuildState=state
                            )
                        }
                    )
                else:
                    self.reply({"errors": [{"code": "NOT_FOUND"}]}, 404)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                self.record(body)
                if self.path == "/v1/betaGroups/group-1/relationships/builds":
                    outer.builds.update(item["id"] for item in body["data"])
                    self.reply(status=204)
                elif self.path == "/v1/betaGroups/group-1/relationships/betaTesters":
                    if outer.persist_members:
                        outer.members.update(item["id"] for item in body["data"])
                    self.reply(status=204)
                elif self.path == "/v1/betaTesters":
                    identity = "tester-new"
                    outer.testers[body["data"]["attributes"]["email"]] = identity
                    if outer.persist_members:
                        outer.members.add(identity)
                    self.reply({"data": outer.resource("betaTesters", identity)}, 201)
                elif self.path == "/v1/betaTesterInvitations":
                    identity = body["data"]["relationships"]["betaTester"]["data"]["id"]
                    code = outer.invite_errors.get(identity)
                    if code:
                        self.reply(
                            {
                                "errors": [
                                    {
                                        "code": code,
                                        "detail": "Arbitrary localized message",
                                    }
                                ]
                            },
                            409,
                        )
                    else:
                        self.reply(
                            {
                                "data": outer.resource(
                                    "betaTesterInvitations", "invite-1"
                                )
                            },
                            201,
                        )
                elif self.path == "/v1/betaBuildLocalizations":
                    resource = {**body["data"], "id": "notes-1"}
                    outer.localizations.append(resource)
                    self.reply({"data": resource}, 201)
                else:
                    self.reply({"errors": [{"code": "NOT_FOUND"}]}, 404)

            def do_PATCH(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                self.record(body)
                if self.path == "/v1/betaBuildLocalizations/notes-1":
                    outer.localizations[0]["attributes"].update(
                        body["data"]["attributes"]
                    )
                    self.reply({"data": outer.localizations[0]})
                else:
                    self.reply({"errors": [{"code": "NOT_FOUND"}]}, 404)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = f"http://127.0.0.1:{self.server.server_port}/v1"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.client = upload.BuildUploader(
            lambda: "private-token", api_base=self.base, allow_local_http=True
        )

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    @staticmethod
    def resource(kind, identity, **attributes):
        return {"type": kind, "id": identity, "attributes": attributes}

    def distribute(self, **options):
        with contextlib.redirect_stdout(io.StringIO()):
            self.client.distribute(
                "build-1", "1234", "Team", poll_interval=0.001, timeout=0.05, **options
            )

    def writes(self):
        return [item for item in self.requests if item[0] != "GET"]

    def test_distributes_build_adds_and_invites_requested_testers_then_verifies_availability(
        self,
    ):
        self.invite_errors["tester-1"] = "STATE_ERROR.TESTER_INVITE.ALREADY_ACCEPTED"
        self.states = [
            "READY_FOR_BETA_TESTING",
            "READY_FOR_BETA_TESTING",
            "IN_BETA_TESTING",
        ]
        self.distribute(
            whats_new="Playback fixes",
            testers=["existing@example.com", "new@example.com"],
        )
        self.assertEqual(self.builds, {"build-1"})
        self.assertEqual(self.members, {"tester-1", "tester-new"})
        creates = [item[3] for item in self.writes() if item[1] == "/v1/betaTesters"]
        self.assertEqual(
            creates[0]["data"]["relationships"]["betaGroups"]["data"],
            [{"type": "betaGroups", "id": "group-1"}],
        )
        invitations = [
            item[3]["data"]["relationships"]
            for item in self.writes()
            if item[1] == "/v1/betaTesterInvitations"
        ]
        self.assertEqual(len(invitations), 2)
        self.assertTrue(
            all(
                item["app"]["data"] == {"type": "apps", "id": "1234"}
                for item in invitations
            )
        )
        self.assertEqual(
            self.localizations[0]["attributes"],
            {"locale": "en-US", "whatsNew": "Playback fixes"},
        )
        self.assertEqual(
            self.localizations[0]["relationships"]["build"]["data"]["id"], "build-1"
        )
        self.assertEqual(
            len(
                [item for item in self.requests if item[1].endswith("buildBetaDetail")]
            ),
            3,
        )

    def test_retry_skips_existing_relations_and_unchanged_notes_but_resends_explicit_invitation(
        self,
    ):
        self.builds.add("build-1")
        self.members.add("tester-1")
        self.localizations = [
            self.resource(
                "betaBuildLocalizations", "notes-1", locale="en-US", whatsNew="Notes"
            )
        ]
        self.distribute(
            whats_new="Notes", testers=["EXISTING@example.com", "existing@example.com"]
        )
        self.assertEqual(
            [(item[0], item[1]) for item in self.writes()],
            [("POST", "/v1/betaTesterInvitations")],
        )

    def test_missing_export_compliance_blocks_notes_group_and_invitations_before_writes(
        self,
    ):
        self.states = ["MISSING_EXPORT_COMPLIANCE"]
        with (
            mock.patch.object(upload.time, "sleep") as sleep,
            self.assertRaises(upload.UploadError) as raised,
        ):
            self.distribute(whats_new="No write", testers=["existing@example.com"])
        self.assertEqual(self.writes(), [])
        sleep.assert_not_called()
        self.assertRegex(
            str(raised.exception),
            "MISSING_EXPORT_COMPLIANCE.*App Store Connect.*--build-id",
        )

    def test_omitted_notes_do_not_read_or_modify_notes_and_explicit_notes_patch_existing_localization(
        self,
    ):
        self.builds.add("build-1")
        self.distribute()
        self.assertFalse(any("Localizations" in item[1] for item in self.requests))
        self.assertEqual(self.writes(), [])
        self.localizations = [
            self.resource(
                "betaBuildLocalizations", "notes-1", locale="en-US", whatsNew="Old"
            )
        ]
        self.distribute(whats_new="New")
        self.assertEqual(
            [(item[0], item[1]) for item in self.writes()],
            [("PATCH", "/v1/betaBuildLocalizations/notes-1")],
        )
        self.assertEqual(self.localizations[0]["attributes"]["whatsNew"], "New")

    def test_wrong_app_unprocessed_expired_and_wrong_group_fail_before_writes(self):
        scenarios = [
            ("build_app", "9999", "does not belong"),
            ("processing", "PROCESSING", "VALID, nonexpired"),
            ("expired", True, "VALID, nonexpired"),
            ("expired", None, "VALID, nonexpired"),
            ("groups", [], "exactly one existing"),
            (
                "groups",
                [
                    self.resource(
                        "betaGroups", "group-1", name="team", isInternalGroup=True
                    )
                ],
                "exactly one existing",
            ),
            (
                "groups",
                [
                    self.resource(
                        "betaGroups", "group-1", name="Team", isInternalGroup=False
                    )
                ],
                "internal group",
            ),
            ("groups", self.groups * 2, "exactly one existing"),
        ]
        for field, value, message in scenarios:
            with self.subTest(field=field, value=value):
                previous = getattr(self, field)
                setattr(self, field, value)
                with self.assertRaisesRegex(upload.UploadError, message):
                    self.distribute(
                        whats_new="No write", testers=["existing@example.com"]
                    )
                self.assertEqual(self.writes(), [])
                setattr(self, field, previous)

    def test_same_named_external_group_is_not_selected_for_internal_delivery(self):
        self.groups.append(
            self.resource(
                "betaGroups", "external-1", name="Team", isInternalGroup=False
            )
        )
        self.distribute()
        self.assertEqual(self.builds, {"build-1"})
        self.assertTrue(all("external-1" not in item[1] for item in self.requests))

    def test_invitation_rejection_other_than_structured_already_accepted_fails(self):
        self.invite_errors["tester-1"] = "STATE_ERROR.TESTER_INVITE.NOT_ALLOWED"
        with self.assertRaises(upload.APIError) as raised:
            self.distribute(testers=["existing@example.com"])
        self.assertEqual(raised.exception.status, 409)
        self.assertEqual(
            raised.exception.codes, {"STATE_ERROR.TESTER_INVITE.NOT_ALLOWED"}
        )

    def test_successful_writes_do_not_imply_verified_membership_or_build_availability(
        self,
    ):
        self.persist_members = False
        with self.assertRaisesRegex(
            upload.UploadError, "Timed out verifying.*IN_BETA_TESTING"
        ):
            self.distribute(testers=["existing@example.com"])
        self.persist_members = True
        self.states = ["READY_FOR_BETA_TESTING"]
        with self.assertRaisesRegex(
            upload.UploadError, "Timed out verifying.*READY_FOR_BETA_TESTING"
        ):
            self.distribute()

    def test_follows_same_endpoint_pagination_and_rejects_foreign_links_before_request(
        self,
    ):
        self.next_page = self.base + "/apps/1234/betaGroups?cursor=next"
        self.distribute()
        self.assertTrue(any(item[1].endswith("?cursor=next") for item in self.requests))
        self.requests.clear()
        self.next_page = "https://example.com/collect-token"
        with self.assertRaisesRegex(upload.UploadError, "unsafe API URL"):
            self.distribute()
        self.assertEqual(
            [urlsplit(item[1]).path for item in self.requests],
            [
                "/v1/builds/build-1",
                "/v1/builds/build-1/app",
                "/v1/apps/1234/betaGroups",
            ],
        )
        self.assertEqual(self.writes(), [])

    def test_cyclic_pagination_fails_without_writes(self):
        self.next_page = self.base + "/apps/1234/betaGroups"
        with self.assertRaisesRegex(upload.UploadError, "cyclic"):
            self.distribute()
        self.assertEqual(self.writes(), [])

    def test_request_keeps_single_resource_validation_by_default(self):
        with self.assertRaisesRegex(upload.UploadError, "invalid resource response"):
            self.client.request("GET", "/apps/1234/betaGroups")
        self.assertEqual(
            len(
                self.client.request("GET", "/apps/1234/betaGroups", collection=True)[
                    "data"
                ]
            ),
            1,
        )

    def test_build_id_cli_distributes_without_package_or_upload(self):
        with (
            mock.patch(
                "sys.argv",
                [
                    "upload-build.py",
                    "--build-id",
                    "build-1",
                    "--app-id",
                    "1234",
                    "--testflight-group",
                    "Team",
                    "--tester",
                    "existing@example.com",
                    "--whats-new",
                    "Notes",
                ],
            ),
            mock.patch.object(
                upload.Token, "from_environment", return_value=lambda: "token"
            ),
            mock.patch.object(upload, "BuildUploader") as client,
        ):
            self.assertEqual(upload.main(), 0)
        client.return_value.upload.assert_not_called()
        client.return_value.distribute.assert_called_once_with(
            "build-1",
            "1234",
            "Team",
            whats_new="Notes",
            testers=["existing@example.com"],
            poll_interval=15,
            timeout=1800,
        )

    def test_upload_cli_distributes_the_build_id_returned_after_processing(self):
        with (
            mock.patch(
                "sys.argv", ["upload-build.py", "app.ipa", "--testflight-group", "Team"]
            ),
            mock.patch.dict("os.environ", {}, clear=True),
            mock.patch.object(
                upload.Token, "from_environment", return_value=lambda: "token"
            ),
            mock.patch.object(upload, "BuildUploader") as client,
        ):
            client.return_value.upload.return_value = "processed-build"
            self.assertEqual(upload.main(), 0)
        self.assertEqual(
            client.return_value.distribute.call_args.args,
            ("processed-build", "6821989154", "Team"),
        )

    def test_conflicting_modes_fail_before_loading_credentials(self):
        combinations = [
            ["--build-id", "build-1"],
            ["--build-id", "build-1", "--testflight-group", "Team", "app.ipa"],
            ["--build-id", "build-1", "--preflight"],
            ["--build-id", "build-1", "--validate-only"],
            ["--preflight", "--testflight-group", "Team"],
            ["app.ipa", "--validate-only", "--testflight-group", "Team"],
            ["app.ipa", "--tester", "existing@example.com"],
            ["app.ipa", "--whats-new", "Notes"],
            ["app.ipa", "--testflight-group", " "],
            ["--build-id", " ", "--testflight-group", "Team"],
            ["app.ipa", "--testflight-group", "Team", "--tester", "invalid"],
        ]
        for args in combinations:
            with (
                self.subTest(args=args),
                mock.patch("sys.argv", ["upload-build.py", *args]),
                mock.patch.object(upload.Token, "from_environment") as token,
                contextlib.redirect_stderr(io.StringIO()),
                self.assertRaises(SystemExit) as error,
            ):
                upload.main()
            self.assertEqual(error.exception.code, 2)
            token.assert_not_called()


if __name__ == "__main__":
    unittest.main()
