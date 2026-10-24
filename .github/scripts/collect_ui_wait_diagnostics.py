"""Capture concurrent app and runner evidence during the deleted-backup UI fixture."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import uuid


SYNC_PROBE = '''
import fcntl, json, os, sys, tempfile, time
with tempfile.TemporaryFile(dir=sys.argv[1]) as target:
    for kind in ('fsync', 'fullfsync'):
        for attempt in range(3):
            started = time.monotonic()
            target.seek(0)
            target.write(b'x' * 4096)
            target.flush()
            if kind == 'fsync':
                os.fsync(target.fileno())
            else:
                fcntl.fcntl(target.fileno(), fcntl.F_FULLFSYNC)
            print(json.dumps({'operation': kind, 'attempt': attempt,
                              'seconds': time.monotonic() - started}), flush=True)
'''


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def matching_app_pids(listing, simulator, device_root):
    prefix = device_root / simulator / 'data/Containers/Bundle/Application'
    executable = re.compile(re.escape(str(prefix))
                            + r'/[^/\s]+/EncryptedMemoriesMobile\.app/EncryptedMemoriesMobile(?:\s|$)')
    result = []
    for line in listing.splitlines():
        match = re.match(r'\s*(\d+)\s+(.+)', line)
        if not match:
            continue
        command = match[2]
        if executable.match(command) and re.search(r'(?:^|\s)-EncryptedMemoriesDeletedBackupFixture(?:\s|$)', command):
            result.append(int(match[1]))
    return result


class Collector:
    def __init__(self, simulator, output, device_root, runner=subprocess.run):
        self.simulator = simulator
        self.output = output
        self.device_root = device_root
        self.runner = runner
        self.captures = 0
        self.errors = []
        self.pid = None
        self.next_capture = None
        self.seen_pids = set()
        self.coverage_gaps = []
        self.decision_tests = set()
        self.capture_pool = ThreadPoolExecutor(max_workers=3)
        self.pending_captures = []
        self.capture_lock = threading.Lock()

    def tick(self, now):
        try:
            listing = self.runner(['/bin/ps', '-ww', '-axo', 'pid=,command='],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=8)
            if listing.returncode:
                raise RuntimeError('process listing failed')
            pids = matching_app_pids(listing.stdout, self.simulator, self.device_root)
        except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
            self.errors.append(type(error).__name__ + ': process discovery failed')
            return
        if len(pids) != 1:
            if len(pids) > 1:
                self.errors.append('Ambiguous fixture process ownership; neither process sampled')
            self.pid = None
            self.next_capture = None
            return
        if pids[0] != self.pid:
            self.pid = pids[0]
            self.seen_pids.add(self.pid)
            self.next_capture = now + 3
        if now >= self.next_capture:
            self.next_capture = now + 3
            self.pending_captures = [future for future in self.pending_captures if not self.completed(future)]
            if len(self.pending_captures) >= 3:
                self.coverage_gaps.append({'pid': self.pid, 'recorded_at': timestamp(),
                                           'outstanding_captures': len(self.pending_captures)})
                self.errors.append('Capture skipped: three diagnostic captures remain outstanding')
            else:
                self.pending_captures.append(self.capture_pool.submit(self.capture, self.pid))

    def completed(self, future):
        if not future.done():
            return False
        try:
            future.result()
        except Exception as error:
            self.errors.append(type(error).__name__ + ': capture failed; causal evidence is incomplete')
        return True

    def finish_captures(self):
        self.capture_pool.shutdown(wait=True)
        for future in self.pending_captures:
            self.completed(future)
        self.pending_captures.clear()

    def note_test_output(self, line):
        match = re.search(r"MobileDeletedBackupUITests (test[A-Za-z]+)\]' started", line)
        if match and match[1] in {
            'testAcknowledgedBackUpAgainTapIsNotRepeated', 'testBackUpAgainRemovesPermanentDecisionRow',
            'testBackUpAgainRetriesAnUnacknowledgedTap', 'testKeepDeletedRemovesDecisionRowAndAttentionCount',
        }:
            self.decision_tests.add(match[1])

    def signpost_availability(self):
        names = ['BackupBackUpAgain', 'BackupDecisionEntry', 'BackupDecisionRows',
                 'BackupDecisionJournal', 'BackupDecisionQueueWrite']
        counts = dict.fromkeys(names, 0)
        active = set()
        with (self.output / 'simulator-signposts.ndjson').open() as stream:
            for line in stream:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue  # log stream also emits non-JSON startup/status lines.
                if not isinstance(event, dict):
                    continue
                name, pid = event.get('signpostName'), event.get('processID')
                if name not in counts or pid not in self.seen_pids:
                    continue
                key = (pid, name, event.get('signpostID'))
                if event.get('signpostType') == 'begin':
                    active.add(key)
                elif event.get('signpostType') == 'end' and key in active:
                    active.remove(key)
                    counts[name] += 1
        expected = dict.fromkeys(names, len(self.decision_tests))
        expected['BackupBackUpAgain'] = sum('BackUpAgain' in name for name in self.decision_tests)
        missing = [name for name in names if counts[name] < expected[name]]
        if missing:
            self.errors.append('Missing complete decision signpost intervals: ' + ', '.join(missing)
                               + '; an attempted decision may not have reached its write')
        return counts, expected

    def capture(self, pid):
        with self.capture_lock:
            self.captures += 1
            directory = self.output / f'capture-{self.captures:04d}'
        directory.mkdir(parents=True)
        metadata = {'pid': pid, 'started_at': timestamp(), 'tools': {}}
        commands = {
            'sample': ['/usr/bin/sample', str(pid), '1', '10', '-mayDie', '-file', str(directory / 'app.sample.txt')],
            'top': ['/usr/bin/top', '-l', '2', '-s', '1', '-n', '20', '-o', 'cpu'],
            'vm-stat': ['/usr/bin/vm_stat'],
            'iostat': ['/usr/sbin/iostat', '-d', '-c', '2', '-w', '1'],
            'sync-latency': [sys.executable, '-u', '-c', SYNC_PROBE, str(self.output)],
        }
        def collect(name, command):
            result = {'started_at': timestamp()}
            with (directory / (name + '.txt')).open('w') as handle:
                try:
                    completed = self.runner(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                            text=True, timeout=8)
                    handle.write(completed.stdout or '')
                    result.update(status='completed', exit_code=completed.returncode)
                    if completed.returncode:
                        self.errors.append(name + ': nonzero exit')
                except subprocess.TimeoutExpired as error:
                    partial = error.stdout or b''
                    handle.write(partial.decode(errors='replace') if isinstance(partial, bytes) else partial)
                    handle.write('\nDiagnostic command exceeded eight seconds.\n')
                    result.update(status='timed_out', exit_code=None)
                    self.errors.append(name + ': timed out')
                except OSError as error:
                    handle.write(type(error).__name__ + ': diagnostic command unavailable\n')
                    result.update(status='unavailable', exit_code=None)
                    self.errors.append(name + ': unavailable')
            result['finished_at'] = timestamp()
            return name, result
        # Tools run concurrently; periodic samples can still miss a wait or time out.
        with ThreadPoolExecutor(max_workers=len(commands)) as pool:
            futures = [pool.submit(collect, name, command) for name, command in commands.items()]
            for future in futures:
                name, result = future.result()
                metadata['tools'][name] = result
        metadata['finished_at'] = timestamp()
        (directory / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')

    def monitor(self, stop):
        while not stop.is_set():
            try:
                self.tick(time.monotonic())
            except Exception as error:
                self.errors.append(type(error).__name__ + ': collector failed; causal evidence is incomplete')
                return
            stop.wait(0.5)


def run(command, collector):
    def diagnose(label, action):
        try:
            return action()
        except Exception as error:
            collector.errors.append(label + ': ' + type(error).__name__)
            return None  # Diagnostic failure must never replace the test result.

    ready = False
    try:
        collector.output.mkdir(parents=True, exist_ok=False)
        ready = True
    except OSError as error:
        collector.errors.append('Diagnostic output unavailable: ' + type(error).__name__)
    stop = threading.Event()
    monitor = threading.Thread(target=collector.monitor, args=(stop,))
    predicate = 'subsystem == "at.oncloud.encryptedmemories" AND category == "Database"'
    stream = log = timeline = None
    if ready:
        # The sync probe measures the output filesystem; retain volume identities for comparison.
        def record_volumes():
            volume = {'probe_device': collector.output.stat().st_dev,
                      'simulator_device': (collector.device_root / collector.simulator).stat().st_dev}
            (collector.output / 'volumes.json').write_text(json.dumps(volume) + '\n')
        diagnose('Diagnostic volume recording failed', record_volumes)
        log = diagnose('Diagnostic log unavailable',
                       lambda: (collector.output / 'simulator-signposts.ndjson').open('w'))
        if log is not None:
            stream = diagnose('Diagnostic initialization failed', lambda: subprocess.Popen(
                ['xcrun', 'simctl', 'spawn', collector.simulator, 'log', 'stream',
                 '--style', 'ndjson', '--level', 'debug', '--signpost', '--predicate', predicate],
                stdout=log, stderr=subprocess.STDOUT))
        timeline = diagnose('Diagnostic timeline unavailable',
                            lambda: (collector.output / 'xcode-output.jsonl').open('w'))
        diagnose('Diagnostic monitor initialization failed', monitor.start)
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            print(line, end='', flush=True)
            collector.note_test_output(line)
            if timeline is not None:
                def record_line():
                    timeline.write(json.dumps({'received_at': timestamp(), 'line': line.rstrip()}) + '\n')
                    timeline.flush()
                    return True
                if not diagnose('Diagnostic timeline recording failed', record_line):
                    diagnose('Diagnostic timeline close failed', timeline.close)
                    timeline = None
        return_code = process.wait()
    finally:
        stop.set()
        if monitor.ident is not None:
            diagnose('Diagnostic monitor shutdown failed', monitor.join)
        diagnose('Diagnostic capture shutdown failed', collector.finish_captures)
        def stop_stream():
            if stream.poll() is None:
                stream.terminate()
                try:
                    stream.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    stream.kill()
                    stream.wait()
            else:
                collector.errors.append('Simulator signpost stream exited early')
        if stream is not None:
            diagnose('Diagnostic stream shutdown failed', stop_stream)
        for handle in [log, timeline]:
            if handle is not None:
                diagnose('Diagnostic output close failed', handle.close)
        availability = diagnose('Diagnostic timing unavailable', collector.signpost_availability) if ready else None
        intervals, expected = availability if availability is not None else ({}, {})
        summary = {'captures': collector.captures, 'seen_pids': sorted(collector.seen_pids),
                   'coverage_gaps': collector.coverage_gaps,
                   'signpost_intervals': intervals, 'expected_signpost_intervals': expected,
                   'errors': collector.errors, 'finished_at': timestamp()}
        if not collector.captures:
            summary['errors'].append('No fixture stack captures; causal diagnosis is unavailable')
        if ready:
            diagnose('Diagnostic summary recording failed',
                     lambda: (collector.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n'))
        print('[ui-diagnostics] ' + json.dumps(summary), flush=True)
    return return_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('a test command is required')
    try:
        simulator = str(uuid.UUID(args.simulator)).upper()
    except ValueError:
        print('[ui-diagnostics] Invalid Simulator ID; diagnostics unavailable', file=sys.stderr)
        return subprocess.call(command)
    device_root = Path.home() / 'Library/Developer/CoreSimulator/Devices'
    return run(command, Collector(simulator, args.output, device_root))


if __name__ == '__main__':
    raise SystemExit(main())
