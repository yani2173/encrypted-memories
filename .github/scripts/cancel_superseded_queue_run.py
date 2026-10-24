#!/usr/bin/env python3
"""Stop a merge-queue run whose entry is no longer in the merge queue of main (issue #717).

The job that runs this script has no checkout and runs no code of the pull request: the job
reads this script from the base commit of the merge group, which is the tip of main, and calls
it with the job token. The decision itself is a pure function, `decide`, so that every rule can
be tested without GitHub:

- KEEP: the head commit of the run is one of the entries of the queue, or every worker job of
  the run is complete (the run then merged or is finishing; there is nothing left to stop).
- CANCEL: the queue read succeeded, the answer is well formed, the head commit is absent from
  every entry, every worker job is listed and not complete, and the run is at least
  MINIMUM_RUN_AGE_SECONDS old.
- UNKNOWN: everything else, for example a failed read, an empty or malformed answer, a
  rate-limit answer, a missing field, or a young run. Do nothing and read again later.

This job must never fail: the failure watchdog of the run cancels the run when any job of the
run fails, and that watchdog stays unchanged. Errors therefore only reach the job log.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import traceback
from datetime import datetime, timezone

KEEP = "KEEP"
CANCEL = "CANCEL"
UNKNOWN = "UNKNOWN"

# A run younger than ten minutes is not cancelled: the queue does not show an entry immediately,
# so an absent entry alone proves nothing in the first minutes of a run.
MINIMUM_RUN_AGE_SECONDS = 600
POLL_INTERVAL_SECONDS = 60
# The loop ends before the job limit, which stays below the 180 minute check timeout of the queue,
# exactly like the failure watchdog of the workflow.
LOOP_DEADLINE_SECONDS = 9900
# A gh command that hangs must end the call, so that the job can end at its time limit.
GH_CALL_TIMEOUT_SECONDS = 60
QUEUE_BRANCH = "main"

QUEUE_QUERY = """query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    mergeQueue(branch: "%s") {
      entries(first: 100, after: $endCursor) {
        nodes {
          state
          headCommit { oid }
        }
        pageInfo { endCursor hasNextPage }
      }
    }
  }
}""" % QUEUE_BRANCH

# The message of a run that is already cancelled or completed needs no cancel, as in the failure
# watchdog of the workflow.
ALREADY_ENDED = re.compile(r"HTTP 409|already|cannot be cancelled", re.IGNORECASE)
FULL_SHA = re.compile(r"[0-9a-f]{40}")


def is_full_sha(value):
    return isinstance(value, str) and FULL_SHA.fullmatch(value) is not None


def parse_json_answer(text):
    """Parse one answer of the GitHub CLI, or None when the text is not JSON."""
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return None


def answer_pages(answer):
    """The pages of an answer that the GitHub CLI produced with --paginate --slurp.

    Returns a non-empty list of pages, or None when the answer is not a page or a list of pages:
    an empty list is also what a failed read can look like.
    """
    if isinstance(answer, list):
        pages = answer
    elif isinstance(answer, dict):
        pages = [answer]
    else:
        return None
    return pages or None


def queue_head_oids(answer):
    """The head commit oid of every entry of the merge queue, or None.

    None means that the answer is not a usable, complete queue read: a page with GraphQL errors,
    a missing field, an empty entry list, or an oid that is not a full 40 character sha. An empty
    or truncated list is also what a failed read can look like, so it is not usable either.
    """
    pages = answer_pages(answer)
    if pages is None:
        return None
    oids = []
    for page in pages:
        if not isinstance(page, dict) or "errors" in page:
            return None
        data = page.get("data")
        repository = data.get("repository") if isinstance(data, dict) else None
        merge_queue = repository.get("mergeQueue") if isinstance(repository, dict) else None
        entries = merge_queue.get("entries") if isinstance(merge_queue, dict) else None
        nodes = entries.get("nodes") if isinstance(entries, dict) else None
        if not isinstance(nodes, list) or not nodes:
            return None
        for node in nodes:
            head_commit = node.get("headCommit") if isinstance(node, dict) else None
            oid = head_commit.get("oid") if isinstance(head_commit, dict) else None
            if not is_full_sha(oid):
                return None
            oids.append(oid)
    return oids


def worker_rows(answer, worker_names):
    """The job rows of the worker jobs of the run, or None.

    None means that the answer is not a usable read of the jobs of the run, or that a worker job
    is not listed yet. A worker job that is not listed cannot be proven complete.
    """
    pages = answer_pages(answer)
    if pages is None:
        return None
    wanted = set(worker_names)
    rows = []
    for page in pages:
        if not isinstance(page, dict):
            return None
        jobs = page.get("jobs")
        if not isinstance(jobs, list):
            return None
        for job in jobs:
            if not isinstance(job, dict):
                return None
            if job.get("name") in wanted:
                rows.append(job)
    if {row.get("name") for row in rows} != wanted:
        return None
    return rows


def all_workers_complete(answer, worker_names):
    """True only when every worker job of the run is listed and complete."""
    rows = worker_rows(answer, worker_names)
    return rows is not None and all(row.get("status") == "completed" for row in rows)


def decide(head_sha, queue_answer, run_state, worker_names):
    """Decide whether the own run may be cancelled. Returns KEEP, CANCEL, or UNKNOWN."""
    if not is_full_sha(head_sha):
        return UNKNOWN
    oids = queue_head_oids(queue_answer)
    if oids is None:
        return UNKNOWN
    if head_sha in oids:
        return KEEP
    if run_state.get("entry_seen") is not True:
        # Only an entry that this watch once saw in the queue can have left it. A head commit that
        # was never listed may belong to another queue, or may not match the queue answer at all.
        return UNKNOWN
    rows = worker_rows(run_state.get("jobs_answer"), worker_names)
    if rows is None:
        return UNKNOWN
    if all(row.get("status") == "completed" for row in rows):
        # The entry merged, or the run is finishing. Never cancel a run for which all worker jobs
        # are complete.
        return KEEP
    age = run_state.get("run_age_seconds")
    if not isinstance(age, int) or age < MINIMUM_RUN_AGE_SECONDS:
        return UNKNOWN
    return CANCEL


def parse_epoch(timestamp):
    """The epoch seconds of a timestamp of the GitHub API, or None."""
    try:
        parsed = datetime.fromisoformat(str(timestamp).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


class Gh:
    """Runs the gh commands that the watch needs. Overridden in tests."""

    def __init__(self, repository):
        self.repository = repository

    def call(self, argv):
        # A gh command that hangs must not hold the job until the job timeout: a hung read
        # counts as a failed read and the watch tries again at the next poll.
        try:
            result = subprocess.run(["gh", *argv], capture_output=True, text=True,
                                    timeout=GH_CALL_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            return False, "gh did not answer within {} seconds.".format(GH_CALL_TIMEOUT_SECONDS)
        return result.returncode == 0, (result.stdout or "") + (result.stderr or "")

    def queue_answer(self, owner, name):
        ok, output = self.call([
            "api", "graphql", "--paginate", "--slurp",
            "-f", "query=" + QUEUE_QUERY, "-f", "owner=" + owner, "-f", "name=" + name,
        ])
        if not ok:
            return None
        return parse_json_answer(output)

    def jobs_answer(self, run_id):
        ok, output = self.call(["api", "repos/{}/actions/runs/{}/jobs".format(self.repository, run_id),
                                 "--paginate", "--slurp"])
        if not ok:
            return None
        return parse_json_answer(output)

    def run_started_at(self, run_id):
        ok, output = self.call(["api", "repos/{}/actions/runs/{}".format(self.repository, run_id),
                                "--jq", ".run_started_at"])
        return output.strip() if ok and output.strip() else None

    def cancel(self, run_id):
        return self.call(["run", "cancel", str(run_id)])


def watch(head_sha, run_id, worker_names, repository, gh, sleep=time.sleep,
          monotonic=time.monotonic, epoch=time.time):
    """Watch the queue until the run ends, the entry is gone, or the time limit ends.

    Cancels only the own run, never another run. Returns always 0: this job must never fail,
    because the failure watchdog of the run cancels the run when any job of it fails.
    """
    owner, _, name = repository.partition("/")
    run_started_epoch = None
    entry_seen = False
    deadline = monotonic() + LOOP_DEADLINE_SECONDS
    while monotonic() < deadline:
        if run_started_epoch is None:
            started = parse_epoch(gh.run_started_at(run_id))
            if started is not None:
                run_started_epoch = started
        age = None if run_started_epoch is None else int(epoch() - run_started_epoch)
        # The queue first: when a merged entry is gone from this read, the jobs read after it
        # shows every worker complete, so the run of a merged pull request is never cancelled.
        queue_answer = gh.queue_answer(owner, name)
        jobs_answer = gh.jobs_answer(run_id)
        if all_workers_complete(jobs_answer, worker_names):
            print("All worker jobs finished without a failure.")
            return 0
        oids = queue_head_oids(queue_answer)
        entry_seen = entry_seen or (oids is not None and head_sha in oids)
        run_state = {"run_age_seconds": age, "jobs_answer": jobs_answer, "entry_seen": entry_seen}
        decision = decide(head_sha, queue_answer, run_state, worker_names)
        if decision == CANCEL:
            print("The entry of this run ({}) is no longer in the merge queue of {}.".format(head_sha, QUEUE_BRANCH))
            ok, output = gh.cancel(run_id)
            if ok or ALREADY_ENDED.search(output):
                print("The run is cancelled.")
                return 0
            print("The run could not be cancelled, it is tried again later: {}".format(output.strip()))
        sleep(POLL_INTERVAL_SECONDS)
    print("The watch ended at its time limit.")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--head-sha", required=True, help="the head commit of the merge group")
    parser.add_argument("--run-id", required=True, type=int, help="the id of the own run")
    parser.add_argument("--worker", dest="workers", action="append", required=True,
                        help="the name of a worker job of the run, repeatable")
    parser.add_argument("--repository", default=os.environ.get("GH_REPO"),
                        help="the owner and name of the repository")
    args = parser.parse_args(argv)
    if not args.repository:
        parser.error("--repository is required")
    return watch(args.head_sha, args.run_id, args.workers, args.repository, Gh(args.repository))


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit as error:
        # An argument error must not fail the job: a failed job makes the failure watchdog of
        # the run cancel the run. Exit code 0 or None is the normal end of the watch, which has
        # already printed its own end message.
        if error.code not in (None, 0):
            print("The watch could not start: exit code {}.".format(error.code))
        sys.exit(0)
    except Exception:
        traceback.print_exc()
        print("The watch ended with an error. The run was not cancelled because of it.")
        sys.exit(0)
