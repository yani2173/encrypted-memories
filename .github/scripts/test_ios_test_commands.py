import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class IOSTestCommands(unittest.TestCase):
    def setUp(self):
        build_root = Path.home() / 'Developer/xcode/EncryptedMemories'
        build_root.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(prefix='ci-command-test-', dir=build_root)
        self.root = Path(self.scratch.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'bin').mkdir()
        source = Path(__file__).resolve().parents[2] / 'scripts/verify-ios-app-tests.sh'
        shutil.copy(source, self.root / 'scripts')
        (self.root / 'scripts/build-paths.sh').write_text('''ENCRYPTED_MEMORIES_BUILD_ROOT="$TEST_ROOT"
ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES="$TEST_ROOT/packages"
ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE="$TEST_ROOT/cache"
encryptedmemories_acquire_build_lock() { :; }
encryptedmemories_pin_generated_project_packages() { :; }
''')
        (self.root / 'BuildSupport').mkdir()
        (self.root / 'BuildSupport/Package.resolved').write_text('{}')
        pinned = self.root / 'EncryptedMemories.xcodeproj/project.xcworkspace/xcshareddata/swiftpm'
        pinned.mkdir(parents=True)
        (pinned / 'Package.resolved').write_text('{}')
        launcher = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_ROOT'] + '/commands.jsonl', 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:4] == ['simctl', 'list', 'devices']:
    devices = {'devices': {
        'com.apple.CoreSimulator.SimRuntime.iOS-26-0': [
            {'name': 'iPhone 17', 'udid': 'older-simulator-test', 'isAvailable': True}],
        'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [
            {'name': 'iPhone 17', 'udid': 'simulator-test', 'isAvailable': True}],
        'com.apple.CoreSimulator.SimRuntime.iOS-27-1': [
            {'name': 'iPhone Duo', 'udid': 'duo-test', 'isAvailable': True}]}}
    if os.environ.get('TEST_PATCH_RUNTIME') == '1':
        devices['devices']['com.apple.CoreSimulator.SimRuntime.iOS-27-1-1'] = [
            {'name': 'iPhone Duo', 'udid': 'patched-duo-test', 'isAvailable': True}]
    print(json.dumps(devices))
if sys.argv[1:3] == ['simctl', 'bootstatus']:
    raise SystemExit(int(os.environ.get('TEST_BOOT_EXIT', '0')))
if sys.argv[1:2] == ['simctl'] and sys.argv[2:3] == ['boot']:
    raise SystemExit(int(os.environ.get('TEST_BOOT_START_EXIT', '0')))
if sys.argv[1:3] == ['simctl', 'shutdown']:
    raise SystemExit(int(os.environ.get('TEST_SHUTDOWN_EXIT', '0')))
