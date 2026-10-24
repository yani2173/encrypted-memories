#!/usr/bin/env python3
"""Apply the recorder target to a clean, detached historical release worktree."""
import argparse
import shutil
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('current', type=Path)
p.add_argument('historical', type=Path)
p.add_argument('expected_commit')
a = p.parse_args()
head = subprocess.check_output(['git', '-C', str(a.historical), 'rev-parse', 'HEAD'], text=True).strip()
if head != a.expected_commit:
    raise SystemExit('Recorder requires the exact requested release commit')
package = a.historical / 'Packages/EncryptedMemoriesKit'
manifest = package / 'Package.swift'
text = manifest.read_text()
marker = '    targets: ['
if 'name: "UpgradeFixtureRecorder"' in text:
    raise SystemExit('Overlay already applied')
# A release whose duplicate-check protocol already requires linkVisibility(of:) needs the fixture backend to provide it.
identity_models = package / 'Sources/UploadCore/Dedupe/UploadIdentityModels.swift'
defines = ['UPGRADE_RECORDING']
if 'func linkVisibility(of' in identity_models.read_text():
    defines.append('UPGRADE_HISTORICAL_LINK_VISIBILITY')
settings = ', '.join(f'.define("{name}")' for name in defines)
text = text.replace(marker, marker + f'''
        .executableTarget(
            name: "UpgradeFixtureRecorder",
            dependencies: ["PhotosCore", "UploadCore", "PhotoLibraryBackupAdapter", "MLSearchCore", "MediaByteCache", "MediaLocationCore"],
            swiftSettings: [{settings}]
        ),''', 1)
text = text.replace('    products: [', '    products: [\n        .executable(name: "UpgradeFixtureRecorder", targets: ["UpgradeFixtureRecorder"]),', 1)
manifest.write_text(text)
source = package / 'Sources/UpgradeFixtureRecorder'
source.mkdir()
shutil.copyfile(a.current / 'Packages/EncryptedMemoriesKit/Tests/UpgradeFixtureTests/FixtureWorkloads.swift', source / 'FixtureWorkloads.swift')
shutil.copyfile(a.current / 'Tools/upgrade-fixtures/Recorder/Main.swift', source / 'Main.swift')
print('Applied recorder target; historical production sources remain unchanged')
