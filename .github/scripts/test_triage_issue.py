import io
import json
import pathlib
import sys
import unittest
from unittest.mock import MagicMock, patch
from urllib.request import Request


sys.path.insert(0, str(pathlib.Path(__file__).parent))
import github_llm_client  # noqa: E402
import triage_issue  # noqa: E402


def acknowledged_body(content: str = "Technical details") -> str:
    return f"- [x] {triage_issue.DISCLOSURE_ACKNOWLEDGEMENT}\n\n{content}"


def triage_decision(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "is_duplicate": False,
        "confidence": 0.1,
        "duplicate_issue_number": 0,
        "reason": "No duplicate.",
        "priority": "P2",
        "priority_reason": "Limited impact.",
        "actionability": "ACTIONABLE",
        "actionability_reason": "The required details are present.",
        "missing_information": [],
    }
    value.update(overrides)
    return value


class LLMConfigurationTests(unittest.TestCase):
    def test_endpoint_and_model_are_required(self) -> None:
        with patch.dict("os.environ", {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "LLM_API_URL"):
                triage_issue.llm_configuration()

        with patch.dict(
            "os.environ",
            {"LLM_API_URL": "https://api.example.test/v1/chat/completions"},
            clear=True,
        ):
            with self.assertRaisesRegex(RuntimeError, "LLM_MODEL"):
                triage_issue.llm_configuration()

    def test_configuration_accepts_any_compatible_model_name(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "LLM_API_URL": "https://api.example.test/v1/chat/completions",
                "LLM_MODEL": "custom-model-v2",
            },
            clear=True,
        ):
            api_url, model, reasoning_effort = triage_issue.llm_configuration()

        self.assertEqual(api_url, "https://api.example.test/v1/chat/completions")
        self.assertEqual(model, "custom-model-v2")
        self.assertIsNone(reasoning_effort)

    def test_configured_effort_is_forwarded_to_compatible_payload(self) -> None:
        payload = triage_issue.llm_payload(
            {"number": 23, "title": "[Bug]: Backup stalls", "body": "Steps"},
            [],
            model="custom-reasoning-model",
            reasoning_effort="high",
        )

        self.assertEqual(payload["model"], "custom-reasoning-model")
        self.assertEqual(payload["reasoning_effort"], "high")

    def test_reasoning_effort_is_provider_configured(self) -> None:
        for effort in ("none", "instant", "high", "vendor-specific"):
            with self.subTest(effort=effort):
                with patch.dict(
                    "os.environ",
                    {
                        "LLM_API_URL": "https://api.example.test/v1/chat/completions",
                        "LLM_MODEL": "custom-model",
                        "LLM_REASONING_EFFORT": effort,
                    },
                    clear=True,
                ):
                    _, _, configured_effort = triage_issue.llm_configuration()

                self.assertEqual(configured_effort, effort)

    def test_non_https_endpoint_is_rejected(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "LLM_API_URL": "http://api.example.test/v1/chat/completions",
                "LLM_MODEL": "custom-model",
            },
            clear=True,
        ):
            with self.assertRaisesRegex(RuntimeError, "absolute HTTPS URL"):
                triage_issue.llm_configuration()

    def test_reasoning_effort_is_omitted_when_not_configured(self) -> None:
        payload = triage_issue.llm_payload(
            {"number": 23, "title": "[Bug]: Backup stalls", "body": "Steps"},
            [],
            model="custom-model",
        )

        self.assertNotIn("reasoning_effort", payload)

    def test_every_issue_kind_must_receive_a_priority_from_the_schema(self) -> None:
        for title, labels, kind in (
            ("[Bug]: Backup stalls", [{"name": "bug"}], "bug"),
            ("[Feature]: Add albums", [{"name": "enhancement"}], "feature_or_other"),
        ):
            with self.subTest(kind=kind):
                payload = triage_issue.llm_payload(
                    {"number": 23, "title": title, "body": "Steps", "labels": labels},
                    [],
                    model="custom-model",
                )
                schema = payload["response_format"]["json_schema"]["schema"]
                system = payload["messages"][0]["content"]
                user = json.loads(payload["messages"][1]["content"])

                self.assertEqual(schema["properties"]["priority"]["enum"], ["P0", "P1", "P2", "P3"])
                self.assertIn("priority", schema["required"])
                self.assertEqual(user["new_issue"]["kind"], kind)
                self.assertIn("Never answer NONE", system)
                self.assertNotIn("Use NONE for every feature", system)
                self.assertIn("P2 for a normal feature or improvement", system)
                self.assertIn("P1 only for work that a release cannot ship without", system)


