from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]

# One line per command: the tool, then its arguments, as the stubs record them.
PHASES = [
    "Apple Vision SDK surface",
    "upgrade fixture release catalog",
    "EncryptedMemoriesKit",
    "vendored sdk-swift",
]

STUB = """#!/bin/bash
echo "$(basename "$0") $*" >> "$STUB_LOG"
if [[ -n "${STUB_FAIL_MATCH:-}" && "$*" == *"$STUB_FAIL_MATCH"* ]]; then
  exit "${STUB_FAIL_CODE:-1}"
fi
"""


class VerifyTestsScriptTests(unittest.TestCase):
    """Runs scripts/verify-tests.sh in a copy of its tree with stubbed tools."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="verify-tests-script-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.root = self.tmp / "repo"
        (self.root / "scripts" / "tests").mkdir(parents=True)
        (self.root / "Vendor" / "sdk-swift").mkdir(parents=True)
        (self.root / "Vendor" / "sdk-swift" / "Package.swift").write_text("")
        for name in ("verify-tests.sh", "build-paths.sh"):
            shutil.copy(REPO / "scripts" / name, self.root / "scripts" / name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for tool in ("python3", "xcrun"):
            stub = self.bin / tool
            stub.write_text(STUB)
            stub.chmod(0o755)
        self.log = self.tmp / "stub.log"

    def run_script(self, **extra: str) -> subprocess.CompletedProcess[str]:
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.tmp / "home"),
            "ENCRYPTED_MEMORIES_BUILD_ROOT": str(self.tmp / "build"),
            "DEVELOPER_DIR": str(self.tmp / "developer"),
            "STUB_LOG": str(self.log),
        }
        env.update(extra)
        return subprocess.run(
            ["bash", str(self.root / "scripts" / "verify-tests.sh")],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )

    def invocations(self) -> list[str]:
        if not self.log.exists():
            return []
        text = self.log.read_text().replace(str(self.root), "<root>").replace(str(self.tmp / "build"), "<build>")
        return text.splitlines()

    def markers(self, output: str) -> list[tuple[str, str, int | None]]:
        found: list[tuple[str, str, int | None]] = []
        for line in output.splitlines():
            start = re.fullmatch(r"\[tests\] start: (.+)", line)
            end = re.fullmatch(r"\[tests\] end: (.+) after (\d+) s \(exit (\d+)\)", line)
            if start:
                found.append(("start", start.group(1), None))
            if end:
                found.append(("end", end.group(1), int(end.group(3))))
        return found

    def test_runs_every_phase_in_order_and_marks_each_one(self) -> None:
        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.invocations(),
            [
                "python3 <root>/scripts/verify-apple-vision-sdk-surface.py",
                "python3 <root>/scripts/tests/test_upgrade_fixture_corpus.py",
                "xcrun swift test --package-path <root>/Packages/EncryptedMemoriesKit"
                " --scratch-path <build>/SPM.noindex"
                " --cache-path <build>/SwiftPMCache.noindex"
                " --force-resolved-versions --no-parallel",
                "xcrun swift test --package-path <root>/Vendor/sdk-swift"
                " --scratch-path <build>/SDK.noindex"
                " --cache-path <build>/SwiftPMCache.noindex"
                " --force-resolved-versions --no-parallel",
            ],
        )
        expected = [(kind, name, 0 if kind == "end" else None) for name in PHASES for kind in ("start", "end")]
        self.assertEqual(self.markers(result.stdout), expected)
        self.assertRegex(result.stdout, r"\[tests\] all package suites passed\n\[tests\] total: \d+ s\n")
        self.assertNotIn("skipped", result.stdout)

    def test_the_switch_skips_only_the_sdk_pass_and_says_so(self) -> None:
        result = self.run_script(ENCRYPTED_MEMORIES_SKIP_SDK_TESTS="1")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([line.split(" --")[0] for line in self.invocations()], [
            "python3 <root>/scripts/verify-apple-vision-sdk-surface.py",
            "python3 <root>/scripts/tests/test_upgrade_fixture_corpus.py",
            "xcrun swift test",
        ])
        self.assertIn("Packages/EncryptedMemoriesKit", self.invocations()[2])
        self.assertEqual(self.markers(result.stdout), [(kind, name, 0 if kind == "end" else None)
                                                       for name in PHASES[:3] for kind in ("start", "end")])
        self.assertIn("[tests] skipped: vendored sdk-swift", result.stdout)
        self.assertIn("[tests] package suites passed; vendored sdk-swift NOT run\n", result.stdout)
        self.assertNotIn("all package suites passed", result.stdout)

    def test_an_empty_switch_runs_every_phase(self) -> None:
        result = self.run_script(ENCRYPTED_MEMORIES_SKIP_SDK_TESTS="")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.invocations()), 4)
        self.assertIn("all package suites passed", result.stdout)

    def test_ci_runs_every_phase_and_refuses_the_switch(self) -> None:
        for ci in ({"CI": "true"}, {"GITHUB_ACTIONS": "true"}, {"CI": "true", "GITHUB_ACTIONS": "true"}):
            with self.subTest(ci=ci, switch=False):
                self.log.unlink(missing_ok=True)
                result = self.run_script(**ci)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.invocations()), 4)
                self.assertIn("all package suites passed", result.stdout)
            with self.subTest(ci=ci, switch=True):
                self.log.unlink(missing_ok=True)
                shutil.rmtree(self.tmp / "build", ignore_errors=True)
                result = self.run_script(ENCRYPTED_MEMORIES_SKIP_SDK_TESTS="1", **ci)

                self.assertEqual(result.returncode, 64, result.stdout)
                self.assertIn("local runs only", result.stderr)
                self.assertEqual(self.invocations(), [])
                self.assertEqual(self.markers(result.stdout), [])
                self.assertFalse((self.tmp / "build").exists(), "the refusal comes before the build lock")

    def test_any_other_switch_value_is_an_error_before_any_phase(self) -> None:
        for value in ("0", "true", "yes", "1 ", "11"):
            with self.subTest(value=value):
                self.log.unlink(missing_ok=True)
                result = self.run_script(ENCRYPTED_MEMORIES_SKIP_SDK_TESTS=value)

                self.assertEqual(result.returncode, 64, result.stdout)
                self.assertIn("must be unset, empty or 1", result.stderr)
                self.assertEqual(self.invocations(), [])
                self.assertEqual(self.markers(result.stdout), [])

    def test_a_failing_phase_still_ends_a_skipping_run_with_its_exit_status(self) -> None:
        result = self.run_script(
            ENCRYPTED_MEMORIES_SKIP_SDK_TESTS="1", STUB_FAIL_MATCH="Packages/EncryptedMemoriesKit", STUB_FAIL_CODE="7")

        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertEqual(self.markers(result.stdout)[-1], ("end", "EncryptedMemoriesKit", 7))
        self.assertNotIn("package suites passed", result.stdout)
        self.assertNotIn("skipped", result.stdout)

    def test_a_failing_phase_ends_the_script_with_its_exit_status(self) -> None:
        failing = {
            "Apple Vision SDK surface": "verify-apple-vision-sdk-surface.py",
            "upgrade fixture release catalog": "test_upgrade_fixture_corpus.py",
            "EncryptedMemoriesKit": "Packages/EncryptedMemoriesKit",
            "vendored sdk-swift": "Vendor/sdk-swift",
        }
        for index, name in enumerate(PHASES):
            with self.subTest(phase=name):
                self.log.unlink(missing_ok=True)
                result = self.run_script(STUB_FAIL_MATCH=failing[name], STUB_FAIL_CODE="7")

                self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
                self.assertEqual(len(self.invocations()), index + 1)
                markers = self.markers(result.stdout)
                self.assertEqual(markers[-1], ("end", name, 7))
                self.assertEqual(len(markers), 2 * (index + 1))
                self.assertNotIn("all package suites passed", result.stdout)

    def test_a_missing_sdk_checkout_stops_before_any_phase(self) -> None:
        (self.root / "Vendor" / "sdk-swift" / "Package.swift").unlink()

        for switch in ("", "1"):
            with self.subTest(switch=switch):
                result = self.run_script(ENCRYPTED_MEMORIES_SKIP_SDK_TESTS=switch)

                self.assertEqual(result.returncode, 66)
                self.assertEqual(self.invocations(), [])
                self.assertEqual(self.markers(result.stdout), [])


if __name__ == "__main__":
    os.environ.setdefault("LC_ALL", "C")
    unittest.main()
