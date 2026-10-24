#!/usr/bin/env python3
"""Pack unchanged historical snapshots. Read SQLite only in disposable copies."""
import argparse
import base64
import gzip
import hashlib
import io
import json
import re
import shutil
import sqlite3
import sys
import tarfile
import tempfile
from pathlib import Path
from urllib.parse import unquote_to_bytes

BUDGET = 15_000_000
MINIMUM_PUBLIC_RELEASE = 'v1.0.5'
SCENARIOS = ('backup', 'model', 'index', 'cache', 'location')
# What a recorded corpus must not hold. Every rule has a category, so a hit names the rule and never the value.
# Every /Users/<name> and /home/<name> is a hit, wherever it stands: stored text follows other cells and type bytes
# with no delimiter. The one exemption is an API route: the exact lowercase folder name directly after a version
# segment, such as /core/v4/users/me. A real home folder is spelled Users, so this spelling is never exempt.
ROUTE = rb'(?<!/v\d)(?<!/v\d\d)'
# What ends a complete folder name: a separator, whitespace, a double quote, an escaped slash or whitespace letter,
# or the end of the data. Every other character, and every other backslash escape, continues the name.
END = rb'(?:[/\s"]|\\(?:/|u002f|[nrt])|$)'
# A name may start with a JSON unicode escape.
NAME = rb'(?:[^/\s"\\]|\\u[0-9a-f]{4})+'
# The shared folder and the hosted runner's account are the only home folders the recorder may name.
ALLOWED = rb'(?:Users/(?:Shared|runner)|home/runner)'

def ci(pattern):
    """The pattern without regard to letter case; the flag is scoped, so a rule can still test the exact case."""
    return rb'(?i:' + pattern + rb')'

def root(names):
    """A home folder; `names` are lowercase alternatives. Only that exact spelling after /v<digits> is exempt."""
    return (rb'(?:' + ROUTE + rb'/' + ci(names) + rb'/|/(?!(?:' + names + rb')/)' + ci(names) + rb'/)')

RULES = (
    ('home path', re.compile(root(rb'users') + ci(rb'(?!(?:Shared|runner)' + END + rb')' + NAME))),
    ('home path', re.compile(root(rb'home') + ci(rb'(?!runner' + END + rb')' + NAME))),
    ('home path', re.compile(root(rb'users|home') + rb'(?=[/\s"\\]|$)')),
    ('path traversal', re.compile(ci(rb'/' + ALLOWED + rb'(?:/[^/\s"\\]*)*/\.\.' + END))),
    ('volume', re.compile(rb'/Volumes/', re.IGNORECASE)),
    ('temporary location', re.compile(rb'/private/|/var/folders/', re.IGNORECASE)),
    ('file URL with a host', re.compile(rb'file://(?!/)', re.IGNORECASE)),
    ('file URL outside the shared folders', re.compile(rb'file:///(?!' + ALLOWED + END + rb')', re.IGNORECASE)),
    ('host', re.compile(rb'[.]ts[.]net|[.]lan\b|[A-Za-z0-9_-]+\.local\b', re.IGNORECASE)),
    ('address', re.compile(
        rb'(?:192\.168|10\.\d+|172\.(?:1[6-9]|2\d|3[01])|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7]))\.\d+\.\d+')),
)

def release_version(tag):
    if not re.fullmatch(r'v(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)', tag):
        raise ValueError('Use a stable release tag without leading zeroes')
    version = tuple(map(int, tag[1:].split('.')))
    if version < (1, 0, 5):
        raise ValueError('v1.0.5 is the first public release; earlier tags are admission tests')
    return version

