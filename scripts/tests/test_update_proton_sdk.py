from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]

TAG = "0.33.0"
COMMIT = "0123456789abcdef0123456789abcdef01234567"

CONNECTION_ERROR = (
    "fatal: unable to access 'https://github.com/ProtonDriveApps/sdk-swift.git/': "
    "Failed to connect to github.com port 443 after 2155 ms"
)
AUTHENTICATION_ERROR = (
    "fatal: Authentication failed for 'https://github.com/ProtonDriveApps/sdk-swift.git/'"
)
URL = "https://github.com/ProtonDriveApps/sdk-swift.git/"
# One realistic git failure message per retry pattern; macOS and Linux runners use
# different texts for the same transport failure.
TRANSIENT_MESSAGES = (
    ("Failed to connect", CONNECTION_ERROR),
    ("Could not resolve host", f"fatal: unable to access '{URL}': Could not resolve host: github.com"),
    ("Connection timed out", f"fatal: unable to access '{URL}': Failed to connect to github.com port 443: Connection timed out"),
    ("Connection reset", f"RPC failed; curl 56 Recv failure: Connection reset by peer"),
    ("early EOF", "fatal: early EOF"),
    ("SSL_ERROR_SYSCALL", f"fatal: unable to access '{URL}': OpenSSL SSL_connect: SSL_ERROR_SYSCALL in connection to github.com:443"),
    ("Operation timed out", f"fatal: unable to access '{URL}': Recv failure: Operation timed out"),
    ("Resolving timed out", f"fatal: unable to access '{URL}': Resolving timed out after 5000 milliseconds"),
    ("Empty reply from server", f"fatal: unable to access '{URL}': Empty reply from server"),
    ("transfer closed with outstanding read data", f"RPC failed; curl 18 transfer closed with outstanding read data remaining"),
    ("gnutls_handshake", f"fatal: unable to access '{URL}': gnutls_handshake() failed: The TLS connection was non-properly terminated."),
    ("HTTP/2 stream not closed cleanly", "error: RPC failed; curl 92 HTTP/2 stream 0 was not closed cleanly: INTERNAL_ERROR (err 2)"),
)

# Every stub records itself in $STUB_LOG. The fake git replays the scripted clone
# failures, then builds the small checkout tree the script expects; no network is used.
GIT_STUB = """#!/bin/bash
echo "$(basename "$0") $*" >> "$STUB_LOG"
if [[ "$1" == clone ]]; then
  attempts="$(cat "$STUB_STATE/clone-attempts" 2>/dev/null || printf 0)"
  attempts=$((attempts + 1))
  printf '%s' "$attempts" > "$STUB_STATE/clone-attempts"
  if (( attempts <= STUB_CLONE_FAILURES )); then
    printf '%s\\n' "$STUB_CLONE_ERROR" >&2
    exit "$STUB_CLONE_EXIT"
  fi
  mkdir -p "$3/Sources/Client" "$3/Resources"
  printf '// swift-tools-version:5.9\\nimport PackageDescription\\n' > "$3/Package.swift"
  exit 0
fi
if [[ "$1" == "-C" && "$3" == fetch ]]; then
  attempts="$(cat "$STUB_STATE/fetch-attempts" 2>/dev/null || printf 0)"
  attempts=$((attempts + 1))
  printf '%s' "$attempts" > "$STUB_STATE/fetch-attempts"
  if (( attempts <= STUB_FETCH_FAILURES )); then
    printf '%s\\n' "$STUB_FETCH_ERROR" >&2
    exit "$STUB_FETCH_EXIT"
  fi
  exit 0
fi
case " $* " in
  *" rev-parse --short"*) echo "1a2b3c4" ;;
  *" rev-parse "*) echo "$STUB_TAG_COMMIT" ;;
esac
exit 0
"""

LOGGER_STUB = """#!/bin/bash
echo "$(basename "$0") $*" >> "$STUB_LOG"
exit 0
"""


