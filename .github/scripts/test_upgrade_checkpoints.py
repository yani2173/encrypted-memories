#!/usr/bin/env python3
"""Hygiene check of the upgrade gate itself: the journey point list and the probe calls in the app must agree.

The journey (`scripts/upgrade-test/run_journey.py`, list `POINTS`) interrupts the old app at named points. The app
reaches a point through exactly one call of `UpgradeTestProbe.checkpoint("<point>")`. A refactor that drops, doubles or
renames such a call would otherwise show only in the release gate, hours after the change. This check fails at once and
names the point.

Rules:
- Every journey point has exactly one call in the app sources.
- Every call names a journey point or one of the observation names that the gate reads (`OBSERVATION_NAMES`).
- Every call takes a plain string literal, so that this check can read the name.
"""

import ast
import sys
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
JOURNEY = ROOT / "scripts/upgrade-test/run_journey.py"
# App sources that ship the probe calls. Tests and vendored code do not count.
SOURCE_DIRECTORIES = ("Packages/EncryptedMemoriesKit/Sources", "iOSApp", "App")
# Names that the gate reads without interrupting the old app at them: `session.loaded` and `network.denied` in
# run_journey.py, `model.activated` and `query.encoded` as observation points of the smart search journey.
OBSERVATION_NAMES = {"session.loaded", "network.denied", "model.activated", "query.encoded"}


def journey_points(path=JOURNEY):
    """The `POINTS` list of the journey, read from the source without running it."""
    for node in ast.parse(path.read_text()).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "POINTS" for t in node.targets):
            return list(ast.literal_eval(node.value))
    raise AssertionError(f"{path} has no POINTS list")


def swift_tokens(text):
    """Yield ('ident' | 'string' | 'interpolated' | 'punct', value) and skip whitespace and comments.

    A string literal is one token, so a comment or a string that only mentions a call is not a call, and a call
    that wraps over several lines is read like one on a single line.
    """
    index, length = 0, len(text)
    while index < length:
        char = text[index]
        if char.isspace():
            index += 1
        elif text.startswith("//", index):
            end = text.find("\n", index)
            index = length if end < 0 else end
        elif text.startswith("/*", index):
            depth, index = 1, index + 2
            while index < length and depth:
                if text.startswith("/*", index):
                    depth, index = depth + 1, index + 2
                elif text.startswith("*/", index):
                    depth, index = depth - 1, index + 2
                else:
                    index += 1
        elif char == '"' or char == "#":
            hashes = 0
            while text.startswith("#", index + hashes):
                hashes += 1
            if not text.startswith('"', index + hashes):
                yield "punct", char
                index += 1
                continue
            quote = '"""' if text.startswith('"""', index + hashes) else '"'
            close = quote + "#" * hashes
            index += hashes + len(quote)
            value, interpolated = [], False
            while index < length and not text.startswith(close, index):
                if text[index] == "\\" and hashes == 0:
                    if text.startswith("\\(", index):
                        interpolated = True
                        depth, index = 1, index + 2
                        while index < length and depth:
                            depth += {"(": 1, ")": -1}.get(text[index], 0)
                            index += 1
                        continue
                    value.append(text[index : index + 2])
                    index += 2
                    continue
                if text.startswith("\\" + "#" * hashes + "(", index) and hashes:
                    interpolated = True
                    depth, index = 1, index + hashes + 2
                    while index < length and depth:
                        depth += {"(": 1, ")": -1}.get(text[index], 0)
                        index += 1
                    continue
                value.append(text[index])
                index += 1
            index += len(close)
            yield ("interpolated" if interpolated else "string"), "".join(value)
        elif char.isalpha() or char == "_":
            end = index + 1
            while end < length and (text[end].isalnum() or text[end] == "_"):
                end += 1
            yield "ident", text[index:end]
            index = end
        else:
            yield "punct", char
            index += 1


def probe_calls(text):
    """Return (names, problems) for every `UpgradeTestProbe.checkpoint` use in one Swift source."""
    tokens = list(swift_tokens(text))
    names, problems = [], []
    for position in range(len(tokens) - 2):
        window = tokens[position : position + 3]
        if window != [("ident", "UpgradeTestProbe"), ("punct", "."), ("ident", "checkpoint")]:
            continue
        rest = tokens[position + 3 : position + 6]
        if len(rest) == 3 and rest[0] == ("punct", "(") and rest[1][0] == "string" and rest[2] == ("punct", ")"):
            names.append(rest[1][1])
        else:
            problems.append("a checkpoint call whose name is not a plain string literal")
    return names, problems


