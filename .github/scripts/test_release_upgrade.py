#!/usr/bin/env python3
"""Behavior checks for release upgrade selection and the explicit override."""

import unittest
from unittest.mock import patch
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import release_upgrade
from release_upgrade import (
    UpgradeError, JOB_BUDGET_MINUTES, PLATFORMS, job_minutes, journey_points, select_sources, select_plan,
    upgrade_matrix, plan_matrix, unbudgeted_matrix, validate_override, MAX_MATRIX_JOBS, MIN_IOS_JOBS, shard_count,
)


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

    def test_the_journey_lists_its_points_once_for_the_matrix(self):
        journey = Path(__file__).resolve().parents[2] / "scripts/upgrade-test/run_journey.py"
        points = journey_points(journey)
        self.assertEqual(len(points), 12)
        self.assertEqual(len(set(points)), len(points))
        self.assertEqual(points[0], "backup.claimed")

    def test_the_matrix_covers_every_point_once_per_platform_and_fits_the_job_budget(self):
        points = [f"point.{index}" for index in range(12)]
        for source_count in range(0, 9):
            matrix = upgrade_matrix([f"v1.0.{index}" for index in range(source_count)], points)
            for platform in PLATFORMS:
                jobs = [job for job in matrix["include"] if job["platform"] == platform]
                with self.subTest(platform=platform, sources=source_count):
                    covered = [point for job in jobs for point in job["points"].split()]
                    self.assertEqual(sorted(covered), sorted(points))
                    self.assertEqual(len({job["shard"] for job in jobs}), len(jobs))
                    for job in jobs:
                        minutes = job_minutes(platform, max(1, source_count), len(job["points"].split()))
                        self.assertLessEqual(minutes, JOB_BUDGET_MINUTES)

    def test_more_sources_never_need_fewer_ios_jobs_and_a_new_point_needs_no_edit(self):
        points = [f"point.{index}" for index in range(12)]
        ios = lambda sources, points: [job for job in upgrade_matrix(sources, points)["include"]
                                       if job["platform"] == "iOS"]
        counts = [len(ios([f"v{index}" for index in range(sources)], points)) for sources in range(1, 9)]
        self.assertEqual(counts, sorted(counts))
        self.assertGreater(counts[3], counts[0])
        more = points + ["point.new"]
        covered = [point for job in ios(["a", "b", "c"], more) for point in job["points"].split()]
        self.assertEqual(sorted(covered), sorted(more))

    def test_one_source_runs_the_ios_gate_in_two_jobs_and_never_more_jobs_than_points(self):
        points = [f"point.{index}" for index in range(12)]
        shape = lambda sources, points, platform: [
            len(job["points"].split()) for job in upgrade_matrix(sources, points)["include"]
            if job["platform"] == platform]
        # One source fits one iOS job, but the minimum plans two of six points. macOS keeps one job.
        self.assertLessEqual(job_minutes("iOS", 1, 12), JOB_BUDGET_MINUTES)
        self.assertEqual(MIN_IOS_JOBS, 2)
        self.assertEqual(shape(["v1.0.5"], points, "iOS"), [6, 6])
        self.assertEqual(shape(["v1.0.5"], points, "macOS"), [12])
        self.assertEqual(shape([], points, "iOS"), [6, 6])
        # Three sources need three iOS jobs anyway.
        self.assertEqual(shape(["a", "b", "c"], points, "iOS"), [4, 4, 4])
        # The minimum never leaves a job without a point: one point is one job, two points are two jobs.
        self.assertEqual(shape(["v1.0.5"], ["point.a"], "iOS"), [1])
        self.assertEqual(shape(["v1.0.5"], ["point.a", "point.b"], "iOS"), [1, 1])
        # The minimum never breaks the budget rule and never plans an empty job.
        for sources in range(1, 9):
            for count in (1, 2, 5, 12):
                with self.subTest(sources=sources, points=count):
                    jobs = [len(job["points"].split()) for job in upgrade_matrix(
                        [f"v{index}" for index in range(sources)], points[:count])["include"]
                        if job["platform"] == "iOS"]
                    self.assertGreaterEqual(len(jobs), min(MIN_IOS_JOBS, count))
                    self.assertTrue(all(size >= 1 for size in jobs))
                    self.assertEqual(sum(jobs), count)
                    self.assertLessEqual(job_minutes("iOS", sources, max(jobs)), JOB_BUDGET_MINUTES)

    def test_shard_count_without_points_fails_with_an_upgrade_error_for_every_platform(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                with self.assertRaises(UpgradeError):
                    shard_count(platform, 1, 0)

    def test_a_point_that_no_job_can_hold_fails_with_its_cost(self):
        with self.assertRaisesRegex(UpgradeError, "more than the 165 minutes"):
            upgrade_matrix([f"v1.0.{index}" for index in range(40)], ["point.a", "point.b"])

    def test_a_plan_of_more_jobs_than_github_accepts_fails_before_it_is_exported(self):
        points = [f"point.{index}" for index in range(250)]
        sources = [f"v1.0.{index}" for index in range(8)]
        with self.assertRaisesRegex(UpgradeError, f"more than the {MAX_MATRIX_JOBS} that GitHub accepts"):
            upgrade_matrix(sources, points)

    def test_a_deliberate_override_falls_back_to_one_job_per_platform_when_no_plan_fits(self):
        points = [f"point.{index}" for index in range(12)]
        sources = [f"v1.0.{index}" for index in range(40)]
        with self.assertRaises(UpgradeError):
            plan_matrix(sources, points, overridden=False)
        matrix, note = plan_matrix(sources, points, overridden=True)
        self.assertEqual(matrix, unbudgeted_matrix(points))
        self.assertEqual([(job["platform"], len(job["points"].split())) for job in matrix["include"]],
                         [("iOS", 12), ("macOS", 12)])
        self.assertIn("more than the 165 minutes", note)
        self.assertIsNone(plan_matrix(["v1.0.5"], points, overridden=True)[1])

    def test_cli_keeps_the_override_escape_path_with_more_sources_than_a_job_can_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = release("v1.2.0", "2026-11-01T12:00:00Z")
            history = [release(f"v1.0.{index}") for index in range(5, 25)] + [target]
            (root / "release.json").write_text(json.dumps(target))
            (root / "history.json").write_text(json.dumps(history))
            command = [sys.executable, str(Path(__file__).with_name("release_upgrade.py")),
                       "--release", str(root / "release.json"), "--history", str(root / "history.json"),
                       "--output", str(root / "plan.json")]
            environment = {"GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary")}
            failed = subprocess.run(command, capture_output=True, env=environment)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("more than the 165 minutes", (root / "summary").read_text())
            overridden = subprocess.run(
                command + ["--event", "workflow_dispatch", "--ref", "refs/heads/main", "--override-tag", "v1.2.0",
                           "--override-reason", "Infrastructure failure"],
                capture_output=True, env=environment)
            self.assertEqual(overridden.returncode, 0, overridden.stderr)
            output = (root / "output").read_text()
            self.assertIn("upgrade_overridden=true", output)
            plan = json.loads((root / "plan.json").read_text())
            self.assertTrue(plan["overridden"])
            self.assertEqual([job["shard"] for job in plan["matrix"]["include"]], ["1-of-1", "1-of-1"])
            self.assertIn("more than the 165 minutes", (root / "summary").read_text())
            self.assertIn("the journey steps are skipped by the override, so the jobs only acknowledge it",
                          (root / "summary").read_text())

    def test_an_empty_point_listing_reports_the_listing_failure_and_invents_no_cost(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = release("v1.1.0-beta.3", "2026-10-08T12:00:00Z")
            (root / "release.json").write_text(json.dumps(target))
            (root / "history.json").write_text(json.dumps([release("v1.0.5"), target]))
            (root / "empty.py").write_text("pass\n")
            command = [sys.executable, str(Path(__file__).with_name("release_upgrade.py")),
                       "--release", str(root / "release.json"), "--history", str(root / "history.json"),
                       "--output", str(root / "plan.json"), "--journey", str(root / "empty.py")]
            environment = {"GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary")}
            self.assertNotEqual(subprocess.run(command, capture_output=True, env=environment).returncode, 0)
            overridden = subprocess.run(
                command + ["--event", "workflow_dispatch", "--ref", "refs/heads/main",
                           "--override-tag", "v1.1.0-beta.3", "--override-reason", "Infrastructure failure"],
                capture_output=True, env=environment)
            self.assertEqual(overridden.returncode, 0, overridden.stderr)
            summary = (root / "summary").read_text()
            self.assertIn("lists no usable interruption points", summary)
            self.assertNotIn("minutes", summary)
        with self.assertRaisesRegex(UpgradeError, "no interruption point to plan"):
            upgrade_matrix(["v1.0.5"], [])

    def test_listing_the_points_has_a_deadline_and_keeps_the_end_of_the_error_text(self):
        with tempfile.TemporaryDirectory() as directory:
            hang = Path(directory) / "hang.py"
            hang.write_text("import time\ntime.sleep(60)\n")
            with patch.object(release_upgrade, "LIST_POINTS_TIMEOUT_SECONDS", 1):
                with self.assertRaisesRegex(UpgradeError, "did not list its interruption points within 1 seconds"):
                    journey_points(hang)
            failing = Path(directory) / "failing.py"
            failing.write_text("import sys\nsys.stderr.write('A' * 300 + 'THE-CAUSE')\nsys.exit(3)\n")
            with self.assertRaises(UpgradeError) as raised:
                journey_points(failing)
            self.assertIn("THE-CAUSE", str(raised.exception))
            self.assertNotIn("A" * 201, str(raised.exception))

    def test_cli_exports_the_matrix_of_the_selected_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = release("v1.1.0-beta.3", "2026-10-08T12:00:00Z")
            (root / "release.json").write_text(json.dumps(target))
            (root / "history.json").write_text(json.dumps([release("v1.0.5"), release("v1.1.0-beta.2"), target]))
            subprocess.run([sys.executable, str(Path(__file__).with_name("release_upgrade.py")),
                            "--release", str(root / "release.json"), "--history", str(root / "history.json"),
                            "--output", str(root / "plan.json")], check=True, capture_output=True,
                           env={"GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary")})
            line = next(line for line in (root / "output").read_text().splitlines()
                        if line.startswith("upgrade_matrix="))
            matrix = json.loads(line.removeprefix("upgrade_matrix="))
            self.assertEqual({job["platform"] for job in matrix["include"]}, set(PLATFORMS))
            self.assertIn("Upgrade jobs: iOS 1-of-2 (6 points), iOS 2-of-2 (6 points), macOS 1-of-1 (12 points)",
                          (root / "summary").read_text())
            self.assertEqual(json.loads((root / "plan.json").read_text())["matrix"], matrix)

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
