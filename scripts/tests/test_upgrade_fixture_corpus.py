#!/usr/bin/env python3
"""Exercise release selection and registration without building historical releases."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
import urllib.parse
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('upgrade_corpus', ROOT / 'Tools/upgrade-fixtures/corpus.py')
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)


class ReleaseCatalogTests(unittest.TestCase):
    def test_only_public_stable_tags_are_accepted(self):
        self.assertEqual(corpus.release_version('v1.0.5'), (1, 0, 5))
        self.assertEqual(corpus.release_version('v2.10.0'), (2, 10, 0))
        for tag in ('v1.0.0', 'v1.0.4', 'v1.1.0-beta.1', 'v1.1.0-rc.1', 'v01.0.5', '../v1.0.5'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                corpus.release_version(tag)

    def test_registration_preserves_existing_release_and_rejects_retargeting(self):
        with tempfile.TemporaryDirectory(prefix='upgrade-catalog-') as temporary:
            root = Path(temporary)
            metadata = dict(release='v1.0.5', commit='7' * 40, sdk='0.29.1')
            folder = root / metadata['release']
            folder.mkdir()
            (folder / 'manifest.json').write_text(json.dumps(dict(format=1, **metadata, scenarios={})))
            (folder / 'corpus.tar.gz').write_bytes(b'synthetic archive')
            (folder / 'wal-policy-proof.json').write_text('{}')
            original = {p.name: p.read_bytes() for p in folder.iterdir()}
            catalog = corpus.release_catalog(folder, metadata)
            (root / 'releases.json').write_text(json.dumps(catalog))
            future = dict(release='v1.1.0', commit='8' * 40, sdk='0.30.0')
            updated = corpus.release_catalog(root / 'v1.1.0', future)
            self.assertEqual([r['tag'] for r in updated['releases']], ['v1.0.5', 'v1.1.0'])
            self.assertEqual(updated['releases'][0], catalog['releases'][0])
            self.assertEqual(original, {p.name: p.read_bytes() for p in folder.iterdir()})
            with self.assertRaises(ValueError):
                corpus.release_catalog(folder, dict(metadata, commit='9' * 40))
            with self.assertRaises(ValueError):
                corpus.release_catalog(root / 'v1.1.1', future)
            (root / 'v9.0.0').mkdir()
            with self.assertRaises(ValueError):
                corpus.release_catalog(root / 'v1.1.0', future)
            (root / 'v9.0.0').rmdir()
            (folder / 'corpus.tar.gz').unlink()
            with self.assertRaises(ValueError):
                corpus.release_catalog(root / 'v1.1.0', future)


    def test_pack_adds_a_release_only_after_artifacts_fit_the_budget(self):
        with tempfile.TemporaryDirectory(prefix='upgrade-pack-') as temporary:
            root = Path(temporary) / 'Fixtures'
            baseline = dict(release='v1.0.5', commit='7' * 40, sdk='0.29.1')
            old = root / baseline['release']
            old.mkdir(parents=True)
            (old / 'manifest.json').write_text(json.dumps(dict(format=1, **baseline, scenarios={})))
            (old / 'corpus.tar.gz').write_bytes(b'synthetic baseline')
            (old / 'wal-policy-proof.json').write_text('{}')
            original = {p.name: p.read_bytes() for p in old.iterdir()}
            catalog_path = root / 'releases.json'
            catalog_path.write_text(json.dumps(corpus.release_catalog(old, baseline)))
            original_catalog = catalog_path.read_bytes()
            future = dict(release='v1.1.0', commit='8' * 40, sdk='0.30.0')
            recorded = Path(temporary) / 'run' / 'recorded'
            recorded.mkdir(parents=True)
            (recorded.parent / 'recording.json').write_text(json.dumps(future))
            payload = b'synthetic half-written file'
            for scenario in corpus.SCENARIOS:
                folder = recorded / scenario
                snapshot = folder / '000001'
                snapshot.mkdir(parents=True)
                (snapshot / 'Synthetic').write_bytes(payload)
                (folder / 'events.jsonl').write_text(json.dumps(dict(id=1, kind='write', path='/Synthetic')) + '\n')
                (folder / '000001.oracle.json').write_text(json.dumps(dict(generation=1, remote=[])))
            destination = root / future['release']
            destination.mkdir()
            (destination / 'wal-policy-proof.json').write_text('{}')
            with patch.object(corpus, 'BUDGET', 1), self.assertRaisesRegex(ValueError, 'budget'):
                corpus.pack(recorded, destination)
            self.assertEqual(catalog_path.read_bytes(), original_catalog)
            with contextlib.redirect_stdout(io.StringIO()):
                corpus.pack(recorded, destination)
            catalog = json.loads(catalog_path.read_text())
            self.assertEqual([r['tag'] for r in catalog['releases']], ['v1.0.5', 'v1.1.0'])
            manifest = json.loads((destination / 'manifest.json').read_text())
            self.assertEqual(manifest['release'], future['release'])
            self.assertEqual(set(manifest['scenarios']), set(corpus.SCENARIOS))
            digest = hashlib.sha256(payload).hexdigest()
            for snapshots in manifest['scenarios'].values():
                self.assertEqual(snapshots[0]['files'], {'Synthetic': digest})
            with tarfile.open(destination / 'corpus.tar.gz', 'r:gz') as archive:
                self.assertEqual(archive.getnames(), ['blobs/' + digest])
                self.assertEqual(archive.extractfile('blobs/' + digest).read(), payload)
            self.assertEqual(original, {p.name: p.read_bytes() for p in old.iterdir()})


class PrivatePathTests(unittest.TestCase):
    """A recorded corpus must hold no local home path. The names are synthetic, and every path is built from parts so
    that this file spells no home path itself."""

    @staticmethod
    def below(folder, name, tail='x', escaped=False):
        path = '/' + folder + '/' + name + '/' + tail
        return (path.replace('/', '\\/') if escaped else path).encode()

    @classmethod
    def setUpClass(cls):
        url = cls.below('Users', 'user', 'Developer/work/data/Exports/asset-1', True)
        cls.ESCAPED = b'{"fileURL":"file:\\/\\/' + url + b'"}'

    def assertFound(self, data, category):
        self.assertEqual(corpus.private_category(data), category, data)

    def assertAllowed(self, data):
        self.assertIsNone(corpus.private_category(data), data)

    def test_a_home_path_is_found_in_every_stored_form(self):
        path = self.below('Users', 'user', 'Developer/work').decode()
        twice = urllib.parse.quote(urllib.parse.quote(path, safe=''), safe='')
        forms = {
            'plain': path.encode(),
            'JSON escaped': self.below('Users', 'user', escaped=True),
            'escaped twice': self.below('Users', 'user', escaped=True).replace(b'\\/', b'\\\\\\/'),
            'unicode escaped slash': self.below('Users', 'user', escaped=True).replace(b'\\/', b'\\u002f'),
            'percent encoded': urllib.parse.quote(path, safe='').encode(),
            'percent encoded twice': twice.encode(),
            'UTF-16 little endian': path.encode('utf-16-le'),
            'UTF-16 big endian': path.encode('utf-16-be'),
            'upper case': path.upper().encode(),
            'lower case folder': self.below('users', 'user'),
            'name starting with a unicode escape': self.below('Users', '\\u00fcnal', escaped=True),
            'in a quoted string': b'"' + path.encode() + b'"',
            'in a file URL': b'file://' + path.encode(),
            'JSON record': self.ESCAPED,
            'home folder': self.below('home', 'user', 'work'),
            'home folder escaped': self.below('home', 'user', 'work', True),
            # Stored text follows other cells and type bytes with no delimiter.
            'after a letter': b'x' + path.encode(),
            'after a digit': b'5' + path.encode(),
            'after a relative prefix': b'..' + path.encode(),
            'after a home shortcut': b'~' + path.encode(),
            'after a version letter and no digit': b'/v' + path.encode(),
        }
        for form, data in forms.items():
            with self.subTest(form=form):
                self.assertFound(data, 'home path')
    def test_the_message_names_the_category_and_the_place_and_never_the_value(self):
        with self.assertRaises(ValueError) as caught:
            corpus.check_bytes(self.ESCAPED, 'backup/Account/queue.sqlite-wal')
        self.assertEqual(str(caught.exception), 'Private home path in backup/Account/queue.sqlite-wal')

    def test_the_shared_and_runner_locations_are_allowed_in_every_form(self):
        below = self.below
        shared = '/' + 'Users' + '/Shared'
        for data in (below('Users', 'Shared', 'EncryptedMemoriesUpgradeFixtures/v1/run/data'),
                     b'file:\\/\\/' + below('Users', 'Shared', escaped=True),
                     below('Users', 'runner', 'work/repo'), below('home', 'runner', 'work', True),
                     below('USERS', 'SHARED'), shared.encode(), b'"' + shared.encode() + b'"',
                     b'file://' + shared.encode()):
            with self.subTest(data=data):
                self.assertAllowed(data)
    def test_a_name_that_only_starts_like_an_allowed_one_is_found(self):
        names = ('runnerX', 'Shared2', 'Shared.x', 'Shared-x', 'Shared\\u0020account', 'Shared\\x41', 'runner\\u0041')
        for name in names:
            with self.subTest(name=name):
                self.assertFound(self.below('Users', name), 'home path')
                self.assertFound(self.below('home', name), 'home path')

    def test_an_allowed_name_may_end_only_at_the_agreed_delimiters(self):
        shared = '/' + 'Users' + '/Shared'
        for ending in ('\\/x', '\\u002fx', '\\u002Fx', '\\n', '\\t', '\\r', ' account', '"', '/', ''):
            with self.subTest(ending=ending):
                self.assertAllowed((shared + ending).encode())

    def test_every_other_character_after_an_allowed_name_continues_it(self):
        shared = '/' + 'Users' + '/Shared'
        for ending in ("'", ':', '%', ';', ',', ')', ']', '}', '>', '?', '#', '&', '|', '%20', '%2F', '\\"', '\\u0022',
                       '\\u0020', '\\x41', 'x', '9', '.', '-'):
            with self.subTest(ending=ending):
                self.assertFound((shared + ending + 'x/y').encode(), 'home path')
    def test_an_api_route_is_no_home_path(self):
        for route in (b'/core/v4/users/me', b'/drive/v10/users/me', b'GET /api/v2/home/feed', b'/v3/' + b'users/x'):
            with self.subTest(route=route):
                self.assertAllowed(route)

    def test_a_version_segment_before_a_home_folder_hides_only_the_lowercase_route(self):
        users = b'/Us' + b'ers'
        for path in (b'/v1' + users + b'/name', b'/v12' + users + b'/name', b'/drive/v4' + users + b'/name',
                     b'https://host/core/v4' + users + b'/name', b'x/v1' + users + b'/name',
                     b'/v1' + users + b'/Shared/../name', b'/v1/USERS/name', b'/v1/Home/name', b'/v5/hOme/name',
                     b'/v123/users/name'):
            with self.subTest(path=path):
                self.assertFound(path, 'path traversal' if b'..' in path else 'home path')

    def test_a_home_path_is_found_wherever_it_stands(self):
        for prefix in (b'path=', b"('", b'x', b'5', b'..', b'~', b'/', b'//', b' '):
            with self.subTest(prefix=prefix):
                self.assertFound(prefix + self.below('Users', 'user'), 'home path')
    def test_a_home_folder_without_a_name_is_found(self):
        for data in (b'/' + b'Users' + b'/', b'"/' + b'home' + b'/"', b'/' + b'Users' + b'//x'):
            with self.subTest(data=data):
                self.assertFound(data, 'home path')

    def test_a_repeated_slash_or_a_space_before_the_name_does_not_hide_it(self):
        for folder in ('Users', 'home'):
            for gap in ('//', '///', '/ ', '/\t', '/ /'):
                data = ('/' + folder + gap + 'user' + '/x').encode()
                with self.subTest(folder=folder, gap=gap):
                    self.assertFound(data, 'home path')
                    self.assertFound(data.replace(b'/', b'\\/'), 'home path')

    def test_a_traversal_out_of_an_allowed_folder_is_found(self):
        below = self.below
        for data in (below('Users', 'Shared', '../x'), below('home', 'runner', 'a/../../x'),
                     below('Users', 'Shared', '../x', True), below('Users', 'runner', '..')):
            with self.subTest(data=data):
                self.assertFound(data, 'path traversal')

    def test_a_file_URL_with_a_host_or_outside_the_allowed_folders_is_found(self):
        self.assertFound(b'file://host/x', 'file URL with a host')
        self.assertFound(b'file://localhost/x', 'file URL with a host')
        self.assertFound(b'file:///tmp/x', 'file URL outside the shared folders')
        self.assertFound(b'FILE:///etc/passwd', 'file URL outside the shared folders')
        self.assertFound(b'file://' + b'/' + b'Users' + b'/Shared%2Fx', 'home path')
        self.assertAllowed(b'file://' + self.below('Users', 'Shared', 'x/y'))
        self.assertAllowed(b'file://' + self.below('home', 'runner', 'w'))
        self.assertAllowed(b'file://' + b'/' + b'Users' + b'/Shared')  # at the end of the data
    def test_the_other_categories_are_named(self):
        self.assertFound(b'/Volumes/Disk/x', 'volume')
        self.assertFound(b'/var/folders/ab/cd', 'temporary location')
        self.assertFound(b'/private/tmp/x', 'temporary location')
        self.assertFound(b'machine.local', 'host')
        self.assertFound(b'name.example' + b'.ts' + b'.net', 'host')
        self.assertFound(b'192.168.' + b'1.5', 'address')

    def test_a_path_inside_a_backup_issue_record_is_found(self):
        record = base64.b64encode(self.ESCAPED)
        with self.assertRaisesRegex(ValueError, 'decoded backup issue'):
            corpus.check_bytes(b'encryptedmemories-backup-issue-v1:' + record, 'label', strict_issues=True)

    def published(self, directory, member=b'clean', manifest=b'{}', proof=b'{}'):
        archive = Path(directory) / 'corpus.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            info = tarfile.TarInfo('blobs/' + 'a' * 64)
            info.size = len(member)
            tar.addfile(info, io.BytesIO(member))
        (Path(directory) / 'manifest.json').write_bytes(manifest)
        (Path(directory) / 'wal-policy-proof.json').write_bytes(proof)
        return Path(directory)

    def test_the_published_files_are_scanned_member_by_member(self):
        with tempfile.TemporaryDirectory() as directory:
            corpus.check_published(self.published(directory))
        for name, parts in (('archive member', dict(member=self.ESCAPED)),
                            ('manifest.json', dict(manifest=self.ESCAPED)),
                            ('wal-policy-proof.json', dict(proof=self.ESCAPED))):
            with self.subTest(place=name), tempfile.TemporaryDirectory() as directory:
                folder = self.published(directory, **parts)
                with self.assertRaisesRegex(ValueError, 'Private home path in .*' + name):
                    corpus.check_published(folder)

    def run_check_published(self, folder):
        return subprocess.run([sys.executable, str(ROOT / 'Tools/upgrade-fixtures/corpus.py'),
                               '--check-published', str(folder)], capture_output=True, text=True)

    def test_the_check_published_command_passes_a_clean_folder_and_fails_on_a_hit(self):
        with tempfile.TemporaryDirectory() as directory:
            clean = self.run_check_published(self.published(directory))
        self.assertEqual(clean.returncode, 0, clean.stderr)
        self.assertIn('No private path or hostname', clean.stdout)
        for place, parts in (('archive member', dict(member=self.ESCAPED)),
                             ('manifest.json', dict(manifest=self.ESCAPED)),
                             ('wal-policy-proof.json', dict(proof=self.ESCAPED))):
            with self.subTest(place=place), tempfile.TemporaryDirectory() as directory:
                hit = self.run_check_published(self.published(directory, **parts))
            self.assertNotEqual(hit.returncode, 0)
            self.assertIn('Private home path in', hit.stderr)
            self.assertIn(place, hit.stderr)
            self.assertNotIn('Developer', hit.stderr + hit.stdout)  # The value stays out of the output.

    def recording(self, root, payload, oracle=None):
        """A minimal recording whose single file holds `payload`, and a destination that already has its proof."""
        future = dict(release='v1.1.0', commit='8' * 40, sdk='0.30.0')
        recorded = root / 'run' / 'recorded'
        recorded.mkdir(parents=True)
        (recorded.parent / 'recording.json').write_text(json.dumps(future))
        for scenario in corpus.SCENARIOS:
            folder = recorded / scenario
            (folder / '000001').mkdir(parents=True)
            (folder / '000001' / 'Synthetic').write_bytes(payload)
            (folder / 'events.jsonl').write_text(json.dumps(dict(id=1, kind='write', path='/Synthetic')) + '\n')
            (folder / '000001.oracle.json').write_text(json.dumps(oracle or dict(generation=1, remote=[])))
        fixtures = root / 'Fixtures'
        baseline = fixtures / 'v1.0.5'
        baseline.mkdir(parents=True)
        metadata = dict(release='v1.0.5', commit='7' * 40, sdk='0.29.1')
        (baseline / 'manifest.json').write_text(json.dumps(dict(format=1, **metadata, scenarios={})))
        (baseline / 'corpus.tar.gz').write_bytes(b'synthetic baseline')
        (baseline / 'wal-policy-proof.json').write_text('{}')
        (fixtures / 'releases.json').write_text(json.dumps(corpus.release_catalog(baseline, metadata)))
        destination = fixtures / 'v1.1.0'
        destination.mkdir()
        return recorded, destination

    def assertNothingWritten(self, destination):
        self.assertEqual(sorted(path.name for path in destination.iterdir()), ['wal-policy-proof.json'])
        self.assertEqual([path.name for path in destination.parent.iterdir() if path.name.startswith('.pack-')], [])

    def test_the_recorder_fails_on_a_hit_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            recorded, destination = self.recording(Path(temporary), self.ESCAPED)
            (destination / 'wal-policy-proof.json').write_text('{}')
            catalog = (destination.parent / 'releases.json').read_bytes()
            with self.assertRaisesRegex(ValueError, 'Private home path in'):
                corpus.pack(recorded, destination)
            self.assertNothingWritten(destination)
            self.assertEqual((destination.parent / 'releases.json').read_bytes(), catalog)

    def test_the_recorder_fails_on_a_hit_in_the_policy_proof_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            recorded, destination = self.recording(Path(temporary), b'clean')
            (destination / 'wal-policy-proof.json').write_bytes(self.ESCAPED)
            catalog = (destination.parent / 'releases.json').read_bytes()
            with self.assertRaisesRegex(ValueError, 'wal-policy-proof.json'):
                corpus.pack(recorded, destination)
            self.assertNothingWritten(destination)
            self.assertEqual((destination.parent / 'releases.json').read_bytes(), catalog)

    def test_the_recorder_fails_on_a_hit_in_the_manifest_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            oracle = dict(generation=1, remote=[], note=self.ESCAPED.decode())
            recorded, destination = self.recording(Path(temporary), b'clean', oracle)
            (destination / 'wal-policy-proof.json').write_text('{}')
            with self.assertRaisesRegex(ValueError, 'Private home path in manifest'):
                corpus.pack(recorded, destination)
            self.assertNothingWritten(destination)

    def test_the_staged_manifest_archive_and_proof_are_scanned_before_they_move(self):
        scanned = []
        original = corpus.check_published

        def spy(folder, proof=None):
            scanned.append((folder, proof, sorted(path.name for path in folder.iterdir())))
            return original(folder, proof)

        with tempfile.TemporaryDirectory() as temporary:
            recorded, destination = self.recording(Path(temporary), b'clean')
            (destination / 'wal-policy-proof.json').write_text('{}')
            with patch.object(corpus, 'check_published', spy), contextlib.redirect_stdout(io.StringIO()):
                corpus.pack(recorded, destination)
            (folder, proof, names), = scanned
            self.assertTrue(folder.name.startswith('.pack-'))
            self.assertEqual(folder.parent, destination.parent)
            self.assertEqual(proof, destination / 'wal-policy-proof.json')
            self.assertEqual(names, ['corpus.tar.gz', 'manifest.json'])

    def test_a_staging_folder_that_an_interrupted_run_left_behind_is_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            recorded, destination = self.recording(Path(temporary), b'clean')
            (destination / 'wal-policy-proof.json').write_text('{}')
            stale = destination.parent / '.pack-interrupted'
            stale.mkdir()
            (stale / 'corpus.tar.gz').write_bytes(b'half written')
            with contextlib.redirect_stdout(io.StringIO()):
                corpus.pack(recorded, destination)
            self.assertFalse(stale.exists())
            self.assertEqual(sorted(path.name for path in destination.iterdir()),
                             ['corpus.tar.gz', 'manifest.json', 'wal-policy-proof.json'])


class ObserverTests(unittest.TestCase):
    """The recorder's observer must see a file creation however Foundation opens the file."""

    @classmethod
    def setUpClass(cls):
        if sys.platform != 'darwin':
            raise unittest.SkipTest('The observer interposes the Darwin C library')
        cls.directory = tempfile.TemporaryDirectory(prefix='upgrade-observer-')
        cls.addClassCleanup(cls.directory.cleanup)
        cls.build = Path(cls.directory.name).resolve()
        recorder = ROOT / 'Tools/upgrade-fixtures/Recorder'
        program = cls.build / 'create.c'
        program.write_text(r'''
#include <fcntl.h>
#include <unistd.h>
extern int open_dprotected_np(const char *, int, int, int, ...);
int main(int argc, char **argv) {
    int plain = open(argv[1], O_WRONLY | O_CREAT | O_EXCL, 0644);
    int protected_file = open_dprotected_np(argv[2], O_WRONLY | O_CREAT | O_EXCL, 4, 0, 0644);
    if (plain < 0 || protected_file < 0) return 1;
    return write(plain, "x", 1) == 1 && write(protected_file, "y", 1) == 1 ? 0 : 2;
}
''')
        xcode = os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
        env = dict(os.environ, DEVELOPER_DIR=xcode)
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-O2', str(recorder / 'observe.c'),
                        str(recorder / 'temporary.m'), '-framework', 'Foundation', '-lsqlite3',
                        '-o', str(cls.build / 'observe.dylib')], check=True, env=env)
        subprocess.run(['xcrun', 'clang', '-O2', str(program), '-o', str(cls.build / 'create')], check=True, env=env)

    def test_creating_a_file_with_a_data_protection_class_is_a_boundary_like_a_plain_open(self):
        root = self.build / 'root'
        output = self.build / 'recorded'
        oracle = self.build / 'oracle.json'
        root.mkdir()
        output.mkdir()
        oracle.write_text('{"generation":1,"remote":[],"complete":[],"queueKeys":[]}\n')
        env = dict(PATH=os.environ['PATH'], DYLD_INSERT_LIBRARIES=str(self.build / 'observe.dylib'),
                   UPGRADE_RECORD_ROOT=str(root), UPGRADE_RECORD_OUTPUT=str(output),
                   UPGRADE_RECORD_ORACLE=str(oracle))
        subprocess.run([str(self.build / 'create'), str(root / 'plain.bin'), str(root / 'protected.bin')],
                       check=True, env=env)
        events = [json.loads(line) for line in (output / 'events.jsonl').read_text().splitlines()]
        creations = sorted(event['path'] for event in events if event['kind'] == 'create-or-truncate')
        self.assertEqual(creations, ['/plain.bin', '/protected.bin'])


