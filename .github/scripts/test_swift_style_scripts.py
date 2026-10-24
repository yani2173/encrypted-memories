import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def tool(directory, name, body):
    path = Path(directory) / name
    path.write_text('#!/usr/bin/env bash\n' + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


class SwiftStyleScripts(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.dir = Path(self.scratch.name)
        self.sample = 'Packages/EncryptedMemoriesKit/Sources/PhotosCore/TimelineMetadataStartGate.swift'
        self.assertTrue((ROOT / self.sample).is_file())

    def run_script(self, script, *arguments, **environment):
        env = dict(os.environ, **environment)
        for key in ['SWIFTLINT_EXECUTABLE', 'SWIFT_FORMAT_EXECUTABLE', 'BASE_SHA', 'HEAD_SHA']:
            if key not in environment:
                env.pop(key, None)
        return subprocess.run(['bash', str(ROOT / 'scripts' / script), *arguments], capture_output=True, text=True,
                              env=env, cwd=ROOT)

    def swiftlint(self, output, status=0, stream='1'):
        # The real tool prints its warnings on stderr; `stream` 2 does the same.
        return tool(self.dir, 'swiftlint', f'''if [[ "$1" == "version" ]]; then echo 0.65.1; exit 0; fi
echo "$@" > "{self.dir}/swiftlint-arguments"
cat <<'TEXT' >&{stream}
{output}
TEXT
exit {status}
''')

    def test_a_skipped_swiftlint_rule_fails_the_check(self):
        messages = [
            "warning: Skipping enabled rule 'custom_rules' because it requires SourceKit and SourceKit access is prohibited.",
            'warning: SourceKit-based rules will be skipped because sourcekitd has failed.',
        ]
        for message in messages:
            for stream in ['1', '2']:
                with self.subTest(message=message[:40], stream=stream):
                    tool_path = self.swiftlint(message, stream=stream)
                    result = self.run_script('lint-swift.sh', self.sample, SWIFTLINT_EXECUTABLE=str(tool_path))
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn('style check is incomplete', result.stderr)

    def test_a_clean_run_passes_and_gets_the_strict_arguments(self):
        tool_path = self.swiftlint('Done linting! Found 0 violations.')
        result = self.run_script('lint-swift.sh', self.sample, SWIFTLINT_EXECUTABLE=str(tool_path))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        arguments = (self.dir / 'swiftlint-arguments').read_text().split()
        self.assertEqual(arguments[:3], ['lint', '--strict', '--config'])
        self.assertEqual(arguments[-1], self.sample)

    def test_swiftlint_violations_keep_their_exit_code_and_output(self):
        tool_path = self.swiftlint('file.swift:1:1: error: a rule fired (trailing_whitespace)', status=2)
        result = self.run_script('lint-swift.sh', self.sample, SWIFTLINT_EXECUTABLE=str(tool_path))
        self.assertEqual(result.returncode, 2)
        self.assertIn('a rule fired', result.stdout)

    def test_the_wrong_swiftlint_version_stops_the_check(self):
        tool_path = tool(self.dir, 'swiftlint', 'echo 0.1.0\n')
        result = self.run_script('lint-swift.sh', self.sample, SWIFTLINT_EXECUTABLE=str(tool_path))
        self.assertEqual(result.returncode, 69)

    def test_swift_format_runs_the_given_executable_with_the_strict_configuration(self):
        tool_path = tool(self.dir, 'swift-format', f'echo "$@" > "{self.dir}/format-arguments"\n')
        result = self.run_script('check-swift-format.sh', self.sample, SWIFT_FORMAT_EXECUTABLE=str(tool_path))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        arguments = (self.dir / 'format-arguments').read_text().split()
        self.assertEqual(arguments[:3], ['lint', '--strict', '--parallel'])
        self.assertEqual(arguments[arguments.index('--configuration') + 1], str(ROOT / '.swift-format'))
        self.assertEqual(arguments[-1], self.sample)

    def test_swift_format_findings_fail_the_check(self):
        tool_path = tool(self.dir, 'swift-format', 'echo "a.swift:1:1: error: [Indentation] indent by 4 spaces"\nexit 1\n')
        result = self.run_script('check-swift-format.sh', self.sample, SWIFT_FORMAT_EXECUTABLE=str(tool_path))
        self.assertEqual(result.returncode, 1)

    def canary_swiftlint(self, fires=True):
        # The canary file has a forbidden comment: a working SwiftLint reports it with exit 2.
        body = f'''if [[ "$1" == "version" ]]; then echo 0.65.1; exit 0; fi
for argument in "$@"; do
  if [[ "$argument" == *StyleCanary.swift ]]; then {'echo "canary: no_em_dash_in_comments"; exit 2' if fires else 'exit 0'}; fi
done
echo "Done linting!"
'''
        return tool(self.dir, 'swiftlint', body)

    def test_a_swiftlint_that_does_not_report_the_canary_fails_the_check(self):
        swiftlint = self.canary_swiftlint(fires=False)
        format_tool = tool(self.dir, 'swift-format', 'exit 0\n')
        result = self.run_script('verify-swift-style.sh', SWIFTLINT_EXECUTABLE=str(swiftlint),
                                 SWIFT_FORMAT_EXECUTABLE=str(format_tool))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('does not run completely', result.stderr)

    def test_the_style_script_checks_the_changed_files_with_a_base_commit_and_all_files_without_one(self):
        head = subprocess.run(['git', 'rev-parse', 'HEAD'], capture_output=True, text=True, cwd=ROOT).stdout.strip()
        swiftlint = self.canary_swiftlint()
        format_tool = tool(self.dir, 'swift-format', f'echo "$#" > "{self.dir}/format-count"\n')
        for base, expected in [(head, 'No changed Swift files require linting.'), ('', 'Done linting')]:
            with self.subTest(base=bool(base)):
                result = self.run_script('verify-swift-style.sh', SWIFTLINT_EXECUTABLE=str(swiftlint),
                                         SWIFT_FORMAT_EXECUTABLE=str(format_tool), BASE_SHA=base, HEAD_SHA=head)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(expected, result.stdout)
                self.assertGreater(int((self.dir / 'format-count').read_text()), 100)


if __name__ == '__main__':
    unittest.main()