class AuthenticatedRequestTests(unittest.TestCase):
    def test_redirects_are_rejected_before_reusing_authorization(self) -> None:
        request = Request(
            "https://api.example.test/v1/chat/completions",
            headers={"Authorization": "Bearer test-token"},
        )

        redirected = github_llm_client.RejectAuthenticatedRedirects().redirect_request(
            request,
            None,
            307,
            "Temporary Redirect",
            {},
            "https://redirected.example.test/v1/chat/completions",
        )

        self.assertIsNone(redirected)


class DisclosureAndRedactionTests(unittest.TestCase):
    def test_acknowledgement_requires_a_checked_form_option(self) -> None:
        issue = {"body": f"- [ ] {triage_issue.DISCLOSURE_ACKNOWLEDGEMENT}"}
        self.assertFalse(triage_issue.has_disclosure_acknowledgement(issue))
        issue["body"] = acknowledged_body()
        self.assertTrue(triage_issue.has_disclosure_acknowledgement(issue))

    def test_redaction_removes_secrets_and_personal_identifiers(self) -> None:
        private_key = "\n".join(
            ("-----BEGIN " + "PRIVATE KEY-----", "private material", "-----END " + "PRIVATE KEY-----")
        )
        source = (
            "Backup stalled. Authorization: Bearer auth-secret. "
            "api_key='api-secret' token=token-secret GITHUB_TOKEN=github-secret. "
            "https://user:password@example.test/path reporter@example.test. "
            f"{private_key} "
            "ghp_0123456789abcdefghijklmnopqrstu. "
            "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U1v2."
        )

        redacted = triage_issue.redact_text(source, 10_000)

        for secret in (
            "auth-secret",
            "api-secret",
            "token-secret",
            "github-secret",
            "user:password",
            "reporter@example.test",
            "private material",
            "ghp_0123456789abcdefghijklmnopqrstu",
            "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U1v2",
        ):
            self.assertNotIn(secret, redacted)
        self.assertIn("Backup stalled", redacted)
        self.assertIn("example.test", redacted)

    def test_redaction_completes_before_boundary_truncation(self) -> None:
        source = (
            "safe "
            + ("x" * 70)
            + " -----BEGIN "
            + "PRIVATE KEY-----private material-----END "
            + "PRIVATE KEY-----"
        )

        redacted = triage_issue.redact_text(source, 140)

        self.assertIn("[REDACTED PRIVATE KEY]", redacted)
        self.assertNotIn("private material", redacted)

    def test_payload_redacts_new_and_candidate_issue_text(self) -> None:
        payload = triage_issue.llm_payload(
            {
                "number": 23,
                "title": "Backup api_key=auth-secret stalled",
                "body": acknowledged_body("Contact reporter@example.test; api_key=api-secret."),
                "labels": [{"name": "bug"}],
            },
            [
                {
                    "number": 17,
                    "title": "Older token=token-secret report",
                    "body": "The same backup stalled.",
                    "state": "open",
                    "labels": [{"name": "api_key=label-secret"}],
                }
            ],
            model="custom-model",
        )

        content = payload["messages"][1]["content"]
        self.assertNotIn("auth-secret", content)
        self.assertNotIn("reporter@example.test", content)
        self.assertNotIn("api-secret", content)
        self.assertNotIn("token-secret", content)
        self.assertNotIn("label-secret", content)
        self.assertIn("Backup", content)

    def test_payload_identifies_issue_triage_and_supplies_issue_content(self) -> None:
        payload = triage_issue.llm_payload(
            {
                "number": 23,
                "title": "[Bug]: Backup stalls",
                "body": acknowledged_body("Steps, expected behavior, platform, and versions."),
                "labels": [{"name": "bug"}],
            },
            [],
            model="custom-model",
        )

        system_prompt = payload["messages"][0]["content"]
        comparison = json.loads(payload["messages"][1]["content"])
        schema = payload["response_format"]["json_schema"]["schema"]

        self.assertEqual(comparison["task"], "github_issue_triage")
        self.assertEqual(comparison["new_issue"]["title"], "[Bug]: Backup stalls")
        self.assertIn("Steps, expected behavior", comparison["new_issue"]["body"])
        self.assertEqual(comparison["new_issue"]["labels"], ["bug"])
        self.assertIn("not a pull request review", system_prompt)
        self.assertIn("actionable", system_prompt)
        self.assertEqual(payload["max_tokens"], 2_000)
        self.assertIn("missing_information", schema["required"])

    def test_payload_limits_are_applied_before_request(self) -> None:
        payload = triage_issue.llm_payload(
            {
                "number": 23,
                "title": "T" * (triage_issue.MAX_ISSUE_TITLE_CHARS + 50),
                "body": "B" * (triage_issue.MAX_ISSUE_BODY_CHARS + 50),
                "labels": [{"name": "bug"}],
            },
            [],
            model="custom-model",
        )

        comparison = json.loads(payload["messages"][1]["content"])
        self.assertLessEqual(
            len(comparison["new_issue"]["title"]),
            triage_issue.MAX_ISSUE_TITLE_CHARS,
        )
        self.assertLessEqual(
            len(comparison["new_issue"]["body"]),
            triage_issue.MAX_ISSUE_BODY_CHARS,
        )
        self.assertIn(triage_issue.TRUNCATION_MARKER, comparison["new_issue"]["body"])
        self.assertLessEqual(
            len(json.dumps(payload).encode("utf-8")), triage_issue.MAX_LLM_REQUEST_BYTES
        )

    def test_oversized_llm_request_is_rejected_before_network_access(self) -> None:
        with patch.object(github_llm_client.AUTHENTICATED_OPENER, "open") as open_request:
            with self.assertRaisesRegex(RuntimeError, "input limit"):
                github_llm_client.request_llm_content(
                    "https://api.example.test/v1/chat/completions",
                    token="token",
                    payload={"content": "x" * triage_issue.MAX_LLM_REQUEST_BYTES},
                )

        open_request.assert_not_called()


