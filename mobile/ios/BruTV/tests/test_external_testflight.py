#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "requests>=2.32,<3",
#     "PyJWT[crypto]>=2.10,<3",
# ]
# ///
"""Verify external TestFlight promotion against a local App Store Connect API."""

import contextlib
import importlib.util
import io
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from urllib.parse import urlsplit

spec = importlib.util.spec_from_file_location(
    "upload_build", Path(__file__).parents[1] / "upload-build.py"
)
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)


class ExternalTestFlightTests(unittest.TestCase):
    @staticmethod
    def resource(kind, identity, **attributes):
        return {"type": kind, "id": identity, "attributes": attributes}

    def setUp(self):
        self.requests = []
        self.processing = "VALID"
        self.expired = False
        self.audience = "APP_STORE_ELIGIBLE"
        self.app = "1234"
        self.groups = [
            self.resource(
                "betaGroups", "external-1", name="Public", isInternalGroup=False
            ),
            self.resource(
                "betaGroups", "internal-1", name="Public", isInternalGroup=True
            ),
        ]
        self.builds = {"old-build"}
        self.external_state = "READY_FOR_BETA_SUBMISSION"
        self.auto_notify = True
        self.review = None
        self.review_changes = []
        self.missing_review_status = 200
        self.submitted_state = "APPROVED"
        self.activate = True
        self.reflect_membership = True
        self.next_page = None
        self.overrides = {}
        self.contact = {
            "contactFirstName": "Private first name",
            "contactLastName": "Private last name",
            "contactPhone": "+10000000000",
            "contactEmail": "reviewer@example.com",
            "demoAccountRequired": False,
        }
        self.notes = [
            self.resource(
                "betaBuildLocalizations",
                "notes-1",
                locale="en-US",
                whatsNew="Playback fixes",
            )
        ]
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, payload=None, status=200):
                body = json.dumps(payload).encode() if payload is not None else b""
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def record(self):
                body = (
                    json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    if self.command in ("POST", "PATCH")
                    else None
                )
                outer.requests.append((self.command, self.path, body))
                override = outer.overrides.get((self.command, urlsplit(self.path).path))
                if override:
                    self.reply(override[1], override[0])
                return body, bool(override)

            def do_GET(self):
                _, handled = self.record()
                if handled:
                    return
                path = urlsplit(self.path).path
                if path == "/v1/builds/build-1":
                    self.reply(
                        {
                            "data": outer.resource(
                                "builds",
                                "build-1",
                                processingState=outer.processing,
                                expired=outer.expired,
                                buildAudienceType=outer.audience,
                            )
                        }
                    )
                elif path == "/v1/builds/build-1/app":
                    self.reply({"data": outer.resource("apps", outer.app)})
                elif path == "/v1/apps/1234/betaGroups":
                    if outer.next_page and not urlsplit(self.path).query:
                        self.reply({"data": [], "links": {"next": outer.next_page}})
                    else:
                        self.reply({"data": outer.groups})
                elif path == "/v1/betaGroups/external-1/relationships/builds":
                    self.reply(
                        {
                            "data": [
                                outer.resource("builds", identity)
                                for identity in outer.builds
                            ]
                        }
                    )
                elif path == "/v1/builds/build-1/buildBetaDetail":
                    self.reply(
                        {
                            "data": outer.resource(
                                "buildBetaDetails",
                                "detail-1",
                                externalBuildState=outer.external_state,
                                internalBuildState="IN_BETA_TESTING",
                                autoNotifyEnabled=outer.auto_notify,
                            )
                        }
                    )
                elif path == "/v1/builds/build-1/betaAppReviewSubmission":
                    if outer.review_changes:
                        state = outer.review_changes.pop(0)
                        outer.set_review(state)
                        if state == "APPROVED":
                            outer.external_state = "READY_FOR_BETA_TESTING"
                    if outer.review is None and outer.missing_review_status == 404:
                        self.reply({"errors": [{"code": "NOT_FOUND"}]}, 404)
                    else:
                        self.reply({"data": outer.review})
                elif path == "/v1/apps/1234/betaAppReviewDetail":
                    self.reply(
                        {
                            "data": outer.resource(
                                "betaAppReviewDetails", "contact-1", **outer.contact
                            )
                        }
                    )
                elif path == "/v1/builds/build-1/betaBuildLocalizations":
                    self.reply({"data": outer.notes})
                else:
                    self.reply({"errors": [{"code": "UNEXPECTED_ENDPOINT"}]}, 404)

            def do_POST(self):
                body, handled = self.record()
                if handled:
                    return
                if self.path == "/v1/betaAppReviewSubmissions":
                    outer.review = outer.resource(
                        "betaAppReviewSubmissions",
                        "review-1",
                        betaReviewState=outer.submitted_state,
                    )
                    outer.external_state = {
                        "APPROVED": "READY_FOR_BETA_TESTING",
                        "REJECTED": "BETA_REJECTED",
                    }.get(outer.submitted_state, "WAITING_FOR_BETA_REVIEW")
                    self.reply({"data": outer.review}, 201)
                elif self.path == "/v1/betaGroups/external-1/relationships/builds":
                    if outer.reflect_membership:
                        outer.builds.update(item["id"] for item in body["data"])
                    if outer.activate and outer.external_state in (
                        "BETA_APPROVED",
                        "READY_FOR_BETA_TESTING",
                        "IN_BETA_TESTING",
                    ):
                        outer.external_state = "IN_BETA_TESTING"
                    self.reply(status=204)
                elif self.path == "/v1/betaBuildLocalizations":
                    outer.notes.append({**body["data"], "id": "notes-1"})
                    self.reply({"data": outer.notes[-1]}, 201)
                else:
                    self.reply({"errors": [{"code": "UNEXPECTED_ENDPOINT"}]}, 404)

            def do_PATCH(self):
                body, handled = self.record()
                if handled:
                    return
                if self.path == "/v1/betaBuildLocalizations/notes-1":
                    outer.notes[0]["attributes"].update(body["data"]["attributes"])
                    self.reply({"data": outer.notes[0]})
                else:
                    self.reply({"errors": [{"code": "UNEXPECTED_ENDPOINT"}]}, 404)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = f"http://127.0.0.1:{self.server.server_port}/v1"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.client = upload.BuildUploader(
            lambda: "private-api-token", api_base=self.base, allow_local_http=True
        )

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def perform(self, **options):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.client.distribute_external(
                "build-1",
                "1234",
                "Public",
                poll_interval=0.001,
                timeout=0.04,
                **options,
            )
        return output.getvalue()

    def writes(self):
        return [
            (method, path, body)
            for method, path, body in self.requests
            if method != "GET"
        ]

    def set_review(self, state):
        self.review = self.resource(
            "betaAppReviewSubmissions", "review-1", betaReviewState=state
        )

    def test_missing_submission_null_or_404_submits_beta_review_then_preserves_existing_group_builds(
        self,
    ):
        for status in (200, 404):
            with self.subTest(missing_status=status):
                self.requests.clear()
                self.builds = {"old-build"}
                self.review = None
                self.external_state = "READY_FOR_BETA_SUBMISSION"
                self.missing_review_status = status
                output = self.perform()
                self.assertIn("available in external TestFlight group", output)
                self.assertEqual(self.builds, {"old-build", "build-1"})
                self.assertEqual(
                    [item[:2] for item in self.writes()],
                    [
                        ("POST", "/v1/betaAppReviewSubmissions"),
                        ("POST", "/v1/betaGroups/external-1/relationships/builds"),
                    ],
                )
                self.assertEqual(
                    self.writes()[0][2],
                    {
                        "data": {
                            "type": "betaAppReviewSubmissions",
                            "relationships": {
                                "build": {"data": {"type": "builds", "id": "build-1"}}
                            },
                        }
                    },
                )

    def test_approved_already_available_build_retry_is_read_only(self):
        self.set_review("APPROVED")
        self.external_state = "IN_BETA_TESTING"
        self.builds.add("build-1")
        self.perform()
        self.assertEqual(self.writes(), [])

    def test_internal_only_or_unconfirmed_audience_is_rejected_before_any_writes(self):
        for audience in ("INTERNAL_ONLY", None):
            with self.subTest(audience=audience):
                self.requests.clear()
                self.audience = audience
                with self.assertRaisesRegex(
                    upload.UploadError, "requires buildAudienceType APP_STORE_ELIGIBLE"
                ):
                    self.perform(whats_new="No write")
                self.assertEqual(self.writes(), [])
                self.assertEqual(
                    [item[1] for item in self.requests], ["/v1/builds/build-1"]
                )

    def test_approved_build_awaiting_manual_start_does_not_override_notification_hold(
        self,
    ):
        self.set_review("APPROVED")
        self.external_state = "READY_FOR_BETA_TESTING"
        self.auto_notify = False
        with (
            mock.patch.object(upload.time, "sleep") as sleep,
            self.assertRaisesRegex(
                upload.UploadError, "Choose Start Testing.*resume with --build-id"
            ),
        ):
            self.perform(whats_new="No write")
        self.assertEqual(self.writes(), [])
        sleep.assert_not_called()

    def test_new_approval_awaiting_manual_start_stops_after_submission_without_group_write(
        self,
    ):
        self.auto_notify = False
        with (
            mock.patch.object(upload.time, "sleep") as sleep,
            self.assertRaisesRegex(upload.UploadError, "Choose Start Testing"),
        ):
            self.perform()
        self.assertEqual(
            [item[1] for item in self.writes()], ["/v1/betaAppReviewSubmissions"]
        )
        sleep.assert_not_called()

    def test_testing_eligible_build_needs_no_review_submission(self):
        self.external_state = "READY_FOR_BETA_TESTING"
        self.perform()
        self.assertEqual(
            [item[1] for item in self.writes()],
            ["/v1/betaGroups/external-1/relationships/builds"],
        )

    def test_pending_review_timeout_keeps_assignment_and_approval_resume_is_read_only(
        self,
    ):
        for review_state, external_state in (
            ("WAITING_FOR_REVIEW", "WAITING_FOR_BETA_REVIEW"),
            ("IN_REVIEW", "IN_BETA_REVIEW"),
        ):
            with self.subTest(review=review_state):
                self.requests.clear()
                self.builds = {"old-build"}
                self.set_review(review_state)
                self.external_state = external_state
                with self.assertRaisesRegex(
                    upload.UploadError, "still pending.*Resume with --build-id"
                ):
                    self.perform()
                self.assertEqual(self.builds, {"old-build", "build-1"})
                self.assertEqual(self.external_state, external_state)
                self.assertEqual(
                    [item[:2] for item in self.writes()],
                    [("POST", "/v1/betaGroups/external-1/relationships/builds")],
                )
                self.requests.clear()
                self.set_review("APPROVED")
                self.external_state = "IN_BETA_TESTING"
                self.assertIn("available in external TestFlight group", self.perform())
                self.assertEqual(self.writes(), [])

    def test_newly_submitted_pending_review_is_not_resubmitted_on_resume(self):
        self.submitted_state = "WAITING_FOR_REVIEW"
        with self.assertRaisesRegex(upload.UploadError, "still pending"):
            self.perform()
        self.assertEqual(
            [item[1] for item in self.writes()],
            [
                "/v1/betaAppReviewSubmissions",
                "/v1/betaGroups/external-1/relationships/builds",
            ],
        )
        self.assertIn("build-1", self.builds)
        self.requests.clear()
        with self.assertRaisesRegex(upload.UploadError, "still pending"):
            self.perform()
        self.assertEqual(self.writes(), [])

    def test_rejected_review_requires_human_action_without_writes(self):
        self.set_review("REJECTED")
        with self.assertRaisesRegex(upload.UploadError, "rejected.*human review"):
            self.perform(whats_new="New notes")
        self.assertEqual(self.writes(), [])

    def test_pending_review_becomes_approved_during_wait_without_another_submission(
        self,
    ):
        self.set_review("WAITING_FOR_REVIEW")
        self.external_state = "WAITING_FOR_BETA_REVIEW"
        self.review_changes = ["WAITING_FOR_REVIEW", "APPROVED"]
        self.perform()
        self.assertEqual(
            [item[1] for item in self.writes()],
            ["/v1/betaGroups/external-1/relationships/builds"],
        )

    def test_rejection_after_submission_stops_before_group_assignment(self):
        self.submitted_state = "REJECTED"
        with self.assertRaisesRegex(upload.UploadError, "rejected.*human review"):
            self.perform()
        self.assertEqual(
            [item[1] for item in self.writes()], ["/v1/betaAppReviewSubmissions"]
        )

    def test_wrong_app_invalid_or_expired_build_and_internal_or_ambiguous_group_block_all_writes(
        self,
    ):
        scenarios = [
            ("app", "9999", "does not belong"),
            ("processing", "PROCESSING", "VALID, nonexpired"),
            ("expired", True, "VALID, nonexpired"),
            ("groups", self.groups[1:], "existing external"),
            ("groups", self.groups[:1] * 2, "existing external"),
            ("groups", [], "existing external"),
        ]
        for field, value, message in scenarios:
            with self.subTest(field=field, value=value):
                previous = getattr(self, field)
                setattr(self, field, value)
                with self.assertRaisesRegex(upload.UploadError, message):
                    self.perform(whats_new="Notes")
                self.assertEqual(self.writes(), [])
                setattr(self, field, previous)

    def test_review_preflight_reports_missing_field_names_without_private_values_or_writes(
        self,
    ):
        self.contact["contactPhone"] = ""
        self.contact["demoAccountRequired"] = True
        self.contact["demoAccountName"] = "private-demo-user"
        self.notes = []
        with self.assertRaises(upload.UploadError) as raised:
            self.perform()
        message = str(raised.exception)
        for field in (
            "contactPhone",
            "demoAccountPassword",
            "betaBuildLocalizations.whatsNew",
        ):
            self.assertIn(field, message)
        for private_value in (
            "Private first name",
            "Private last name",
            "reviewer@example.com",
            "private-demo-user",
        ):
            self.assertNotIn(private_value, message)
        self.assertEqual(self.writes(), [])

    def test_explicit_notes_supply_review_requirement_and_create_localization(self):
        self.notes = []
        self.perform(whats_new="What to test")
        self.assertEqual(
            self.notes[0]["attributes"], {"locale": "en-US", "whatsNew": "What to test"}
        )
        self.assertEqual(self.writes()[0][1], "/v1/betaBuildLocalizations")

    def test_approved_response_without_membership_or_external_testing_never_reports_success(
        self,
    ):
        self.set_review("APPROVED")
        self.external_state = "READY_FOR_BETA_TESTING"
        self.reflect_membership = False
        with self.assertRaisesRegex(
            upload.UploadError, "still pending.*not confirmed available"
        ):
            self.perform()
        self.assertEqual(len(self.writes()), 1)
        self.reflect_membership = True
        self.activate = False
        self.external_state = "READY_FOR_BETA_TESTING"
        with self.assertRaisesRegex(
            upload.UploadError, "still pending.*READY_FOR_BETA_TESTING"
        ):
            self.perform()

    def test_permission_errors_are_not_treated_as_missing_review(self):
        self.overrides[("GET", "/v1/builds/build-1/betaAppReviewSubmission")] = (
            403,
            {"errors": [{"code": "FORBIDDEN"}]},
        )
        with self.assertRaises(upload.APIError) as raised:
            self.perform()
        self.assertEqual(raised.exception.status, 403)
        self.assertEqual(self.writes(), [])

    def test_beta_review_submission_rejection_propagates_without_group_assignment(self):
        self.overrides[("POST", "/v1/betaAppReviewSubmissions")] = (
            409,
            {"errors": [{"code": "STATE_ERROR"}]},
        )
        with self.assertRaises(upload.APIError):
            self.perform()
        self.assertEqual(
            [item[1] for item in self.writes()], ["/v1/betaAppReviewSubmissions"]
        )

    def test_group_pagination_is_supported_but_foreign_links_receive_no_request(self):
        self.next_page = self.base + "/apps/1234/betaGroups?cursor=next"
        self.perform()
        self.requests.clear()
        self.next_page = "https://example.com/collect-token"
        with self.assertRaisesRegex(upload.UploadError, "unsafe API URL"):
            self.perform()
        self.assertEqual(self.writes(), [])
        self.assertEqual(len(self.requests), 3)

    def test_null_resource_is_only_accepted_when_explicitly_requested(self):
        with self.assertRaisesRegex(upload.UploadError, "invalid resource response"):
            self.client.request("GET", "/builds/build-1/betaAppReviewSubmission")
        self.assertIsNone(self.client.beta_review("/builds/build-1"))

    def test_external_cli_resumes_build_without_reuploading(self):
        with (
            mock.patch(
                "sys.argv",
                [
                    "upload-build.py",
                    "--app-id",
                    "1234",
                    "--build-id",
                    "build-1",
                    "--external-testflight-group",
                    "Public",
                ],
            ),
            mock.patch.object(
                upload.Token, "from_environment", return_value=lambda: "token"
            ),
            mock.patch.object(upload, "BuildUploader") as client,
        ):
            self.assertEqual(upload.main(), 0)
        client.return_value.upload.assert_not_called()
        client.return_value.distribute.assert_not_called()
        client.return_value.distribute_external.assert_called_once_with(
            "build-1", "1234", "Public", whats_new=None, poll_interval=15, timeout=1800
        )

    def test_external_cli_rejects_internal_mode_testers_and_offline_validation_before_credentials(
        self,
    ):
        for extra in (
            ["--testflight-group", "Internal"],
            ["--tester", "tester@example.com"],
            ["--preflight"],
            ["--validate-only"],
        ):
            with (
                self.subTest(extra=extra),
                mock.patch(
                    "sys.argv",
                    [
                        "upload-build.py",
                        "--build-id",
                        "build-1",
                        "--external-testflight-group",
                        "Public",
                        *extra,
                    ],
                ),
                mock.patch.object(upload.Token, "from_environment") as token,
                contextlib.redirect_stderr(io.StringIO()),
                self.assertRaises(SystemExit) as raised,
            ):
                upload.main()
            self.assertEqual(raised.exception.code, 2)
            token.assert_not_called()


if __name__ == "__main__":
    unittest.main()
