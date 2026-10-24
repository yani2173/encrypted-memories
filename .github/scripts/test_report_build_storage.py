import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ReportBuildStorage(unittest.TestCase):
    def setUp(self):
        # A copy of the scripts in an empty checkout: the .build folders of the real checkout stay out of the total.
        self.checkout = tempfile.TemporaryDirectory()
        self.addCleanup(self.checkout.cleanup)
        scripts = Path(self.checkout.name) / 'scripts'
        scripts.mkdir()
        for name in ['report-build-storage.sh', 'build-paths.sh']:
            shutil.copy(ROOT / 'scripts' / name, scripts)

    def report(self, build_root):
        environment = dict(os.environ, ENCRYPTED_MEMORIES_BUILD_ROOT=str(build_root))
        return subprocess.run(['bash', str(Path(self.checkout.name) / 'scripts/report-build-storage.sh')],
                              capture_output=True, text=True, env=environment, cwd=self.checkout.name)

    def test_each_folder_of_the_build_root_is_listed_with_its_size_in_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'build'
            (root / 'SourcePackages.noindex').mkdir(parents=True)
            (root / 'XcodePackageCache.noindex').mkdir()
            (root / 'SourcePackages.noindex/big').write_bytes(b'0' * 3 * 1024 * 1024)
            (root / 'XcodePackageCache.noindex/small').write_bytes(b'0' * 1024 * 1024)
            result = self.report(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertEqual(lines[0], 'Canonical Encrypted Memories build storage:')
            names = [match.group(1) for line in lines if (match := re.match(r'\s+[\d.]+ GiB {4}(\S+)$', line))]
            self.assertEqual(names, ['SourcePackages.noindex', 'XcodePackageCache.noindex'])

    def test_a_missing_build_root_lists_nothing_and_succeeds(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.report(Path(directory) / 'missing')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            self.assertNotRegex(result.stdout, r'GiB {4}\S')

    def test_the_size_of_a_folder_is_in_gibibytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'build'
            (root / 'data').mkdir(parents=True)
            (root / 'data/file').write_bytes(b'0' * 64 * 1024 * 1024)
            result = self.report(root)
            size = float(re.search(r'\s+([\d.]+) GiB {4}data$', result.stdout, re.MULTILINE).group(1))
            self.assertAlmostEqual(size, 64 / 1024, delta=0.01)

    def child_lines(self, result):
        return [m.group(1) for line in result.stdout.splitlines() if (m := re.match(r'\s+[\d.?]+ GiB {4}(.+)$', line))]

    def test_only_folders_are_listed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'build'
            (root / 'folder/nested').mkdir(parents=True)
            (root / 'run.log').write_text('log')
            result = self.report(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.child_lines(result), ['folder'])

    def test_a_folder_that_cannot_be_read_is_marked_and_does_not_end_the_report(self):
        if os.geteuid() == 0:
            self.skipTest('root reads every folder')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'build'
            for name in ['a-locked', 'b-open']:
                (root / name).mkdir(parents=True)
            (root / 'a-locked/inner').mkdir()
            (root / 'a-locked').chmod(0)
            try:
                result = self.report(root)
            finally:
                (root / 'a-locked').chmod(0o755)
            self.assertEqual(result.returncode, 0, result.stderr)
            # GNU du prints the readable part and BSD du prints nothing; both are marked, neither is dropped.
            self.assertEqual(self.child_lines(result), ['a-locked (incomplete)', 'b-open'])
            root_line = [line for line in result.stdout.splitlines() if line.endswith(str(root) + ' (incomplete)')]
            self.assertEqual(len(root_line), 1, result.stdout)
            self.assertIn('Total reported build storage:', result.stdout)

    def test_a_build_root_that_cannot_be_read_is_marked_and_does_not_end_the_report(self):
        if os.geteuid() == 0:
            self.skipTest('root reads every folder')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'build'
            (root / 'inner').mkdir(parents=True)
            root.chmod(0)
            try:
                result = self.report(root)
            finally:
                root.chmod(0o755)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            self.assertEqual(len([line for line in result.stdout.splitlines() if line.endswith(str(root) + ' (incomplete)')]), 1)
            self.assertEqual(self.child_lines(result), [])
            self.assertIn('Total reported build storage:', result.stdout)

    def test_a_folder_name_with_a_newline_or_a_space_is_listed_once_with_its_size(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'build'
            (root / 'with space').mkdir(parents=True)
            (root / 'two\nlines').mkdir()
            (root / 'two\nlines/data').write_bytes(b'0' * 64 * 1024 * 1024)
            result = self.report(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            self.assertIn('with space', self.child_lines(result))
            self.assertEqual(len([line for line in result.stdout.splitlines() if re.match(r'\s+[\d.?]+ GiB {4}', line)]), 2)
            newline_size = float(re.search(r'\s+([\d.]+) GiB {4}two$', result.stdout, re.MULTILINE).group(1))
            self.assertAlmostEqual(newline_size, 64 / 1024, delta=0.01)
            self.assertIn('Total reported build storage:', result.stdout)

    def test_a_trailing_slash_on_the_build_root_does_not_change_the_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'build'
            (root / 'folder').mkdir(parents=True)
            result = self.report(str(root) + '/')
            self.assertEqual(self.child_lines(result), ['folder'])

    def test_the_sizes_show_the_split_that_the_cache_measurement_needs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'build'
            for name, megabytes in [('SourcePackages.noindex', 400), ('XcodePackageCache.noindex', 100)]:
                (root / name).mkdir(parents=True)
                (root / name / 'data').write_bytes(b'0' * megabytes * 1024 * 1024)
            result = self.report(root)
            sizes = {m.group(2): float(m.group(1)) for line in result.stdout.splitlines()
                     if (m := re.match(r'\s+([\d.]+) GiB {4}(\S+)$', line))}
            self.assertGreater(sizes['SourcePackages.noindex'], 3 * sizes['XcodePackageCache.noindex'])
            # The folders are part of the root: the total is the root, not the root plus its folders.
            total = float(re.search(r'Total reported build storage: ([\d.]+) GiB', result.stdout).group(1))
            root_size = float(re.search(r'\s+([\d.]+) GiB  ' + re.escape(str(root)), result.stdout).group(1))
            self.assertAlmostEqual(total, root_size, delta=0.05)


if __name__ == '__main__':
    unittest.main()
