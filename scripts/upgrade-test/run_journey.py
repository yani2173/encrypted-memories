#!/usr/bin/env python3
"""Run install-over UI journeys on an owned simulator or the macOS runner."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import sys
import threading
import uuid
import time

from build_apps import build_app, clean_environment, command, output, release_metadata, verify_bundle_metadata
from journey import JourneyError, run_cases
from server import FixtureServer

BUNDLE = 'at.oncloud.encryptedmemories.upgrade-test'
POINTS = ['backup.claimed', 'backup.remoteReceipt', 'backup.localRecord',
          'model.partial', 'model.installRecord', 'model.promoted',
          'index.embed', 'index.beforeCommit', 'index.afterCommit',
          'thumbnail.beforeLoad', 'thumbnail.afterLoad', 'thumbnail.stored']
LIMITATION = ('macOS-Keychain-Persistenz über das Update wird nicht im Prüfbau geprüft; '
              'abgedeckt durch iOS-Simulator und Entitlement-Vergleich.')
CONSENT_LIMITATION = ('The backup journey requires consent already saved on disk. The immediate v1.0.5 '
                     'Enable-to-SIGKILL case is a known historical limit and is not tested here.')

# The exact iOS Simulator runtime that the journey evidence names. Measured on the hosted xcode-27 runner
# with Xcode 27.0 (27A266a), image 20261006.0244.1. A runner image that changes it must fail visibly until
# this pin is updated deliberately.
IOS_RUNTIME = {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'version': '27.0',
               'buildversion': '24A434'}

# xcodebuild needs its own time to start the UI runner before XCTest starts a test case. On the loaded hosted
# runner this startup took 160 s, nearly the whole former preparation budget, and the UI test never ran. The
# preparation budget therefore starts with the first test case, the app's own arrival at its checkpoint, or the end
# of the UI run, whichever comes first; the verification budget starts with the first test case or the end of the
# run. A runner that never starts a test case still fails after UI_STARTUP_SECONDS.
UI_TEST_STARTED = re.compile(r"^Test Case '[^']+' started\.$", re.M)
UI_STARTUP_SECONDS = 600
PREPARATION_SECONDS = 180
VERIFICATION_SECONDS = 240

METADATA_SCOPE = ('The gate requires installed CFBundleShortVersionString and CFBundleVersion to equal '
                  'the published release data string-for-string before every old and new probe starts. '
                  'External authentication-header acceptance remains unverified.')


def select_ios_runtime(runtimes, expected=IOS_RUNTIME):
    """Return the pinned runtime; fail before any device exists when it is missing, ambiguous or different."""
    name = f"{expected['identifier']} ({expected['version']}, build {expected['buildversion']})"
    matches = [r for r in runtimes if r.get('identifier') == expected['identifier']]
    if not matches:
        installed = [f"{r.get('identifier')} ({r.get('version')}, build {r.get('buildversion')}, "
                     f"{'available' if r.get('isAvailable') else 'unavailable'})" for r in runtimes
                     if str(r.get('identifier', '')).startswith('com.apple.CoreSimulator.SimRuntime.iOS-')]
        raise JourneyError('The pinned iOS Simulator runtime is not installed: expected ' + name + ', installed '
                           + (', '.join(installed) or 'no iOS runtime'))
    if len(matches) != 1:
        raise JourneyError('Ambiguous Simulator runtime identifier: ' + expected['identifier'] + ' is installed '
                           + str(len(matches)) + ' times with builds '
                           + ', '.join(str(r.get('buildversion')) for r in matches) + '; expected ' + name)
    runtime = matches[0]
    installed = f"{runtime.get('version')}, build {runtime.get('buildversion')}"
    if runtime.get('version') != expected['version'] or runtime.get('buildversion') != expected['buildversion']:
        raise JourneyError('The installed iOS Simulator runtime differs from the pin: expected ' + name
                           + ', installed ' + installed + '. Update IOS_RUNTIME in run_journey.py deliberately.')
    if not runtime.get('isAvailable'):
        raise JourneyError('The pinned iOS Simulator runtime is installed but unavailable: ' + name)
    return runtime


def summary(message):
    print(message, flush=True)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as report:
            report.write(message + '\n\n')


def read_backup_consent(preferences):
    try:
        values = plistlib.loads(preferences.read_bytes())
    except FileNotFoundError:
        return None
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise JourneyError('Unreadable backup preferences in the owned app container') from error
    if not isinstance(values, dict):
        raise JourneyError('Unreadable backup preferences: expected a preference dictionary')
    return values.get('photoBackup.enabled.v1')


def wait_saved_backup_consent(preferences, deadline):
    # The selected task stays held. This wait uses the remainder of its preparation budget.
    while True:
        if read_backup_consent(preferences) is True:
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise JourneyError('The old app has no saved backup consent: photoBackup.enabled.v1 must be true')
        time.sleep(min(0.2, remaining))


def verify_saved_backup_consent(preferences, before):
    after = read_backup_consent(preferences)
    if before is not True or after is not before:
        raise JourneyError('Saved backup consent changed after install-over in the owned app container')
    return after


def owned_process(args, log, env=None):
    return subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, env=env or clean_environment(), start_new_session=True)


def stop_group(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def free_gib(path=Path.home()):
    return shutil.disk_usage(path).free / 2**30


class PartialSize(float):
    """The total of a tree that `du` could not read completely: a lower bound, not the size."""


# The six trees of the first rehearsals keep their 300 s; the four trees that #498 added have a smaller bound, so that
# one slow tree adds at most 60 s to a sample round.
TREE_TIMEOUT_SECONDS = 300
NEW_TREE_TIMEOUT_SECONDS = 60
TREE_TIMEOUTS = {'tmp': NEW_TREE_TIMEOUT_SECONDS, 'caches': NEW_TREE_TIMEOUT_SECONDS,
                 'logs': NEW_TREE_TIMEOUT_SECONDS, 'diagnostics': NEW_TREE_TIMEOUT_SECONDS}


def tree_gib(path, timeout=TREE_TIMEOUT_SECONDS):
    try:
        if not path.exists():
            return 0.0
        result = subprocess.run(['du', '-sk', str(path)], capture_output=True, text=True, timeout=timeout)
        size = int(result.stdout.split()[0]) / 2**20
    except (OSError, subprocess.TimeoutExpired, ValueError, IndexError):
        return float('nan')  # Unknown: no total, for example a root that the user cannot read.
    # A nonzero exit with a total (a readable tree with an unreadable part, or GNU du with an unreadable root) is
    # only a lower bound.
    return PartialSize(size) if result.returncode else size


def tree_label(size):
    return f'{size:.1f}' + (' partial' if isinstance(size, PartialSize) else '')


def swap_used_mib():
    # `sysctl vm.swapusage` prints "vm.swapusage: total = 2048.00M  used = 1.25M  free = 2046.75M  (encrypted)".
    # The C locale keeps the decimal point; Apple's sysctl honors LC_NUMERIC.
    try:
        result = subprocess.run(['sysctl', 'vm.swapusage'], capture_output=True, text=True, timeout=10,
                                env=dict(os.environ, LC_ALL='C'))
        if result.returncode:
            return float('nan')
        used, unit = re.search(r'used = ([0-9.]+)([MG])', result.stdout).groups()
        return float(used) * (1024 if unit == 'G' else 1)
    except (subprocess.TimeoutExpired, OSError, AttributeError, ValueError):
        return float('nan')


def runner_trees(path, root):
    home = Path.home()
    try:
        temporary = Path(tempfile.gettempdir())
    except Exception:  # gettempdir probes by creating files; no failure of it may stop the journey.
        temporary = None
    return {'evidence': path.parent, 'scratch': root / 'scratch', 'products': root / 'products',
            'simulators': home / 'Library/Developer/CoreSimulator/Devices',
            'simulator-logs': home / 'Library/Logs/CoreSimulator',
            'derived-data': home / 'Library/Developer/Xcode/DerivedData',
            # The free disk of a hosted iOS shard fell by about 0.9 GiB per case outside the trees above (#498).
            # `logs` contains `simulator-logs`: do not add the two.
            'tmp': temporary, 'caches': home / 'Library/Caches', 'logs': home / 'Library/Logs',
            'diagnostics': Path('/var/db/diagnostics')}


def runner_sample_line(count, trees):
    line = (time.strftime('%H:%M:%S') + ' load ' + ' '.join(f'{value:.2f}' for value in os.getloadavg())
            + f' free {free_gib():.1f} GiB swap used {swap_used_mib():.0f} MiB')
    if count % 5 == 0:
        sizes = {name: float('nan') if tree is None else tree_gib(tree, TREE_TIMEOUTS.get(name, TREE_TIMEOUT_SECONDS))
                 for name, tree in trees.items()}
        line += ' |' + ''.join(f' {name} {tree_label(size)}' for name, size in sizes.items()) + ' GiB'
    return line


def sample_runner(path, root, interval=60):
    # Load, free disk and swap every minute, and the large trees every fifth minute, show what a slow or failed case
    # met. A hosted iOS shard ran out of disk (rehearsal 38181793360) without any record of what filled it.
    def sample():
        trees = runner_trees(path, root)
        for count in range(sys.maxsize):
            line = runner_sample_line(count, trees)
            try:
                with open(path, 'a') as log:
                    log.write(line + '\n')
            except OSError:
                return  # The evidence directory is gone or the disk is full; the journey reports the failure itself.
            time.sleep(interval)
    threading.Thread(target=sample, daemon=True).start()


class SigningIdentity:
    """One temporary identity signs both macOS installations. No release credential is used."""
    def __init__(self, root):
        self.directory = Path(tempfile.mkdtemp(prefix='upgrade-signing-', dir=root))
        self.keychain = self.directory / 'fixture.keychain-db'
        self.password = os.urandom(32).hex()
        self.created = False

    def secure_command(self, args, operation, env=None):
        result = subprocess.run(args, env=env or clean_environment(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode:
            raise JourneyError(f'Temporary signing identity: {operation} failed ({result.returncode})')

    def __enter__(self):
        try:
            config = self.directory / 'certificate.conf'
            config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=signing\nprompt=no\n'
                              '[dn]\nCN=Encrypted Memories Upgrade Fixture\n[signing]\n'
                              'keyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n')
            self.secure_command(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                                 '-config', str(config), '-keyout', str(self.directory / 'key.pem'),
                                 '-out', str(self.directory / 'certificate.pem')], 'certificate creation')
            env = dict(clean_environment(), UPGRADE_SIGNING_PASSWORD=self.password)
            self.secure_command(['openssl', 'pkcs12', '-export', '-inkey', str(self.directory / 'key.pem'),
                                 '-in', str(self.directory / 'certificate.pem'), '-out', str(self.directory / 'identity.p12'),
                                 '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'SHA1',
                                 '-passout', 'env:UPGRADE_SIGNING_PASSWORD'], 'identity export', env)
            self.secure_command(['security', 'create-keychain', '-p', self.password, str(self.keychain)], 'keychain creation')
            self.created = True
            self.secure_command(['security', 'unlock-keychain', '-p', self.password, str(self.keychain)], 'keychain unlock')
            self.secure_command(['security', 'import', str(self.directory / 'identity.p12'), '-k', str(self.keychain),
                                 '-P', self.password, '-T', '/usr/bin/codesign'], 'identity import')
            self.secure_command(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s',
                                 '-k', self.password, str(self.keychain)], 'signing access')
            identities = output(['security', 'find-identity', '-p', 'codesigning', str(self.keychain)])
            match = re.search(r'\b([A-F0-9]{40})\b', identities)
            if not match:
                raise JourneyError('The temporary keychain contains no signing identity')
            self.identity = match[1]
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def sign(self, app, entitlements=None):
        args = ['codesign', '--force', '--deep', '--sign', self.identity, '--keychain', str(self.keychain), '--timestamp=none']
        if entitlements:
            args += ['--entitlements', str(entitlements)]
        command(args + [str(app)])
        command(['codesign', '--verify', '--deep', '--strict', str(app)])

    def __exit__(self, exc_type, *_):
        try:
            if self.created:
                self.secure_command(['security', 'delete-keychain', str(self.keychain)], 'keychain removal')
        except JourneyError as error:
            if exc_type is None:
                raise
            summary(str(error))
        finally:
            shutil.rmtree(self.directory)



class InstalledApp:
    def __init__(self, platform, directory, signer=None):
        self.platform = platform
        self.directory = directory
        self.signer = signer
        self.launch_arguments = []
        self.case_id = uuid.uuid4().hex
        self.simulator = None
        self.app_log = None
        if platform == 'iOS':
            runtime = select_ios_runtime(json.loads(output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes'])
            types = json.loads(output(['xcrun', 'simctl', 'list', 'devicetypes', '--json']))['devicetypes']
            phones = [d for d in types if d['name'] == 'iPhone 17']
            if not phones:
                raise JourneyError('No iPhone Simulator device type is available')
            self.simulator = output(['xcrun', 'simctl', 'create', 'EncryptedMemoriesUpgrade-' + self.case_id, phones[-1]['identifier'], runtime['identifier']])
            try:
                (directory / 'simulator.txt').write_text(self.simulator + '\n')
                (directory / 'simulator-runtime.json').write_text(json.dumps(runtime) + '\n')
                print('Owned iOS Simulator runtime: ' + runtime['identifier'] + ' (' + runtime['version'] + ', build '
                      + runtime['buildversion'] + ')', flush=True)
                print('Owned iOS Simulator: ' + self.simulator, flush=True)
                command(['xcrun', 'simctl', 'boot', self.simulator])
                command(['xcrun', 'simctl', 'bootstatus', self.simulator, '-b'])
            except BaseException:
                try:
                    self.close()
                except (subprocess.CalledProcessError, OSError) as error:
                    summary(f'Owned Simulator cleanup failed: {error}')
                raise

    @property
    def destination(self):
        return 'platform=iOS Simulator,id=' + self.simulator if self.simulator else 'platform=macOS'

    def stream_app_log(self, app):
        # The app's own system log explains a failing case, for example a crash before the UI test acts.
        if self.app_log:
            return
        if self.simulator:
            stream = ['xcrun', 'simctl', 'spawn', self.simulator, 'log', 'stream', '--style', 'compact',
                      '--predicate', f'process == "{self.executable}"']
        else:
            stream = ['/usr/bin/log', 'stream', '--style', 'compact', '--predicate', f'processImagePath BEGINSWITH "{self.installed}/"']
        self.app_log_file = open(self.directory / 'app.log', 'w')
        self.app_log = owned_process(stream, self.app_log_file)

    def install(self, app):
        if self.simulator:
            # This always installs over the existing app. The upgrade phase never uninstalls or erases it.
            command(['xcrun', 'simctl', 'install', self.simulator, str(app)])
            # The name of the installed version, for the log filter of the first install and for messages about its process.
            self.executable = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleExecutable']
        else:
            self.installed = self.directory / 'installed.app'
            if self.installed.exists():
                shutil.rmtree(self.installed)  # Only the owned executable bundle, never its persisted data.
            shutil.copytree(app, self.installed, symlinks=True)
            entitlements = self.directory / 'fixture-entitlements.plist'
            entitlements.write_bytes(plistlib.dumps({
                'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True,
                'com.apple.security.files.user-selected.read-write': True,
                'com.apple.security.personal-information.photos-library': True}))
            self.signer.sign(self.installed, entitlements)
        self.stream_app_log(app)

    def verify_metadata(self, release, phase, source_commit=None):
        bundle = Path(output(['xcrun', 'simctl', 'get_app_container', self.simulator, BUNDLE, 'app'])) if self.simulator else self.installed
        actual = verify_bundle_metadata(bundle, self.platform, release, 'installed ' + phase)
        (self.directory / (phase + '-bundle.json')).write_text(json.dumps({
            'expected': release, 'source_commit': source_commit, 'installed': actual}, indent=2) + '\n')
        summary(f'{self.platform} {phase} bundle: {release["tag"]}, version {actual["CFBundleShortVersionString"]}, build {actual["CFBundleVersion"]}')

    @property
    def preferences_path(self):
        if self.simulator:
            container = Path(output(['xcrun', 'simctl', 'get_app_container', self.simulator, BUNDLE, 'data']))
        else:
            container = Path.home() / 'Library/Containers' / BUNDLE / 'Data'
        return container / 'Library/Preferences' / (BUNDLE + '.plist')

    def launch(self, server, seed=False):
        args = ['-EncryptedMemoriesUITestFixture', '-EncryptedMemoriesUpgradeServer', server.url,
                '-EncryptedMemoriesUpgradeCase', self.case_id,
                '-AppleLanguages', '(en)', '-AppleLocale', 'en_US']
        if seed:
            args += ['-EncryptedMemoriesUpgradeSeed']
        if self.simulator:
            result = output(['xcrun', 'simctl', 'launch', self.simulator, BUNDLE] + args)
            self.app_pid = int(result.rsplit(':', 1)[1].strip())
        else:
            # XCTest owns the LaunchServices start and passes these arguments to that exact app.
            self.launch_arguments = args

    def ended_reason(self):
        """Describe the app that simctl launched when its process is gone; None while it runs or when XCTest owns the launch."""
        if not self.simulator or not hasattr(self, 'app_pid'):
            return None
        if subprocess.run(['/bin/ps', '-p', str(self.app_pid)], stdout=subprocess.DEVNULL).returncode == 0:
            return None
        try:
            lines = (self.directory / 'app.log').read_text(errors='replace').splitlines()[-5:]
        except OSError:
            lines = []
        return (f'The app process {self.app_pid} ({self.executable}) is no longer running; if it ended before activate(), XCTest '
                'starts it again without the fixture arguments. Last app log lines: ' + (' | '.join(lines) or 'none'))

    def require_running(self):
        reason = self.ended_reason()
        if reason:
            raise JourneyError(reason)

    def explain(self, message):
        """Append the ended app to a failure message, so the cause is named next to the original failure."""
        reason = self.ended_reason()
        return f'{message}; {reason}' if reason else message

    def macos_app_pid(self):
        if not hasattr(self, 'installed'):
            return None
        info = plistlib.loads((self.installed / 'Contents/Info.plist').read_bytes())
        binary = str(self.installed / 'Contents/MacOS' / info['CFBundleExecutable'])
        matches = []
        for line in output(['/bin/ps', '-axo', 'pid=,comm=']).splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) == 2 and fields[1] == binary:
                matches.append(int(fields[0]))
        if len(matches) > 1:
            raise JourneyError('Multiple processes use the exact owned macOS app bundle')
        return matches[0] if matches else None

    def kill_app(self):
        if self.simulator:
            # simctl launch reports a host PID. Check its exact device-owned executable before SIGKILL.
            bundle = output(['xcrun', 'simctl', 'get_app_container', self.simulator, BUNDLE, 'app'])
            executable = output(['/bin/ps', '-ww', '-p', str(self.app_pid), '-o', 'comm='])
            if not executable.startswith(bundle + '/'):
                raise JourneyError('Refusing to kill a process outside the owned Simulator app bundle')
            os.kill(self.app_pid, signal.SIGKILL)
        else:
            app_pid = self.macos_app_pid()
            if app_pid is None:
                raise JourneyError('The old macOS app exited before the selected interruption')
            os.kill(app_pid, signal.SIGKILL)

    def close(self):
        if self.app_log:
            stop_group(self.app_log)
            self.app_log_file.close()
            self.app_log = None
        if self.simulator:
            try:
                command(['xcrun', 'simctl', 'shutdown', self.simulator])
            finally:
                command(['xcrun', 'simctl', 'delete', self.simulator])
                self.simulator = None
        else:
            app_pid = self.macos_app_pid()
            if app_pid is not None:
                os.kill(app_pid, signal.SIGTERM)


def ui_run(runner, destination, point, phase, evidence, app_path=None, launch_arguments=None):
    def resolve(value):
        if isinstance(value, str):
            return value.replace('__TESTROOT__', str(runner.parent))
        if isinstance(value, dict):
            return {key: resolve(item) for key, item in value.items()}
        if isinstance(value, list):
            return [resolve(item) for item in value]
        return value
    payload = resolve(plistlib.loads(runner.read_bytes()))
    def configure(value):
        if isinstance(value, dict):
            if value.get('IsUITestBundle'):
                if phase == 'prepare' and destination.startswith('platform=iOS Simulator,'):
                    # XCTest's automatic recording ended at the kill point, and SimRenderServer crashed in both runs at that moment.
                    value['PreferredScreenCaptureFormat'] = 'screenshots'
                value.setdefault('EnvironmentVariables', {}).update(
                    UPGRADE_POINT=point, UPGRADE_PHASE=phase, UPGRADE_APP_PATH=str(app_path or ''),
                    UPGRADE_APP_ARGUMENTS=json.dumps(launch_arguments or []),
                    DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
            for item in value.values():
                configure(item)
        elif isinstance(value, list):
            for item in value:
                configure(item)
    configure(payload)
    configured = evidence / (phase + '.xctestrun')
    configured.write_bytes(plistlib.dumps(payload))
    log = open(evidence / (phase + '-ui.log'), 'w')
    process = owned_process(['xcrun', 'xcodebuild', 'test-without-building', '-xctestrun', str(configured),
                             '-destination', destination, '-parallel-testing-enabled', 'NO',
                             '-resultBundlePath', str(evidence / (phase + '.xcresult'))], log)
    return process, log


def wait_ui_test_start(process, log, label, reached=None, timeout=UI_STARTUP_SECONDS, app_check=None):
    """Return the seconds until XCTest started a test case, the run exited, or the app reached its checkpoint.

    `app_check` raises as soon as the app that the host launched has ended."""
    started = time.monotonic()
    event = 'exited'
    while process.poll() is None:
        if app_check is not None:
            try:
                app_check()
            except JourneyError as error:
                raise JourneyError(f'{label}: {error}') from error
        if reached is not None and reached.is_set():
            event = 'reached its checkpoint'
            break
        if log.exists() and UI_TEST_STARTED.search(log.read_text(errors='replace')):
            event = 'started its first test case'
            break
        if time.monotonic() - started >= timeout:
            raise JourneyError(f'{label}: xcodebuild did not start the UI test within {timeout} s')
        time.sleep(0.5)
    elapsed = round(time.monotonic() - started)
    print(f'{label}: the UI run {event} after {elapsed} s', flush=True)
    return elapsed


def main():
    if sys.argv[1:] == ['--list-points']:
        # The one list of interruption points. The release workflow builds its job matrix from this output.
        print(' '.join(POINTS))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--automation', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--target', required=True)
    parser.add_argument('--sources', nargs='+', required=True)
    parser.add_argument('--platform', choices=['iOS', 'macOS'], required=True)
    parser.add_argument('--points', nargs='+', choices=POINTS, default=POINTS)
    parser.add_argument('--working-copy', action='store_true')
    parser.add_argument('--release-tag', default=os.environ.get('UPGRADE_RELEASE_TAG'),
                        help='Published metadata for the candidate; required when its commit has no unique tag')
    args = parser.parse_args()
    toolchain = output(['xcodebuild', '-version'])
    summary('Xcode toolchain: ' + toolchain.replace('\n', '; '))
    summary('Listen backlog limit kern.ipc.somaxconn: ' + output(['sysctl', '-n', 'kern.ipc.somaxconn']))
    if args.platform == 'macOS':
        command(['xcrun', 'swift', str(args.automation / 'scripts/upgrade-test/metal_devices.swift')])
    summary(CONSENT_LIMITATION)
    summary(LIMITATION)
    summary(METADATA_SCOPE)
    for path in [args.root / 'scratch', args.root / 'evidence']:
        path.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(args.automation / '.github/scripts'))
    from keychain_entitlements import compare_groups, snapshot
    stable = [tag for tag in args.sources if re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag)]
    if not stable:
        raise JourneyError('No supported stable upgrade source was selected')
    previous = max(stable, key=lambda tag: tuple(map(int, tag[1:].split('.'))))
    compare_groups(snapshot(args.repo, previous),
                   snapshot(args.repo, None if args.working_copy else args.target))
    summary(f'Keychain access groups match {previous} (macOS and iOS).')
    metadata = release_metadata(args.repo, args.automation, args.release_tag or args.target)
    if args.working_copy:
        summary(f'Local working-copy rehearsal uses published metadata from {metadata["tag"]}; its source changes are not a shipping artifact.')
    current = build_app(args.repo, args.automation, args.target, args.platform, args.root,
                        historical=False, working_copy=args.working_copy, metadata=metadata)
    predecessors = {tag: build_app(args.repo, args.automation, tag, args.platform, args.root) for tag in args.sources}
    # Build the standalone UI runner from the current release, without an app dependency.
    source = current.source
    if source is None:
        raise JourneyError('The current build has no source for its UI runner')
    # Replace the whole directory so a cached source cannot keep a removed or renamed UI-test file.
    shutil.rmtree(source / 'UpgradeUITests', ignore_errors=True)
    shutil.copytree(args.automation / 'scripts/upgrade-test/UITests', source / 'UpgradeUITests')
    dd = source.parent / 'build/DerivedData.noindex'
    sdk = 'iphonesimulator' if args.platform == 'iOS' else 'macosx'
    command(['xcrun', 'xcodebuild', 'build-for-testing', '-project', 'EncryptedMemories.xcodeproj',
             '-scheme', 'UpgradeJourney', '-configuration', 'Release', '-sdk', sdk,
             '-destination', 'generic/platform=iOS Simulator' if args.platform == 'iOS' else 'platform=macOS',
             '-derivedDataPath', str(dd),
             '-clonedSourcePackagesDirPath', str(source.parent / 'build/SourcePackages.noindex'),
             '-packageCachePath', str(source.parent / 'build/XcodePackageCache.noindex'),
             '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
             'CODE_SIGN_IDENTITY=-', 'ENABLE_HARDENED_RUNTIME=NO',
             'ARCHS=' + output(['uname', '-m']), 'ONLY_ACTIVE_ARCH=YES'], cwd=source)
    runners = list((dd / 'Build/Products').glob('*.xctestrun'))
    if len(runners) != 1:
        raise JourneyError('Expected exactly one standalone UI runner')
    runner = runners[0]
    signer = SigningIdentity(args.root) if args.platform == 'macOS' else None
    if signer:
        signer.__enter__()
    evidence_root = args.root / 'evidence' / uuid.uuid4().hex
    try:
        evidence_root.mkdir(parents=True)
        (evidence_root / 'toolchain.json').write_text(json.dumps({
            'xcode': toolchain, 'platform': args.platform, 'target': args.target}) + '\n')
        (evidence_root / 'build-metadata.json').write_text(json.dumps({
            name: {'source_commit': build.commit, 'release': build.metadata,
                   'built': verify_bundle_metadata(build.app, args.platform, build.metadata, 'built evidence')}
            for name, build in [('candidate', current), *predecessors.items()]}, indent=2) + '\n')
        print(f'Free disk after the builds: {free_gib():.1f} GiB', flush=True)
        sample_runner(evidence_root / 'runner-load.log', args.root)

        def execute(tag, point):
            case = evidence_root / args.platform / tag / point
            case.mkdir(parents=True, exist_ok=True)
            timing = {'started': time.strftime('%H:%M:%S')}
            case_started = time.monotonic()
            passed = False
            with FixtureServer(case, point) as server:
                app = InstalledApp(args.platform, case, signer)
                preparing = None
                try:
                    app.install(predecessors[tag].app)
                    app.verify_metadata(predecessors[tag].metadata, 'old', predecessors[tag].commit)
                    app.launch(server, seed=True)
                    preparing, prepare_log = ui_run(runner, app.destination, point, 'prepare', case, getattr(app, 'installed', None), app.launch_arguments)
                    timing['prepare_ui_startup_s'] = wait_ui_test_start(
                        preparing, case / 'prepare-ui.log', f'{tag} / {point} preparation', server.reached,
                        app_check=app.require_running)
                    # The consent wait below also ends within this budget, before the server releases its held checkpoint.
                    preparation_deadline = time.monotonic() + PREPARATION_SECONDS
                    try:
                        server.wait_checkpoint(timeout=max(0, preparation_deadline - time.monotonic()), preparing=preparing)
                    except JourneyError as error:
                        raise JourneyError(app.explain(str(error))) from error
                    saved_consent = None
                    consent_evidence = {}
                    if point.startswith('backup.'):
                        saved_consent = wait_saved_backup_consent(app.preferences_path, preparation_deadline)
                        consent_evidence['before_kill'] = saved_consent
                        (case / 'backup-consent.json').write_text(json.dumps(consent_evidence) + '\n')
                    app.kill_app()
                    stop_group(preparing)
                    prepare_log.close()
                    server.begin_upgrade()
                    app.install(current.app)
                    app.verify_metadata(current.metadata, 'new', current.commit)
                    if saved_consent is not None:
                        consent_evidence['after_install_over'] = verify_saved_backup_consent(app.preferences_path, saved_consent)
                        (case / 'backup-consent.json').write_text(json.dumps(consent_evidence) + '\n')
                    app.launch(server)
                    verifying, verify_log = ui_run(runner, app.destination, point, 'verify', case, getattr(app, 'installed', None), app.launch_arguments)
                    try:
                        timing['verify_ui_startup_s'] = wait_ui_test_start(
                            verifying, case / 'verify-ui.log', f'{tag} / {point} verification', app_check=app.require_running)
                        code = verifying.wait(timeout=VERIFICATION_SECONDS)
                        if code:
                            raise JourneyError(app.explain(f'{tag} / {point}: UI verification failed ({code})'))
                    except subprocess.TimeoutExpired as error:
                        raise JourneyError(app.explain(f'{tag} / {point}: UI verification timed out')) from error
                    finally:
                        stop_group(verifying)
                        verify_log.close()
                    if point.startswith('backup.'):
                        consent_evidence['after_ui_verification'] = verify_saved_backup_consent(app.preferences_path, saved_consent)
                        (case / 'backup-consent.json').write_text(json.dumps(consent_evidence) + '\n')
                        server.verify_uploads()
                    if point == 'model.partial':
                        server.verify_model_resume()
                    if not any(r['phase'] == 'new' and r['path'] == '/checkpoint/session.loaded' for r in server.requests):
                        raise JourneyError(f'{tag} / {point}: the replacement app did not load the saved session')
                    if any(r['path'] == '/checkpoint/network.denied' for r in server.requests):
                        raise JourneyError(f'{tag} / {point}: the app attempted an external request')
                    summary(f'PASS {args.platform}: {tag} → {args.target}, {point}')
                    passed = True
                finally:
                    if preparing:
                        stop_group(preparing)
                    app.close()
                    timing['case_s'] = round(time.monotonic() - case_started)
                    timing['free_gib'] = round(free_gib(), 1)
                    print(f'{tag} / {point}: case took {timing["case_s"]} s, free disk {timing["free_gib"]} GiB', flush=True)
                    (case / 'timing.json').write_text(json.dumps(timing) + '\n')
                    if passed:
                        # Only a failing case keeps its app log; a full gate would otherwise retain hundreds of megabytes.
                        (case / 'app.log').unlink(missing_ok=True)
        run_cases(args.sources, args.points, execute)
    finally:
        if signer:
            signer.__exit__(*sys.exc_info())


# CI cancellation must unwind the owned UI/app groups and temporary signing material.
def terminate(*_):
    # Keep caught handlers during unwind; exec resets them for cleanup subprocesses.
    # SIG_IGN would also disable termination in those subprocesses.
    signal.signal(signal.SIGTERM, lambda *_: None)
    signal.signal(signal.SIGINT, lambda *_: None)
    raise KeyboardInterrupt('Upgrade journey cancelled')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        main()
    except (JourneyError, subprocess.CalledProcessError, OSError, ValueError) as error:
        summary(f'**Upgrade check failed:** {error}. Re-run after correcting this cause, or use the explicit main-branch override.')
        raise SystemExit(1)
