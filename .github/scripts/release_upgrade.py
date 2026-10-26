#!/usr/bin/env python3
"""Select published upgrade sources and validate a deliberate release override."""

import argparse
from datetime import datetime
import json
import html
import math
import os
from pathlib import Path
import re
import subprocess
import sys


class UpgradeError(ValueError):
    """Release metadata or upgrade evidence cannot authorize an upload."""


# v1.0.5 was the first public App Store version. Earlier releases were admission tests.
OLDEST_SUPPORTED_STABLE = "v1.0.5"
# Beta 2 had only testers and predates the test entry. Stable sources cannot use this exception.
PREVIOUS_BETA_WITHOUT_ENTRY = frozenset({"v1.1.0-beta.2"})

# A hosted job stops after 180 minutes. A job may plan at most this long, which keeps a margin for a slow runner.
JOB_BUDGET_MINUTES = 165
PLATFORMS = ("iOS", "macOS")
# A job needs: builds + cases = BUILD_MINUTES_PER_SOURCE x sources + CASE_MINUTES x sources x points of the job.
# Measured on the hosted runner (v1.1.0-rc.1, run 38202469938, two sources, and v1.1.0, run 38307297868, one source):
#   iOS case: mean 6.6 to 7.6 minutes per job (slowest job mean 454 s), slowest single case 653 s (10.9 minutes).
#   iOS builds and set-up: 9.6 minutes for one source, 18.5 and 25.6 minutes for two sources (9 to 13 per source).
#   macOS case: mean 48 to 59 seconds (slowest single case 115 s); builds and set-up: 8.0 minutes for one source,
#   about 25 minutes for two sources (up to 13 per source).
# The constants are estimates from the job means of these two releases (cache-miss builds in the two-source run): iOS case
# 8.0, macOS case 1.5, builds 12.0 minutes per source. The measured maxima are higher: a build and set-up residual of up to
# 12.8 (iOS) and 12.4 (macOS) minutes per source, a slowest point mean of 9.2 minutes per iOS case (model.installRecord:
# 653 and 455 seconds), and a slowest single case of 10.9 minutes. The check at 165 minutes keeps a margin against the
# estimate only; a job that concentrates slow points, or a slower runner, can use more of its 180-minute timeout.
BUILD_MINUTES_PER_SOURCE = {"iOS": 12.0, "macOS": 12.0}
CASE_MINUTES = {"iOS": 8.0, "macOS": 1.5}
# A release with one source would fit one iOS job (about 108 planned minutes). Two jobs halve the wall-clock time of the
# gate for about one more build of runner time.
MIN_IOS_JOBS = 2
# GitHub accepts at most 256 jobs from one matrix.
MAX_MATRIX_JOBS = 256
# The journey prints its points at once; a longer run is a hang, not a slow list.
LIST_POINTS_TIMEOUT_SECONDS = 30

TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(beta|rc)\.([1-9][0-9]*))?\Z")


def published_release(payload):
    tag = payload.get("tag_name", "")
    match = TAG.fullmatch(tag)
    if not match:
        raise UpgradeError("Invalid app release tag")
    prerelease = payload.get("prerelease")
    if type(prerelease) is not bool or prerelease != (match[4] is not None):
        raise UpgradeError(f"Prerelease flag disagrees with {tag}")
    if payload.get("draft") is not False or not payload.get("published_at"):
        raise UpgradeError(f"Release {tag} is not published")
    try:
        timestamp = datetime.fromisoformat(payload["published_at"].replace("Z", "+00:00"))
        if timestamp.tzinfo is None:
            raise ValueError("Timestamp has no time zone")
    except (TypeError, ValueError) as error:
        raise UpgradeError(f"Invalid publication time for {tag}") from error
    version = tuple(int(match[i]) for i in (1, 2, 3))
    # A stable release follows every beta and release candidate of its version.
    order = (*version, {"beta": 0, "rc": 1, None: 2}[match[4]], int(match[5] or 0))
    return tag, version, match[4], order, timestamp


def select_sources(target, history):
    target_tag, _, target_channel, target_order, target_time = published_release(target)
    if not isinstance(history, list):
        raise UpgradeError("Release history must contain every API page")
    releases = {}
    for payload in history:
        if payload.get("draft") is True or not payload.get("published_at"):
            continue
        # Model releases in this repository are not app upgrade sources.
        if not payload.get("tag_name", "").startswith("v"):
            continue
        parsed = published_release(payload)
        if parsed[0] in releases:
            raise UpgradeError(f"Duplicate published release tag {parsed[0]}")
        releases[parsed[0]] = parsed
    if releases.get(target_tag) != published_release(target):
        raise UpgradeError("Target release is absent or differs from the complete release history")
    predecessors = [r for r in releases.values() if r[3] < target_order and r[4] <= target_time]
    floor = tuple(map(int, OLDEST_SUPPORTED_STABLE[1:].split(".")))
    stable = sorted((r for r in predecessors if r[2] is None and r[1] >= floor), key=lambda r: r[3])
    result = [r[0] for r in stable]
    if target_channel is not None:
        betas = [r for r in predecessors if r[2] == "beta" and r[1] >= floor]
        if betas:
            result.append(max(betas, key=lambda r: (r[4], r[3]))[0])
    return result


def select_plan(target, history):
    selected = select_sources(target, history)
    untested = [tag for tag in selected if TAG.fullmatch(tag)[4] == "beta" and tag in PREVIOUS_BETA_WITHOUT_ENTRY]
    return {"sources": [tag for tag in selected if tag not in untested], "untested": untested}