def release_catalog(destination, metadata):
    entry = dict(tag=metadata['release'], commit=metadata['commit'], sdk=metadata['sdk'])
    release_version(entry['tag'])
    if destination.name != entry['tag']:
        raise ValueError('The corpus must use its release folder')
    path = destination.parent / 'releases.json'
    catalog = json.loads(path.read_text()) if path.exists() else dict(format=1, minimumPublicRelease=MINIMUM_PUBLIC_RELEASE, releases=[])
    if catalog['format'] != 1 or catalog['minimumPublicRelease'] != MINIMUM_PUBLIC_RELEASE:
        raise ValueError('Invalid public release list')
    if len({record['tag'] for record in catalog['releases']}) != len(catalog['releases']):
        raise ValueError('Duplicate release in the public release list')
    entries = {}
    for record in catalog['releases'] + [entry]:
        release_version(record['tag'])
        if not re.fullmatch(r'[0-9a-f]{40}', record['commit']) or not re.fullmatch(r'[0-9]+[.][0-9]+[.][0-9]+', record['sdk']):
            raise ValueError('Invalid recorded commit or SDK')
        previous = entries.get(record['tag'])
        if previous is not None and previous != record:
            raise ValueError('A recorded release must not change commit or SDK')
        entries[record['tag']] = record
    if MINIMUM_PUBLIC_RELEASE not in entries:
        raise ValueError('Retain the first public release corpus')
    for tag, record in entries.items():
        if tag == entry['tag']:
            continue
        folder = destination.parent / tag
        manifest = json.loads((folder / 'manifest.json').read_text())
        if any(manifest[key] != record[field] for key, field in [('release', 'tag'), ('commit', 'commit'), ('sdk', 'sdk')]):
            raise ValueError('Existing release metadata differs from the release list')
        if not all((folder / name).is_file() for name in ('corpus.tar.gz', 'wal-policy-proof.json')):
            raise ValueError('Existing release corpus is incomplete')
    folders = {p.name for p in destination.parent.iterdir() if p.is_dir()}
    if folders - {entry['tag']} != set(entries) - {entry['tag']}:
        raise ValueError('Release folders and release list differ')
    catalog['releases'] = sorted(entries.values(), key=lambda record: release_version(record['tag']))
    return catalog

def unescaped(data):
    # JSON writes a slash as "\\/" or "\\u002f", and a record inside a record repeats the escape.
    data = re.sub(rb'\\u002f', b'/', data, flags=re.IGNORECASE)
    while b'\\/' in data:
        data = data.replace(b'\\/', b'/')
    return data

def views(data):
    """The data as stored, JSON-unescaped, percent-decoded once and twice, each also without NUL bytes (UTF-16)."""
    for base in (data, data.replace(b'\x00', b'')) if b'\x00' in data else (data,):
        flat = unescaped(base)
        yield base
        yield flat
        if b'%' in flat:
            decoded = unquote_to_bytes(flat)
            yield decoded
            if b'%' in decoded:
                yield unquote_to_bytes(decoded)

def private_category(data):
    for view in views(data):
        for category, rule in RULES:
            if rule.search(view):
                return category
    return None

def check_bytes(data, label, strict_issues=False):
    # The message names the category and the place, never the value.
    category = private_category(data)
    if category:
        raise ValueError(f'Private {category} in {label}')
    for encoded in re.findall(rb'encryptedmemories-backup-issue-v1:([A-Za-z0-9+/]+={0,2})', data):
        if not strict_issues:
            # A raw SQLite page can end inside a value. Decode every complete prefix.
            encoded = encoded.rstrip(b'=')
            if len(encoded) % 4 == 1:
                encoded = encoded[:-1]
            encoded += b'=' * (-len(encoded) % 4)
        check_bytes(base64.b64decode(encoded, validate=True), label + ' decoded backup issue')

def check_published(folder, proof=None):
    """Scan what a release folder publishes: every archive member, the manifest and the WAL policy proof."""
    with tarfile.open(folder / 'corpus.tar.gz', 'r:gz') as archive:
        for member in archive:
            if member.isfile():
                check_bytes(archive.extractfile(member).read(), 'archive member ' + member.name)
    check_bytes((folder / 'manifest.json').read_bytes(), 'manifest.json')
    check_bytes((proof or folder / 'wal-policy-proof.json').read_bytes(), 'wal-policy-proof.json')

def network_retry(value):
    prefix = 'encryptedmemories-backup-issue-v1:'
    if not value.startswith(prefix):
        return False
    record = json.loads(base64.b64decode(value[len(prefix):], validate=True))
    return record.get('kind') == 'network' and record.get('automaticRetryAttempt', 0) > 0