FOLDER = 'EncryptedMemoriesUpgradeFixtures'


class DataTreeTests(unittest.TestCase):
    """The recorder's cleanup removes the data tree of its own run and nothing else."""

    def bash(self, script, *arguments, env=None, cwd=None):
        return subprocess.run(['bash', '-c', 'set -euo pipefail; source "$1"; ' + script, 'bash',
                               str(ROOT / 'Tools/upgrade-fixtures/data-tree.sh'), *arguments],
                              capture_output=True, text=True, env=dict(os.environ, **(env or {})), cwd=cwd)

    def remove(self, base, release, run, env=None, cwd=None):
        return self.bash('remove_data_tree "$2" "$3" "$4"; echo after', str(base), release, run, env=env, cwd=cwd)

    def tree(self, base, release='v1.1.0', run='run.ab12'):
        (base / release / run / 'Temporary').mkdir(parents=True)
        (base / release / run / 'Temporary' / 'file').write_text('x')
        return base / release / run

    def test_a_data_folder_is_valid_only_when_absolute_clean_and_named_for_the_tool(self):
        for base, valid in (('/Users/Shared/' + FOLDER, True), ('/tmp/x/' + FOLDER, True), ('/' + FOLDER, True),
                            ('//', False), ('/', False), ('/.', False), ('/tmp/x', False), ('/tmp/x/', False),
                            ('/tmp//' + FOLDER, False), ('/tmp/./' + FOLDER, False), ('/tmp/../' + FOLDER, False),
                            (FOLDER, False), ('data/' + FOLDER, False), ('/tmp/' + FOLDER + '/', False),
                            ('/tmp/x' + FOLDER, False), ('/tmp/' + FOLDER + '/x', False), ('', False)):
            with self.subTest(base=base):
                result = self.bash('data_base_is_valid "$2" && echo valid || echo invalid', base)
                self.assertEqual(result.stdout.strip(), 'valid' if valid else 'invalid', result.stderr)

    def test_it_removes_the_tree_of_its_run_and_the_parents_that_became_empty(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary) / FOLDER
            tree = self.tree(base)
            other = self.tree(base, run='run.other')
            result = self.remove(base, 'v1.1.0', 'run.ab12')
            self.assertEqual((result.returncode, result.stdout.strip()), (0, 'after'), result.stderr)
            self.assertFalse(tree.exists())
            self.assertTrue(other.exists())
            self.remove(base, 'v1.1.0', 'run.other')
            self.assertFalse(base.exists())

    def test_it_refuses_a_run_a_release_or_a_folder_that_could_reach_something_else(self):
        # Every refused input would reach a directory that exists, so removing the refusal removes something.
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            base = parent / FOLDER
            tree = self.tree(base)
            protected = [tree, base / 'sentinel']
            (base / 'sentinel').write_text('keep')
            for victim in (base / 'v1.1.0' / 'run.', base / 'v1.1.0' / 'other', base / 'v1.1.0' / 'run.keep',
                           base / 'v1.1' / 'run.ab12', base / 'run.ab12', parent / 'run.ab12', base / 'x' / 'y',
                           parent / 'other' / 'v1.1.0' / 'run.ab12'):
                (victim / 'Temporary').mkdir(parents=True)
                protected.append(victim)
            cases = [(base, 'v1.1.0', run) for run in
                     ('..', '.', 'run.', 'run.a/..', 'run.a/../..', 'other', 'run.ab12/../run.keep')]
            cases += [(base, release, 'run.ab12') for release in ('..', 'v1.1', 'v1.1.0/..', '')]
            cases += [(Path(str(base) + '/x/../'), 'v1.1.0', 'run.ab12'), (parent / 'other', 'v1.1.0', 'run.ab12'),
                      (Path('/'), 'v1.1.0', 'run.ab12'), (Path('//'), 'v1.1.0', 'run.ab12'),
                      (Path('/.'), 'v1.1.0', 'run.ab12'), (Path('/tmp/x'), 'v1.1.0', 'run.ab12')]
            for base_argument, release, run in cases:
                with self.subTest(base=str(base_argument), release=release, run=run):
                    result = self.remove(base_argument, release, run)
                    self.assertEqual((result.returncode, result.stdout.strip()), (0, 'after'), result.stderr)
                    self.assertIn('Refusing', result.stderr)
                    for path in protected:
                        self.assertTrue(path.exists(), path)
            relative = self.remove(Path(FOLDER), 'v1.1.0', 'run.ab12', cwd=parent)
            self.assertEqual((relative.returncode, relative.stdout.strip()), (0, 'after'), relative.stderr)
            self.assertIn('Refusing', relative.stderr)
            self.assertTrue(tree.exists())

    def test_a_failed_removal_does_not_stop_the_cleanup_that_follows(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary) / FOLDER
            tree = self.tree(base)
            locked = tree / 'Temporary'
            locked.chmod(0o555)
            try:
                result = self.remove(base, 'v1.1.0', 'run.ab12')
            finally:
                locked.chmod(0o755)
            self.assertEqual((result.returncode, result.stdout.strip()), (0, 'after'), result.stderr)
            self.assertIn('could not be removed completely', result.stderr)
            self.assertTrue(tree.exists())


