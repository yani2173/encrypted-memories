#!/usr/bin/env python3
"""Exercise the loopback oracle and the fail-closed upgrade journey."""
import json
import re
import plistlib
from pathlib import Path
import sys
import subprocess
import tempfile
import tarfile
import io
import unittest
from unittest.mock import patch
import signal
import os
import uuid
import select
import threading
import socket
import time
from contextlib import nullcontext

from http.client import HTTPConnection
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/upgrade-test'))
import build_apps
from build_apps import apply_overlay, Build, PAYLOAD, publish_product
from journey import JourneyError, run_cases
from server import FixtureServer
import run_journey


def _temporary_directory():
    # A late write by the code under test can race the cleanup (OSError 39, Directory not empty).
    # The directory holds only synthetic files, so a failed cleanup must not fail the test.
    if sys.version_info >= (3, 10):
        return tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
    return tempfile.TemporaryDirectory()


class UpgradeJourneyTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Native Settings controls require macOS')
    def test_native_macos_settings_pane_retries_only_unacknowledged_clicks(self):
        repo = Path(__file__).resolve().parents[2]
        scratch = Path(os.environ.get('ENCRYPTED_MEMORIES_BUILD_ROOT',
            str(Path.home() / 'Developer/xcode/EncryptedMemories'))) / 'UpgradeSettings'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temporary:
            root = Path(temporary)
            main = root / 'main.swift'
            main.write_text(r"""
for pane in ["Backup", "Smart Search"] {
    for dropped in 0...2 {
        var clicks = 0
        var acknowledged = false
        var success = false
        do {
            try SettingsPaneTestSupport.select(pane, click: {
                clicks += 1
                if clicks > dropped { acknowledged = true }
            }, isAcknowledged: { acknowledged }, waitForAcknowledgement: { acknowledged })
            success = true
        } catch SettingsPaneTestError.notAcknowledged(let name) {
            precondition(name == pane)
            precondition(String(describing: SettingsPaneTestError.notAcknowledged(name))
                == "Settings did not select the \(pane) pane after two clicks")
        } catch {
            fatalError("Unexpected Settings control error: \(error)")
        }
        print("\(pane)|\(dropped)|\(clicks)|\(success)")
    }
    var clicks = 0
    var checks = 0
    var success = false
    do {
        try SettingsPaneTestSupport.select(pane, click: { clicks += 1 }, isAcknowledged: {
            checks += 1
            return true
        }, waitForAcknowledgement: { false })
        success = true
    } catch SettingsPaneTestError.notAcknowledged(let name) {
        precondition(name == pane)
    } catch {
        fatalError("Unexpected Settings control error: \(error)")
    }
    print("\(pane)|late|\(clicks)|\(checks)|\(success)")
}
""")
            binary = root / 'settings-controls'
            subprocess.run(['xcrun', 'swiftc', '-O',
                str(repo / 'scripts/upgrade-test/UITests/SettingsPaneTestSupport.swift'),
                str(main), '-o', str(binary)], check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            rows = [line.split('|') for line in result.stdout.splitlines()]
            expected = []
            for pane in ['Backup', 'Smart Search']:
                expected.extend([[pane, '0', '1', 'true'], [pane, '1', '2', 'true'],
                                 [pane, '2', '2', 'false'], [pane, 'late', '1', '1', 'true']])
            self.assertEqual(len(rows), len(expected))
            for actual, wanted in zip(rows, expected):
                with self.subTest(pane=wanted[0], dropped=wanted[1]):
                    self.assertEqual(actual, wanted)

    def test_repeated_cancellation_does_not_interrupt_owned_cleanup(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            marker = root / 'owned-resource'
            marker.touch()
            script = """
import signal, sys, subprocess, os
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from run_journey import terminate
signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)
try:
    print('ready', flush=True)
    sys.stdin.readline()
finally:
    print('cleanup', flush=True)
    sys.stdin.readline()
    Path(sys.argv[2]).unlink()
    child = subprocess.run(['/bin/sh', '-c', 'kill -TERM $$'])
    if child.returncode != -signal.SIGTERM:
        Path(sys.argv[2]).touch()
"""
            with (root / 'cancel.log').open('w') as log:
                process = subprocess.Popen([sys.executable, '-c', script,
                    str(Path(__file__).resolve().parents[2] / 'scripts/upgrade-test'), str(marker)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                    text=True, start_new_session=True)
                try:
                    self.assertEqual(process.stdout.readline().strip(), 'ready')
                    os.killpg(process.pid, signal.SIGTERM)
                    self.assertEqual(process.stdout.readline().strip(), 'cleanup')
                    os.killpg(process.pid, signal.SIGINT)
                    process.stdin.write('finish cleanup\n')
                    process.stdin.flush()
                    self.assertNotEqual(process.wait(timeout=5), 0, 'Cancellation must remain a failed run')
                    self.assertFalse(marker.exists(), 'Repeated cancellation interrupted owned resource cleanup')
                finally:
                    run_journey.stop_group(process)
                    process.stdin.close()
                    process.stdout.close()

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_PROBES') == '1', 'Native cleanup is opt-in')
    def test_native_cancellation_removes_owned_simulator_and_signing_identity(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            script = """
import json, os, signal, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from run_journey import InstalledApp, SigningIdentity, terminate
ready = os.fdopen(os.dup(sys.stdout.fileno()), 'w')
os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)
root = Path(sys.argv[2])
with SigningIdentity(root) as signer:
    app = InstalledApp('iOS', root, signer)
    try:
        print(json.dumps({'simulator': app.simulator, 'directory': str(signer.directory)}), file=ready, flush=True)
        sys.stdin.readline()
    finally:
        print('cleanup', file=ready, flush=True)
        sys.stdin.readline()
        app.close()
"""
            def line(process):
                self.assertTrue(select.select([process.stdout], [], [], 120)[0], 'Native cleanup probe timed out')
                return process.stdout.readline().strip()
            with (root / 'native-cancel.log').open('w') as log:
                process = subprocess.Popen([sys.executable, '-c', script,
                    str(Path(__file__).resolve().parents[2] / 'scripts/upgrade-test'), str(root)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                    text=True, start_new_session=True, env=run_journey.clean_environment())
                try:
                    resources = json.loads(line(process))
                    os.killpg(process.pid, signal.SIGINT)
                    self.assertEqual(line(process), 'cleanup')
                    os.killpg(process.pid, signal.SIGTERM)
                    process.stdin.write('finish cleanup\n')
                    process.stdin.flush()
                    self.assertNotEqual(process.wait(timeout=30), 0)
                    self.assertFalse(Path(resources['directory']).exists())
                    devices = json.loads(run_journey.output(['xcrun', 'simctl', 'list', 'devices', '--json']))['devices']
                    self.assertFalse(any(device['udid'] == resources['simulator'] for group in devices.values() for device in group))
                    print('PASS: repeated cancellation removed only the owned simulator and temporary signing identity', flush=True)
                finally:
                    run_journey.stop_group(process)
                    process.stdin.close()
                    process.stdout.close()

    def test_backup_consent_waits_for_delayed_flush_without_changing_preferences(self):
        with tempfile.TemporaryDirectory() as root:
            preferences = Path(root) / 'preferences.plist'
            preferences.write_bytes(plistlib.dumps({'unrelated': True}))
            flushed = plistlib.dumps({'unrelated': True, 'photoBackup.enabled.v1': True})
            with patch('time.monotonic', side_effect=[0, 0.2]), patch('time.sleep', side_effect=lambda _: preferences.write_bytes(flushed)) as pause:
                self.assertIs(run_journey.wait_saved_backup_consent(preferences, deadline=1), True)
            pause.assert_called_once()
            self.assertEqual(preferences.read_bytes(), flushed)

    def test_backup_consent_requires_the_exact_saved_true_key_within_the_existing_budget(self):
        for values in [{'unrelated': True}, {'photoBackup.enabled.v1': False}, {'photoBackup.enabled.v1': 1}]:
            with self.subTest(values=values), tempfile.TemporaryDirectory() as root:
                preferences = Path(root) / 'preferences.plist'
                original = plistlib.dumps(values)
                preferences.write_bytes(original)
                with patch('time.monotonic', return_value=1), patch('time.sleep') as pause:
                    with self.assertRaisesRegex(JourneyError, 'saved backup consent'):
                        run_journey.wait_saved_backup_consent(preferences, deadline=1)
                pause.assert_not_called()
                self.assertEqual(preferences.read_bytes(), original)

    def test_unreadable_backup_preferences_fail_without_waiting_or_repair(self):
        with tempfile.TemporaryDirectory() as root:
            preferences = Path(root) / 'preferences.plist'
            preferences.write_bytes(b'not a plist')
            with patch('time.sleep') as pause:
                with self.assertRaisesRegex(JourneyError, 'Unreadable backup preferences'):
                    run_journey.wait_saved_backup_consent(preferences, deadline=1)
            pause.assert_not_called()
            self.assertEqual(preferences.read_bytes(), b'not a plist')

    def test_install_over_must_retain_the_actually_saved_backup_consent(self):
        with tempfile.TemporaryDirectory() as root:
            preferences = Path(root) / 'preferences.plist'
            preferences.write_bytes(plistlib.dumps({'photoBackup.enabled.v1': True}))
            baseline = run_journey.wait_saved_backup_consent(preferences, deadline=0)
            run_journey.verify_saved_backup_consent(preferences, baseline)
            for values in [{}, {'photoBackup.enabled.v1': False}]:
                preferences.write_bytes(plistlib.dumps(values))
                with self.assertRaisesRegex(JourneyError, 'Saved backup consent changed'):
                    run_journey.verify_saved_backup_consent(preferences, baseline)

    def test_standalone_ui_runner_does_not_inherit_app_hardening(self):
        repo = Path(__file__).resolve().parents[2]
        with _temporary_directory() as root:
            root = Path(root)
            source = root / 'scratch/source'
            (source / 'UpgradeUITests').mkdir(parents=True)
            products = source.parent / 'build/DerivedData.noindex/Build/Products'
            products.mkdir(parents=True)
            (products / 'runner.xctestrun').touch()
            metadata = {'tag': 'v1.0.5', 'version': '1.0.5', 'build_number': '397223379', 'commit': 'a' * 40}
            bundle = root / 'fixture.app/Contents'
            bundle.mkdir(parents=True)
            (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': run_journey.BUNDLE,
                'CFBundleShortVersionString': '1.0.5', 'CFBundleVersion': '397223379'}))
            build = Build(root / 'fixture.app', source, metadata, 'a' * 40)
            arguments = ['run_journey', '--repo', str(repo), '--automation', str(repo),
                         '--root', str(root), '--target', 'HEAD', '--sources', 'v1.0.5', '--platform', 'macOS']
            with patch.object(sys, 'argv', arguments), patch.object(run_journey, 'build_app', return_value=build), \
                    patch.object(run_journey, 'release_metadata', return_value=metadata), \
                    patch('keychain_entitlements.snapshot', return_value={}), \
                    patch.object(run_journey, 'SigningIdentity'), patch.object(run_journey, 'run_cases'), \
                    patch.object(run_journey, 'output', return_value='arm64'), \
                    patch.object(run_journey, 'command') as command:
                run_journey.main()
            toolchain = next((root / 'evidence').glob('*/toolchain.json'))
            self.assertEqual(json.loads(toolchain.read_text()), {'xcode': 'arm64', 'platform': 'macOS', 'target': 'HEAD'})
            command.assert_any_call(['xcrun', 'swift', str(repo / 'scripts/upgrade-test/metal_devices.swift')])
            invocation = command.call_args.args[0]
            self.assertEqual(invocation[:3], ['xcrun', 'xcodebuild', 'build-for-testing'])
            self.assertIn('UpgradeJourney', invocation)
            self.assertIn('ENABLE_HARDENED_RUNTIME=NO', invocation)

    def test_cached_ui_runner_refreshes_support_files_before_each_compile(self):
        repo = Path(__file__).resolve().parents[2]
        with _temporary_directory() as temporary:
            root = Path(temporary)
            automation = root / 'automation'
            inputs = automation / 'scripts/upgrade-test/UITests'
            inputs.mkdir(parents=True)
            (inputs / 'UpgradeJourneyUITests.swift').write_text('current journey')
            source = root / 'cached/source'
            ui = source / 'UpgradeUITests'
            ui.mkdir(parents=True)
            (ui / 'SettingsPaneTestSupport.swift').write_text('cached support')
            (ui / 'RemovedSupport.swift').write_text('removed support')
            products = source.parent / 'build/DerivedData.noindex/Build/Products'
            products.mkdir(parents=True)
            (products / 'runner.xctestrun').touch()
            metadata = {'tag': 'v1.0.5', 'version': '1.0.5', 'build_number': '397223379', 'commit': 'a' * 40}
            bundle = root / 'fixture.app/Contents'
            bundle.mkdir(parents=True)
            (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': run_journey.BUNDLE,
                'CFBundleShortVersionString': '1.0.5', 'CFBundleVersion': '397223379'}))
            cached = Build(root / 'fixture.app', source, metadata, 'a' * 40)
            arguments = ['run_journey', '--repo', str(repo), '--automation', str(automation),
                         '--root', str(root), '--target', 'HEAD', '--sources', 'v1.0.5',
                         '--platform', 'macOS', '--working-copy']
            compiled = []

            def command(args, **kwargs):
                if args[:3] == ['xcrun', 'xcodebuild', 'build-for-testing']:
                    compiled.append((ui / 'SettingsPaneTestSupport.swift').read_text())
                    self.assertFalse((ui / 'RemovedSupport.swift').exists(), 'A removed UI-test file survived')
                    self.assertEqual((ui / 'UpgradeJourneyUITests.swift').read_text(), 'current journey')

            with patch.object(sys, 'argv', arguments), patch.object(run_journey, 'build_app', return_value=cached), \
                    patch.object(run_journey, 'release_metadata', return_value=metadata), \
                    patch('keychain_entitlements.snapshot', return_value={}), \
                    patch.object(run_journey, 'SigningIdentity'), patch.object(run_journey, 'run_cases'), \
                    patch.object(run_journey, 'output', return_value='arm64'), \
                    patch.object(run_journey, 'command', side_effect=command):
                for version in ['first support', 'edited support']:
                    (inputs / 'SettingsPaneTestSupport.swift').write_text(version)
                    run_journey.main()
            self.assertEqual(compiled, ['first support', 'edited support'])

    def test_macos_launch_passes_the_same_case_to_the_ui_runner_without_a_second_launcher(self):
        with tempfile.TemporaryDirectory() as root:
            app = run_journey.InstalledApp('macOS', Path(root))
            app.installed = Path(root) / 'installed.app'
            (app.installed / 'Contents').mkdir(parents=True)
            (app.installed / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Fixture'}))
            with patch.object(run_journey, 'owned_process') as launch:
                app.launch(type('Server', (), {'url': 'http://127.0.0.1:1234'})(), seed=True)
                launch.assert_not_called()
            self.assertIn(app.case_id, app.launch_arguments)
            self.assertIn('-EncryptedMemoriesUpgradeSeed', app.launch_arguments)
            app.launch(type('Server', (), {'url': 'http://127.0.0.1:1234'})())
            self.assertIn(app.case_id, app.launch_arguments)
            self.assertNotIn('-EncryptedMemoriesUpgradeSeed', app.launch_arguments)

    def test_macos_kill_requires_one_process_from_the_exact_owned_app_bundle(self):
        with tempfile.TemporaryDirectory() as root:
            app = run_journey.InstalledApp('macOS', Path(root))
            app.installed = Path(root) / 'installed.app'
            (app.installed / 'Contents').mkdir(parents=True)
            (app.installed / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Fixture'}))
            binary = str(app.installed / 'Contents/MacOS/Fixture')
            for processes in ['', '99 /foreign/Fixture', '41 ' + binary + '\n42 ' + binary]:
                with patch.object(run_journey, 'output', return_value=processes), patch.object(run_journey.os, 'kill') as kill:
                    with self.assertRaises(JourneyError):
                        app.kill_app()
                    kill.assert_not_called()
            with patch.object(run_journey, 'output', return_value='99 /foreign/Fixture\n42 ' + binary), \
                    patch.object(run_journey.os, 'kill') as kill:
                app.kill_app()
                kill.assert_called_once_with(42, signal.SIGKILL)

    def test_ui_runner_receives_the_owned_application_arguments(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            runner = root / 'runner.xctestrun'
            runner.write_bytes(plistlib.dumps({'Tests': {'IsUITestBundle': True}}))
            arguments = ['-EncryptedMemoriesUITestFixture', '-EncryptedMemoriesUpgradeCase', 'a' * 32]
            with patch.object(run_journey, 'owned_process'):
                process, log = run_journey.ui_run(runner, 'platform=macOS', 'backup.claimed', 'prepare',
                                                 root, root / 'installed.app', launch_arguments=arguments)
                log.close()
            configured = plistlib.loads((root / 'prepare.xctestrun').read_bytes())
            environment = configured['Tests']['EnvironmentVariables']
            self.assertEqual(json.loads(environment['UPGRADE_APP_ARGUMENTS']), arguments)

    def test_simulator_preparation_uses_screenshots_when_its_ui_group_is_interrupted(self):
        for destination, phase, capture in [
            ('platform=iOS Simulator,id=OWN-DEVICE', 'prepare', 'screenshots'),
            ('platform=iOS Simulator,id=OWN-DEVICE', 'verify', 'screenRecording'),
            ('platform=macOS', 'prepare', 'screenRecording'),
        ]:
            with self.subTest(destination=destination, phase=phase), tempfile.TemporaryDirectory() as root:
                root = Path(root)
                runner = root / 'runner.xctestrun'
                runner.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [
                    {'IsUITestBundle': True, 'PreferredScreenCaptureFormat': 'screenRecording'},
                    {'IsUITestBundle': False},
                ]}]}))
                with patch.object(run_journey, 'owned_process'):
                    _, log = run_journey.ui_run(runner, destination, 'backup.claimed', phase, root)
                    log.close()
                configured = plistlib.loads((root / (phase + '.xctestrun')).read_bytes())
                ui, unit = configured['TestConfigurations'][0]['TestTargets']
                self.assertEqual(ui['PreferredScreenCaptureFormat'], capture)
                self.assertNotIn('PreferredScreenCaptureFormat', unit)
                self.assertEqual(ui['EnvironmentVariables']['UPGRADE_POINT'], 'backup.claimed')
                self.assertEqual(ui['EnvironmentVariables']['UPGRADE_PHASE'], phase)

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_PROBES') == '1', 'Native signing and checkpoint probes are opt-in')
    def test_temporary_identity_signs_both_installations_and_is_removed(self):
        import shutil
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            with run_journey.SigningIdentity(root) as signer:
                directory = signer.directory
                requirements = []
                for name in ['old', 'new']:
                    installation = root / name
                    installation.mkdir()
                    executable = installation / 'fixture'
                    shutil.copyfile('/bin/echo', executable)
                    executable.chmod(0o755)
                    signer.sign(executable)
                    result = subprocess.run(['codesign', '-d', '-r-', str(executable)],
                                            capture_output=True, text=True, check=True)
                    requirement = result.stdout + result.stderr
                    self.assertIn('designated => ', requirement)
                    requirements.append(requirement.split('designated => ', 1)[1].splitlines()[0])
                self.assertEqual(*requirements)
            self.assertFalse(directory.exists())

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_PROBES') == '1', 'Native signing and checkpoint probes are opt-in')
    def test_native_checkpoint_stays_held_through_the_preparation_budget(self):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            # Only the unused identifier dependency is a stand-in. The compiled checkpoint is the actual source.
            main = root / 'main.swift'
            main.write_text('public struct PhotoUID { public init(volumeID: String, nodeID: String) {} }\n'
                            'UpgradeTestProbe.checkpoint("backup.claimed")\n')
            binary = root / 'checkpoint'
            subprocess.run(['xcrun', 'swiftc', '-O', '-D', 'ENCRYPTED_MEMORIES_UPGRADE_TEST',
                            str(repo / 'Packages/EncryptedMemoriesKit/Sources/PhotosCore/UpgradeTestProbe.swift'),
                            str(main), '-o', str(binary)], check=True)
            with FixtureServer(root, 'backup.claimed') as server, (root / 'app.log').open('w') as log:
                process = run_journey.owned_process([str(binary), '-EncryptedMemoriesUITestFixture',
                    '-EncryptedMemoriesUpgradeServer', server.url], log)
                try:
                    server.wait_checkpoint(timeout=10, preparing=process)
                    with self.assertRaises(subprocess.TimeoutExpired):
                        process.wait(timeout=185)
                    server.begin_upgrade()
                    self.assertEqual(process.wait(timeout=10), 0)
                finally:
                    server.begin_upgrade()
                    run_journey.stop_group(process)

    def test_simulator_kill_refuses_a_foreign_process(self):
        app = run_journey.InstalledApp.__new__(run_journey.InstalledApp)
        app.simulator = 'OWN-DEVICE'
        app.app_pid = 42
        with patch.object(run_journey, 'output', side_effect=[
            '/devices/OWN-DEVICE/data/Application/own.app',
            '/devices/FOREIGN-DEVICE/data/Application/foreign.app/App',
        ]), patch.object(run_journey.os, 'kill') as kill, patch.object(run_journey, 'command'):
            with self.assertRaisesRegex(JourneyError, 'owned Simulator'):
                app.kill_app()
            kill.assert_not_called()

    def simulator_app(self, directory, pid, log_lines):
        app = run_journey.InstalledApp.__new__(run_journey.InstalledApp)
        app.simulator, app.app_pid, app.executable, app.directory = 'OWN-DEVICE', pid, 'EncryptedMemories', Path(directory)
        if log_lines is not None:
            (app.directory / 'app.log').write_text('\n'.join(log_lines) + '\n')
        return app

    def test_an_ended_simulator_app_is_named_with_its_process_and_last_log_lines(self):
        ended = subprocess.Popen([sys.executable, '-c', 'pass'])
        ended.wait()
        lines = [f'line {number}' for number in range(6)] + ['Fatal error: synthetic thumbnail request failed']
        with tempfile.TemporaryDirectory() as directory:
            app = self.simulator_app(directory, ended.pid, lines)
            with self.assertRaises(JourneyError) as caught:
                app.require_running()
        message = str(caught.exception)
        self.assertIn(f'The app process {ended.pid} (EncryptedMemories) is no longer running', message)
        self.assertIn('Fatal error: synthetic thumbnail request failed', message)
        self.assertNotIn('line 1 ', message + ' ')  # Only the last five lines.

    def test_an_ended_simulator_app_without_a_log_still_fails_with_its_process(self):
        ended = subprocess.Popen([sys.executable, '-c', 'pass'])
        ended.wait()
        with tempfile.TemporaryDirectory() as directory:
            app = self.simulator_app(directory, ended.pid, None)
            with self.assertRaisesRegex(JourneyError, rf'process {ended.pid} \(EncryptedMemories\) is no longer running.*none'):
                app.require_running()

    def test_a_running_simulator_app_and_a_macos_app_pass_the_running_check(self):
        with tempfile.TemporaryDirectory() as directory:
            self.simulator_app(directory, os.getpid(), None).require_running()
            macos = run_journey.InstalledApp.__new__(run_journey.InstalledApp)
            macos.simulator = None
            macos.require_running()

    def test_the_ui_start_wait_fails_at_once_when_the_launched_app_ended(self):
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
            self.addCleanup(process.kill)

            def app_check():
                raise JourneyError('The app process 1 (EncryptedMemories) is no longer running')

            started = time.monotonic()
            with self.assertRaisesRegex(JourneyError, r'^label: The app process 1 \(EncryptedMemories\) is no longer running$'):
                run_journey.wait_ui_test_start(process, Path(directory) / 'ui.log', 'label', app_check=app_check)
            self.assertLess(time.monotonic() - started, 5)

    def test_the_listen_backlog_limit_enters_the_journey_summary(self):
        error, _, _, _ = self.run_case_on_a_virtual_clock(prepare_startup=1, verify_startup=1)
        self.assertIsNone(error)
        self.assertIn('Listen backlog limit kern.ipc.somaxconn: 128', self.summary_lines)

    def test_a_dead_app_ends_the_wait_for_the_ui_test_at_once(self):
        error, events, now, _ = self.run_case_on_a_virtual_clock(
            prepare_startup=None, verify_startup=1, app_ended='The app process 7 (EncryptedMemories) is no longer running')
        self.assertEqual(str(error), 'v1.0.5 / index.embed preparation: The app process 7 (EncryptedMemories) is no longer running')
        self.assertEqual(events, ['ui-prepare'])
        self.assertLess(now, 5)

    def test_a_dead_new_app_ends_the_wait_for_the_verification_ui_test_at_once(self):
        ended = 'The app process 8 (EncryptedMemories) is no longer running'
        error, events, now, _ = self.run_case_on_a_virtual_clock(
            prepare_startup=1, verify_startup=None, app_ended=ended, ended_from_verify=True)
        self.assertEqual(str(error), 'v1.0.5 / index.embed verification: ' + ended)
        self.assertEqual(events, ['ui-prepare', 'kill-old', 'ui-verify'])
        self.assertLess(now, 30)  # The preparation takes 21 s; the verification wait ends at its first check.

    def test_a_verification_timeout_keeps_its_message_and_names_the_app_that_ended_after_activation(self):
        ended = 'The app process 7 (EncryptedMemories) is no longer running'
        error, _, _, _ = self.run_case_on_a_virtual_clock(
            prepare_startup=1, verify_startup=1, app_ended=ended, ended_after_start=True, verify_act=241)
        self.assertEqual(str(error), 'v1.0.5 / index.embed: UI verification timed out; ' + ended)
        error, _, _, _ = self.run_case_on_a_virtual_clock(prepare_startup=1, verify_startup=1, verify_act=241)
        self.assertEqual(str(error), 'v1.0.5 / index.embed: UI verification timed out')

    def test_the_process_name_follows_the_installed_version_of_the_app(self):
        with tempfile.TemporaryDirectory() as directory:
            versions = []
            for name in ['OldExecutable', 'NewExecutable']:
                bundle = Path(directory) / (name + '.app')
                bundle.mkdir()
                (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': name}))
                versions.append(bundle)
            app = run_journey.InstalledApp.__new__(run_journey.InstalledApp)
            app.simulator, app.directory, app.app_log = 'OWN-DEVICE', Path(directory), None
            with patch.object(run_journey, 'command'), patch.object(run_journey.InstalledApp, 'stream_app_log'):
                app.install(versions[0])
                self.assertEqual(app.executable, 'OldExecutable')
                app.install(versions[1])
                self.assertEqual(app.executable, 'NewExecutable')

    def test_a_missing_checkpoint_keeps_its_message_and_names_the_app_that_ended_after_activation(self):
        ended = 'The app process 7 (EncryptedMemories) is no longer running'
        error, _, _, _ = self.run_case_on_a_virtual_clock(
            prepare_startup=10, verify_startup=1, act=181, app_ended=ended, ended_after_start=True)
        self.assertEqual(str(error), 'The historical app did not reach index.embed; ' + ended)
        error, _, _, _ = self.run_case_on_a_virtual_clock(prepare_startup=10, verify_startup=1, act=181)
        self.assertEqual(str(error), 'The historical app did not reach index.embed')

    def test_a_failed_verification_keeps_its_exit_code_and_names_the_app_that_ended_after_activation(self):
        ended = 'The app process 7 (EncryptedMemories) is no longer running'
        error, _, _, _ = self.run_case_on_a_virtual_clock(
            prepare_startup=1, verify_startup=1, app_ended=ended, ended_after_start=True, verify_code=1)
        self.assertEqual(str(error), 'v1.0.5 / index.embed: UI verification failed (1); ' + ended)
        error, _, _, _ = self.run_case_on_a_virtual_clock(prepare_startup=1, verify_startup=1, verify_code=1)
        self.assertEqual(str(error), 'v1.0.5 / index.embed: UI verification failed (1)')

    def test_owned_simulator_journey_preserves_a_foreign_booted_device(self):
        devices = {'FOREIGN-DEVICE': 'Booted'}
        operations = []
        def output(args):
            operation = args[2] if args[:2] == ['xcrun', 'simctl'] else 'ps'
            if operation == 'list':
                if args[3] == 'runtimes':
                    return json.dumps({'runtimes': [
                        {'isAvailable': True, 'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-1', 'version': '27.1',
                         'buildversion': 'NEWER'},
                        dict(run_journey.IOS_RUNTIME, isAvailable=True),
                    ]})
                return json.dumps({'devicetypes': [{'name': 'iPhone 17', 'identifier': 'phone'}]})
            if operation == 'create':
                self.assertRegex(args[3], r'^EncryptedMemoriesUpgrade-[a-f0-9]{32}$')
                self.assertEqual(args[-1], 'com.apple.CoreSimulator.SimRuntime.iOS-27-0')
                devices['OWN-DEVICE'] = 'Shutdown'
                return 'OWN-DEVICE'
            self.assertEqual(args[3], 'OWN-DEVICE') if operation != 'ps' else None
            if operation == 'launch':
                return run_journey.BUNDLE + ': 42'
            if operation == 'get_app_container':
                return '/devices/OWN-DEVICE/data/Application/own.app'
            if operation == 'ps':
                return '/devices/OWN-DEVICE/data/Application/own.app/App'
            raise AssertionError(args)
        def command(args):
            operations.append(args)
            self.assertEqual(args[:2], ['xcrun', 'simctl'])
            self.assertEqual(args[3], 'OWN-DEVICE')
            if args[2] == 'boot':
                devices['OWN-DEVICE'] = 'Booted'
            elif args[2] == 'shutdown':
                devices['OWN-DEVICE'] = 'Shutdown'
            elif args[2] == 'delete':
                del devices['OWN-DEVICE']
        class LogStream:
            def __init__(self, args, log):
                self.args = args
                operations.append(args)

        def stop(stream):
            operations.append(['stop-log-stream'])

        with tempfile.TemporaryDirectory() as directory, patch.object(run_journey, 'output', side_effect=output), \
                patch.object(run_journey, 'command', side_effect=command), patch.object(run_journey.os, 'kill') as kill, \
                patch.object(run_journey, 'owned_process', LogStream), patch.object(run_journey, 'stop_group', stop):
            bundles = {}
            for name in ['old', 'new']:
                bundles[name] = Path(directory) / (name + '.app')
                bundles[name].mkdir()
                (bundles[name] / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'App'}))
            app = run_journey.InstalledApp('iOS', Path(directory))
            runtime = json.loads((Path(directory) / 'simulator-runtime.json').read_text())
            self.assertEqual(runtime['identifier'], 'com.apple.CoreSimulator.SimRuntime.iOS-27-0')
            self.assertEqual(runtime['version'], '27.0')
            self.assertEqual(runtime['buildversion'], '24A434', 'The pin is the build measured on the hosted runner')
            self.assertEqual(app.destination, 'platform=iOS Simulator,id=OWN-DEVICE')
            app.install(bundles['old'])
            app.launch(type('Server', (), {'url': 'http://127.0.0.1:1234'})(), seed=True)
            app.kill_app()
            app.install(bundles['new'])
            app.close()
            kill.assert_called_once_with(42, signal.SIGKILL)
        self.assertEqual(devices, {'FOREIGN-DEVICE': 'Booted'})
        self.assertEqual([args[2] for args in operations if args[:2] == ['xcrun', 'simctl']],
                         ['boot', 'bootstatus', 'install', 'spawn', 'install', 'shutdown', 'delete'])
        # One app log stream runs inside the owned device for both phases and stops before the device shuts down.
        streams = [args for args in operations if args[2:3] == ['spawn']]
        self.assertEqual(streams, [['xcrun', 'simctl', 'spawn', 'OWN-DEVICE', 'log', 'stream', '--style', 'compact',
                                    '--predicate', 'process == "App"']])
        self.assertLess(operations.index(['stop-log-stream']), operations.index(next(a for a in operations if a[2:3] == ['shutdown'])))

    def test_ambiguous_selected_runtime_fails_before_creating_a_simulator(self):
        runtimes = {'runtimes': [
            {'isAvailable': True, 'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'version': '27.0', 'buildversion': build}
            for build in ['first', 'second']
        ]}
        replies = [json.dumps(runtimes), json.dumps({'devicetypes': [{'name': 'iPhone 17', 'identifier': 'phone'}]}), 'OWN-DEVICE']
        with tempfile.TemporaryDirectory() as root, patch.object(run_journey, 'output', side_effect=replies) as output, \
                patch.object(run_journey, 'command'):
            with self.assertRaisesRegex(JourneyError, 'Ambiguous Simulator runtime identifier: com.apple.CoreSimulator.SimRuntime.iOS-27-0'):
                run_journey.InstalledApp('iOS', Path(root))
            self.assertFalse(any(call.args[0][2] == 'create' for call in output.call_args_list))

    def test_pinned_runtime_failures_name_the_expected_and_installed_runtime_before_creating_a_simulator(self):
        pinned = dict(run_journey.IOS_RUNTIME, isAvailable=True)
        expected = re.escape(run_journey.IOS_RUNTIME['buildversion'])
        newer = {'isAvailable': True, 'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-1', 'version': '27.1',
                 'buildversion': 'NEWER'}
        cases = [
            ('missing', [newer],
             'not installed: expected .*build ' + expected + r'\), installed .*iOS-27-1 \(27\.1, build NEWER, available\)'),
            ('other version', [dict(pinned, version='27.0.1')], r'differs from the pin: .*installed 27\.0\.1, build'),
            ('other build', [dict(pinned, buildversion='OTHER')],
             'differs from the pin: expected .*build ' + expected + r'\), installed 27\.0, build OTHER'),
            ('unavailable', [dict(pinned, isAvailable=False)], 'installed but unavailable'),
            ('duplicate', [pinned, dict(pinned, buildversion='OTHER')], 'Ambiguous .* 2 times with builds'),
            ('duplicate with the same build', [pinned, dict(pinned)], 'Ambiguous .* 2 times with builds'),
        ]
        for name, runtimes, message in cases:
            with self.subTest(name), tempfile.TemporaryDirectory() as root, \
                    patch.object(run_journey, 'output', side_effect=[json.dumps({'runtimes': runtimes})]) as output, \
                    patch.object(run_journey, 'command') as command:
                with self.assertRaisesRegex(JourneyError, message):
                    run_journey.InstalledApp('iOS', Path(root))
                self.assertEqual(output.call_count, 1, 'No device query or creation may follow')
                command.assert_not_called()
        self.assertEqual(run_journey.select_ios_runtime([newer, pinned]), pinned,
                         'A newer extra runtime must not change the selection')

    def test_boot_failure_still_deletes_only_the_owned_simulator(self):
        replies = [json.dumps({'runtimes': [dict(run_journey.IOS_RUNTIME, isAvailable=True)]}),
            json.dumps({'devicetypes': [{'name': 'iPhone 17', 'identifier': 'phone'}]}), 'OWN-DEVICE']
        with tempfile.TemporaryDirectory() as directory, patch.object(run_journey, 'output', side_effect=replies), \
                patch.object(run_journey, 'command', side_effect=[JourneyError('boot failed'), None, None]) as command:
            with self.assertRaisesRegex(JourneyError, 'boot failed'):
                run_journey.InstalledApp('iOS', Path(directory))
            self.assertEqual(command.call_args_list[-1].args[0], ['xcrun', 'simctl', 'delete', 'OWN-DEVICE'])

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_TARGET'), 'Native install-over rehearsal is opt-in')
    def test_native_journey_keeps_another_booted_simulator(self):
        sentinel = run_journey.output(['xcrun', 'simctl', 'create',
            'EncryptedMemoriesUpgradeIsolation-' + uuid.uuid4().hex,
            'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
            run_journey.IOS_RUNTIME['identifier']])
        try:
            run_journey.command(['xcrun', 'simctl', 'boot', sentinel])
            run_journey.command(['xcrun', 'simctl', 'bootstatus', sentinel, '-b'])
            home = Path(run_journey.output(['xcrun', 'simctl', 'getenv', sentinel, 'HOME']))
            self.assertIn(sentinel, home.parts)
            marker = home / 'tmp' / ('upgrade-isolation-' + uuid.uuid4().hex)
            marker.write_bytes(b'separate booted device remains unchanged')
            repo = Path(__file__).resolve().parents[2]
            args = ['bash', str(repo / 'scripts/test-release-upgrade.sh'), '--target',
                    os.environ['UPGRADE_NATIVE_TARGET'], '--release-tag',
                    os.environ.get('UPGRADE_RELEASE_TAG') or os.environ['UPGRADE_NATIVE_TARGET'],
                    '--sources', 'v1.0.5', '--platform', 'iOS']
            if os.environ.get('UPGRADE_NATIVE_WORKING_COPY') == '1':
                args.append('--working-copy')
            run_journey.command(args, cwd=repo)
            devices = json.loads(run_journey.output(['xcrun', 'simctl', 'list', 'devices', '--json']))['devices']
            observed = next(device for group in devices.values() for device in group if device['udid'] == sentinel)
            self.assertEqual(observed['state'], 'Booted')
            self.assertEqual(marker.read_bytes(), b'separate booted device remains unchanged')
            print('PASS: separate booted Simulator and its data survived the complete iOS journey', flush=True)
        finally:
            try:
                run_journey.command(['xcrun', 'simctl', 'shutdown', sentinel])
            finally:
                run_journey.command(['xcrun', 'simctl', 'delete', sentinel])

    def test_native_query_control_restores_handlers_after_owned_group_cancellation(self):
        with tempfile.TemporaryDirectory() as root:
            marker = Path(root) / 'owned-resource'
            marker.touch()
            script = """
import os, signal, sys
from pathlib import Path
from unittest.mock import patch
os.environ['UPGRADE_NATIVE_QUERY_TARGET'] = 'HEAD'
sys.path.insert(0, sys.argv[1])
from test_upgrade_journey import UpgradeJourneyTests
import run_journey
original = {value: signal.getsignal(value) for value in [signal.SIGINT, signal.SIGTERM]}
marker = Path(sys.argv[2])
def cancelled_main():
    try:
        os.killpg(os.getpid(), signal.SIGTERM)
    finally:
        marker.unlink()
try:
    with patch.object(run_journey, 'main', cancelled_main):
        UpgradeJourneyTests().test_native_pending_query_cannot_pass_with_the_retained_library()
except KeyboardInterrupt:
    assert not marker.exists()
    assert all(signal.getsignal(value) == handler for value, handler in original.items())
else:
    raise AssertionError('Cancellation did not propagate')
"""
            result = subprocess.run([sys.executable, '-c', script, str(Path(__file__).resolve().parent), str(marker)],
                                    start_new_session=True, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists(), 'Owned cancellation interrupted cleanup')

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_QUERY_TARGET'), 'Native pending-query control is opt-in')
    def test_native_pending_query_cannot_pass_with_the_retained_library(self):
        servers = []

        class PendingQueryServer(FixtureServer):
            def __init__(self, *args):
                super().__init__(*args)
                servers.append(self)

            def begin_upgrade(self):
                super().begin_upgrade()
                with self.lock:
                    self.point = 'query.encoded'
                    self.hold_phase = 'new'
                    self.release.clear()

        repo = Path(__file__).resolve().parents[2]
        root = Path(os.environ.get('ENCRYPTED_MEMORIES_BUILD_ROOT',
                    str(Path.home() / 'Developer/xcode/EncryptedMemories'))) / 'UpgradeCheck'
        argv = ['run_journey.py', '--repo', str(repo), '--automation', str(repo), '--root', str(root),
                '--target', os.environ['UPGRADE_NATIVE_QUERY_TARGET'], '--sources', 'v1.0.5',
                '--platform', os.environ.get('UPGRADE_NATIVE_QUERY_PLATFORM', 'macOS'),
                '--points', 'model.partial']
        if os.environ.get('UPGRADE_NATIVE_WORKING_COPY') == '1':
            argv.append('--working-copy')
        owned_process = run_journey.owned_process

        def installed_journey_only(args, *remaining, **kwargs):
            # Keep the negative control independent of the standalone oracle's unit tests.
            return owned_process(args + [
                '-only-testing:UpgradeJourneyUITests/UpgradeJourneyUITests/testInstalledAppJourney'],
                *remaining, **kwargs)

        handlers = {value: signal.getsignal(value) for value in [signal.SIGINT, signal.SIGTERM]}
        try:
            for value in handlers:
                signal.signal(value, run_journey.terminate)
            with patch.object(run_journey, 'FixtureServer', PendingQueryServer), \
                    patch.object(run_journey, 'owned_process', installed_journey_only), patch.object(sys, 'argv', argv):
                with self.assertRaisesRegex(JourneyError, 'UI verification failed'):
                    run_journey.main()
        finally:
            for value, handler in handlers.items():
                signal.signal(value, handler)
        self.assertEqual(len(servers), 1)
        self.assertTrue(any(request['phase'] == 'new' and request['path'] == '/checkpoint/query.encoded'
                            for request in servers[0].requests), 'The negative control never held a real query')
        ui_log = (servers[0].directory / 'verify-ui.log').read_text()
        self.assertIn('The saved index did not return all eight photos', ui_log)
        print('PASS: a held native query cannot use the eight retained library elements', flush=True)

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_SEED_TARGET'), 'Native seed regression is opt-in')
    def test_native_seed_identity_survives_restarts_and_reseeds_changed_cases_or_servers(self):
        handlers = {value: signal.getsignal(value) for value in [signal.SIGINT, signal.SIGTERM]}
        try:
            for value in handlers:
                signal.signal(value, run_journey.terminate)
            from build_apps import build_app
            repo = Path(__file__).resolve().parents[2]
            root = Path(os.environ.get('ENCRYPTED_MEMORIES_BUILD_ROOT',
                        str(Path.home() / 'Developer/xcode/EncryptedMemories'))) / 'UpgradeCheck'
            (root / 'scratch').mkdir(parents=True, exist_ok=True)
            evidence = root / 'evidence' / uuid.uuid4().hex
            evidence.mkdir(parents=True)
            platform = os.environ.get('UPGRADE_NATIVE_SEED_PLATFORM', 'macOS')
            (evidence / 'toolchain.json').write_text(json.dumps({
                'xcode': run_journey.output(['xcodebuild', '-version']), 'platform': platform}) + '\n')
            target = os.environ['UPGRADE_NATIVE_SEED_TARGET']
            for tag in [target, 'v1.0.5']:
                with self.subTest(tag=tag):
                    metadata = run_journey.release_metadata(repo, repo, os.environ.get('UPGRADE_RELEASE_TAG') or target) if tag == target else None
                    build = build_app(repo, repo, tag, platform, root, metadata=metadata,
                        working_copy=tag == target and os.environ.get('UPGRADE_NATIVE_WORKING_COPY') == '1')
                    case = evidence / platform / tag
                    case.mkdir(parents=True)
                    identity = run_journey.SigningIdentity(root) if platform == 'macOS' else nullcontext()
                    with identity as signer, FixtureServer(case / 'server', 'session.loaded') as server:
                        app = run_journey.InstalledApp(platform, case, signer)
                        try:
                            app.install(build.app)
                            def session_file():
                                return app.preferences_path.parents[2] / 'Library/Application Support/EncryptedMemories' / (
                                    'upgrade-fixture-account-' + app.case_id) / 'upgrade-fixture-session.json'

                            def launch(endpoint, seed=True):
                                endpoint.reached.clear()
                                endpoint.release.clear()
                                app.launch(endpoint, seed=seed)
                                expected = {'server': endpoint.url, 'account': 'upgrade-fixture-account-' + app.case_id}
                                process, log = None, None
                                if platform == 'macOS':
                                    info = plistlib.loads((app.installed / 'Contents/Info.plist').read_bytes())
                                    binary = app.installed / 'Contents/MacOS' / info['CFBundleExecutable']
                                    log = (case / (uuid.uuid4().hex + '.log')).open('w')
                                    process = run_journey.owned_process([str(binary), *app.launch_arguments], log)
                                try:
                                    endpoint.wait_checkpoint(timeout=20)
                                    # Read the app's own flush before interruption. Never repair its marker here.
                                    deadline = time.monotonic() + 20
                                    while True:
                                        try:
                                            marker = plistlib.loads(app.preferences_path.read_bytes()).get('upgrade.fixture.seeded')
                                        except FileNotFoundError:
                                            marker = None
                                        if marker == expected:
                                            break
                                        if time.monotonic() >= deadline:
                                            self.fail('The case/server seed marker did not reach the owned preferences file')
                                        time.sleep(0.2)
                                    (case / (uuid.uuid4().hex + '-marker.json')).write_text(json.dumps(marker) + '\n')
                                finally:
                                    if process is not None:
                                        if process.poll() is None:
                                            process.terminate()
                                        try:
                                            process.wait(timeout=10)
                                        except subprocess.TimeoutExpired:
                                            if process.poll() is None:
                                                process.kill()
                                            process.wait(timeout=10)
                                    else:
                                        app.kill_app()
                                    if log:
                                        log.close()
                                    endpoint.release.set()

                            if platform == 'iOS':
                                # A fresh owned device has never loaded this preference domain.
                                preferences = app.preferences_path
                                preferences.parent.mkdir(parents=True, exist_ok=True)
                                preferences.write_bytes(plistlib.dumps({'upgrade.fixture.seeded': server.url}))
                                self.assertEqual(plistlib.loads(preferences.read_bytes())['upgrade.fixture.seeded'], server.url)
                            launch(server)
                            first = app.case_id
                            app.case_id = uuid.uuid4().hex
                            self.assertNotEqual(first, app.case_id)
                            launch(server)  # Same port, different case: the original regression.
                            if platform == 'macOS':
                                path = session_file()
                                retained = json.loads(path.read_text())
                                retained['accessToken'] = 'synthetic-retained-access'
                                path.write_text(json.dumps(retained))
                            launch(server)
                            launch(server, seed=False)
                            if platform == 'macOS':
                                self.assertEqual(json.loads(path.read_text()), retained, 'An unchanged identity reseeded the session')

                            with FixtureServer(case / 'changed-server', 'session.loaded') as other:
                                self.assertNotEqual(server.url, other.url)
                                launch(other)  # Same case, different server.
                                if platform == 'macOS':
                                    self.assertEqual(json.loads(path.read_text())['accessToken'], 'synthetic-access',
                                                     'A changed server did not reseed the session')
                        finally:
                            if platform == 'iOS':
                                app.close()
                    print('PASS: native case/server reseeding and unchanged restart: ' + platform + ' / ' + tag, flush=True)
        finally:
            for value, handler in handlers.items():
                signal.signal(value, handler)

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_PROBES') == '1', 'Native identifier validation is opt-in')
    def test_native_case_identifier_accepts_only_exactly_32_ascii_hex_characters(self):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            main = root / 'main.swift'
            # PhotoUID is unused by this probe; identity validation uses the real compiled source.
            main.write_text('public struct PhotoUID { public init(volumeID: String, nodeID: String) {} }\n'
                            'print(UpgradeTestProbe.accountUID)\n')
            binary = root / 'identity'
            subprocess.run(['xcrun', 'swiftc', '-O', '-D', 'ENCRYPTED_MEMORIES_UPGRADE_TEST',
                str(repo / 'Packages/EncryptedMemoriesKit/Sources/PhotosCore/UpgradeTestProbe.swift'),
                str(main), '-o', str(binary)], check=True, env=run_journey.clean_environment())
            for identifier in ['0123456789abcdef' * 2, '0123456789ABCDEF' * 2]:
                result = subprocess.run([str(binary), '-EncryptedMemoriesUpgradeCase', identifier],
                    capture_output=True, text=True, env=run_journey.clean_environment())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), 'upgrade-fixture-account-' + identifier)
            for arguments in [[], ['-EncryptedMemoriesUpgradeCase']] + [
                ['-EncryptedMemoriesUpgradeCase', value]
                for value in ['', 'a' * 31, 'a' * 33, 'g' * 32, '../' + 'a' * 29, 'Ａ' * 32, 'a' * 31 + '\n']
            ]:
                result = subprocess.run([str(binary), *arguments], capture_output=True, text=True,
                    env=run_journey.clean_environment())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('exactly 32 ASCII hexadecimal characters', result.stderr)

    def test_historical_overlays_apply_to_the_exact_published_tag(self):
        repo = Path(__file__).resolve().parents[2]
        overlay = repo / 'scripts/upgrade-test/overlays'
        for tag, metadata in json.loads((overlay / 'versions.json').read_text()).items():
            with self.subTest(tag=tag), tempfile.TemporaryDirectory() as root:
                sha = subprocess.check_output(['git', 'rev-parse', tag + '^{commit}'], cwd=repo, text=True).strip()
                self.assertEqual(sha, metadata['commit'])
                archive = subprocess.check_output(['git', 'archive', sha, 'Packages/EncryptedMemoriesKit/Sources'], cwd=repo)
                with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
                    tree.extractall(root, filter='data')
                subprocess.run(['git', 'apply', '--check', '--unidiff-zero', str(overlay / (tag + '.patch'))], cwd=root, check=True)

    def test_release_with_its_own_test_entry_applies_only_its_reviewed_patch(self):
        repo = Path(__file__).resolve().parents[2]
        sha = subprocess.check_output(['git', 'rev-parse', 'v1.1.0-beta.3^{commit}'], cwd=repo, text=True).strip()
        sources = 'Packages/EncryptedMemoriesKit/Sources'
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            archive = subprocess.check_output(['git', 'archive', sha, sources], cwd=repo)
            with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
                tree.extractall(root, filter='data')
            before = {path.relative_to(root): path.read_bytes() for path in root.rglob('*') if path.is_file()}
            apply_overlay(root, repo, 'v1.1.0-beta.3', sha)
            after = {path.relative_to(root): path.read_bytes() for path in root.rglob('*') if path.is_file()}
            metal = Path(sources) / 'MetalRenderingCore/Metal3RuntimeCapability.swift'
            self.assertEqual(sorted(path for path in after if after[path] != before.get(path)), [metal],
                             'The release keeps its own test entry; only the reviewed patch changes')
            self.assertIn('#if ENCRYPTED_MEMORIES_UPGRADE_TEST && os(macOS)', after[metal].decode())
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / sources / 'PhotosCore').mkdir(parents=True)
            (root / sources / 'PhotosCore/UpgradeTestProbe.swift').touch()
            with self.assertRaisesRegex(JourneyError, 'no reviewed overlay'):
                apply_overlay(root, repo, 'v1.1.0-beta.3', 'a' * 40)
            apply_overlay(root, repo, 'v1.1.0', 'b' * 40)

    def test_release_without_its_own_test_entry_receives_the_patch_and_the_test_entry(self):
        repo = Path(__file__).resolve().parents[2]
        sha = subprocess.check_output(['git', 'rev-parse', 'v1.0.5^{commit}'], cwd=repo, text=True).strip()
        sources = Path('Packages/EncryptedMemoriesKit/Sources')
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            archive = subprocess.check_output(['git', 'archive', sha, str(sources)], cwd=repo)
            with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
                tree.extractall(root, filter='data')
            self.assertFalse((root / sources / 'PhotosCore/UpgradeTestProbe.swift').exists())
            apply_overlay(root, repo, 'v1.0.5', sha)
            for relative in PAYLOAD:
                with self.subTest(file=relative):
                    self.assertEqual((root / sources / relative).read_bytes(), (repo / sources / relative).read_bytes())
            metal = (root / sources / 'MetalRenderingCore/Metal3RuntimeCapability.swift').read_text()
            self.assertIn('#if ENCRYPTED_MEMORIES_UPGRADE_TEST && os(macOS)', metal)

    def test_a_rebuilt_product_replaces_its_restored_copy(self):
        # Release run 38171860265 saved the macOS candidate product. A later gate restored it without its source,
        # rebuilt the candidate, and copying over the restored framework symlinks failed with "File exists".
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def bundle(name, binary):
                framework = root / name / 'Encrypted Memories.app/Contents/Frameworks/Sentry.framework'
                (framework / 'Versions/A/Resources').mkdir(parents=True)
                (framework / 'Versions/A/Sentry').write_text(binary)
                os.symlink('A', framework / 'Versions/Current')
                os.symlink('Versions/Current/Resources', framework / 'Resources')
                os.symlink('Versions/Current/Sentry', framework / 'Sentry')
                return root / name / 'Encrypted Memories.app'
            product = root / 'products/macOS/identity'
            restored = publish_product(bundle('first', 'restored'), product, {'source': '/gone'})
            (restored / 'Contents/stale.txt').write_text('left by the restored copy')
            app = publish_product(bundle('second', 'rebuilt'), product, {'source': '/current'})
            framework = app / 'Contents/Frameworks/Sentry.framework'
            self.assertEqual((framework / 'Sentry').read_text(), 'rebuilt')
            self.assertEqual(os.readlink(framework / 'Versions/Current'), 'A')
            self.assertFalse((app / 'Contents/stale.txt').exists())
            self.assertEqual(json.loads((product / 'complete.json').read_text()), {'source': '/current'})

    def test_only_the_candidate_keeps_its_build_scratch(self):
        # Rehearsal 38181793360: an iOS shard ran out of disk. A historical journey needs only its published app.
        def build(root, historical):
            def command(args, cwd=None, env=None):
                if args[:3] == ['xcrun', 'xcodebuild', 'build']:
                    derived = Path(args[args.index('-derivedDataPath') + 1])
                    (derived / 'Build/Products/Release-iphonesimulator/App.app').mkdir(parents=True)
            with patch.object(build_apps, 'output', side_effect=lambda args, *rest: 'a' * 40 if args[1] == 'rev-parse' else 'value'), \
                    patch.object(build_apps, 'command', side_effect=command), patch.object(build_apps, 'source_tree'), \
                    patch.object(build_apps, 'apply_overlay'), patch.object(build_apps, 'test_project'), \
                    patch.object(build_apps, 'verify_bundle_metadata'):
                return build_apps.build_app(Path(root), Path(__file__).resolve().parents[2], 'v1.0.5', 'iOS', Path(root),
                                            historical=historical, metadata={'commit': 'a' * 40, 'tag': 'v1.0.5', 'version': '1.0.5', 'build_number': '1'})
        for historical in [True, False]:
            with self.subTest(historical=historical), tempfile.TemporaryDirectory() as root:
                (Path(root) / 'scratch').mkdir()
                result = build(root, historical)
                self.assertTrue((result.app).is_dir())
                scratch = list((Path(root) / 'scratch').iterdir())
                if historical:
                    self.assertEqual(scratch, [])
                    self.assertIsNone(result.source)
                else:
                    self.assertEqual([path.name for path in scratch], [result.source.parent.name])

    def test_unknown_predecessor_without_entry_fails(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(JourneyError, 'no reviewed overlay'):
                apply_overlay(Path(root), Path(__file__).resolve().parents[2], 'v1.2.0', 'a' * 40)

    def test_fixture_server_keeps_a_burst_of_connections_while_its_accept_loop_is_busy(self):
        with tempfile.TemporaryDirectory() as root:
            server = FixtureServer(Path(root), 'backup.claimed')
            results = []
            # A loaded runner accepts late: the app's parallel thumbnail requests wait in the listen backlog. Beyond
            # it, macOS resets connections and Linux drops them, so every connection opens before the server accepts.
            connections = []
            for _ in range(40):
                try:
                    connection = socket.create_connection(('127.0.0.1', server.http.server_port), timeout=2)
                    connection.settimeout(30)
                    connections.append(connection)
                except OSError as error:
                    results.append(type(error).__name__)
            with server:
                for connection in connections:
                    request = HTTPConnection('127.0.0.1', server.http.server_port)
                    request.sock = connection
                    try:
                        request.request('GET', '/thumbnail/asset-1')
                        results.append(request.getresponse().status)
                    except OSError as error:
                        results.append(type(error).__name__)
                    finally:
                        request.close()
            self.assertEqual(results, [200] * 40)

    def test_runner_sampler_line_reports_swap_every_minute_and_the_trees_every_fifth(self):
        timeouts = {}

        def size(tree, timeout=300):
            timeouts[tree.name] = timeout
            return 1.5
        with patch.object(run_journey, 'free_gib', return_value=20.0), \
                patch.object(run_journey, 'swap_used_mib', return_value=12.0), \
                patch.object(run_journey, 'tree_gib', side_effect=size):
            trees = run_journey.runner_trees(Path('/evidence/runner-load.log'), Path('/root'))
            first = run_journey.runner_sample_line(0, trees)
            second = run_journey.runner_sample_line(1, trees)
            fifth = run_journey.runner_sample_line(5, trees)
        self.assertIn('free 20.0 GiB swap used 12 MiB', first)
        for name in ('evidence', 'scratch', 'products', 'simulators', 'derived-data',
                     'tmp', 'caches', 'logs', 'diagnostics'):
            self.assertIn(f' {name} 1.5', first)
        self.assertNotIn('|', second)
        self.assertIn('swap used 12 MiB', second)
        self.assertIn(' tmp 1.5', fifth)
        self.assertEqual(trees['tmp'], Path(tempfile.gettempdir()))
        # The four trees that #498 added have the smaller bound; the six old ones keep theirs.
        self.assertEqual(timeouts[Path(tempfile.gettempdir()).name], 60)
        self.assertEqual({timeouts[name] for name in ('Caches', 'Logs', 'diagnostics')}, {60})
        self.assertEqual({timeouts[name] for name in ('evidence', 'scratch', 'products', 'Devices', 'CoreSimulator',
                                                      'DerivedData')} - {300}, set())

    def test_a_failing_temporary_directory_lookup_does_not_stop_the_sampler_line(self):
        with patch.object(run_journey.tempfile, 'gettempdir', side_effect=FileNotFoundError('no temporary directory')), \
                patch.object(run_journey, 'free_gib', return_value=20.0), \
                patch.object(run_journey, 'swap_used_mib', return_value=12.0), \
                patch.object(run_journey, 'tree_gib', return_value=1.5):
            trees = run_journey.runner_trees(Path('/evidence/runner-load.log'), Path('/root'))
            line = run_journey.runner_sample_line(0, trees)
        self.assertIsNone(trees['tmp'])
        self.assertIn(' tmp nan', line)
        self.assertIn(' caches 1.5', line)

    def test_swap_usage_reads_megabytes_and_gigabytes_and_fails_open(self):
        def result(text, code=0):
            return subprocess.CompletedProcess(['sysctl'], code, stdout=text)
        with patch.object(run_journey.subprocess, 'run',
                          return_value=result('vm.swapusage: total = 2048.00M  used = 1.25M  free = 2046.75M  (encrypted)')):
            self.assertEqual(run_journey.swap_used_mib(), 1.25)
        with patch.object(run_journey.subprocess, 'run',
                          return_value=result('vm.swapusage: total = 8.00G  used = 2.00G  free = 6.00G  (encrypted)')):
            self.assertEqual(run_journey.swap_used_mib(), 2048.0)
        with patch.object(run_journey.subprocess, 'run', return_value=result('')):
            self.assertTrue(run_journey.swap_used_mib() != run_journey.swap_used_mib())  # NaN
        with patch.object(run_journey.subprocess, 'run',
                          return_value=result('vm.swapusage: total = 2048.00M  used = 1.25M  free = 2046.75M', 1)):
            self.assertTrue(run_journey.swap_used_mib() != run_journey.swap_used_mib())  # NaN: nonzero exit
        with patch.object(run_journey.subprocess, 'run', side_effect=FileNotFoundError()):
            self.assertTrue(run_journey.swap_used_mib() != run_journey.swap_used_mib())

    def test_swap_usage_is_read_in_the_c_locale(self):
        with patch.object(run_journey.subprocess, 'run', return_value=subprocess.CompletedProcess(
                ['sysctl'], 0, stdout='vm.swapusage: total = 1.00M  used = 1.00M  free = 0.00M')) as run:
            run_journey.swap_used_mib()
        self.assertEqual(run.call_args.kwargs['env']['LC_ALL'], 'C')

    def stub_du(self, root, code, stdout):
        directory = Path(root) / 'bin'
        directory.mkdir()
        script = directory / 'du'
        script.write_text(f'#!/bin/sh\nprintf "{stdout}"\nexit {code}\n')
        script.chmod(0o755)
        return patch.dict(os.environ, {'PATH': f'{directory}{os.pathsep}{os.environ["PATH"]}'})

    def test_a_tree_total_is_clean_only_when_du_exits_zero(self):
        with tempfile.TemporaryDirectory() as root:
            tree = Path(root) / 'tree'
            tree.mkdir()
            with self.stub_du(root, 0, '2097152\\t/tree\\n'):
                clean = run_journey.tree_gib(tree)
            self.assertEqual(clean, 2.0)
            self.assertNotIsInstance(clean, run_journey.PartialSize)
            self.assertEqual(run_journey.tree_label(clean), '2.0')

    def test_a_tree_with_an_unreadable_part_is_a_partial_total_and_a_failed_du_is_unknown(self):
        with tempfile.TemporaryDirectory() as root:
            tree = Path(root) / 'tree'
            tree.mkdir()
            partial_root = Path(root) / 'partial'
            partial_root.mkdir()
            with self.stub_du(partial_root, 1, '1048576\\t/tree\\n'):
                partial = run_journey.tree_gib(tree)
            self.assertIsInstance(partial, run_journey.PartialSize)
            self.assertEqual(float(partial), 1.0)
            self.assertEqual(run_journey.tree_label(partial), '1.0 partial')
            failed_root = Path(root) / 'failed'
            failed_root.mkdir()
            with self.stub_du(failed_root, 1, ''):
                unknown = run_journey.tree_gib(tree)
            self.assertTrue(unknown != unknown)  # NaN
            self.assertEqual(run_journey.tree_label(unknown), 'nan')

    def test_tree_size_passes_its_time_limit_to_du(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.object(run_journey.subprocess, 'run', return_value=subprocess.CompletedProcess(
                    ['du'], 0, stdout='1024\t/x\n')) as run:
                run_journey.tree_gib(Path(root), 60)
                run_journey.tree_gib(Path(root))
        self.assertEqual([call.kwargs['timeout'] for call in run.call_args_list], [60, 300])

    def test_a_tree_that_cannot_be_examined_reads_as_unknown(self):
        class Unexaminable:
            def exists(self):
                raise PermissionError(13, 'Permission denied')
        self.assertTrue(run_journey.tree_gib(Unexaminable()) != run_journey.tree_gib(Unexaminable()))  # NaN
        with tempfile.TemporaryDirectory() as root, patch.object(run_journey.subprocess, 'run', side_effect=FileNotFoundError()):
            size = run_journey.tree_gib(Path(root))
        self.assertTrue(size != size)  # NaN: no du

    @unittest.skipIf(os.geteuid() == 0, 'root can read every directory')
    def test_an_unreadable_tree_never_reads_as_a_clean_number(self):
        # BSD du prints nothing for an unreadable root; GNU du prints a total and exits 1. Both are not a clean number.
        with tempfile.TemporaryDirectory() as root:
            tree = Path(root) / 'diagnostics'
            tree.mkdir()
            (tree / 'file').write_bytes(b'x' * 4096)
            tree.chmod(0)
            try:
                size = run_journey.tree_gib(tree)
            finally:
                tree.chmod(0o700)
            self.assertTrue(size != size or isinstance(size, run_journey.PartialSize), size)

    def test_fixture_server_binds_without_a_name_lookup(self):
        # The loopback server needs no host name. A reverse lookup of its address can reach mDNS on macOS and show the
        # local network prompt over the journey.
        def refuse(*arguments, **keywords):
            raise AssertionError('the fixture server looked up a host name')

        with tempfile.TemporaryDirectory() as root:
            with patch('socket.getfqdn', side_effect=refuse), patch('socket.gethostbyaddr', side_effect=refuse):
                server = FixtureServer(Path(root), 'backup.claimed')
            with server:
                self.assertEqual(server.http.server_name, '127.0.0.1')
                with urlopen(server.url + '/links', timeout=10) as response:
                    self.assertEqual(json.load(response), [])

    def test_the_journey_lists_its_points_without_any_other_argument(self):
        result = subprocess.run([sys.executable, str(Path(run_journey.__file__)), '--list-points'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), run_journey.POINTS)

    def test_upload_ledger_survives_app_replacement_and_exposes_duplicates(self):
        with tempfile.TemporaryDirectory() as root, FixtureServer(Path(root), 'backup.claimed') as server:
            def upload():
                request = Request(server.url + '/upload', data=json.dumps({'name': 'Synthetic-0.png', 'hash': 'abc'}).encode(), headers={'Content-Type': 'application/json'})
                return json.load(urlopen(request))
            self.assertEqual(upload()['id'], 'link-0')
            self.assertEqual(json.load(urlopen(server.url + '/links'))[0]['hash'], 'abc')
            upload()
            with self.assertRaisesRegex(JourneyError, 'duplicate'):
                server.verify_uploads(expected=1)

    def test_model_supports_exact_resume_and_thumbnail_is_valid_png(self):
        with tempfile.TemporaryDirectory() as root, FixtureServer(Path(root), 'model.partial') as server:
            response = urlopen(Request(server.url + '/model', headers={'Range': 'bytes=4096-8191'}))
            self.assertEqual(response.status, 206)
            self.assertEqual(response.headers['Content-Range'], 'bytes 4096-8191/16384')
            self.assertEqual(response.read(), bytes([0xA7]) * 4096)
            self.assertTrue(urlopen(server.url + '/thumbnail/asset-0').read().startswith(b'\x89PNG\r\n\x1a\n'))

    def test_model_resume_requires_the_saved_partial_offset(self):
        with tempfile.TemporaryDirectory() as root, FixtureServer(Path(root), 'model.partial') as server:
            urlopen(Request(server.url + '/model', headers={'Range': 'bytes=0-8191'})).read()
            server.begin_upgrade()
            urlopen(Request(server.url + '/model', headers={'Range': 'bytes=8192-16383'})).read()
            server.verify_model_resume()

    def test_model_redownload_and_missing_resume_fail(self):
        for first_range in [None, 'bytes=0-8191']:
            with self.subTest(first_range=first_range), tempfile.TemporaryDirectory() as root:
                with FixtureServer(Path(root), 'model.partial') as server:
                    server.begin_upgrade()
                    if first_range:
                        urlopen(Request(server.url + '/model', headers={'Range': first_range})).read()
                    with self.assertRaisesRegex(JourneyError, 'saved partial'):
                        server.verify_model_resume()

    def test_failed_case_stops_before_the_next_case(self):
        calls = []
        def execute(source, point):
            calls.append((source, point))
            if point == 'model.partial':
                raise JourneyError('Model did not resume')
        with self.assertRaisesRegex(JourneyError, 'Model did not resume'):
            run_cases(['v1.0.5', 'v1.1.0'], ['backup.claimed', 'model.partial', 'index.embed'], execute)
        self.assertEqual(calls, [('v1.0.5', 'backup.claimed'), ('v1.0.5', 'model.partial')])

    def test_empty_source_or_case_set_never_reports_success(self):
        for sources, points in [([], ['backup.claimed']), (['v1.0.5'], [])]:
            with self.assertRaises(JourneyError):
                run_cases(sources, points, lambda *_: None)

    def test_failed_preparation_reports_its_exit_without_waiting_for_a_checkpoint(self):
        with tempfile.TemporaryDirectory() as root, FixtureServer(Path(root), 'backup.claimed') as server:
            process = subprocess.Popen([sys.executable, '-c', 'raise SystemExit(7)'])
            with self.assertRaisesRegex(JourneyError, r'UI preparation failed \(7\)'):
                server.wait_checkpoint(timeout=1, preparing=process)
            self.assertEqual(process.wait(), 7)

    def test_missing_checkpoint_fails_with_the_selected_boundary(self):
        with tempfile.TemporaryDirectory() as root, FixtureServer(Path(root), 'index.beforeCommit') as server:
            with self.assertRaisesRegex(JourneyError, 'index.beforeCommit'):
                server.wait_checkpoint(timeout=0.01)

    def run_case_on_a_virtual_clock(
            self, prepare_startup, verify_startup, act=20, reach_at=None, app_ended=None, ended_after_start=False, verify_code=0,
            ended_from_verify=False, verify_act=None):
        """Run index.embed through run_journey.main() with UI runs whose first test case starts after the given seconds.

        Each UI run acts `act` seconds after its first test case started; None never starts a test case. With
        `reach_at`, the old app reaches its checkpoint on its own that many seconds after the preparation launch.
        With `app_ended`, the launched app is gone: its running check fails with that message at once, or only
        names it next to a later failure when `ended_after_start`; with `ended_from_verify` it is alive until the new app launches. `verify_code` is the exit code of the verification run and `verify_act` the seconds that it acts (default `act`)."""
        clock = {'now': 0.0}
        runs, events, servers = [], [], []
        self.summary_lines = []

        def advance(seconds):
            clock['now'] += seconds
            if clock['now'] > 3600:
                raise AssertionError('The journey kept waiting beyond every budget')
            for run in runs:
                if run.reach_at is not None and clock['now'] >= run.reach_at:
                    servers[-1].reached.set()
                if run.start_at is not None and clock['now'] >= run.start_at and not run.announced:
                    run.announced = True
                    with open(run.log, 'a') as log:
                        log.write("Test Case '-[UpgradeJourneyUITests.UpgradeJourneyUITests testInstalledAppJourney]' started.\n")

        class Clock:
            strftime = staticmethod(time.strftime)
            monotonic = staticmethod(lambda: clock['now'])
            sleep = staticmethod(advance)

        class Run:
            def __init__(self, log, startup, reach=None, code=0, acts=None):
                self.log, self.announced, self.stopped, self.code = log, False, False, code
                self.acts = act if acts is None else acts
                self.start_at = None if startup is None else clock['now'] + startup
                self.reach_at = None if reach is None else clock['now'] + reach
                log.write_text('Running tests...\n')

            def remaining(self):
                return float('inf') if self.start_at is None else max(0, self.start_at + self.acts - clock['now'])

            def poll(self):
                return 0 if self.stopped else None

            def wait(self, timeout):
                if self.remaining() > timeout:
                    advance(timeout)
                    raise subprocess.TimeoutExpired('xcodebuild', timeout)
                advance(self.remaining())
                self.stopped = True
                return self.code

        class Server:
            def __init__(self, case, point):
                self.reached = threading.Event()
                self.requests = [{'phase': 'new', 'path': '/checkpoint/session.loaded'}]
                servers.append(self)

            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def wait_checkpoint(self, timeout, preparing=None):
                if self.reached.is_set():
                    return
                if preparing.remaining() > timeout:
                    advance(timeout)
                    raise JourneyError('The historical app did not reach index.embed')
                advance(preparing.remaining())
                self.reached.set()

            def begin_upgrade(self):
                pass

        class App:
            destination = 'platform=iOS Simulator,id=fixture'
            launch_arguments = []

            def __init__(self, *_):
                pass

            def install(self, bundle):
                pass

            def verify_metadata(self, *_):
                pass

            def launch(self, server, seed=False):
                pass

            def require_running(self):
                if app_ended and not ended_after_start and (not ended_from_verify or 'ui-verify' in events):
                    raise JourneyError(app_ended)

            def explain(self, message):
                return f'{message}; {app_ended}' if app_ended else message

            def kill_app(self):
                events.append('kill-old')
                clock['killed'] = clock['now']

            def close(self):
                pass

        def ui(runner, destination, point, phase, case, *_):
            runs.append(Run(case / (phase + '-ui.log'), prepare_startup if phase == 'prepare' else verify_startup,
                            reach_at if phase == 'prepare' else None, verify_code if phase == 'verify' else 0,
                            verify_act if phase == 'verify' else None))
            events.append('ui-' + phase)
            return runs[-1], io.StringIO()

        with _temporary_directory() as directory:
            root = Path(directory)
            source = root / 'source'
            (source / 'UpgradeUITests').mkdir(parents=True)
            products = root / 'build/DerivedData.noindex/Build/Products'
            products.mkdir(parents=True)
            (products / 'runner.xctestrun').touch()
            builds = [Build(root / 'new.app', source, {'tag': 'v1.1.0'}, 'a' * 40), Build(root / 'old.app', None, {'tag': 'v1.0.5'}, 'b' * 40)]
            arguments = ['run_journey', '--repo', str(root), '--automation', str(Path(__file__).resolve().parents[2]),
                         '--root', str(root), '--target', 'HEAD', '--release-tag', 'v1.1.0', '--sources', 'v1.0.5',
                         '--platform', 'iOS', '--points', 'index.embed']
            with patch.object(sys, 'argv', arguments), patch.object(run_journey, 'release_metadata', return_value={'tag': 'v1.1.0'}), \
                    patch.object(run_journey, 'build_app', side_effect=builds), patch.object(run_journey, 'command'), \
                    patch.object(run_journey, 'output', side_effect=lambda args, *_, **__: '128' if args == ['sysctl', '-n', 'kern.ipc.somaxconn'] else 'arm64'), \
                    patch.object(run_journey, 'summary', side_effect=self.summary_lines.append), \
                    patch.object(run_journey, 'verify_bundle_metadata', return_value={}), \
                    patch.object(run_journey, 'InstalledApp', App), patch.object(run_journey, 'FixtureServer', Server), \
                    patch.object(run_journey, 'ui_run', side_effect=ui), patch.object(run_journey, 'stop_group', lambda run: setattr(run, 'stopped', True)), \
                    patch.object(run_journey, 'sample_runner'), patch.object(run_journey, 'time', Clock), \
                    patch('keychain_entitlements.snapshot', return_value={}):
                try:
                    run_journey.main()
                    error = None
                except JourneyError as failure:
                    error = failure
                timing = next(root.glob('evidence/*/iOS/v1.0.5/index.embed/timing.json'), None)
                self.killed_at = clock.get('killed')
                return error, events, clock['now'], json.loads(timing.read_text()) if timing else None

    def test_slow_ui_runner_startup_keeps_the_full_preparation_and_verification_budgets(self):
        # Release run 38171860265: the UI runner needed 160 s to start, and the 180 s budget expired before it acted.
        error, events, _, timing = self.run_case_on_a_virtual_clock(prepare_startup=170, verify_startup=300)
        self.assertIsNone(error)
        self.assertEqual(events, ['ui-prepare', 'kill-old', 'ui-verify'])
        self.assertEqual((timing['prepare_ui_startup_s'], timing['verify_ui_startup_s']), (170, 300))

    def test_a_checkpoint_reached_before_the_ui_test_starts_ends_the_startup_wait(self):
        # iOS thumbnail points reach their checkpoint without the UI test. The kill must follow while the server still
        # holds that checkpoint (240 s), even when the UI runner starts late or never.
        for startup in [None, 300]:
            with self.subTest(prepare_startup=startup):
                error, events, _, timing = self.run_case_on_a_virtual_clock(startup, verify_startup=1, reach_at=5)
                self.assertIsNone(error)
                self.assertEqual(events, ['ui-prepare', 'kill-old', 'ui-verify'])
                self.assertEqual(timing['prepare_ui_startup_s'], 5)
                self.assertLess(self.killed_at, 5 + 240)

    def test_ui_runner_budgets_stay_bounded(self):
        for prepare, verify, act, message, elapsed in [
                (None, 1, 20, 'index.embed preparation: xcodebuild did not start the UI test within 600 s', 600),
                (1, None, 20, 'index.embed verification: xcodebuild did not start the UI test within 600 s', 621),
                (10, 1, 181, 'did not reach index.embed', 190)]:
            with self.subTest(prepare=prepare, verify=verify, act=act):
                error, events, now, _ = self.run_case_on_a_virtual_clock(prepare, verify, act)
                self.assertRegex(str(error), message)
                self.assertAlmostEqual(now, elapsed, delta=1)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, run_journey.terminate)
    signal.signal(signal.SIGINT, run_journey.terminate)
    unittest.main()
