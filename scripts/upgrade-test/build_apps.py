#!/usr/bin/env python3
"""Build optimized upgrade apps in separate source and SDK scratch directories."""
import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import quote

from journey import JourneyError

PAYLOAD = [
    'ProtonAuth/UpgradeTestSessionFile.swift', 'PhotosCore/UpgradeTestProbe.swift', 'ProtonDriveBackend/UpgradeTestBackend.swift',
    'PhotoLibraryBackupAdapter/UpgradeTestPhotoLibrary.swift', 'MLSearchAppleAdapter/UpgradeTestSmartSearch.swift',
]
FLAG = 'ENCRYPTED_MEMORIES_UPGRADE_TEST'


@dataclass(frozen=True)
class Build:
    app: Path
    source: Path | None
    metadata: dict | None = None
    commit: str | None = None


def clean_environment():
    environment = {key: value for key, value in os.environ.items()
                   if key in {'HOME', 'USER', 'PATH', 'DEVELOPER_DIR', 'TMPDIR', 'LANG', 'LC_ALL'}}
    # A stalled Git transfer must fail rather than hold the release or local build queue indefinitely.
    environment.update(GIT_HTTP_LOW_SPEED_LIMIT='1', GIT_HTTP_LOW_SPEED_TIME='120')
    return environment


def command(args, cwd=None, env=None):
    subprocess.run(args, cwd=cwd, env=env or clean_environment(), check=True)


def output(args, cwd=None, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env or clean_environment(), text=True).strip()