def rows(directory, name, sql=None):
    source = directory / name
    if not source.exists() or source.stat().st_size == 0:
        return []
    with tempfile.TemporaryDirectory(prefix='upgrade-oracle-') as temporary:
        copy = Path(temporary) / name
        copy.parent.mkdir(parents=True, exist_ok=True)
        for suffix in ('', '-wal', '-shm'):
            sidecar = Path(str(source) + suffix)
            if sidecar.exists():
                shutil.copyfile(sidecar, Path(str(copy) + suffix))
        with sqlite3.connect(copy) as db:
            tables = {row[0] for row in db.execute("SELECT name FROM sqlite_schema WHERE type='table'")}
            if not tables:
                return []
            # Scan every recovered table value, not only printable strings in the file container.
            for table in tables:
                quoted = '"' + table.replace('"', '""') + '"'
                for row in db.execute('SELECT * FROM ' + quoted):
                    for value in row:
                        if isinstance(value, str):
                            check_bytes(value.encode(), name + ' SQLite text', strict_issues=True)
                        elif isinstance(value, bytes):
                            check_bytes(value, name + ' SQLite blob')
            if sql is None:
                return []
            table = re.search(r'FROM ([a-z_]+)', sql).group(1)
            return list(db.execute(sql)) if table in tables else []

def safe_rows(tree, name, unreadable, sql):
    return [] if name in unreadable else rows(tree, name, sql)

