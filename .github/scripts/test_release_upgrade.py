#!/usr/bin/env python3
"""Behavior checks for release upgrade selection and the explicit override."""

import unittest
from unittest.mock import patch
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from release_upgrade import UpgradeError, select_sources, select_plan, validate_override


def release(tag, published="2026-10-01T12:00:00Z", **changes):
    result = {
        "tag_name": tag,
        "draft": False,
        "prerelease": "-" in tag,
        "published_at": published,
    }
    result.update(changes)
    return result


class ReleaseUpgradeTests(unittest.TestCase):
    def test_stable_checks_every_supported_published_stable_predecessor(self):
        target = release("v1.1.0", "2026-10-08T12:00:00Z")
        history = [release("v1.0.5"), release("v1.0.3"), release("v1.0.4"), target]
        self.assertEqual(select_sources(target, history), ["v1.0.5"])

    def test_new_stable_releases_join_without_an_allowlist(self):
        target = release("v1.3.0", "2026-10-08T12:00:00Z")
        self.assertEqual(select_sources(target, [release("v1.0.4"), release("v1.0.5"),
                                                release("v1.1.0"), release("v1.2.0"), target]),
                         ["v1.0.5", "v1.1.0", "v1.2.0"])

    def test_beta_three_reports_the_exact_previous_beta_exception(self):
        target = release("v1.1.0-beta.3", "2026-10-08T12:00:00Z")
        plan = select_plan(target, [release("v1.0.5"), release("v1.1.0-beta.2"), target])
        self.assertEqual(plan["sources"], ["v1.0.5"])
        self.assertEqual(plan["untested"], ["v1.1.0-beta.2"])

    def test_later_beta_with_entry_is_not_excepted(self):
        target = release("v1.1.0-beta.4", "2026-10-08T12:00:00Z")
        plan = select_plan(target, [release("v1.0.5"), release("v1.1.0-beta.3"), target])
        self.assertEqual(plan, {"sources": ["v1.0.5", "v1.1.0-beta.3"], "untested": []})

    def test_stable_one_one_does_not_select_or_except_a_beta(self):
        target = release("v1.1.0", "2026-10-08T12:00:00Z")
        self.assertEqual(select_plan(target, [release("v1.0.5"), release("v1.1.0-beta.2"), target]),
                         {"sources": ["v1.0.5"], "untested": []})

    def test_beta_adds_the_previous_published_beta(self):
        target = release("v1.1.0-beta.2", "2026-10-08T12:00:00Z")
        history = [release("v1.0.5"), release("v1.1.0-beta.1"), release("v1.0.5-beta.3"), target]
        self.assertEqual(select_sources(target, history), ["v1.0.5", "v1.1.0-beta.1"])

    def test_previous_beta_uses_publication_time_not_response_order(self):
        target = release("v1.1.0-beta.11", "2026-10-08T12:00:00Z")
        history = [release("v1.1.0-beta.10", "2026-10-07T12:00:00Z"),
                   release("v1.1.0-beta.9", "2026-10-06T12:00:00Z"), target]
        self.assertEqual(select_sources(target, history), ["v1.1.0-beta.10"])

    def test_ignores_drafts_unpublished_and_future_releases(self):
        target = release("v1.1.0", "2026-10-08T12:00:00Z")
        history = [release("v1.0.3", draft=True), release("v1.0.4", published_at=None),
                   release("v1.0.5"), release("v1.2.0"),
                   release("v1.0.6", "2026-10-09T12:00:00Z"), target]
        self.assertEqual(select_sources(target, history), ["v1.0.5"])

    def test_semantic_versions_sort_numerically(self):
        target = release("v1.11.0", "2026-10-08T12:00:00Z")
        history = [release("v1.10.0"), release("v1.9.0"), target]
        self.assertEqual(select_sources(target, history), ["v1.9.0", "v1.10.0"])

    def test_beta_does_not_select_the_stable_of_the_same_version(self):
        target = release("v1.1.0-beta.2", "2026-10-08T12:00:00Z")
        self.assertEqual(select_sources(target, [release("v1.1.0"), target]), [])

    def test_rejects_ambiguous_duplicate_published_tags(self):
        target = release("v1.1.0")
        with self.assertRaises(UpgradeError):
            select_sources(target, [target, release("v1.0.5"), release("v1.0.5")])

    def test_rejects_missing_target_from_paginated_history(self):
        with self.assertRaises(UpgradeError):
            select_sources(release("v1.1.0"), [release("v1.0.5")])

    def test_rejects_prerelease_flag_that_disagrees_with_tag(self):
        target = release("v1.1.0")
        with self.assertRaises(UpgradeError):
            select_sources(target, [target, release("v1.0.5", prerelease=True)])

    def test_stable_sources_cannot_be_excepted_even_if_the_list_changes(self):
        target = release("v1.1.0")
        with patch("release_upgrade.PREVIOUS_BETA_WITHOUT_ENTRY", frozenset({"v1.0.5"})):
            self.assertEqual(select_plan(target, [release("v1.0.5"), target]),
                             {"sources": ["v1.0.5"], "untested": []})

    def test_cli_reports_the_previous_beta_exception_and_exports_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = release("v1.1.0-beta.3", "2026-10-08T12:00:00Z")
            (root / "release.json").write_text(json.dumps(target))
            (root / "history.json").write_text(json.dumps([release("v1.0.5"), release("v1.1.0-beta.2"), target]))
            subprocess.run([sys.executable, str(Path(__file__).with_name("release_upgrade.py")),
                            "--release", str(root / "release.json"), "--history", str(root / "history.json"),
                            "--output", str(root / "plan.json")], check=True, capture_output=True,
                           env={"GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary")})
            self.assertTrue((root / "summary").exists(), "The excluded beta is absent from the job summary")
            self.assertIn("nicht getestet: v1.1.0-beta.2 (kein Prüfeinstieg)", (root / "summary").read_text())
            self.assertIn('upgrade_sources=["v1.0.5"]', (root / "output").read_text())
            self.assertIn("upgrade_overridden=false", (root / "output").read_text())

    def test_cli_failure_records_the_cause_in_the_job_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "release.json").write_text(json.dumps(release("v1.1.0")))
            (root / "history.json").write_text("[]")
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("release_upgrade.py")),
                                     "--release", str(root / "release.json"), "--history", str(root / "history.json"),
                                     "--output", str(root / "plan.json")], capture_output=True,
                                    env={"GITHUB_STEP_SUMMARY": str(root / "summary")})
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((root / "summary").exists(), "The failure cause is absent from the job summary")
            self.assertIn("Target release is absent", (root / "summary").read_text())

    def test_no_override_needs_no_reason(self):
        self.assertFalse(validate_override("release", "refs/tags/v1.1.0", "v1.1.0", "", ""))

    def test_explicit_main_dispatch_override_requires_tag_and_reason(self):
        self.assertTrue(validate_override("workflow_dispatch", "refs/heads/main", "v1.1.0",
                                          "v1.1.0", "Confirmed infrastructure failure"))

    def test_rejects_automatic_wrong_ref_wrong_tag_and_empty_reason_overrides(self):
        cases = [("release", "refs/heads/main", "v1.1.0", "Reason"),
                 ("workflow_dispatch", "refs/heads/work/test", "v1.1.0", "Reason"),
                 ("workflow_dispatch", "refs/heads/main", "v1.0.5", "Reason"),
                 ("workflow_dispatch", "refs/heads/main", "v1.1.0", "   ")]
        for event, ref, confirmation, reason in cases:
            with self.subTest(event=event, ref=ref, confirmation=confirmation):
                with self.assertRaises(UpgradeError):
                    validate_override(event, ref, "v1.1.0", confirmation, reason)


if __name__ == "__main__":
    unittest.main()
