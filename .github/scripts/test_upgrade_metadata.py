#!/usr/bin/env python3
"""Verify release-derived probe metadata at build, cache, and installed boundaries."""
import json
import io
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/upgrade-test'))
import build_apps
import run_journey
from journey import JourneyError

REPO = Path(__file__).resolve().parents[2]
SHA = 'a' * 40
RELEASE = {'tag': 'v1.0.5', 'version': '1.0.5', 'build_number': '390000001',
           'release_id': 390000001, 'commit': SHA}
BUNDLE = 'at.oncloud.encryptedmemories.upgrade-test'


def write_bundle(app, platform, version='1.0.5', build='390000001'):
    path = app / ('Info.plist' if platform == 'iOS' else 'Contents/Info.plist')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps({'CFBundleIdentifier': BUNDLE,
        'CFBundleShortVersionString': version, 'CFBundleVersion': build}))


class UpgradeMetadataTests(unittest.TestCase):
    def build_fixture(self, root, platform, fallback=False, release=RELEASE):
        def output(args, cwd=None):
            if args[0] == 'git' and args[1] == 'rev-parse':
                return SHA
            if args[0] == 'git':
                return ''
            if args[0] == 'xcodebuild':
                return 'Xcode 27.1\nBuild version 27A9275'
            if args[0] == 'uname':
                return 'arm64'
            raise AssertionError(args)

        def command(args, cwd=None, env=None):
            if args[:3] == ['xcrun', 'xcodebuild', 'build']:
                products = Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products'
                products /= 'Release-iphonesimulator' if platform == 'iOS' else 'Release'
                settings = dict(value.split('=', 1) for value in args if '=' in value)
                write_bundle(products / 'fixture.app', platform,
                    '1.0.3' if fallback else settings.get('MARKETING_VERSION', '1.0.3'),
                    '713' if fallback else settings.get('CURRENT_PROJECT_VERSION', '713'))

        (root / 'scratch').mkdir(exist_ok=True)
        with patch.object(build_apps, 'output', side_effect=output), \
                patch.object(build_apps, 'command', side_effect=command), \
                patch.object(build_apps, 'source_tree', side_effect=lambda repo, sha, destination, **_: destination.mkdir()), \
                patch.object(build_apps, 'apply_overlay'), patch.object(build_apps, 'test_project'), \
                patch.object(build_apps, 'harness_digest', return_value='harness'), \
                patch.object(build_apps, 'release_metadata', return_value=release, create=True):
            return build_apps.build_app(REPO, REPO, release['tag'], platform, root)

    def test_build_uses_release_values_instead_of_the_project_fallback_on_both_platforms(self):
        for platform in ['iOS', 'macOS']:
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                built = self.build_fixture(Path(directory), platform)
                path = built.app / ('Info.plist' if platform == 'iOS' else 'Contents/Info.plist')
                info = plistlib.loads(path.read_bytes())
                self.assertEqual(info['CFBundleShortVersionString'], RELEASE['version'])
                self.assertEqual(info['CFBundleVersion'], RELEASE['build_number'])

    def test_inherited_fallback_is_rejected_before_a_product_enters_the_cache(self):
        for platform in ['iOS', 'macOS']:
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with self.assertRaisesRegex(JourneyError, 'CFBundleShortVersionString'):
                    self.build_fixture(root, platform, fallback=True)
                self.assertFalse(list(root.rglob('complete.json')))

    def test_cache_rechecks_the_actual_bundle_even_when_its_completion_record_is_valid(self):
        for platform in ['iOS', 'macOS']:
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                built = self.build_fixture(root, platform)
                write_bundle(built.app, platform, build='713')
                with self.assertRaisesRegex(JourneyError, 'CFBundleVersion'):
                    self.build_fixture(root, platform)

    def test_releases_of_one_commit_have_distinct_cached_products(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            beta = dict(RELEASE, tag='v1.1.0-beta.3', version='1.1.0')
            stable = dict(beta, tag='v1.1.0', build_number='390000002', release_id=390000002)
            first = self.build_fixture(root, 'macOS', release=beta)
            second = self.build_fixture(root, 'macOS', release=stable)
            self.assertNotEqual(first.app.parent, second.app.parent)

    def test_installed_checks_read_the_owned_simulator_bundle_and_the_copied_macos_bundle(self):
        for platform in ['iOS', 'macOS']:
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                installed = root / 'installed.app'
                write_bundle(installed, platform)
                app = run_journey.InstalledApp.__new__(run_journey.InstalledApp)
                app.platform, app.directory = platform, root
                app.simulator = 'OWN-DEVICE' if platform == 'iOS' else None
                app.installed = installed
                with patch.object(run_journey, 'output', return_value=str(installed)) as output:
                    app.verify_metadata(RELEASE, 'old')
                if platform == 'iOS':
                    output.assert_called_once_with(['xcrun', 'simctl', 'get_app_container', 'OWN-DEVICE', BUNDLE, 'app'])
                evidence = json.loads((root / 'old-bundle.json').read_text())
                self.assertEqual(evidence['expected'], RELEASE)
                self.assertEqual(evidence['installed']['CFBundleVersion'], RELEASE['build_number'])
                write_bundle(installed, platform, build='713')
                with patch.object(run_journey, 'output', return_value=str(installed)):
                    with self.assertRaisesRegex(JourneyError, 'CFBundleVersion'):
                        app.verify_metadata(RELEASE, 'new')

    def test_wrong_installed_values_stop_before_the_corresponding_phase_launch_or_ui_step(self):
        for wrong_phase in ['old', 'new']:
            # The journey's runner sampler can still write its load log while this directory is removed.
            with self.subTest(phase=wrong_phase), tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as directory:
                root = Path(directory)
                steps = []
                source = root / 'source'
                (source / 'UpgradeUITests').mkdir(parents=True)
                products = root / 'build/DerivedData.noindex/Build/Products'
                products.mkdir(parents=True)
                (products / 'runner.xctestrun').touch()
                old, new = root / 'old.app', root / 'new.app'
                for bundle in [old, new]:
                    write_bundle(bundle, 'macOS')
                builds = [build_apps.Build(new, source, RELEASE, SHA), build_apps.Build(old, None, RELEASE, SHA)]
                verify = run_journey.InstalledApp.verify_metadata

                class InstalledFixture:
                    destination = 'platform=macOS'

                    def __init__(self, platform, directory, signer):
                        self.platform, self.directory, self.simulator = platform, directory, None
                        self.installed = directory / 'installed.app'
                        self.launch_arguments = []
                        self.phase = 'old'

                    def install(self, bundle):
                        self.phase = 'old' if bundle == old else 'new'
                        write_bundle(self.installed, 'macOS', build='713' if self.phase == wrong_phase else RELEASE['build_number'])

                    verify_metadata = verify

                    def launch(self, server, seed=False):
                        steps.append('launch-' + self.phase)

                    def require_running(self):
                        pass

                    def explain(self, message):
                        return message

                    def kill_app(self):
                        steps.append('kill-old')

                    def close(self):
                        pass

                class ServerFixture:
                    requests = [{'phase': 'new', 'path': '/checkpoint/session.loaded'}]
                    reached = None
                    def __init__(self, *args):
                        pass
                    def __enter__(self):
                        return self
                    def __exit__(self, *args):
                        pass
                    def wait_checkpoint(self, **kwargs):
                        pass
                    def begin_upgrade(self):
                        pass

                class ProcessFixture:
                    def poll(self):
                        return 0
                    def wait(self, **kwargs):
                        return 0

                def ui(*args):
                    steps.append('ui-' + args[3])
                    return ProcessFixture(), io.StringIO()

                arguments = ['run_journey', '--repo', str(REPO), '--automation', str(REPO), '--root', str(root),
                    '--target', 'HEAD', '--release-tag', 'v1.0.5', '--sources', 'v1.0.5', '--platform', 'macOS', '--points', 'index.embed']
                with patch.object(sys, 'argv', arguments), patch.object(run_journey, 'release_metadata', return_value=RELEASE), \
                        patch.object(run_journey, 'build_app', side_effect=builds), patch.object(run_journey, 'command'), \
                        patch.object(run_journey, 'output', return_value='arm64'), patch.object(run_journey, 'SigningIdentity'), \
                        patch.object(run_journey, 'InstalledApp', InstalledFixture), patch.object(run_journey, 'FixtureServer', ServerFixture), \
                        patch.object(run_journey, 'ui_run', side_effect=ui), patch('keychain_entitlements.snapshot', return_value={}):
                    with self.assertRaisesRegex(JourneyError, 'installed ' + wrong_phase + ' CFBundleVersion'):
                        run_journey.main()
                self.assertEqual(steps, [] if wrong_phase == 'old' else ['launch-old', 'ui-prepare', 'kill-old'])

    def test_missing_nonstring_and_incorrect_values_fail_closed(self):
        for key in ['CFBundleShortVersionString', 'CFBundleVersion']:
            for invalid in [None, 713, True, '', 'wrong']:
                with self.subTest(key=key, invalid=invalid), tempfile.TemporaryDirectory() as directory:
                    app = Path(directory) / 'fixture.app'
                    write_bundle(app, 'macOS')
                    path = app / 'Contents/Info.plist'
                    info = plistlib.loads(path.read_bytes())
                    if invalid is None:
                        del info[key]
                    else:
                        info[key] = invalid
                    path.write_bytes(plistlib.dumps(info))
                    with self.assertRaisesRegex(JourneyError, key):
                        build_apps.verify_bundle_metadata(app, 'macOS', RELEASE, 'built')

    def test_release_metadata_uses_the_shared_shipping_helper_and_actual_tag_commit(self):
        payload = {'id': 390000001, 'tag_name': 'v1.0.5', 'draft': False,
                   'published_at': '2026-09-01T10:00:00Z', 'prerelease': False}
        with patch.object(build_apps, 'output', side_effect=[SHA, json.dumps(payload)]), \
                patch.object(build_apps.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(RELEASE), '')) as ruby:
            result = build_apps.release_metadata(REPO, REPO, 'v1.0.5')
        self.assertEqual(result, RELEASE)
        self.assertEqual(ruby.call_args.args[0], ['ruby', str(REPO / '.github/scripts/release_identity.rb'), SHA])
        self.assertEqual(json.loads(ruby.call_args.kwargs['input']), payload)
        self.assertEqual(ruby.call_args.kwargs['cwd'], REPO)

    def test_missing_or_nonmatching_published_release_never_uses_fallback_metadata(self):
        with patch.object(build_apps, 'output', side_effect=[SHA, subprocess.CalledProcessError(1, ['gh'])]):
            with self.assertRaisesRegex(JourneyError, 'no readable published GitHub release'):
                build_apps.release_metadata(REPO, REPO, 'v1.0.5')
        valid = {'id': 390000001, 'tag_name': 'v1.0.5', 'draft': False,
                 'published_at': '2026-09-01T10:00:00Z', 'prerelease': False}
        for payload in [dict(valid, tag_name='v1.0.4'), {}, None, [],
                        dict(valid, draft=True), dict(valid, published_at=None)]:
            with self.subTest(payload=payload), patch.object(build_apps, 'output', side_effect=[SHA, json.dumps(payload)]), \
                    patch.object(build_apps.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(RELEASE), '')) as ruby:
                with self.assertRaisesRegex(JourneyError, 'published GitHub release'):
                    build_apps.release_metadata(REPO, REPO, 'v1.0.5')
                ruby.assert_not_called()

    def test_a_source_commit_mismatch_fails_before_any_build_command(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(build_apps, 'output', return_value='b' * 40), \
                patch.object(build_apps, 'command') as command:
            with self.assertRaisesRegex(JourneyError, 'source commit does not match'):
                build_apps.build_app(REPO, REPO, 'HEAD', 'macOS', Path(directory), metadata=RELEASE)
            command.assert_not_called()

    def test_unreleased_or_ambiguous_candidate_needs_an_explicit_release_tag(self):
        for tags in ['', 'v1.1.0-beta.3\nv1.1.0']:
            with self.subTest(tags=tags), patch.object(build_apps, 'output', side_effect=[SHA, tags]):
                with self.assertRaisesRegex(JourneyError, 'explicit release tag'):
                    build_apps.release_metadata(REPO, REPO, 'HEAD')

    def test_native_seed_caller_uses_explicit_release_metadata_for_untagged_head(self):
        import inspect
        from test_upgrade_journey import UpgradeJourneyTests

        class ReachedCandidateBuild(Exception):
            pass

        def build(repo, automation, tag, platform, root, **kwargs):
            self.assertEqual(tag, 'HEAD')
            self.assertEqual(kwargs.get('metadata'), RELEASE,
                             'The native seed caller must resolve the explicit published release')
            raise ReachedCandidateBuild()

        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
                'UPGRADE_NATIVE_SEED_TARGET': 'HEAD', 'UPGRADE_NATIVE_WORKING_COPY': '1',
                'UPGRADE_RELEASE_TAG': RELEASE['tag'], 'ENCRYPTED_MEMORIES_BUILD_ROOT': directory}), \
                patch.object(run_journey, 'output', return_value='Xcode fixture'), \
                patch.object(run_journey, 'release_metadata', return_value=RELEASE) as metadata, \
                patch.object(build_apps, 'build_app', side_effect=build):
            with self.assertRaises(ReachedCandidateBuild):
                inspect.unwrap(UpgradeJourneyTests.test_native_seed_identity_survives_restarts_and_reseeds_changed_cases_or_servers)(
                    UpgradeJourneyTests())
            metadata.assert_called_once_with(REPO, REPO, RELEASE['tag'])

    def test_native_isolation_caller_passes_release_tag_as_an_argument(self):
        import inspect
        from test_upgrade_journey import UpgradeJourneyTests

        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / 'OWN-SENTINEL'
            (home / 'tmp').mkdir(parents=True)
            devices = {'devices': {'runtime': [{'udid': 'OWN-SENTINEL', 'state': 'Booted'}]}}
            with patch.dict(os.environ, {'UPGRADE_NATIVE_TARGET': 'HEAD',
                    'UPGRADE_NATIVE_WORKING_COPY': '1', 'UPGRADE_RELEASE_TAG': RELEASE['tag']}), \
                    patch.object(run_journey, 'output', side_effect=['OWN-SENTINEL', str(home), json.dumps(devices)]), \
                    patch.object(run_journey, 'command') as command:
                inspect.unwrap(UpgradeJourneyTests.test_native_journey_keeps_another_booted_simulator)(
                    UpgradeJourneyTests())
                journeys = [call.args[0] for call in command.call_args_list if call.args[0][0] == 'bash']
                self.assertEqual(len(journeys), 1)
                self.assertIn('--release-tag', journeys[0])
                self.assertEqual(journeys[0][journeys[0].index('--release-tag') + 1], RELEASE['tag'])
                self.assertNotIn('UPGRADE_RELEASE_TAG', run_journey.clean_environment())


if __name__ == '__main__':
    unittest.main()
