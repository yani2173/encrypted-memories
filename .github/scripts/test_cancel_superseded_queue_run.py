import json
import subprocess
import sys
import unittest
from pathlib import Path

import cancel_superseded_queue_run as script

WORKERS = [
    "Repository hygiene",
    "Package verification and style",
    "iOS verification",
    "iOS UI verification",
    "macOS verification",
]
HEAD_SHA = "1234567890abcdef1234567890abcdef12345678"
PREFIX_COLLIDING_OID = "1234567890ffffffffffffffffffffffffffffff"
OTHER_SHA = "fedcba0987654321fedcba0987654321fedcba09"
STARTED_AT = "2026-01-01T00:00:00Z"


def queue_page(oids):
    return {
        "data": {
            "repository": {
                "mergeQueue": {
                    "entries": {
                        "nodes": [
                            {"state": "BUILDABLE", "headCommit": {"oid": oid}} for oid in oids
                        ],
                        "pageInfo": {"endCursor": None, "hasNextPage": False},
                    }
                }
            }
        }
    }


def jobs_answer(states):
    """A jobs answer where every worker job has the given status, or a missing job for None."""
    rows = []
    for name in WORKERS:
        status = states.get(name) if isinstance(states, dict) else states
        if status is not None:
            rows.append({"name": name, "status": status, "conclusion": None})
    return {"total_count": len(rows), "jobs": rows}


def run_state(age, answer, entry_seen=True):
    return {"run_age_seconds": age, "jobs_answer": answer, "entry_seen": entry_seen}


def next_answer(items):
    """Take the first answer, but keep the last one when the list runs out."""
    if len(items) > 1:
        return items.pop(0)
    return items[0]


class Clock:
    """A fake clock that lets the watch loop run for a few iterations, then ends it."""

    def __init__(self, iterations=6, epochs=None):
        self.calls = 0
        self.limit = iterations
        self.epochs = list(epochs or [])
        self.sleeps = []

    def monotonic(self):
        self.calls += 1
        if self.calls <= self.limit:
            return 0.0
        return float(script.LOOP_DEADLINE_SECONDS + 1)

    def epoch(self):
        return next_answer(self.epochs) if self.epochs else script.parse_epoch(STARTED_AT) + 7200

    def sleep(self, seconds):
        self.sleeps.append(seconds)


class FakeGh(script.Gh):
    """A gh that answers from scripted data instead of the network."""

    def __init__(self, queue_answers, jobs_answers=(), cancel_results=(), started_at=STARTED_AT):
        super().__init__("owner/repo")
        self.queue_answers = list(queue_answers)
        self.jobs_answers = list(jobs_answers)
        self.cancel_results = list(cancel_results) or [(True, "")]
        self.started_at = started_at
        self.cancel_calls = []

    def call(self, argv):
        text = " ".join(argv)
        if text.startswith("run cancel"):
            self.cancel_calls.append(list(argv))
            return next_answer(self.cancel_results)
        if "graphql" in text:
            answer = next_answer(self.queue_answers)
            if isinstance(answer, tuple):
                return answer
            return True, json.dumps(answer)
        if "/jobs" in text:
            answer = next_answer(self.jobs_answers)
            if isinstance(answer, tuple):
                return answer
            return True, json.dumps(answer)
        return True, self.started_at


class MergedDuringTheReadGh(FakeGh):
    """The entry is present at the first poll and merges before the second queue read."""

    def __init__(self):
        super().__init__([[queue_page([HEAD_SHA])], [queue_page([OTHER_SHA])]], [jobs_answer("in_progress")])
        self.merged = False

    def call(self, argv):
        text = " ".join(argv)
        if "graphql" in text:
            ok, output = super().call(argv)
            if OTHER_SHA in output:
                self.merged = True
            return ok, output
        if "/jobs" in text and self.merged:
            return True, json.dumps(jobs_answer("completed"))
        return super().call(argv)