def contract_problems(points, sources):
    """The ways in which the probe calls in `sources` ({path: text}) break the contract with `points`."""
    problems, calls = [], Counter()
    for path in sorted(sources):
        names, found = probe_calls(sources[path])
        calls.update(names)
        problems += [f"{path}: {problem}" for problem in found]
        for name in names:
            if name not in points and name not in OBSERVATION_NAMES:
                problems.append(
                    f"{path}: the checkpoint call '{name}' is neither a journey point nor an observation name"
                )
    for point in points:
        if calls[point] == 0:
            problems.append(f"journey point '{point}' has no checkpoint call in the app")
        elif calls[point] > 1:
            problems.append(
                f"journey point '{point}' has {calls[point]} checkpoint calls in the app; it needs exactly one"
            )
    return problems


def app_sources(root=ROOT):
    sources = {}
    for directory in SOURCE_DIRECTORIES:
        for path in sorted((root / directory).rglob("*.swift")):
            sources[str(path.relative_to(root))] = path.read_text()
    return sources


class UpgradeCheckpointContractTests(unittest.TestCase):
    POINTS = ["backup.claimed", "model.partial"]

    def call(self, name, text=None):
        return text or f'func work() {{\n    UpgradeTestProbe.checkpoint("{name}")\n}}\n'

    def test_the_app_calls_each_journey_point_exactly_once_and_no_unknown_name(self):
        points = journey_points()
        self.assertTrue(points)
        self.assertEqual(contract_problems(points, app_sources()), [])

    def test_a_call_that_wraps_over_several_lines_counts(self):
        wrapped = 'UpgradeTestProbe\n    .checkpoint(\n        "backup.claimed"\n    )\n'
        self.assertEqual(probe_calls(wrapped), (["backup.claimed"], []))
        spaced = 'UpgradeTestProbe . checkpoint( "backup.claimed" )'
        self.assertEqual(probe_calls(spaced), (["backup.claimed"], []))

    def test_a_missing_point_is_reported_with_its_name(self):
        sources = {"a.swift": self.call("backup.claimed")}
        self.assertEqual(
            contract_problems(self.POINTS, sources), ["journey point 'model.partial' has no checkpoint call in the app"]
        )

    def test_a_doubled_point_is_reported_with_its_name(self):
        sources = {
            "a.swift": self.call("backup.claimed"),
            "b.swift": self.call("backup.claimed") + self.call("model.partial"),
        }
        problems = contract_problems(self.POINTS, sources)
        self.assertEqual(len(problems), 1)
        self.assertIn("'backup.claimed' has 2 checkpoint calls", problems[0])

    def test_an_unknown_name_is_reported_with_the_file_and_the_name(self):
        sources = {
            "a.swift": self.call("backup.claimed") + self.call("model.partial"),
            "b.swift": self.call("backup.claimd"),
        }
        problems = contract_problems(self.POINTS, sources)
        self.assertEqual(len(problems), 1)
        self.assertIn("b.swift", problems[0])
        self.assertIn("'backup.claimd'", problems[0])

    def test_an_observation_name_needs_no_journey_point(self):
        sources = {"a.swift": self.call("backup.claimed") + self.call("model.partial") + self.call("session.loaded")}
        self.assertEqual(contract_problems(self.POINTS, sources), [])

    def test_a_name_that_is_not_a_plain_literal_is_reported(self):
        for text in (
            'UpgradeTestProbe.checkpoint(point)',
            'UpgradeTestProbe.checkpoint("backup.\\(suffix)")',
            'let call = UpgradeTestProbe.checkpoint',
        ):
            names, problems = probe_calls(text)
            self.assertEqual(names, [], text)
            self.assertEqual(len(problems), 1, text)

    def test_comments_and_strings_that_only_mention_a_call_are_no_calls(self):
        text = (
            '// UpgradeTestProbe.checkpoint("backup.claimed")\n'
            '/* outer /* nested */ UpgradeTestProbe.checkpoint("backup.claimed") */\n'
            'let note = "UpgradeTestProbe.checkpoint(\\"backup.claimed\\")"\n'
            'let raw = #"UpgradeTestProbe.checkpoint("backup.claimed")"#\n'
            'let multi = """\nUpgradeTestProbe.checkpoint("backup.claimed")\n"""\n'
            'UpgradeTestProbe.checkpoint("model.partial")\n'
        )
        self.assertEqual(probe_calls(text), (["model.partial"], []))

    def test_the_declaration_of_the_probe_function_is_no_call(self):
        declaration = 'public static func checkpoint(_ point: String) { }\n'
        self.assertEqual(probe_calls(declaration), ([], []))


if __name__ == "__main__":
    unittest.main(argv=sys.argv)