def pack(recorded, destination):
    # A staging folder that an interrupted run left behind would count as an unlisted release.
    for stale in destination.parent.glob('.pack-*'):
        shutil.rmtree(stale, ignore_errors=True)
    blobs = {}
    manifest = dict(format=1, **json.loads((recorded.parent / 'recording.json').read_text()), scenarios={})
    catalog = release_catalog(destination, manifest)
    for scenario in SCENARIOS:
        folder = recorded / scenario
        events = [json.loads(line) for line in (folder / 'events.jsonl').read_text().splitlines()]
        atomic_targets = {}
        atomic_helpers = {}
        for event in events:
            source = event.get('source')
            target = event['path'].lstrip('/')
            completed = folder / f"{event['id']:06d}" / target
            if source and completed.is_file():
                digest = hashlib.sha256(completed.read_bytes()).hexdigest()
                atomic_targets.setdefault(target, set()).add(digest)
                atomic_helpers[source.lstrip('/')] = target
        atomic_targets = {target: sorted(digests) for target, digests in atomic_targets.items()}
        # A journal can be atomically created and then intentionally appended in place.
        mutable_after = {}
        for event in events:
            target = event['path'].lstrip('/')
            if target in atomic_targets and event['kind'] in ('write', 'write-nocancel', 'pwrite', 'pwrite-nocancel', 'writev', 'truncate', 'create-or-truncate'):
                mutable_after.setdefault(target, event['id'])
        snapshots = []
        for event in events:
            tree = folder / f"{event['id']:06d}"
            files = {}
            directories = []
            metadata = {}
            for path in sorted(tree.rglob('*')):
                relative = path.relative_to(tree).as_posix()
                if path.is_dir():
                    directories.append(relative)
                    continue
                if not path.is_file() or path.is_symlink():
                    raise ValueError('Snapshot must contain regular files only')
                data = path.read_bytes()
                check_bytes(data, scenario + '/' + relative)
                digest = hashlib.sha256(data).hexdigest()
                blobs[digest] = data
                files[relative] = digest
                metadata[relative] = dict(mtimeNanoseconds=path.stat().st_mtime_ns, mode=path.stat().st_mode & 0o777, byteCount=len(data))
            # These copies may precede a valid SQLite header or the transaction's final WAL frame.
            # Keep those states; the checker must still open them. Record unreadable oracle stores explicitly.
            unreadable = []
            for database in tree.rglob('*.sqlite'):
                try:
                    rows(tree, database.relative_to(tree).as_posix())
                except sqlite3.DatabaseError:
                    unreadable.append(database.relative_to(tree).as_posix())
            oracle = json.loads((folder / f"{event['id']:06d}.oracle.json").read_text())
            oracle['unreadableStores'] = unreadable
            oracle['complete'] = [dict(zip(('identifier', 'resource', 'revision', 'resourceCount'), row)) for row in safe_rows(tree, 'Account/upload-backup-state-v1.sqlite', unreadable, 'SELECT source_id,resource,revision_us,resource_count FROM backup_asset_state WHERE pending_resources=0')]
            oracle['queueKeys'] = ['|'.join(map(str, row)) for row in safe_rows(tree, 'Account/upload-backup-sync-queue-v1.sqlite', unreadable, 'SELECT source_id,resource,revision_us FROM backup_sync_queue')]
            oracle['queueStates'] = sorted({row[0] for row in safe_rows(tree, 'Account/upload-backup-sync-queue-v1.sqlite', unreadable, 'SELECT state FROM backup_sync_queue')})
            retry = any(network_retry(row[0]) for row in safe_rows(tree, 'Account/upload-backup-sync-queue-v1.sqlite', unreadable, 'SELECT last_error FROM backup_sync_queue WHERE last_error IS NOT NULL'))
            snapshots.append({'atomicTargets': {path: hashes for path, hashes in atomic_targets.items() if event['id'] < mutable_after.get(path, float('inf'))}, 'atomicHelpers': {path: target for path, target in atomic_helpers.items() if path in files}, 'retryIssueObserved': retry, 'event': event, 'files': files, 'directories': directories, 'metadata': metadata, 'oracle': oracle})
        if not snapshots:
            raise ValueError('No write boundaries for ' + scenario)
        manifest['scenarios'][scenario] = snapshots
    destination.mkdir(parents=True, exist_ok=True)
    proof = destination / 'wal-policy-proof.json'
    if not proof.is_file():
        raise ValueError('The WAL policy proof is missing')
    encoded = json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()
    check_bytes(encoded, 'manifest')
    # Write and scan in a staging folder, so a hit or the budget leaves the release folder as it was.
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix='.pack-') as staging_name:
        staging = Path(staging_name)
        archive = staging / 'corpus.tar.gz'
        with archive.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', mtime=0) as compressed, \
                tarfile.open(fileobj=compressed, mode='w') as tar:
            for digest, data in sorted(blobs.items()):
                info = tarfile.TarInfo('blobs/' + digest)
                info.size = len(data)
                info.mode = 0o644
                tar.addfile(info, io.BytesIO(data))
        (staging / 'manifest.json').write_bytes(encoded)
        check_published(staging, proof)
        archive_bytes = archive.stat().st_size
        size = sum(path.stat().st_size for path in staging.iterdir()) + proof.stat().st_size
        if size > BUDGET:
            raise ValueError(f'Corpus exceeds hard 15 MB budget: {size}')
        for name in ('corpus.tar.gz', 'manifest.json'):
            (staging / name).replace(destination / name)
    catalog_path = destination.parent / 'releases.json'
    encoded_catalog = json.dumps(catalog, indent=2) + '\n'
    check_bytes(encoded_catalog.encode(), 'release list')
    temporary_catalog = catalog_path.with_suffix('.json.tmp')
    temporary_catalog.write_text(encoded_catalog)
    temporary_catalog.replace(catalog_path)
    summary = {'snapshots': {key: len(value) for key, value in manifest['scenarios'].items()}, 'blobs': len(blobs),
               'archiveBytes': archive_bytes, 'manifestBytes': len(encoded), 'totalBytes': size}
    print(json.dumps(summary, indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('recorded', type=Path, nargs='?')
    parser.add_argument('destination', type=Path, nargs='?')
    parser.add_argument('--check-release')
    parser.add_argument('--check-published', type=Path, help='Scan the published files of one release folder')
    args = parser.parse_args()
    if args.check_published is not None:
        try:
            check_published(args.check_published)
        except ValueError as error:
            sys.exit(str(error))
        print('No private path or hostname in ' + args.check_published.name)
    elif args.check_release is not None:
        release_version(args.check_release)
    elif args.recorded is None or args.destination is None:
        parser.error('recorded and destination are required')
    else:
        pack(args.recorded, args.destination)