class DecideTests(unittest.TestCase):
    def decide(self, head_sha, queue_answer, age, answer, workers=WORKERS, entry_seen=True):
        return script.decide(head_sha, queue_answer, run_state(age, answer, entry_seen), workers)

    def test_entry_present_keeps_the_run(self):
        self.assertEqual(
            script.KEEP, self.decide(HEAD_SHA, [queue_page([OTHER_SHA, HEAD_SHA])], 7200, jobs_answer("in_progress"))
        )

    def test_entry_present_in_a_later_page_keeps_the_run(self):
        self.assertEqual(
            script.KEEP, self.decide(HEAD_SHA, [queue_page([OTHER_SHA]), queue_page([HEAD_SHA])], 7200, jobs_answer("in_progress"))
        )

    def test_entry_gone_and_old_run_cancels(self):
        self.assertEqual(
            script.CANCEL, self.decide(HEAD_SHA, [queue_page([OTHER_SHA])], 7200, jobs_answer("in_progress"))
        )

    def test_an_entry_that_was_never_seen_stays(self):
        self.assertEqual(
            script.UNKNOWN,
            self.decide(HEAD_SHA, [queue_page([OTHER_SHA])], 7200, jobs_answer("in_progress"), entry_seen=False),
        )

    def test_entry_gone_but_young_run_stays(self):
        self.assertEqual(
            script.UNKNOWN, self.decide(HEAD_SHA, [queue_page([OTHER_SHA])], 599, jobs_answer("in_progress"))
        )

    def test_entry_gone_after_all_workers_completed_keeps_the_run(self):
        self.assertEqual(
            script.KEEP, self.decide(HEAD_SHA, [queue_page([OTHER_SHA])], 7200, jobs_answer("completed"))
        )

    def test_failed_queue_read_stays(self):
        self.assertEqual(script.UNKNOWN, self.decide(HEAD_SHA, None, 7200, jobs_answer("in_progress")))

    def test_empty_answer_stays(self):
        self.assertEqual(script.UNKNOWN, self.decide(HEAD_SHA, [], 7200, jobs_answer("in_progress")))

    def test_empty_entry_list_stays(self):
        self.assertEqual(script.UNKNOWN, self.decide(HEAD_SHA, [queue_page([])], 7200, jobs_answer("in_progress")))

    def test_malformed_json_answer_stays(self):
        self.assertIsNone(script.parse_json_answer("not json at all"))
        self.assertEqual(script.UNKNOWN, self.decide(HEAD_SHA, "not json at all", 7200, jobs_answer("in_progress")))

    def test_rate_limited_answer_stays(self):
        answer = [{"errors": [{"type": "RATE_LIMITED", "message": "API rate limit exceeded"}]}]
        self.assertEqual(script.UNKNOWN, self.decide(HEAD_SHA, answer, 7200, jobs_answer("in_progress")))

    def test_errors_with_partial_data_stay(self):
        page = dict(queue_page([OTHER_SHA]), errors=[{"message": "partial answer"}])
        self.assertEqual(script.UNKNOWN, self.decide(HEAD_SHA, [page], 7200, jobs_answer("in_progress")))

    def test_a_null_node_or_head_commit_stays(self):
        for node in (None, {"state": "BUILDABLE", "headCommit": None}, {"state": "BUILDABLE"}):
            page = queue_page([OTHER_SHA])
            page["data"]["repository"]["mergeQueue"]["entries"]["nodes"].append(node)
            self.assertEqual(script.UNKNOWN, self.decide(HEAD_SHA, [page], 7200, jobs_answer("in_progress")))

    def test_an_upper_case_oid_does_not_count_as_the_entry(self):
        self.assertEqual(
            script.UNKNOWN, self.decide(HEAD_SHA, [queue_page([HEAD_SHA.upper()])], 7200, jobs_answer("in_progress"))
        )

    def test_missing_field_stays(self):
        self.assertEqual(script.UNKNOWN, self.decide(HEAD_SHA, [{"data": None}], 7200, jobs_answer("in_progress")))
        self.assertEqual(
            script.UNKNOWN, self.decide(HEAD_SHA, [{"data": {"repository": None}}], 7200, jobs_answer("in_progress"))
        )

    def test_sha_prefix_collision_does_not_count_as_present(self):
        self.assertTrue(PREFIX_COLLIDING_OID.startswith(HEAD_SHA[:10]))
        self.assertNotEqual(PREFIX_COLLIDING_OID, HEAD_SHA)
        self.assertEqual(
            script.CANCEL, self.decide(HEAD_SHA, [queue_page([PREFIX_COLLIDING_OID])], 7200, jobs_answer("in_progress"))
        )

    def test_partial_oid_does_not_count_as_an_entry(self):
        self.assertEqual(
            script.UNKNOWN, self.decide(HEAD_SHA, [queue_page([HEAD_SHA[:39]])], 7200, jobs_answer("in_progress"))
        )

    def test_invalid_head_sha_stays(self):
        self.assertEqual(script.UNKNOWN, self.decide(HEAD_SHA[:39], [queue_page([OTHER_SHA])], 7200, jobs_answer("in_progress")))

    def test_worker_that_is_not_listed_stays(self):
        answer = {"total_count": 1, "jobs": [{"name": "Repository hygiene", "status": "queued"}]}
        self.assertEqual(script.UNKNOWN, self.decide(HEAD_SHA, [queue_page([OTHER_SHA])], 7200, answer))

    def test_failed_jobs_read_stays(self):
        self.assertEqual(script.UNKNOWN, self.decide(HEAD_SHA, [queue_page([OTHER_SHA])], 7200, None))

    def test_parse_epoch_reads_timestamps_of_the_api(self):
        self.assertIsNotNone(script.parse_epoch(STARTED_AT))
        self.assertIsNone(script.parse_epoch("not a timestamp"))