if sys.argv[1:4] == ['xcresulttool', 'get', 'test-results']:
    total = int(os.environ.get('TEST_TOTAL', '7'))
    print(json.dumps({'totalTestCount': total, 'passedTests': int(os.environ.get('TEST_PASSED', total)),
                      'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 0}))
    raise SystemExit(int(os.environ.get('TEST_XCRESULT_EXIT', '0')))
if sys.argv[1:2] == ['xcodebuild']:
    raise SystemExit(int(os.environ.get('TEST_XCODEBUILD_EXIT', '0')))
'''
        for name in ['xcrun', 'xcodegen']:
            command = self.root / 'bin' / name
            command.write_text(launcher)
            command.chmod(0o755)

    def tearDown(self):
        self.scratch.cleanup()

    def run_script(self, mode='hosted', **options):
        environment = dict(os.environ)
        for key in list(environment):
            if key.startswith('IOS_TEST_'):
                del environment[key]
        environment.update(TEST_ROOT=str(self.root), PATH=str(self.root / 'bin') + ':' + os.environ['PATH'])
        environment.update(TEST_BOOT_EXIT="0", TEST_PATCH_RUNTIME="0", TEST_TOTAL="7", TEST_XCRESULT_EXIT="0",
                           TEST_XCODEBUILD_EXIT="0", TEST_BOOT_START_EXIT="0", TEST_SHUTDOWN_EXIT="0")
        environment.pop('TEST_PASSED', None)
        environment.update(options)
        (self.root / "commands.jsonl").write_text("")
        result = subprocess.run(['bash', str(self.root / 'scripts/verify-ios-app-tests.sh'), mode],
                                env=environment, capture_output=True, text=True)
        commands = self.root / 'commands.jsonl'
        logged = [json.loads(line) for line in commands.read_text().splitlines()] if commands.exists() else []
        # The count of the result bundle is read after the run; the tests of the run look at the commands before it.
        self.summary_commands = [command for command in logged if command[:1] == ['xcresulttool']]
        self.commands = [command for command in logged if command[:1] != ['xcresulttool']]
        return result

    def test_default_commands_keep_both_local_modes(self):
        for mode, scheme in [('hosted', 'EncryptedMemoriesMobileTests'), ('ui', 'EncryptedMemoriesMobileUITests')]:
            with self.subTest(mode=mode):
                result = self.run_script(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                invocation = self.commands[-1]
                self.assertEqual(invocation[-1], 'test')
                self.assertEqual(invocation[invocation.index('-scheme') + 1], scheme)
                self.assertTrue(any('-resolvePackageDependencies' in command for command in self.commands))

    def test_explicit_simulator_id_boots_before_both_test_modes(self):
        for mode in ['hosted', 'ui']:
            with self.subTest(mode=mode):
                result = self.run_script(mode, IOS_TEST_DESTINATION='platform=iOS Simulator,id=simulator-test')
                self.assertEqual(result.returncode, 0, result.stderr)
                boot = ['simctl', 'bootstatus', 'simulator-test', '-b']
                self.assertIn(boot, self.commands)
                self.assertLess(self.commands.index(boot), len(self.commands) - 1)
                invocation = self.commands[-1]
                self.assertEqual(invocation[invocation.index('-destination') + 1],
                                 'platform=iOS Simulator,id=simulator-test')

    def test_named_simulator_override_boots_and_tests_the_same_device(self):
        result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone Duo,OS=latest,arch=arm64')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['simctl', 'bootstatus', 'duo-test', '-b'], self.commands)
        invocation = self.commands[-1]
        self.assertEqual(invocation[invocation.index('-destination') + 1],
                         'platform=iOS Simulator,arch=arm64,id=duo-test')

    def test_explicit_simulator_build_does_not_boot(self):
        result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,id=simulator-test',
                                 IOS_TEST_ACTION='build-for-testing')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[:2] == ['simctl', 'bootstatus'] for command in self.commands))

    def test_named_override_honors_an_explicit_runtime(self):
        result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17,OS=26.0.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['simctl', 'bootstatus', 'older-simulator-test', '-b'], self.commands)
        invocation = self.commands[-1]
        self.assertEqual(invocation[invocation.index('-destination') + 1],
                         'platform=iOS Simulator,id=older-simulator-test')

    def test_unavailable_or_invalid_named_runtime_stops_before_xcodebuild(self):
        for runtime, expected in [('27.0', 69), ('not-a-version', 64)]:
            with self.subTest(runtime=runtime):
                result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone Duo,OS=' + runtime)
                self.assertEqual(result.returncode, expected)
                self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_partial_or_missing_runtime_selects_the_highest_matching_version(self):
        for runtime in ['27.1', '27', None]:
            with self.subTest(runtime=runtime):
                destination = 'platform=iOS Simulator,name=iPhone Duo'
                if runtime is not None:
                    destination += ',OS=' + runtime
                result = self.run_script(IOS_TEST_DESTINATION=destination, TEST_PATCH_RUNTIME='1')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(['simctl', 'bootstatus', 'patched-duo-test', '-b'], self.commands)
                invocation = self.commands[-1]
                self.assertEqual(invocation[invocation.index('-destination') + 1],
                                 'platform=iOS Simulator,id=patched-duo-test')

    def test_three_component_runtime_matches_exactly(self):
        for runtime, simulator in [('27.1.0', 'duo-test'), ('27.1.1', 'patched-duo-test')]:
            with self.subTest(runtime=runtime):
                result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone Duo,OS=' + runtime,
                                         TEST_PATCH_RUNTIME='1')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(['simctl', 'bootstatus', simulator, '-b'], self.commands)
                invocation = self.commands[-1]
                self.assertEqual(invocation[invocation.index('-destination') + 1],
                                 'platform=iOS Simulator,id=' + simulator)

    def test_unmatched_partial_runtime_stops_before_xcodebuild(self):
        result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone Duo,OS=28',
                                 TEST_PATCH_RUNTIME='1')
        self.assertEqual(result.returncode, 69, result.stderr)
        self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_empty_destination_id_stops_before_xcodebuild(self):
        for destination in ['platform=iOS Simulator,id=',
                            'platform=iOS Simulator,id=,name=iPhone Duo',
                            'platform=iOS Simulator,name=iPhone Duo,id=']:
            with self.subTest(destination=destination):
                result = self.run_script(IOS_TEST_DESTINATION=destination)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('destination id cannot be empty', result.stderr)
                self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_empty_destination_os_stops_before_xcodebuild(self):
        for destination in ['platform=iOS Simulator,name=iPhone Duo,OS=',
                            'platform=iOS Simulator,id=duo-test,OS=']:
            with self.subTest(destination=destination):
                result = self.run_script(IOS_TEST_DESTINATION=destination)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('destination OS cannot be empty', result.stderr)
                self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_destination_fields_without_equals_stop_before_xcodebuild(self):
        for destination in ['platform=iOS Simulator,name=iPhone Duo, Book',
                            'platform=iOS Simulator,name=iPhone Duo,',
                            'platform=iOS Simulator,,name=iPhone Duo']:
            with self.subTest(destination=destination):
                result = self.run_script(IOS_TEST_DESTINATION=destination)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('destination fields must use key=value', result.stderr)
                self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_invalid_runtime_with_id_stops_before_any_command(self):
        for runtime in ['not-a-version', '27.1.1.1', '27.', '.27', '-1']:
            with self.subTest(runtime=runtime):
                result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,id=abc,OS=' + runtime)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('simulator OS must be latest or a numeric version', result.stderr)
                self.assertEqual(self.commands, [])

    def test_valid_runtime_with_id_is_forwarded_unchanged(self):
        for runtime in ['27', '27.1', '27.1.1', 'latest']:
            with self.subTest(runtime=runtime):
                destination = 'platform=iOS Simulator,id=abc,OS=' + runtime
                result = self.run_script(IOS_TEST_DESTINATION=destination)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(['simctl', 'bootstatus', 'abc', '-b'], self.commands)
                invocation = self.commands[-1]
                self.assertEqual(invocation[invocation.index('-destination') + 1], destination)

    def test_failed_explicit_boot_stops_before_test_launch(self):
        result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,id=duo-test',
                                 IOS_TEST_PREPARED='1', TEST_BOOT_EXIT='1')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('simulator did not finish booting', result.stderr)
        self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_other_platform_destination_does_not_boot_an_ios_simulator(self):
        result = self.run_script(IOS_TEST_DESTINATION='platform=macOS,id=host-test')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[:2] == ['simctl', 'bootstatus'] for command in self.commands))

    def test_prepared_build_builds_both_bundles_without_filtering(self):
        result = self.run_script(IOS_TEST_ACTION='build-for-testing', IOS_TEST_SCHEME='EncryptedMemoriesMobileCI',
                                 IOS_TEST_PREPARED='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands[-1][-1], 'build-for-testing')
        self.assertNotIn('-only-testing:EncryptedMemoriesMobileTests', self.commands[-1])
        self.assertFalse(any('-resolvePackageDependencies' in command for command in self.commands))

    def test_prepared_runs_select_the_complete_bundle(self):
        self.write_xctestrun('EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun')
        for mode, target in [('hosted', 'EncryptedMemoriesMobileTests'), ('ui', 'EncryptedMemoriesMobileUITests')]:
            with self.subTest(mode=mode):
                result = self.run_script(mode, IOS_TEST_ACTION='test-without-building',
                                         IOS_TEST_SCHEME='EncryptedMemoriesMobileCI', IOS_TEST_PREPARED='1',
                                         IOS_TEST_PARALLEL_WORKERS='2', IOS_TEST_RESULT_BUNDLE_PATH=str(self.root / 'results'))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.commands[-1][-1], 'test-without-building')
                self.assertIn('-only-testing:' + target, self.commands[-1])
                self.assertIn('-resultBundlePath', self.commands[-1])
                self.assertFalse(any('-resolvePackageDependencies' in command for command in self.commands))
                if mode == 'ui':
                    self.assertIn('-parallel-testing-enabled', self.commands[-1])
                    self.assertEqual(self.commands[-1][self.commands[-1].index('-parallel-testing-worker-count') + 1], '2')

    def test_test_actions_skip_the_simulator_diagnostics_collection_and_the_build_does_not(self):
        self.write_xctestrun('EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun')
        for mode in ['hosted', 'ui']:
            for action in ['test', 'test-without-building']:
                with self.subTest(mode=mode, action=action):
                    result = self.run_script(mode, IOS_TEST_ACTION=action, IOS_TEST_PREPARED='1',
                                             IOS_TEST_SCHEME='EncryptedMemoriesMobileCI')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    invocation = self.commands[-1]
                    self.assertEqual(invocation[-1], action)
                    self.assertEqual(invocation[invocation.index('-collect-test-diagnostics') + 1], 'never')
                    self.assertEqual(invocation.count('-collect-test-diagnostics'), 1)
        for mode in ['hosted', 'ui']:
            with self.subTest(mode=mode, run='local default'):
                result = self.run_script(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                invocation = self.commands[-1]
                self.assertEqual(invocation[invocation.index('-collect-test-diagnostics') + 1], 'never')
        result = self.run_script(IOS_TEST_ACTION='build-for-testing', IOS_TEST_PREPARED='1',
                                 IOS_TEST_SCHEME='EncryptedMemoriesMobileCI')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('-collect-test-diagnostics', self.commands[-1])

    def write_xctestrun(self, *names):
        products = self.root / 'DD.tests.ios.noindex/Build/Products'
        products.mkdir(parents=True, exist_ok=True)
        for name in names:
            (products / name).write_text('{}')
        return products

    def test_a_prepared_test_run_starts_from_the_test_run_file_of_the_build(self):
        products = self.write_xctestrun('EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun',
                                        'EncryptedMemoriesMobileTests_iphonesimulator27.0-arm64.xctestrun')
        for mode, target in [('hosted', 'EncryptedMemoriesMobileTests'), ('ui', 'EncryptedMemoriesMobileUITests')]:
            with self.subTest(mode=mode):
                result = self.run_script(mode, IOS_TEST_ACTION='test-without-building', IOS_TEST_PREPARED='1',
                                         IOS_TEST_SCHEME='EncryptedMemoriesMobileCI',
                                         IOS_TEST_RESULT_BUNDLE_PATH=str(self.root / 'results'))
                self.assertEqual(result.returncode, 0, result.stderr)
                invocation = self.commands[-1]
                self.assertEqual(invocation[invocation.index('-xctestrun') + 1],
                                 str(products / 'EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun'))
                for option in ['-project', '-scheme', '-clonedSourcePackagesDirPath', '-packageCachePath']:
                    self.assertNotIn(option, invocation)
                self.assertEqual(invocation[invocation.index('-destination') + 1], 'platform=iOS Simulator,id=simulator-test')
                self.assertIn('-only-testing:' + target, invocation)
                self.assertIn('-resultBundlePath', invocation)
                self.assertEqual(invocation[invocation.index('-derivedDataPath') + 1], str(self.root / 'DD.tests.ios.noindex'))
                self.assertEqual(invocation[invocation.index('-collect-test-diagnostics') + 1], 'never')
                self.assertEqual(invocation[-1], 'test-without-building')

    def test_the_test_run_file_keeps_the_parallel_testing_options_of_the_ui_run(self):
        self.write_xctestrun('EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun')
        for mode, parallel in [('ui', True), ('hosted', False)]:
            with self.subTest(mode=mode):
                result = self.run_script(mode, IOS_TEST_ACTION='test-without-building', IOS_TEST_PREPARED='1',
                                         IOS_TEST_SCHEME='EncryptedMemoriesMobileCI', IOS_TEST_PARALLEL_WORKERS='2')
                self.assertEqual(result.returncode, 0, result.stderr)
                invocation = self.commands[-1]
                self.assertIn('-xctestrun', invocation)
                self.assertEqual('-parallel-testing-enabled' in invocation, parallel)
                if parallel:
                    self.assertEqual(invocation[invocation.index('-parallel-testing-worker-count') + 1], '2')

    def test_a_prepared_run_without_exactly_one_test_run_file_fails_before_xcodebuild_starts(self):
        cases = {
            'none': [],
            'other scheme only': ['EncryptedMemoriesMobileTests_iphonesimulator27.0-arm64.xctestrun'],
            'two for the scheme': ['EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun',
                                   'EncryptedMemoriesMobileCI_iphonesimulator27.1-arm64.xctestrun'],
        }
        for mode in ['hosted', 'ui']:
            for name, files in cases.items():
                with self.subTest(mode=mode, case=name):
                    shutil.rmtree(self.root / 'DD.tests.ios.noindex', ignore_errors=True)
                    self.write_xctestrun(*files)
                    result = self.run_script(mode, IOS_TEST_ACTION='test-without-building', IOS_TEST_PREPARED='1',
                                             IOS_TEST_SCHEME='EncryptedMemoriesMobileCI',
                                             IOS_TEST_RESULT_BUNDLE_PATH=str(self.root / 'results'))
                    self.assertEqual(result.returncode, 66, result.stderr)
                    self.assertIn('expected one test run file', result.stderr)
                    self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))
                    # The missing file is found before the wait for the simulator, which can take minutes.
                    self.assertFalse(any(command[:2] == ['simctl', 'bootstatus'] for command in self.commands))

    def test_only_a_prepared_test_without_building_uses_the_test_run_file(self):
        self.write_xctestrun('EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun',
                             'EncryptedMemoriesMobileTests_iphonesimulator27.0-arm64.xctestrun')
        cases = [
            dict(IOS_TEST_ACTION='test-without-building', IOS_TEST_PREPARED='0'),
            dict(IOS_TEST_ACTION='build-for-testing', IOS_TEST_PREPARED='1', IOS_TEST_SCHEME='EncryptedMemoriesMobileCI'),
            dict(IOS_TEST_ACTION='test', IOS_TEST_PREPARED='0'),
        ]
        for options in cases:
            with self.subTest(**options):
                result = self.run_script(**options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('-xctestrun', self.commands[-1])

    def test_the_simulator_start_boots_the_selected_device_and_runs_nothing_else(self):
        for mode in ['hosted', 'ui']:
            with self.subTest(mode=mode):
                result = self.run_script(mode, IOS_TEST_ACTION='boot-simulator')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(['simctl', 'boot', 'simulator-test'], self.commands)
                self.assertFalse(any(command[:2] == ['simctl', 'bootstatus'] for command in self.commands))
                self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))
                self.assertFalse(any(command and command[0] == 'xcodegen' for command in self.commands))

    def test_the_simulator_start_uses_the_destination_device_and_never_fails_the_job(self):
        result = self.run_script(IOS_TEST_ACTION='boot-simulator', IOS_TEST_DESTINATION='platform=iOS Simulator,id=chosen')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['simctl', 'boot', 'chosen'], self.commands)
        result = self.run_script(IOS_TEST_ACTION='boot-simulator', IOS_TEST_DESTINATION='platform=macOS,id=host-test')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[:2] == ['simctl', 'boot'] for command in self.commands))

    def test_a_test_run_that_executed_no_test_fails_for_both_forms_and_both_modes(self):
        self.write_xctestrun('EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun')
        for mode in ['hosted', 'ui']:
            for action, prepared in [('test-without-building', '1'), ('test-without-building', '0'), ('test', '0')]:
                for total, status in [('0', '0'), ('7', '1')]:
                    with self.subTest(mode=mode, action=action, prepared=prepared, total=total, status=status):
                        result = self.run_script(mode, IOS_TEST_ACTION=action, IOS_TEST_PREPARED=prepared,
                                                 IOS_TEST_SCHEME='EncryptedMemoriesMobileCI', TEST_TOTAL=total,
                                                 TEST_XCRESULT_EXIT=status,
                                                 IOS_TEST_RESULT_BUNDLE_PATH=str(self.root / 'results'))
                        self.assertEqual(result.returncode, 70, result.stderr)
                        self.assertIn('executed no test', result.stderr)

    def test_a_test_run_in_which_every_test_was_skipped_fails(self):
        for mode in ['hosted', 'ui']:
            with self.subTest(mode=mode):
                result = self.run_script(mode, IOS_TEST_ACTION='test', TEST_TOTAL='4', TEST_PASSED='0',
                                         IOS_TEST_RESULT_BUNDLE_PATH=str(self.root / 'results'))
                self.assertEqual(result.returncode, 70, result.stderr)
        result = self.run_script(IOS_TEST_ACTION='test', TEST_TOTAL='4', TEST_PASSED='3',
                                 IOS_TEST_RESULT_BUNDLE_PATH=str(self.root / 'results'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('executed tests: 3 (4 in total', result.stdout)

    def test_a_test_run_with_tests_passes_and_reports_the_count(self):
        self.write_xctestrun('EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun')
        for mode in ['hosted', 'ui']:
            with self.subTest(mode=mode):
                result = self.run_script(mode, IOS_TEST_ACTION='test-without-building', IOS_TEST_PREPARED='1',
                                         IOS_TEST_SCHEME='EncryptedMemoriesMobileCI', TEST_TOTAL='141',
                                         IOS_TEST_RESULT_BUNDLE_PATH=str(self.root / 'results'))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('executed tests: 141 (141 in total', result.stdout)
                summary = self.summary_commands
                self.assertEqual(len(summary), 1)
                self.assertEqual(summary[0][summary[0].index('--path') + 1], str(self.root / 'results'))

    def test_the_count_is_not_checked_for_the_build_and_the_xcodebuild_status_wins(self):
        result = self.run_script(IOS_TEST_ACTION='build-for-testing', IOS_TEST_PREPARED='1',
                                 IOS_TEST_SCHEME='EncryptedMemoriesMobileCI', TEST_TOTAL='0',
                                 IOS_TEST_RESULT_BUNDLE_PATH=str(self.root / 'results'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.summary_commands, [])
        self.write_xctestrun('EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun')
        result = self.run_script(IOS_TEST_ACTION='test-without-building', IOS_TEST_PREPARED='1',
                                 IOS_TEST_SCHEME='EncryptedMemoriesMobileCI', TEST_XCODEBUILD_EXIT='65',
                                 IOS_TEST_RESULT_BUNDLE_PATH=str(self.root / 'results'))
        self.assertEqual(result.returncode, 65)
        self.assertEqual(self.summary_commands, [])

    def test_a_failed_simulator_start_leaves_the_boot_to_the_test_run(self):
        options = dict(IOS_TEST_ACTION='boot-simulator', TEST_BOOT_START_EXIT='1')
        result = self.run_script(**options)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['simctl', 'boot', 'simulator-test'], self.commands)
        # The test run waits with `bootstatus -b`, which boots the device when it is not booted yet.
        self.write_xctestrun('EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun')
        prepared = dict(IOS_TEST_ACTION='test-without-building', IOS_TEST_PREPARED='1',
                        IOS_TEST_SCHEME='EncryptedMemoriesMobileCI')
        result = self.run_script(**prepared, TEST_BOOT_START_EXIT='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        boot = ['simctl', 'bootstatus', 'simulator-test', '-b']
        self.assertIn(boot, self.commands)
        self.assertLess(self.commands.index(boot), len(self.commands) - 1)
        self.assertEqual(self.commands[-1][0], 'xcodebuild')
        # A device that does not boot in the test run still fails it.
        result = self.run_script(**prepared, TEST_BOOT_EXIT='1')
        self.assertEqual(result.returncode, 1)
        self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_a_simulator_that_the_start_step_booted_and_the_tests_do_not_use_is_shut_down(self):
        record = self.root / 'boot-record'
        self.write_xctestrun('EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun')
        prepared = dict(IOS_TEST_ACTION='test-without-building', IOS_TEST_PREPARED='1',
                        IOS_TEST_SCHEME='EncryptedMemoriesMobileCI', IOS_TEST_BOOT_RECORD=str(record))
        started = self.run_script(IOS_TEST_ACTION='boot-simulator', IOS_TEST_BOOT_RECORD=str(record))
        self.assertEqual(started.returncode, 0, started.stderr)
        self.assertEqual(record.read_text().strip(), 'simulator-test')
        # The same device: nothing is shut down.
        result = self.run_script(**prepared)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[:2] == ['simctl', 'shutdown'] for command in self.commands))
        # Another device was booted: it is shut down, after the tested device is ready, and the run goes on.
        record.write_text('other-simulator\n')
        result = self.run_script(**prepared)
        self.assertEqual(result.returncode, 0, result.stderr)
        shutdown = ['simctl', 'shutdown', 'other-simulator']
        self.assertEqual([c for c in self.commands if c[:2] == ['simctl', 'shutdown']], [shutdown])
        self.assertLess(self.commands.index(['simctl', 'bootstatus', 'simulator-test', '-b']), self.commands.index(shutdown))
        # A failed shutdown does not fail the run.
        result = self.run_script(**prepared, TEST_SHUTDOWN_EXIT='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        # Without a record, or with an empty one, nothing is shut down.
        for content in [None, '']:
            with self.subTest(record=content):
                record.unlink(missing_ok=True)
                if content is not None:
                    record.write_text(content)
                result = self.run_script(**prepared)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(command[:2] == ['simctl', 'shutdown'] for command in self.commands))
        # No variable, no record, no shutdown of a device of someone else.
        record.write_text('other-simulator\n')
        result = self.run_script(**{key: value for key, value in prepared.items() if key != 'IOS_TEST_BOOT_RECORD'})
        self.assertFalse(any(command[:2] == ['simctl', 'shutdown'] for command in self.commands))

    def test_the_simulator_start_and_the_test_run_use_the_same_device(self):
        destinations = {
            'default': {},
            'id': dict(IOS_TEST_DESTINATION='platform=iOS Simulator,id=duo-test'),
            'name': dict(IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone Duo,OS=latest'),
            'name and runtime': dict(IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17,OS=26.0'),
        }
        self.write_xctestrun('EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun')
        for name, destination in destinations.items():
            for mode in ['hosted', 'ui']:
                with self.subTest(destination=name, mode=mode):
                    started = self.run_script(**destination, IOS_TEST_ACTION='boot-simulator')
                    self.assertEqual(started.returncode, 0, started.stderr)
                    booted = [command[2] for command in self.commands if command[:2] == ['simctl', 'boot']]
                    self.assertEqual(len(booted), 1)
                    tested = self.run_script(mode, **destination, IOS_TEST_ACTION='test-without-building',
                                             IOS_TEST_PREPARED='1', IOS_TEST_SCHEME='EncryptedMemoriesMobileCI')
                    self.assertEqual(tested.returncode, 0, tested.stderr)
                    invocation = self.commands[-1]
                    waited = [command[2] for command in self.commands if command[:2] == ['simctl', 'bootstatus']]
                    self.assertEqual(waited, booted)
                    self.assertIn('id=' + booted[0], invocation[invocation.index('-destination') + 1].split(','))

    def test_invalid_action_fails_before_xcodebuild(self):
        result = self.run_script(IOS_TEST_ACTION='archive')
        self.assertEqual(result.returncode, 64)
        self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_prepared_project_requires_the_pinned_graph(self):
        (self.root / 'BuildSupport/Package.resolved').write_text('{"changed":true}')
        result = self.run_script(IOS_TEST_PREPARED='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_ui_diagnostics_wrap_the_complete_command_and_force_one_simulator(self):
        self.write_xctestrun('EncryptedMemoriesMobileCI_iphonesimulator27.0-arm64.xctestrun')
        scripts = self.root / '.github/scripts'
        scripts.mkdir(parents=True)
        (scripts / 'collect_ui_wait_diagnostics.py').write_text(
            "import json, os, subprocess, sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['TEST_ROOT'] + '/diagnostics.json').write_text(json.dumps(sys.argv[1:]))\n"
            "raise SystemExit(subprocess.call(sys.argv[sys.argv.index('--') + 1:]))\n")
        result = self.run_script('ui', IOS_TEST_ACTION='test-without-building', IOS_TEST_PREPARED='1',
                                 IOS_TEST_SCHEME='EncryptedMemoriesMobileCI',
                                 IOS_TEST_DIAGNOSTICS_PATH=str(self.root / 'diagnostics'))
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads((self.root / 'diagnostics.json').read_text())
        self.assertEqual(arguments[arguments.index('--simulator') + 1], 'simulator-test')
        self.assertEqual(arguments[arguments.index('--output') + 1], str(self.root / 'diagnostics'))
        self.assertIn('-only-testing:EncryptedMemoriesMobileUITests', self.commands[-1])
        self.assertEqual(self.commands[-1][self.commands[-1].index('-parallel-testing-enabled') + 1], 'NO')
        wrapped = arguments[arguments.index('--') + 1:]
        self.assertEqual(wrapped[wrapped.index('-collect-test-diagnostics') + 1], 'never')

    def test_diagnostics_reject_parallel_clones_and_unknown_destination_ownership(self):
        for options in [{'IOS_TEST_PARALLEL_WORKERS': '2'},
                        {'IOS_TEST_DESTINATION': 'generic/platform=iOS Simulator'},
                        {'IOS_TEST_DESTINATION': 'platform=macOS,id=host-test'}]:
            with self.subTest(options=options):
                result = self.run_script('ui', IOS_TEST_PREPARED='1',
                                         IOS_TEST_DIAGNOSTICS_PATH=str(self.root / 'diagnostics'), **options)
                self.assertEqual(result.returncode, 64)
                self.assertIn('diagnostics require one simulator', result.stderr)
                self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))


if __name__ == '__main__':
    unittest.main()