def release_metadata(repo, automation, tag):
    sha = output(['git', 'rev-parse', '--verify', '--end-of-options', tag + '^{commit}'], repo)
    if not tag.startswith('v'):
        tags = [value for value in output(['git', 'tag', '--points-at', sha], repo).splitlines() if value.startswith('v')]
        if len(tags) != 1:
            raise JourneyError('The candidate needs an explicit release tag; no unique tag matches its commit')
        tag = tags[0]
    environment = clean_environment()
    if os.environ.get('GH_TOKEN'):
        environment['GH_TOKEN'] = os.environ['GH_TOKEN']
    try:
        payload = json.loads(output(['gh', 'api', 'repos/{owner}/{repo}/releases/tags/' + quote(tag, safe='')],
                                    repo, env=environment))
    except (subprocess.CalledProcessError, OSError, ValueError) as error:
        raise JourneyError(f'{tag}: no readable published GitHub release for this tag') from error
    if not isinstance(payload, dict) or payload.get('tag_name') != tag:
        raise JourneyError(f'{tag}: the published GitHub release does not match this tag')
    if payload.get('draft') is not False or not payload.get('published_at'):
        raise JourneyError(f'{tag}: not a published GitHub release')
    result = subprocess.run(['ruby', str(automation / '.github/scripts/release_identity.rb'), sha],
                            input=json.dumps(payload), cwd=repo, env=clean_environment(),
                            capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise JourneyError(f'{tag}: {result.stderr.strip()}')
    return json.loads(result.stdout)


def verify_bundle_metadata(app, platform, release, stage):
    path = app / ('Info.plist' if platform == 'iOS' else 'Contents/Info.plist')
    try:
        info = plistlib.loads(path.read_bytes())
    except (OSError, ValueError) as error:
        raise JourneyError(f'{release["tag"]}: unreadable {stage} bundle metadata') from error
    expected = {'CFBundleShortVersionString': release['version'], 'CFBundleVersion': release['build_number']}
    if not isinstance(info, dict) or info.get('CFBundleIdentifier') != 'at.oncloud.encryptedmemories.upgrade-test':
        raise JourneyError(f'{release["tag"]}: {stage} bundle does not have the test identifier')
    for key, value in expected.items():
        if type(info.get(key)) is not str or info[key] != value:
            raise JourneyError(f'{release["tag"]}: {stage} {key} must equal {value!r}; got {info.get(key)!r}')
    return {key: info[key] for key in expected}


def harness_digest(automation):
    files = [automation / name for name in ['scripts/upgrade-test/build_apps.py',
             '.github/scripts/release_identity.rb', '.github/scripts/release_build_number.rb']]
    files += list((automation / 'scripts/upgrade-test/overlays').rglob('*'))
    files += [automation / 'Packages/EncryptedMemoriesKit/Sources' / name for name in PAYLOAD]
    digest = hashlib.sha256()
    for path in sorted(files):
        if path.is_file() and '__pycache__' not in path.parts:
            digest.update(str(path.relative_to(automation)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def source_tree(repo, sha, destination, working_copy=False):
    destination.mkdir(parents=True)
    archive = destination.parent / 'source.tar'
    command(['git', 'archive', '-o', str(archive), sha], cwd=repo)
    with tarfile.open(archive) as tree:
        tree.extractall(destination, filter='data')
    archive.unlink()
    if working_copy:
        # Rehearsal only. CI always extracts the exact release commit.
        patch = subprocess.check_output(['git', 'diff', '--binary', 'HEAD'], cwd=repo)
        if patch:
            subprocess.run(['git', 'apply', '-'], input=patch, cwd=destination, check=True)
        for relative in output(['git', 'ls-files', '--others', '--exclude-standard'], repo).splitlines():
            source = repo / relative
            if source.is_file():
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)


def apply_overlay(source, automation, tag, sha):
    manifest = json.loads((automation / 'scripts/upgrade-test/overlays/versions.json').read_text())
    sentinel = source / 'Packages/EncryptedMemoriesKit/Sources/PhotosCore/UpgradeTestProbe.swift'
    # A release with its own test entry needs an overlay only when its tag has a reviewed one.
    has_test_entry = sentinel.exists()
    if has_test_entry and tag not in manifest:
        return
    if tag not in manifest or manifest[tag]['commit'] != sha:
        raise JourneyError(f'{tag}: no reviewed overlay for commit {sha}')
    patch = automation / 'scripts/upgrade-test/overlays' / (tag + '.patch')
    command(['git', 'apply', '--check', '--unidiff-zero', str(patch)], cwd=source)
    command(['git', 'apply', '--unidiff-zero', str(patch)], cwd=source)
    if has_test_entry:
        return
    for relative in PAYLOAD:
        target = source / 'Packages/EncryptedMemoriesKit/Sources' / relative
        shutil.copy2(automation / 'Packages/EncryptedMemoriesKit/Sources' / relative, target)


def test_project(source, automation, platform):
    project = source / 'project.yml'
    text = project.read_text()
    shipping_id = 'PRODUCT_BUNDLE_IDENTIFIER: at.oncloud.encryptedmemories\n'
    if text.count(shipping_id) != 2 or FLAG in text:
        raise JourneyError('The source must retain the ordinary archive configuration')
    text = text.replace(shipping_id, 'PRODUCT_BUNDLE_IDENTIFIER: at.oncloud.encryptedmemories.upgrade-test\n')
    ui = source / 'UpgradeUITests'
    ui.mkdir()
    shutil.copytree(automation / 'scripts/upgrade-test/UITests', ui, dirs_exist_ok=True)
    target = f'''  UpgradeJourneyUITests:
    type: bundle.ui-testing
    platform: {platform}
    deploymentTarget: "26.0"
    sources:
      - UpgradeUITests
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: at.oncloud.encryptedmemories.upgrade-test.runner
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGNING_ALLOWED: YES
        CODE_SIGN_IDENTITY: "-"

'''
    text = text.replace('schemes:\n', target + 'schemes:\n', 1)
    text += '''
  UpgradeJourney:
    build:
      targets:
        UpgradeJourneyUITests: [test]
    test:
      config: Release
      targets:
        - UpgradeJourneyUITests
'''
    project.write_text(text)
    for relative in ['App/Info.plist', 'iOSApp/Info.plist']:
        path = source / relative
        value = plistlib.loads(path.read_bytes())
        value['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True,
            'NSExceptionDomains': {'127.0.0.1': {'NSExceptionAllowsInsecureHTTPLoads': True}}}
        path.write_bytes(plistlib.dumps(value))


def build_app(repo, automation, tag, platform, root, historical=True, working_copy=False, metadata=None):
    sha = output(['git', 'rev-parse', tag + '^{commit}'], repo)
    metadata = metadata or release_metadata(repo, automation, tag)
    if metadata['commit'] != sha and not working_copy:
        raise JourneyError(f'{tag}: the source commit does not match published release {metadata["tag"]}')
    toolchain = output(['xcodebuild', '-version'])
    identity = hashlib.sha256((sha + toolchain + platform + output(['uname', '-m'])
                               + harness_digest(automation) + json.dumps(metadata, sort_keys=True)).encode()).hexdigest()
    if working_copy:
        app_paths = ['App', 'iOSApp', 'Shared', 'Packages', 'project.yml',
                     'scripts/update-proton-sdk.sh', 'scripts/build-paths.sh']
        digest = hashlib.sha256(subprocess.check_output(['git', 'diff', '--binary', 'HEAD', '--', *app_paths], cwd=repo))
        for relative in output(['git', 'ls-files', '--others', '--exclude-standard', '--', *app_paths], repo).splitlines():
            path = repo / relative
            if path.is_file():
                digest.update(relative.encode())
                digest.update(path.read_bytes())
        identity = hashlib.sha256((identity + digest.hexdigest()).encode()).hexdigest()
    product = root / 'products' / platform / identity
    if (product / 'complete.json').exists():
        cached = json.loads((product / 'complete.json').read_text())
        app = product / cached['app']
        if cached['identity'] != identity or cached.get('commit') != sha or cached.get('release') != metadata or not app.is_dir():
            raise JourneyError(f'{tag}: invalid historical app cache')
        verify_bundle_metadata(app, platform, metadata, 'cached')
        source = Path(cached['source']) if cached.get('source') else None
        if historical or (source and source.is_dir()):
            return Build(app, None if historical else source, metadata, sha)
    scratch = Path(tempfile.mkdtemp(prefix=f'{tag.replace("/", "_")}-{platform}-', dir=root / 'scratch'))
    source = scratch / 'source'
    source_tree(repo, sha, source, working_copy=working_copy)
    apply_overlay(source, automation, tag, sha)
    test_project(source, automation, platform)
    env = clean_environment()
    env.update(ENCRYPTED_MEMORIES_BUILD_ROOT=str(scratch / 'build'),
               DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
    # Each tag runs its own SDK restore script with its own default pin and scratch.
    command(['bash', 'scripts/update-proton-sdk.sh'], cwd=source, env=env)
    command(['xcodegen', 'generate'], cwd=source, env=env)
    command(['bash', '-c', 'source scripts/build-paths.sh; encryptedmemories_pin_generated_project_packages "$PWD"'], cwd=source, env=env)
    sdk = 'iphonesimulator' if platform == 'iOS' else 'macosx'
    scheme = 'EncryptedMemoriesMobile' if platform == 'iOS' else 'EncryptedMemories'
    destination = 'generic/platform=iOS Simulator' if platform == 'iOS' else 'platform=macOS'
    dd = scratch / 'build/DerivedData.noindex'
    command(['xcrun', 'xcodebuild', '-resolvePackageDependencies',
             '-project', 'EncryptedMemories.xcodeproj', '-scheme', scheme,
             '-clonedSourcePackagesDirPath', str(scratch / 'build/SourcePackages.noindex'),
             '-packageCachePath', str(scratch / 'build/XcodePackageCache.noindex'),
             '-onlyUsePackageVersionsFromResolvedFile'], cwd=source, env=env)
    signing = ['CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-'] if platform == 'iOS' else ['CODE_SIGNING_ALLOWED=NO']
    command(['xcrun', 'xcodebuild', 'build', '-project', 'EncryptedMemories.xcodeproj',
             '-scheme', scheme, '-configuration', 'Release', '-sdk', sdk, '-destination', destination,
             '-derivedDataPath', str(dd), '-clonedSourcePackagesDirPath', str(scratch / 'build/SourcePackages.noindex'),
             '-packageCachePath', str(scratch / 'build/XcodePackageCache.noindex'),
             '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
             '-skipPackagePluginValidation', '-skipMacroValidation',
             *signing, 'MARKETING_VERSION=' + metadata['version'],
             'CURRENT_PROJECT_VERSION=' + metadata['build_number'],
             'SWIFT_ACTIVE_COMPILATION_CONDITIONS=' + FLAG,
             'SWIFT_OPTIMIZATION_LEVEL=-O', 'ARCHS=' + output(['uname', '-m']), 'ONLY_ACTIVE_ARCH=YES'], cwd=source, env=env)
    built = dd / 'Build/Products' / ('Release-iphonesimulator' if platform == 'iOS' else 'Release')
    apps = [path for path in built.glob('*.app') if 'Runner' not in path.name]
    if len(apps) != 1:
        raise JourneyError(f'{tag}: expected one built app, found {len(apps)}')
    verify_bundle_metadata(apps[0], platform, metadata, 'built')
    app = publish_product(apps[0], product, {'identity': identity, 'commit': sha, 'app': apps[0].name,
                                             'source': str(source) if not historical else None, 'release': metadata})
    if historical:
        # A historical journey needs only its published app. Its source, SDK and derived data take several GiB on
        # a hosted runner whose disk also holds every case's Simulator.
        shutil.rmtree(scratch)
        return Build(app, None, metadata, sha)
    return Build(app, source, metadata, sha)


def publish_product(built, product, record):
    """Only finished products enter the historical cache. Source, SDK and partial builds remain separate."""
    # A restored cache can already hold this product without its source, so the candidate is rebuilt. Copying over
    # it fails on the framework symlinks of a macOS bundle; replace the old copy, and mark it complete only after.
    product.mkdir(parents=True, exist_ok=True)
    (product / 'complete.json').unlink(missing_ok=True)
    app = product / built.name
    if app.exists():
        shutil.rmtree(app)
    shutil.copytree(built, app, symlinks=True)
    (product / 'complete.json').write_text(json.dumps(record) + '\n')
    return app


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--automation', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--platform', choices=['iOS', 'macOS'], required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--working-copy', action='store_true')
    parser.add_argument('--release-tag', help='Published metadata for the candidate; required when its commit has no unique tag')
    args = parser.parse_args()
    (args.root / 'scratch').mkdir(parents=True, exist_ok=True)
    print(build_app(args.repo.resolve(), args.automation.resolve(), args.tag, args.platform,
                    args.root.resolve(), historical=not args.working_copy, working_copy=args.working_copy,
                    metadata=release_metadata(args.repo.resolve(), args.automation.resolve(), args.release_tag or args.tag)).app)
