import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

import collect_ui_wait_diagnostics as diagnostics


class UIWaitDiagnosticsTests(unittest.TestCase):
    simulator = '00000000-0000-0000-0000-000000000001'
    device_root = Path('/synthetic/Devices')

    def process(self, pid=42, simulator=None, arguments='-EncryptedMemoriesDeletedBackupFixture'):
        device = simulator or self.simulator
        return (f'{pid} {self.device_root}/{device}/data/Containers/Bundle/Application/fixture/'
                f'EncryptedMemoriesMobile.app/EncryptedMemoriesMobile {arguments}\n')

    def test_only_the_exact_owned_simulator_fixture_is_sampled(self):
        listing = (self.process() + self.process(43, simulator='foreign')
                   + self.process(44, arguments='-EncryptedMemoriesUITestFixture')
                   + '45 /synthetic/EncryptedMemoriesMobile.app/EncryptedMemoriesMobile '
                   '-EncryptedMemoriesDeletedBackupFixture\n')
        self.assertEqual(diagnostics.matching_app_pids(listing, self.simulator, self.device_root), [42])

    def test_shell_commands_and_partial_fixture_arguments_are_excluded(self):
        listing = ('51 /bin/bash -c ' + self.process(42)
                   + self.process(52, arguments='-EncryptedMemoriesDeletedBackupFixtureOther'))
        self.assertEqual(diagnostics.matching_app_pids(listing, self.simulator, self.device_root), [])

    def collector(self, directory, listing=None):
        def runner(command, **kwargs):
            if command[0] == '/bin/ps':
                return subprocess.CompletedProcess(command, 0, listing or self.process())
            if command[0] == '/usr/bin/sample':
                Path(command[-1]).write_text('Synthetic main-thread stack\n')
            return subprocess.CompletedProcess(command, 0, 'Synthetic tool output\n')
        return diagnostics.Collector(self.simulator, Path(directory), self.device_root, runner=runner)

    def test_sampling_starts_at_three_seconds_and_repeats_during_a_blocked_wait(self):
        with tempfile.TemporaryDirectory() as directory:
            collector = self.collector(directory)
            with mock.patch.object(collector, 'capture') as capture:
                for now in [0, 2.9, 3, 4, 6, 9]:
                    collector.tick(now)
                collector.finish_captures()
                self.assertEqual(capture.call_count, 3)
                capture.assert_called_with(42)

    def test_a_relaunched_app_gets_a_new_three_second_baseline(self):
        with tempfile.TemporaryDirectory() as directory:
            collector = self.collector(directory)
            with mock.patch.object(collector, 'capture') as capture:
                collector.tick(0)
                collector.tick(3)
                replacement = self.collector(directory, self.process(43))
                collector.runner = replacement.runner
                collector.tick(4)
                collector.tick(6.9)
                collector.tick(7)
                collector.finish_captures()
                self.assertEqual(capture.call_args_list, [mock.call(42), mock.call(43)])

    def test_ambiguous_app_ownership_never_samples_either_process(self):
        with tempfile.TemporaryDirectory() as directory:
            collector = self.collector(directory, self.process() + self.process(43))
            with mock.patch.object(collector, 'capture') as capture:
                collector.tick(0)
                collector.tick(3)
                capture.assert_not_called()
            self.assertTrue(collector.errors)

    def test_capture_retains_stacks_resources_and_disk_latency_with_timestamps(self):
        with tempfile.TemporaryDirectory() as directory:
            collector = self.collector(directory)
            collector.capture(42)
            capture = Path(directory) / 'capture-0001'
            self.assertTrue((capture / 'app.sample.txt').is_file())
            for name in ['top.txt', 'vm-stat.txt', 'iostat.txt', 'sync-latency.txt']:
                self.assertIn('Synthetic tool output', (capture / name).read_text())
            metadata = json.loads((capture / 'metadata.json').read_text())
            self.assertEqual(metadata['pid'], 42)
            self.assertEqual(set(metadata['tools']), {'sample', 'top', 'vm-stat', 'iostat', 'sync-latency'})
            self.assertIn('started_at', metadata)
            self.assertIn('finished_at', metadata)
            self.assertTrue(all(tool['exit_code'] == 0 for tool in metadata['tools'].values()))

    def test_tool_failure_is_recorded_without_discarding_other_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            collector = self.collector(directory)
            original = collector.runner
            def fail_sample(command, **kwargs):
                if command[0] == '/usr/bin/sample':
                    raise subprocess.TimeoutExpired(command, 8)
                return original(command, **kwargs)
            collector.runner = fail_sample
            collector.capture(42)
            capture = Path(directory) / 'capture-0001'
            metadata = json.loads((capture / 'metadata.json').read_text())
            self.assertEqual(metadata['tools']['sample']['status'], 'timed_out')
            self.assertTrue((capture / 'top.txt').is_file())
            self.assertTrue(collector.errors)

    def test_the_original_test_failure_is_preserved_and_diagnostic_absence_is_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / self.simulator).mkdir()
            collector = diagnostics.Collector(self.simulator, root / 'output', root)
            stream = mock.Mock()
            stream.poll.return_value = None
            test = mock.Mock()
            test.stdout = ['Synthetic test failed\n']
            test.wait.return_value = 65
            with mock.patch.object(collector, 'monitor'), mock.patch('subprocess.Popen', side_effect=[stream, test]):
                result = diagnostics.run(['synthetic-tests'], collector)
            self.assertEqual(result, 65)
            summary = json.loads((collector.output / 'summary.json').read_text())
            self.assertIn('No fixture stack captures; causal diagnosis is unavailable', summary['errors'])
            stream.terminate.assert_called_once()
            self.assertTrue((collector.output / 'xcode-output.jsonl').is_file())


    def test_slow_resource_commands_do_not_block_sampling_admission(self):
        with tempfile.TemporaryDirectory() as directory:
            collector = self.collector(directory)
            original = collector.runner
            release = threading.Event()
            admitted = threading.Event()
            lock = threading.Condition()
            samples = []
            def held_runner(command, **kwargs):
                if command[0] == '/usr/sbin/iostat':
                    release.wait(3)
                if command[0] == '/usr/bin/sample':
                    with lock:
                        samples.append(command[1])
                        lock.notify_all()
                return original(command, **kwargs)
            collector.runner = held_runner
            collector.tick(0)
            def first_tick():
                collector.tick(3)
                admitted.set()
            worker = threading.Thread(target=first_tick)
            worker.start()
            try:
                with lock:
                    self.assertTrue(lock.wait_for(lambda: len(samples) == 1, timeout=1))
                self.assertTrue(admitted.wait(0.5), 'A held command must not block the monitor')
                collector.tick(6)
                with lock:
                    self.assertTrue(lock.wait_for(lambda: len(samples) == 2, timeout=1))
            finally:
                release.set()
                worker.join()
                if hasattr(collector, 'finish_captures'):
                    collector.finish_captures()

    def test_outstanding_captures_are_bounded_and_every_skipped_capture_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            collector = self.collector(directory)
            release = threading.Event()
            started = threading.Condition()
            count = 0
            def held_capture(pid):
                nonlocal count
                with started:
                    count += 1
                    started.notify_all()
                release.wait(3)
            with mock.patch.object(collector, 'capture', side_effect=held_capture):
                collector.tick(0)
                try:
                    for index, now in enumerate([3, 6, 9], 1):
                        collector.tick(now)
                        with started:
                            self.assertTrue(started.wait_for(lambda: count == index, timeout=1))
                    collector.tick(12)
                    self.assertEqual(count, 3, 'Never accumulate an unbounded diagnostic queue')
                    self.assertTrue(collector.coverage_gaps)
                    self.assertEqual(collector.coverage_gaps[0]['pid'], 42)
                    self.assertEqual(collector.coverage_gaps[0]['outstanding_captures'], 3)
                finally:
                    release.set()
                    if hasattr(collector, 'finish_captures'):
                        collector.finish_captures()

    def run_with_stream(self, directory, status=None, records=(), return_code=0, stream_error=False):
        root = Path(directory)
        (root / self.simulator).mkdir()
        collector = diagnostics.Collector(self.simulator, root / 'output', root)
        collector.captures = 1
        collector.seen_pids.add(42)
        stream = mock.Mock()
        stream.poll.return_value = status
        stream.returncode = status
        test = mock.Mock()
        test.stdout = ["Test Case '-[EncryptedMemoriesMobileUITests.MobileDeletedBackupUITests "
                       "testBackUpAgainRemovesPermanentDecisionRow]' started.\n"]
        test.wait.return_value = return_code
        def popen(command, **kwargs):
            if command[0] == 'xcrun':
                if stream_error:
                    raise OSError('Synthetic diagnostic startup failure')
                for record in records:
                    kwargs['stdout'].write(json.dumps(record) + '\n')
                kwargs['stdout'].flush()
                return stream
            return test
        with mock.patch.object(collector, 'monitor'), mock.patch('subprocess.Popen', side_effect=popen):
            result = diagnostics.run(['synthetic-tests'], collector)
        summary = json.loads((collector.output / 'summary.json').read_text())
        return result, summary

    def signpost_records(self, pid=42, complete=True):
        names = ['BackupBackUpAgain', 'BackupDecisionEntry', 'BackupDecisionRows',
                 'BackupDecisionJournal', 'BackupDecisionQueueWrite']
        return [{'processID': pid, 'signpostName': name, 'signpostID': index, 'signpostType': kind}
                for index, name in enumerate(names)
                for kind in (['begin', 'end'] if complete else ['begin'])]

    def test_every_premature_stream_exit_is_reported_and_the_test_result_stays_intact(self):
        for status in [0, 1]:
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                result, summary = self.run_with_stream(directory, status=status, return_code=65)
                self.assertEqual(result, 65)
                self.assertIn('Simulator signpost stream exited early', summary['errors'])

    def test_missing_or_incomplete_decision_intervals_are_explicit(self):
        for records in [[], self.signpost_records(complete=False), self.signpost_records(pid=99)]:
            with self.subTest(records=records), tempfile.TemporaryDirectory() as directory:
                result, summary = self.run_with_stream(directory, records=records)
                self.assertEqual(result, 0, 'Diagnostic failure must not replace the test result')
                self.assertTrue(any('Missing complete decision signpost intervals' in error
                                    for error in summary['errors']))

    def test_complete_owned_decision_intervals_are_available(self):
        with tempfile.TemporaryDirectory() as directory:
            result, summary = self.run_with_stream(directory, records=self.signpost_records())
            self.assertEqual(result, 0)
            self.assertEqual(summary['errors'], [])
            self.assertEqual(summary['signpost_intervals']['BackupBackUpAgain'], 1)


    def test_diagnostic_startup_failure_still_runs_the_test_and_preserves_its_result(self):
        with tempfile.TemporaryDirectory() as directory:
            result, summary = self.run_with_stream(directory, return_code=65, stream_error=True)
            self.assertEqual(result, 65)
            self.assertTrue(any('Diagnostic initialization failed' in error for error in summary['errors']))

    def test_diagnostic_summary_failure_does_not_replace_a_successful_test_result(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path.write_text
            def write(path, *args, **kwargs):
                if path.name == 'summary.json':
                    raise OSError('Synthetic diagnostic output failure')
                return original(path, *args, **kwargs)
            root = Path(directory)
            (root / self.simulator).mkdir()
            collector = diagnostics.Collector(self.simulator, root / 'output', root)
            stream = mock.Mock()
            stream.poll.return_value = None
            test = mock.Mock()
            test.stdout = ['Synthetic test passed\n']
            test.wait.return_value = 0
            with mock.patch.object(collector, 'monitor'), mock.patch.object(Path, 'write_text', write), \
                    mock.patch('subprocess.Popen', side_effect=[stream, test]):
                self.assertEqual(diagnostics.run(['synthetic-tests'], collector), 0)



    def test_invalid_diagnostic_simulator_does_not_replace_the_test_result(self):
        with tempfile.TemporaryDirectory() as directory:
            command = [sys.executable, '-B', str(Path(diagnostics.__file__)),
                       '--simulator', 'invalid-synthetic-simulator', '--output', directory, '--',
                       sys.executable, '-c', 'raise SystemExit(65)']
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 65)
            self.assertIn('diagnostics unavailable', result.stderr)



if __name__ == '__main__':
    unittest.main()
