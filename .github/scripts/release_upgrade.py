#!/usr/bin/env python3
"""Select published upgrade sources and validate a deliberate release override."""

import argparse
from datetime import datetime
import json
import html
import os
from pathlib import Path
import re


class UpgradeError(ValueError):
    """Release metadata or upgrade evidence cannot authorize an upload."""


# v1.0.5 was the first public App Store version. Earlier releases were admission tests.
OLDEST_SUPPORTED_STABLE = "v1.0.5"
# Beta 2 had only testers and predates the test entry. Stable sources cannot use this exception.
PREVIOUS_BETA_WITHOUT_ENTRY = frozenset({"v1.1.0-beta.2"})

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
    args = parser.parse_args()
    target = json.loads(args.release.read_text())
    selection = select_plan(target, json.loads(args.history.read_text()))
    overridden = validate_override(args.event, args.ref, target["tag_name"],
                                   args.override_tag, args.override_reason)
    plan = {"target": target["tag_name"], **selection,
            "overridden": overridden, "override_reason": args.override_reason}
    args.output.write_text(json.dumps(plan, indent=2) + "\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("upgrade_sources=" + json.dumps(selection["sources"]) + "\n")
            output.write("upgrade_overridden=" + str(overridden).lower() + "\n")
    report("Upgrade sources: " + ", ".join(selection["sources"]))
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