def journey_points(journey):
    """The interruption points of the journey: its one list."""
    try:
        result = subprocess.run([sys.executable, str(journey), "--list-points"], capture_output=True, text=True,
                                timeout=LIST_POINTS_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise UpgradeError(
            f"The journey did not list its interruption points within {LIST_POINTS_TIMEOUT_SECONDS} seconds") from error
    except OSError as error:
        raise UpgradeError(f"The journey could not be started: {error}") from error
    points = result.stdout.split()
    if result.returncode or not points or len(set(points)) != len(points):
        raise UpgradeError(f"The journey lists no usable interruption points: {result.stderr.strip()[-200:]}")
    return points


def job_minutes(platform, source_count, point_count):
    return BUILD_MINUTES_PER_SOURCE[platform] * source_count + CASE_MINUTES[platform] * source_count * point_count


def shard_count(platform, source_count, point_count):
    """The fewest jobs of one platform so that each job, with every source, fits the job budget.

    The iOS gate never runs in fewer than MIN_IOS_JOBS jobs, but never in more jobs than points, so every job holds at
    least one point: with one point a single job is planned."""
    minimum = max(1, min(MIN_IOS_JOBS, point_count)) if platform == "iOS" else 1
    for count in range(minimum, point_count + 1):
        if job_minutes(platform, source_count, math.ceil(point_count / count)) <= JOB_BUDGET_MINUTES:
            return count
    raise UpgradeError(
        f"One interruption point of {source_count} sources needs {job_minutes(platform, source_count, 1):.0f} "
        f"minutes on {platform}, more than the {JOB_BUDGET_MINUTES} minutes that a job may plan")


def upgrade_matrix(sources, points):
    """The jobs of the upgrade gate: each platform tests every source, and together its jobs cover every point once."""
    if not points:
        raise UpgradeError("There is no interruption point to plan")
    include = []
    for platform in PLATFORMS:
        count = shard_count(platform, max(1, len(sources)), len(points))
        size, extra = divmod(len(points), count)
        start = 0
        for index in range(count):
            end = start + size + (1 if index < extra else 0)
            include.append({"platform": platform, "shard": f"{index + 1}-of-{count}",
                            "points": " ".join(points[start:end])})
            start = end
    if len(include) > MAX_MATRIX_JOBS:
        raise UpgradeError(f"The plan needs {len(include)} jobs, more than the {MAX_MATRIX_JOBS} that GitHub accepts")
    return {"include": include}


def unbudgeted_matrix(points):
    """One job per platform with every point, for a deliberate override that no time budget can plan."""
    return {"include": [{"platform": platform, "shard": "1-of-1", "points": " ".join(points)}
                        for platform in PLATFORMS]}


def plan_matrix(sources, points, overridden):
    """The matrix and a note. A deliberate override keeps its escape path: a plan that does not fit falls back."""
    try:
        return upgrade_matrix(sources, points), None
    except UpgradeError as error:
        if not overridden:
            raise
        return unbudgeted_matrix(points), (
            f"Override: {error}. The plan falls back to one job per platform with every point; the journey steps "
            "are skipped by the override, so the jobs only acknowledge it.")


def validate_override(event, ref, tag, confirmation, reason):
    if not confirmation and not reason:
        return False
    if event != "workflow_dispatch" or ref != "refs/heads/main":
        raise UpgradeError("Only a manual run from main can override the upgrade check")
    if confirmation != tag or not reason.strip():
        raise UpgradeError("An override requires the exact release tag and a nonempty reason")
    if len(reason) > 500 or any(ord(c) < 32 for c in reason):
        raise UpgradeError("The override reason must be one printable line of at most 500 characters")
    return True


def report(message):
    print(message, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(message + "\n\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--history", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--event", default="release")
    parser.add_argument("--ref", default="")
    parser.add_argument("--override-tag", default="")
    parser.add_argument("--override-reason", default="")
    parser.add_argument("--journey", type=Path,
                        default=Path(__file__).resolve().parents[2] / "scripts/upgrade-test/run_journey.py")
    args = parser.parse_args()
    target = json.loads(args.release.read_text())
    selection = select_plan(target, json.loads(args.history.read_text()))
    overridden = validate_override(args.event, args.ref, target["tag_name"],
                                   args.override_tag, args.override_reason)
    try:
        points = journey_points(args.journey)
    except UpgradeError as error:
        if not overridden:
            raise
        # The journey steps are skipped by the override; the matrix only has to exist, so no cost is planned.
        report(f"Override: {error}. The journey steps are skipped by the override, so the jobs only acknowledge it.")
        matrix, note = unbudgeted_matrix([]), None
    else:
        matrix, note = plan_matrix(selection["sources"], points, overridden)
    plan = {"target": target["tag_name"], **selection, "matrix": matrix,
            "overridden": overridden, "override_reason": args.override_reason}
    args.output.write_text(json.dumps(plan, indent=2) + "\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("upgrade_sources=" + json.dumps(selection["sources"]) + "\n")
            output.write("upgrade_overridden=" + str(overridden).lower() + "\n")
            output.write("upgrade_matrix=" + json.dumps(matrix, separators=(",", ":")) + "\n")
    report("Upgrade sources: " + ", ".join(selection["sources"]))
    if note:
        report(note)
    report("Upgrade jobs: " + ", ".join(f"{job['platform']} {job['shard']} ({len(job['points'].split())} points)"
                                         for job in matrix["include"]))
    for tag in selection["untested"]:
        report(f"nicht getestet: {tag} (kein Prüfeinstieg)")
    if overridden:
        report("**Upgrade check deliberately overridden for " + target["tag_name"] + ":** "
               + html.escape(args.override_reason))


if __name__ == "__main__":
    try:
        main()
    except (UpgradeError, OSError, json.JSONDecodeError) as error:
        report(f"Release upgrade check failed: {error}")
        raise SystemExit(1)