class RegenerateCleanupTests(unittest.TestCase):
    """regenerate.sh with stubs: its cleanup removes only the data tree of its own run, whatever the variables say."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.base = self.root / FOLDER
        stubs = self.root / 'stubs'
        stubs.mkdir()
        self.calls = self.root / 'calls'
        self.calls.write_text('')
        # git: the tag lookup, the worktree add and the worktree remove are recorded and answered.
        (stubs / 'git').write_text(f'''#!/usr/bin/env bash
echo "git $*" >> "{self.calls}"
case "$*" in
  *"rev-parse refs/tags/"*) echo {'a' * 40} ;;
  *"worktree add"*) mkdir -p "${{@: -2:1}}" ;;
  *"worktree remove"*) rm -rf "${{@: -1}}" ;;
esac
exit 0
''')
        # The build queue: record-scenario.sh would create the data tree of this run, then the scenario fails.
        self.fail_after_tree = stubs / 'queue-stub.sh'
        self.fail_after_tree.write_text(f'''#!/usr/bin/env bash
echo "queue $*" >> "{self.calls}"
mkdir -p "$UPGRADE_FIXTURE_DATA_BASE/$UPGRADE_FIXTURE_RELEASE/$UPGRADE_FIXTURE_RUN_ID/Temporary"
exit 1
''')
        # python3: the release check and the packer are real; the overlay step is replaced.
        (stubs / 'python3').write_text(f'''#!/usr/bin/env bash
case "$1" in
  *apply-overlay.py) [[ -e "{self.root}/overlay-fails" ]] && exit 1; exit 0 ;;
esac
exec {sys.executable} "$@"
''')
        for name in ('git', 'python3'):
            (stubs / name).chmod(0o755)
        self.fail_after_tree.chmod(0o755)
        self.stubs = stubs

    def regenerate(self, overlay_fails, data_base=None, **extra_environment):
        # A failing overlay ends the script before its run folder exists; otherwise the first scenario fails.
        overlay_marker = self.root / 'overlay-fails'
        overlay_marker.unlink(missing_ok=True)
        if overlay_fails:
            overlay_marker.write_text('')
        environment = dict(os.environ, PATH=f'{self.stubs}:{os.environ["PATH"]}',
                           UPGRADE_FIXTURE_BUILD_TURN=str(self.fail_after_tree),
                           ENCRYPTED_MEMORIES_BUILD_ROOT=str(self.root / 'build'),
                           UPGRADE_FIXTURE_DATA_BASE=str(data_base or self.base), **extra_environment)
        return subprocess.run(['bash', str(ROOT / 'Tools/upgrade-fixtures/regenerate.sh'), 'v1.1.0'],
                              capture_output=True, text=True, env=environment, cwd=self.root)

    def keep(self, run):
        (self.base / 'v1.1.0' / run / 'Temporary').mkdir(parents=True, exist_ok=True)
        return self.base / 'v1.1.0' / run

    def test_a_failure_before_its_own_run_exists_ignores_an_inherited_run_name(self):
        for inherited in ('run.victim', '..', 'run.victim/../run.keep'):
            with self.subTest(inherited=inherited):
                victim = self.keep('run.victim')
                result = self.regenerate(True, UPGRADE_FIXTURE_RUN_ID=inherited)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('worktree remove', self.calls.read_text(), 'the cleanup ran')
                self.assertTrue(victim.exists(), result.stderr)
                self.assertTrue(self.base.exists())

    def test_a_failure_after_the_tree_exists_removes_only_the_tree_of_this_run(self):
        victim = self.keep('run.victim')
        result = self.regenerate(False, UPGRADE_FIXTURE_RUN_ID='run.victim')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('queue ', self.calls.read_text(), 'the scenario was started')
        self.assertIn('worktree remove', self.calls.read_text(), 'the cleanup ran')
        self.assertTrue(victim.exists(), result.stderr)
        self.assertEqual(sorted(path.name for path in (self.base / 'v1.1.0').iterdir()), ['run.victim'])

    def test_an_unsafe_data_folder_is_refused_before_anything_is_recorded(self):
        for base in ('/tmp', str(self.root / 'x'), str(self.base) + '/'):
            with self.subTest(base=base):
                result = self.regenerate(False, data_base=base)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('named ' + FOLDER, result.stderr)
                # The refusal comes before the historical checkout, the overlay and the first scenario.
                self.assertEqual(self.calls.read_text(), '')


if __name__ == '__main__':
    unittest.main()