class UpdateProtonSdkScriptTests(unittest.TestCase):
    """Runs scripts/update-proton-sdk.sh in a copy of its tree with a fake git."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="update-proton-sdk-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.root = self.tmp / "repo"
        patch_dir = self.root / "VendorPatches" / "sdk-swift" / TAG
        patch_dir.mkdir(parents=True)
        (patch_dir / "UPSTREAM_COMMIT").write_text(f"{COMMIT}\n")
        (patch_dir / "0001-example.patch").write_text(
            "--- a/Sources/Client/Example.swift\n"
            "+++ b/Sources/Client/Example.swift\n"
            "@@ -0,0 +1 @@\n"
            "+// reviewed placeholder\n"
        )
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "Vendor").mkdir()
        (self.root / "BuildSupport").mkdir()
        (self.root / "BuildSupport" / "Package.resolved").write_text("{}\n")
        for name in ("update-proton-sdk.sh", "build-paths.sh"):
            shutil.copy(REPO / "scripts" / name, self.root / "scripts" / name)
        self.bin = self.tmp / "bin"
        self.state = self.tmp / "state"
        self.bin.mkdir()
        self.state.mkdir()
        for tool, body in (("git", GIT_STUB), ("sleep", LOGGER_STUB), ("lipo", LOGGER_STUB)):
            stub = self.bin / tool
            stub.write_text(body)
            stub.chmod(0o755)
        self.log = self.tmp / "stub.log"

    def run_script(self, **extra: str) -> subprocess.CompletedProcess[str]:
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.tmp / "home"),
            "ENCRYPTED_MEMORIES_BUILD_ROOT": str(self.tmp / "build"),
            "STUB_LOG": str(self.log),
            "STUB_STATE": str(self.state),
            "STUB_TAG_COMMIT": COMMIT,
            "STUB_CLONE_FAILURES": "0",
            "STUB_CLONE_ERROR": CONNECTION_ERROR,
            "STUB_CLONE_EXIT": "128",
            "STUB_FETCH_FAILURES": "0",
            "STUB_FETCH_ERROR": CONNECTION_ERROR,
            "STUB_FETCH_EXIT": "128",
        }
        env.update(extra)
        return subprocess.run(
            ["bash", str(self.root / "scripts" / "update-proton-sdk.sh")],
            cwd=self.root,
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )

    def invocations(self) -> list[str]:
        if not self.log.exists():
            return []
        text = self.log.read_text().replace(str(self.root), "<root>")
        return [line for line in text.splitlines() if line.strip()]

    def clone_attempts(self) -> int:
        counter = self.state / "clone-attempts"
        if not counter.exists():
            return 0
        return int(counter.read_text())

    def fetch_attempts(self) -> int:
        counter = self.state / "fetch-attempts"
        if not counter.exists():
            return 0
        return int(counter.read_text())

    def test_a_transient_connection_error_is_retried_and_the_restore_finishes(self) -> None:
        result = self.run_script(STUB_CLONE_FAILURES="1")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.clone_attempts(), 2)
        self.assertIn("attempt 1 of 3", result.stderr)
        self.assertIn(CONNECTION_ERROR, result.stderr)
        self.assertIn("sdk-swift now at: 0.33.0", result.stdout)
        # The pin check still runs after the retried clone and checks out the pinned revision.
        self.assertIn(
            f"git -C Vendor/sdk-swift rev-parse refs/tags/{TAG}^{{commit}}",
            self.invocations(),
        )
        self.assertIn(
            f"git -C Vendor/sdk-swift checkout --quiet --force {COMMIT}",
            self.invocations(),
        )

    def test_a_persistent_connection_error_fails_after_three_attempts(self) -> None:
        result = self.run_script(STUB_CLONE_FAILURES="3")

        self.assertEqual(result.returncode, 128, result.stdout + result.stderr)
        self.assertEqual(self.clone_attempts(), 3)
        self.assertIn("attempt 1 of 3", result.stderr)
        self.assertIn("attempt 2 of 3", result.stderr)
        self.assertNotIn("attempt 3 of 3", result.stderr)
        self.assertIn(CONNECTION_ERROR, result.stderr)
        self.assertEqual([line for line in self.invocations() if line.startswith("sleep")],
                         ["sleep 5", "sleep 15"])
        self.assertFalse([line for line in self.invocations() if " rev-parse " in line])

    def test_a_transient_fetch_connection_error_is_retried_and_the_restore_finishes(self) -> None:
        result = self.run_script(STUB_FETCH_FAILURES="1")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.clone_attempts(), 1)
        self.assertEqual(self.fetch_attempts(), 2)
        self.assertIn("attempt 1 of 3", result.stderr)
        self.assertIn(CONNECTION_ERROR, result.stderr)
        self.assertIn("sdk-swift now at: 0.33.0", result.stdout)
        # The pin check still runs after the retried fetch and checks out the pinned revision.
        self.assertIn(
            f"git -C Vendor/sdk-swift rev-parse refs/tags/{TAG}^{{commit}}",
            self.invocations(),
        )
        self.assertIn(
            f"git -C Vendor/sdk-swift checkout --quiet --force {COMMIT}",
            self.invocations(),
        )

    def test_each_transient_transport_message_is_retried(self) -> None:
        for pattern, message in TRANSIENT_MESSAGES:
            with self.subTest(pattern=pattern):
                # subTest shares the fixture, so every iteration starts from clean counters.
                for counter in ("clone-attempts", "fetch-attempts"):
                    (self.state / counter).unlink(missing_ok=True)
                if self.log.exists():
                    self.log.unlink()
                result = self.run_script(STUB_CLONE_FAILURES="1", STUB_CLONE_ERROR=message)

                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.clone_attempts(), 2, pattern)
                self.assertIn("attempt 1 of 3", result.stderr, pattern)
                self.assertIn(message, result.stderr, pattern)
                self.assertIn(
                    f"git -C Vendor/sdk-swift rev-parse refs/tags/{TAG}^{{commit}}",
                    self.invocations(),
                )
                self.assertIn(
                    f"git -C Vendor/sdk-swift checkout --quiet --force {COMMIT}",
                    self.invocations(),
                )

    def test_an_exit_code_one_with_a_connection_message_fails_without_a_retry(self) -> None:
        result = self.run_script(STUB_CLONE_FAILURES="1", STUB_CLONE_EXIT="1")

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.clone_attempts(), 1)
        self.assertIn(CONNECTION_ERROR, result.stderr)
        self.assertNotIn("attempt 1 of 3", result.stderr)
        self.assertFalse([line for line in self.invocations() if line.startswith("sleep")])
        self.assertFalse([line for line in self.invocations() if " rev-parse " in line])

    def test_an_authentication_failure_fails_immediately_without_a_retry(self) -> None:
        result = self.run_script(STUB_CLONE_FAILURES="1", STUB_CLONE_ERROR=AUTHENTICATION_ERROR)

        self.assertEqual(result.returncode, 128, result.stdout + result.stderr)
        self.assertEqual(self.clone_attempts(), 1)
        self.assertIn(AUTHENTICATION_ERROR, result.stderr)
        self.assertNotIn("attempt 1 of 3", result.stderr)
        self.assertFalse([line for line in self.invocations() if line.startswith("sleep")])
        self.assertFalse([line for line in self.invocations() if " rev-parse " in line])


if __name__ == "__main__":
    unittest.main()