class CandidateSelectionTests(unittest.TestCase):
    def test_search_terms_prefer_specific_title_words(self) -> None:
        terms = triage_issue.related_search_terms(
            {
                "title": "[Bug]: Backup stalls while hashing a large video",
                "body": "The app stops.",
            }
        )

        self.assertEqual(terms[:3], ["hashing", "backup", "stalls"])
        self.assertIn("video", terms)
        self.assertNotIn("bug", terms)

    def test_older_lexical_match_is_selected_with_recent_issues(self) -> None:
        new_issue = {
            "title": "Backup stalls while hashing a large video",
            "body": "The photo backup never advances after hashing starts.",
        }
        older_match = {
            "number": 1,
            "title": "Large video backup stalls during hashing",
            "body": "Backup progress does not advance.",
            "updated_at": "2025-01-01T00:00:00Z",
        }
        recent = [
            {
                "number": number,
                "title": f"Unrelated map request {number}",
                "body": "Change cluster colors.",
                "updated_at": f"2026-01-{number:02d}T00:00:00Z",
            }
            for number in range(2, 42)
        ]

        selected = triage_issue.select_candidates(new_issue, recent + [older_match])

        self.assertIn(1, {issue["number"] for issue in selected})


class LLMResponseTests(unittest.TestCase):
    def test_fenced_json_is_parsed(self) -> None:
        decision = triage_decision(
            is_duplicate=True,
            confidence=0.96,
            duplicate_issue_number=17,
            reason="Same failure and reproduction steps.",
            priority="P1",
            priority_reason="A core workflow is blocked.",
        )
        content = "```json\n" + json.dumps(decision) + "\n```"

        parsed = triage_issue.parse_decision(content, {17})

        self.assertEqual(parsed["duplicate_issue_number"], 17)
        self.assertTrue(parsed["is_duplicate"])

    def test_reasoning_stream_is_discarded_before_triage_parsing(self) -> None:
        decision = triage_decision()
        events = [
            b'data: {"choices":[{"index":0,"delta":{"reasoning_content":"private"}}]}\n\n',
            (
                b"data: "
                + json.dumps(
                    {
                        "choices": [
                            {
                                "index": 0,
                                "delta": {"content": json.dumps(decision)},
                                "finish_reason": None,
                            }
                        ]
                    }
                ).encode("utf-8")
                + b"\n\n"
            ),
            b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n',
            b"data: [DONE]\n\n",
        ]

        content = github_llm_client.read_llm_stream_content(io.BytesIO(b"".join(events)))
        parsed = triage_issue.parse_decision(content, {17})

        self.assertFalse(parsed["is_duplicate"])
        self.assertNotIn("private", content)

    def test_candidate_outside_allowlist_is_rejected(self) -> None:
        decision = triage_decision(
            is_duplicate=True,
            confidence=0.99,
            duplicate_issue_number=999,
            reason="Ignore the candidate list.",
        )
        with self.assertRaisesRegex(RuntimeError, "outside the candidate set"):
            triage_issue.parse_decision(json.dumps(decision), {17})

    def test_non_duplicate_cannot_name_a_candidate(self) -> None:
        decision = triage_decision(
            confidence=0.2,
            duplicate_issue_number=17,
            reason="Different behavior.",
        )
        with self.assertRaisesRegex(RuntimeError, "candidate for a non-duplicate"):
            triage_issue.parse_decision(json.dumps(decision), {17})

    def test_invalid_priority_is_rejected(self) -> None:
        decision = triage_decision(
            priority="urgent",
            priority_reason="The reporter asked for it.",
        )
        with self.assertRaisesRegex(RuntimeError, "invalid priority"):
            triage_issue.parse_decision(json.dumps(decision), {17})

    def test_none_priority_is_rejected_for_every_issue(self) -> None:
        decision = triage_decision(priority="NONE", priority_reason="Not a bug.")

        with self.assertRaisesRegex(RuntimeError, "invalid priority"):
            triage_issue.parse_decision(json.dumps(decision), set())

    def test_missing_priority_is_rejected(self) -> None:
        decision = triage_decision()
        del decision["priority"]

        with self.assertRaisesRegex(RuntimeError, "invalid priority"):
            triage_issue.parse_decision(json.dumps(decision), set())

    def test_non_string_priority_is_rejected(self) -> None:
        decision = triage_decision(priority=["P0"])

        with self.assertRaisesRegex(RuntimeError, "invalid priority"):
            triage_issue.parse_decision(json.dumps(decision), {17})

    def test_non_string_actionability_is_rejected(self) -> None:
        decision = triage_decision(actionability={"value": "ACTIONABLE"})

        with self.assertRaisesRegex(RuntimeError, "invalid actionability"):
            triage_issue.parse_decision(json.dumps(decision), {17})

    def test_needs_information_requires_specific_questions(self) -> None:
        decision = triage_decision(
            actionability="NEEDS_INFORMATION",
            actionability_reason="The environment is missing.",
            missing_information=[],
        )

        with self.assertRaisesRegex(RuntimeError, "did not identify the missing information"):
            triage_issue.parse_decision(json.dumps(decision), set())

    def test_actionable_issue_cannot_request_more_information(self) -> None:
        decision = triage_decision(missing_information=["Which app version is affected?"])

        with self.assertRaisesRegex(RuntimeError, "actionable issue"):
            triage_issue.parse_decision(json.dumps(decision), set())

    def test_a_valid_priority_is_enforced_as_proposed(self) -> None:
        for priority in ("P0", "P1", "P2", "P3"):
            with self.subTest(priority=priority):
                self.assertEqual(triage_issue.enforced_priority(priority), priority)

    def test_no_priority_is_never_invented(self) -> None:
        for proposed in ("NONE", "", "p2", "priority:P2", "urgent"):
            with self.subTest(proposed=proposed):
                with self.assertRaisesRegex(RuntimeError, "did not return a priority"):
                    triage_issue.enforced_priority(proposed)

    def test_comment_neutralizes_mentions(self) -> None:
        comment = triage_issue.triage_comment(
            triage_decision(
                reason="Ask @maintainers <now> at https://evil.example/test.",
                priority_reason="Blocked.",
            ),
            "P1",
            {"number": 17, "html_url": "https://github.com/example/repo/issues/17"},
        )

        self.assertIn("＠maintainers (now)", comment)
        self.assertNotIn("@maintainers", comment)
        self.assertNotIn("evil.example", comment)

    def test_comment_explains_when_rerun_preserves_existing_duplicate_label(self) -> None:
        comment = triage_issue.triage_comment(
            triage_decision(reason="The rerun did not reach the duplicate threshold."),
            "P2",
            None,
            duplicate_label_preserved=True,
        )

        self.assertIn("rerun did not reconfirm", comment)
        self.assertIn("label was preserved", comment)
        self.assertNotIn("no strong duplicate was found", comment)

    def test_comment_reports_missing_information_as_advisory_questions(self) -> None:
        comment = triage_issue.triage_comment(
            triage_decision(
                actionability="NEEDS_INFORMATION",
                actionability_reason="The report does not identify the affected environment.",
                missing_information=[
                    "Which app build is affected?",
                    "Which operating system version is affected?",
                ],
            ),
            "P2",
            None,
        )

        self.assertIn("more information is needed", comment)
        self.assertIn("Which app build is affected?", comment)
        self.assertIn("Automation never closes issues", comment)