class WatchTests(unittest.TestCase):
    def watch(self, gh, clock=None):
        clock = clock or Clock()
        status = script.watch(
            HEAD_SHA, 4242, WORKERS, "owner/repo", gh, sleep=clock.sleep, monotonic=clock.monotonic, epoch=clock.epoch
        )
        return status, clock

    def test_cancels_only_the_own_run_when_the_entry_is_gone(self):
        gh = FakeGh([[queue_page([HEAD_SHA])], [queue_page([OTHER_SHA])]], [jobs_answer("in_progress")], [(True, "")])
        status, clock = self.watch(gh)
        self.assertEqual(0, status)
        self.assertEqual([["run", "cancel", "4242"]], gh.cancel_calls)
        self.assertEqual([script.POLL_INTERVAL_SECONDS], clock.sleeps)

    def test_an_entry_that_was_never_in_the_queue_is_not_cancelled(self):
        gh = FakeGh([[queue_page([OTHER_SHA])]], [jobs_answer("in_progress")], [(True, "")])
        status, _ = self.watch(gh)
        self.assertEqual(0, status)
        self.assertEqual([], gh.cancel_calls)

    def test_a_run_whose_entry_merged_during_the_read_is_not_cancelled(self):
        gh = MergedDuringTheReadGh()
        status, _ = self.watch(gh)
        self.assertEqual(0, status)
        self.assertEqual([], gh.cancel_calls)

    def test_a_cancel_that_answers_already_completed_is_a_success(self):
        gh = FakeGh(
            [[queue_page([HEAD_SHA])], [queue_page([OTHER_SHA])]],
            [jobs_answer("in_progress")],
            [(False, "HTTP 409: cannot be cancelled, already completed")],
        )
        status, _ = self.watch(gh)
        self.assertEqual(0, status)
        self.assertEqual(1, len(gh.cancel_calls))

    def test_does_not_cancel_while_the_entry_is_present(self):
        gh = FakeGh([[queue_page([HEAD_SHA])]], [jobs_answer("in_progress")], [(True, "")])
        status, clock = self.watch(gh)
        self.assertEqual(0, status)
        self.assertEqual([], gh.cancel_calls)
        self.assertIn(script.POLL_INTERVAL_SECONDS, clock.sleeps)

    def test_ends_without_a_cancel_when_all_workers_are_complete(self):
        gh = FakeGh([[queue_page([OTHER_SHA])]], [jobs_answer("completed")], [(True, "")])
        status, _ = self.watch(gh)
        self.assertEqual(0, status)
        self.assertEqual([], gh.cancel_calls)

    def test_a_failed_cancel_is_tried_again(self):
        gh = FakeGh(
            [[queue_page([HEAD_SHA])], [queue_page([OTHER_SHA])]],
            [jobs_answer("in_progress")],
            [(False, "HTTP 500: boom"), (True, "")],
        )
        status, _ = self.watch(gh, Clock(iterations=6))
        self.assertEqual(0, status)
        self.assertEqual(2, len(gh.cancel_calls))

    def test_a_young_run_is_not_cancelled_until_it_is_old_enough(self):
        started_epoch = script.parse_epoch(STARTED_AT)
        gh = FakeGh([[queue_page([HEAD_SHA])], [queue_page([OTHER_SHA])]], [jobs_answer("in_progress")], [(True, "")])
        young, old = started_epoch + 300, started_epoch + script.MINIMUM_RUN_AGE_SECONDS
        status, clock = self.watch(gh, Clock(epochs=[young, young, old]))
        self.assertEqual(0, status)
        self.assertEqual(1, len(gh.cancel_calls))
        self.assertEqual([script.POLL_INTERVAL_SECONDS] * 2, clock.sleeps)

    def test_a_failed_queue_read_leads_to_no_cancel(self):
        gh = FakeGh([(False, "HTTP 502: bad gateway")], [jobs_answer("in_progress")], [(True, "")])
        status, _ = self.watch(gh)
        self.assertEqual(0, status)
        self.assertEqual([], gh.cancel_calls)

    def test_a_malformed_queue_answer_leads_to_no_cancel(self):
        gh = FakeGh(["not json at all"], [jobs_answer("in_progress")], [(True, "")])
        status, _ = self.watch(gh)
        self.assertEqual(0, status)
        self.assertEqual([], gh.cancel_calls)


class CliTests(unittest.TestCase):
    def test_an_argument_error_does_not_fail_the_job(self):
        result = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("cancel_superseded_queue_run.py")), "--run-id", "1"],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("could not start", result.stdout)

    def test_the_normal_end_prints_no_start_error(self):
        result = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("cancel_superseded_queue_run.py")), "--help"],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertNotIn("could not start", result.stdout + result.stderr)


class GhTimeoutTests(unittest.TestCase):
    def test_a_hung_gh_call_counts_as_a_failed_read(self):
        timeouts = []

        def hang(*args, **kwargs):
            timeouts.append(kwargs.get("timeout"))
            raise subprocess.TimeoutExpired(cmd=["gh"], timeout=script.GH_CALL_TIMEOUT_SECONDS)

        original = script.subprocess.run
        script.subprocess.run = hang
        try:
            ok, output = script.Gh("owner/repo").call(["run", "cancel", "1"])
        finally:
            script.subprocess.run = original
        self.assertFalse(ok)
        self.assertIn("did not answer", output)
        self.assertEqual([script.GH_CALL_TIMEOUT_SECONDS], timeouts)


if __name__ == "__main__":
    unittest.main()