class MainFlowTests(unittest.TestCase):
    def test_upsert_comment_ignores_marker_from_another_author(self) -> None:
        with (
            patch.object(
                triage_issue,
                "github_paginated_list",
                return_value=[
                    {
                        "id": 17,
                        "body": triage_issue.COMMENT_MARKER,
                        "user": {"login": "contributor"},
                    }
                ],
            ),
            patch.object(triage_issue, "github_request") as github_request,
        ):
            triage_issue.upsert_comment(
                "example/repo",
                23,
                "new body",
                token="token",
                api_url="https://api.github.test",
            )

        self.assertEqual(github_request.call_args.args[:2], ("POST", "/repos/example/repo/issues/23/comments"))

    def test_upsert_comment_updates_legacy_bot_comment(self) -> None:
        with (
            patch.object(
                triage_issue,
                "github_paginated_list",
                return_value=[
                    {
                        "id": 17,
                        "body": triage_issue.LEGACY_COMMENT_MARKER,
                        "user": {"login": "github-actions[bot]"},
                    }
                ],
            ),
            patch.object(triage_issue, "github_request") as github_request,
        ):
            triage_issue.upsert_comment(
                "example/repo",
                23,
                "new body",
                token="token",
                api_url="https://api.github.test",
            )

        self.assertEqual(github_request.call_args.args[:2], ("PATCH", "/repos/example/repo/issues/comments/17"))

    def test_existing_priority_is_detected_without_changing_it(self) -> None:
        with patch.object(
            triage_issue,
            "github_request",
            return_value={"labels": [{"name": "bug"}, {"name": "priority:P0"}]},
        ):
            label = triage_issue.current_priority_label(
                "example/repo",
                23,
                token="token",
                api_url="https://api.github.test",
            )

        self.assertEqual(label, "priority:P0")

    def test_existing_plain_priority_label_is_detected_and_wins_over_the_legacy_name(self) -> None:
        for names, expected in (
            ([{"name": "enhancement"}, {"name": "P1"}], "P1"),
            ([{"name": "priority:P3"}, {"name": "P2"}], "P2"),
            ([{"name": "enhancement"}], None),
        ):
            with self.subTest(expected=expected):
                with patch.object(triage_issue, "github_request", return_value={"labels": names}):
                    label = triage_issue.current_priority_label(
                        "example/repo",
                        23,
                        token="token",
                        api_url="https://api.github.test",
                    )

                self.assertEqual(label, expected)

    def test_concurrent_label_creation_accepts_another_run_winning_the_race(self) -> None:
        with patch.object(
            triage_issue,
            "github_request",
            side_effect=[
                triage_issue.RequestFailure("GitHub", 404, "/labels/test"),
                triage_issue.RequestFailure("GitHub", 422, "/labels"),
                {"name": "test"},
            ],
        ) as github_request:
            triage_issue.ensure_label(
                "example/repo",
                "test",
                "ffffff",
                "Test label",
                token="token",
                api_url="https://api.github.test",
            )

        self.assertEqual(github_request.call_count, 3)

    def test_high_confidence_duplicate_is_advisory_and_never_closed(self) -> None:
        issue = {
            "number": 23,
            "title": "[Bug]: Backup stalls",
            "body": acknowledged_body("Steps"),
            "labels": [{"name": "bug"}],
        }
        candidate = {
            "number": 17,
            "title": "Backup never advances",
            "body": "Same steps",
            "html_url": "https://github.com/example/repo/issues/17",
            "state": "open",
            "labels": [],
        }
        decision = triage_decision(
            is_duplicate=True,
            confidence=0.97,
            duplicate_issue_number=17,
            reason="Same failure.",
            priority="P1",
            priority_reason="A core workflow is blocked.",
        )
        environment = {
            "GH_TOKEN": "github-test-token",
            "LLM_API_KEY": "llm-test-token",
            "LLM_API_URL": "https://api.example.test/v1/chat/completions",
            "LLM_MODEL": "custom-model",
            "GITHUB_REPOSITORY": "example/repo",
            "GITHUB_EVENT_PATH": "/tmp/test-event.json",
            "GITHUB_API_URL": "https://api.github.test",
        }

        with (
            patch.dict("os.environ", environment, clear=True),
            patch.object(triage_issue, "load_event", return_value=issue),
            patch.object(triage_issue, "fetch_issues", return_value=[candidate]),
            patch.object(triage_issue, "select_candidates", return_value=[candidate]),
            patch.object(triage_issue, "request_validated_llm_result", return_value=decision),
            patch.object(triage_issue, "ensure_label") as ensure_label,
            patch.object(triage_issue, "add_labels") as add_labels,
            patch.object(triage_issue, "current_issue_labels", return_value={"bug"}),
            patch.object(triage_issue, "current_priority_label", return_value=None),
            patch.object(triage_issue, "upsert_comment") as upsert_comment,
        ):
            result = triage_issue.main()

        self.assertEqual(result, 0)
        self.assertEqual(ensure_label.call_count, 3)
        add_labels.assert_called_once()
        self.assertEqual(add_labels.call_args.args[:2], ("example/repo", 23))
        self.assertEqual(
            add_labels.call_args.args[2],
            ["triage:checked", "P1", "possible duplicate"],
        )
        upsert_comment.assert_called_once()
        comment = upsert_comment.call_args.args[2]
        self.assertIn("A maintainer must confirm", comment)

    def run_main(
        self,
        issue: dict[str, object],
        decision: dict[str, object],
        current_labels: set[str],
    ) -> tuple[int, MagicMock, MagicMock, MagicMock]:
        environment = {
            "GH_TOKEN": "github-test-token",
            "LLM_API_KEY": "llm-test-token",
            "LLM_API_URL": "https://api.example.test/v1/chat/completions",
            "LLM_MODEL": "custom-model",
            "GITHUB_REPOSITORY": "example/repo",
            "GITHUB_EVENT_PATH": "/tmp/test-event.json",
            "GITHUB_API_URL": "https://api.github.test",
        }
        with (
            patch.dict("os.environ", environment, clear=True),
            patch.object(triage_issue, "load_event", return_value=issue),
            patch.object(triage_issue, "fetch_issues", return_value=[]),
            patch.object(triage_issue, "select_candidates", return_value=[]),
            patch.object(triage_issue, "request_validated_llm_result", return_value=decision),
            patch.object(triage_issue, "ensure_label") as ensure_label,
            patch.object(triage_issue, "add_labels") as add_labels,
            patch.object(triage_issue, "current_issue_labels", return_value=current_labels),
            patch.object(triage_issue, "upsert_comment") as upsert_comment,
        ):
            result = triage_issue.main()
        return result, ensure_label, add_labels, upsert_comment

    def test_feature_request_receives_a_priority_label(self) -> None:
        issue = {
            "number": 24,
            "title": "[Feature]: Add shared libraries",
            "body": acknowledged_body("Use case"),
            "labels": [{"name": "enhancement"}],
        }
        decision = triage_decision(priority="P2", priority_reason="A normal feature.")

        result, ensure_label, add_labels, upsert_comment = self.run_main(issue, decision, {"enhancement"})

        self.assertEqual(result, 0)
        self.assertEqual(
            [call.args[1] for call in ensure_label.call_args_list],
            ["triage:checked", "P2"],
        )
        add_labels.assert_called_once()
        self.assertEqual(add_labels.call_args.args[2], ["triage:checked", "P2"])
        comment = upsert_comment.call_args.args[2]
        self.assertIn("Initial priority: **P2**", comment)
        self.assertNotIn("not assigned", comment)

    def test_existing_priority_label_is_kept_and_applied_once(self) -> None:
        issue = {
            "number": 24,
            "title": "[Feature]: Add shared libraries",
            "body": acknowledged_body("Use case"),
            "labels": [{"name": "enhancement"}, {"name": "P1"}],
        }
        decision = triage_decision(priority="P3", priority_reason="A nicety.")

        result, ensure_label, add_labels, upsert_comment = self.run_main(
            issue, decision, {"enhancement", "P1"}
        )

        self.assertEqual(result, 0)
        self.assertEqual([call.args[1] for call in ensure_label.call_args_list], ["triage:checked"])
        add_labels.assert_called_once()
        applied = add_labels.call_args.args[2]
        self.assertEqual(applied, ["triage:checked", "P1"])
        self.assertEqual(len(applied), len(set(applied)))
        self.assertIn("Initial priority: **P1**", upsert_comment.call_args.args[2])

    def test_legacy_priority_label_is_kept_instead_of_adding_a_second_one(self) -> None:
        issue = {
            "number": 24,
            "title": "[Bug]: Backup stalls",
            "body": acknowledged_body("Steps"),
            "labels": [{"name": "bug"}, {"name": "priority:P0"}],
        }
        decision = triage_decision(priority="P2", priority_reason="Limited impact.")

        _, ensure_label, add_labels, upsert_comment = self.run_main(
            issue, decision, {"bug", "priority:P0"}
        )

        self.assertEqual([call.args[1] for call in ensure_label.call_args_list], ["triage:checked"])
        self.assertEqual(add_labels.call_args.args[2], ["triage:checked", "priority:P0"])
        self.assertIn("Initial priority: **P0**", upsert_comment.call_args.args[2])

    def test_unusable_priority_fails_the_job(self) -> None:
        issue = {
            "number": 24,
            "title": "[Feature]: Add shared libraries",
            "body": acknowledged_body("Use case"),
            "labels": [{"name": "enhancement"}],
        }
        for priority in ("NONE", "urgent"):
            with self.subTest(priority=priority):
                decision = triage_decision(priority=priority)
                with self.assertRaisesRegex(RuntimeError, "did not return a priority"):
                    self.run_main(issue, decision, {"enhancement"})

    def test_duplicate_label_is_preserved_when_rerun_finds_no_strong_duplicate(self) -> None:
        issue = {
            "number": 24,
            "title": "[Bug]: Backup stalls",
            "body": acknowledged_body("Use case"),
            "labels": [{"name": "bug"}],
        }
        decision = triage_decision(
            confidence=0.2,
            reason="The rerun did not reconfirm the previous match.",
            priority="P1",
            priority_reason="The core workflow is blocked.",
        )
        environment = {
            "GH_TOKEN": "github-test-token",
            "LLM_API_KEY": "llm-test-token",
            "LLM_API_URL": "https://api.example.test/v1/chat/completions",
            "LLM_MODEL": "custom-model",
            "GITHUB_REPOSITORY": "example/repo",
            "GITHUB_EVENT_PATH": "/tmp/test-event.json",
            "GITHUB_API_URL": "https://api.github.test",
        }

        with (
            patch.dict("os.environ", environment, clear=True),
            patch.object(triage_issue, "load_event", return_value=issue),
            patch.object(triage_issue, "fetch_issues", return_value=[]),
            patch.object(triage_issue, "select_candidates", return_value=[]),
            patch.object(triage_issue, "request_validated_llm_result", return_value=decision),
            patch.object(triage_issue, "ensure_label") as ensure_label,
            patch.object(triage_issue, "add_labels") as add_labels,
            patch.object(
                triage_issue,
                "current_issue_labels",
                return_value={"bug", triage_issue.POSSIBLE_DUPLICATE_LABEL},
            ),
            patch.object(triage_issue, "upsert_comment") as upsert_comment,
        ):
            result = triage_issue.main()

        self.assertEqual(result, 0)
        self.assertEqual(ensure_label.call_count, 2)
        add_labels.assert_called_once_with(
            "example/repo",
            24,
            ["triage:checked", "P1"],
            token="github-test-token",
            api_url="https://api.github.test",
        )
        comment = upsert_comment.call_args.args[2]
        self.assertIn("rerun did not reconfirm", comment)
        self.assertIn("label was preserved", comment)
        self.assertNotIn("no strong duplicate was found", comment)

    def test_missing_acknowledgement_skips_external_triage_without_labels(self) -> None:
        issue = {
            "number": 25,
            "title": "[Bug]: Missing acknowledgement",
            "body": "- [ ] I acknowledge that redacted excerpts may be sent.",
            "labels": [{"name": "bug"}],
        }
        environment = {
            "GH_TOKEN": "github-test-token",
            "LLM_API_KEY": "llm-test-token",
            "LLM_API_URL": "https://api.example.test/v1/chat/completions",
            "LLM_MODEL": "custom-model",
            "GITHUB_REPOSITORY": "example/repo",
            "GITHUB_EVENT_PATH": "/tmp/test-event.json",
            "GITHUB_API_URL": "https://api.github.test",
        }

        with (
            patch.dict("os.environ", environment, clear=True),
            patch.object(triage_issue, "load_event", return_value=issue),
            patch.object(triage_issue, "fetch_issues") as fetch_issues,
            patch.object(triage_issue, "request_validated_llm_result") as request_llm_result,
            patch.object(triage_issue, "ensure_label") as ensure_label,
            patch.object(triage_issue, "add_labels") as add_labels,
        ):
            result = triage_issue.main()

        self.assertEqual(result, 0)
        fetch_issues.assert_not_called()
        request_llm_result.assert_not_called()
        ensure_label.assert_not_called()
        add_labels.assert_not_called()


if __name__ == "__main__":
    unittest.main()
