#!/usr/bin/env python3
"""Compile the actual candidate and historical Metal admission against controlled devices."""
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/upgrade-test'))
from build_apps import apply_overlay


@unittest.skipUnless(sys.platform == 'darwin', 'Controlled Metal compilation requires macOS')
class UpgradeMetalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo = Path(__file__).resolve().parents[2]
        scratch = Path(os.environ.get('ENCRYPTED_MEMORIES_BUILD_ROOT',
            str(Path.home() / 'Developer/xcode/EncryptedMemories'))) / 'UpgradeMetal'
        scratch.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(dir=scratch)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        adapter = cls.root / 'Metal.swift'
        adapter.write_text("""
public enum MTLGPUFamily { case metal3 }
public protocol MTLDevice { func supportsFamily(_ family: MTLGPUFamily) -> Bool }
public final class ControlledDevice: MTLDevice {
    public let supported: Bool
    public init(_ supported: Bool) { self.supported = supported }
    public func supportsFamily(_ family: MTLGPUFamily) -> Bool { supported }
}
public var controlledDevice: MTLDevice?
public func MTLCreateSystemDefaultDevice() -> MTLDevice? { controlledDevice }
""")
        cls.run_command(['xcrun', 'swiftc', '-emit-library', '-emit-module', '-module-name',
            'Metal', str(adapter), '-o', str(cls.root / 'libMetal.dylib')])
        main = cls.root / 'main.swift'
        main.write_text("""
import Metal
controlledDevice = nil
print(Metal3RuntimeCapability.supportsDefaultDevice())
controlledDevice = ControlledDevice(false)
print(Metal3RuntimeCapability.supportsDefaultDevice())
controlledDevice = ControlledDevice(true)
print(Metal3RuntimeCapability.supportsDefaultDevice())
print(Metal3RuntimeCapability.supports(device: ControlledDevice(false)))
print(Metal3RuntimeCapability.supports(device: ControlledDevice(true)))
""")
        relative = 'Packages/EncryptedMemoriesKit/Sources/MetalRenderingCore/Metal3RuntimeCapability.swift'
        manifest = json.loads((cls.repo / 'scripts/upgrade-test/overlays/versions.json').read_text())
        cls.tags = sorted(manifest)
        sources = [('candidate', cls.repo / relative)]
        for tag in cls.tags:
            sha = cls.run_command(['git', 'rev-parse', tag + '^{commit}']).stdout.strip()
            if sha != manifest[tag]['commit']:
                raise AssertionError(tag + ' differs from the pinned published commit')
            historical = cls.root / tag
            historical.mkdir()
            archive = subprocess.check_output(['git', 'archive', sha,
                'Packages/EncryptedMemoriesKit/Sources'], cwd=cls.repo)
            with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
                tree.extractall(historical, filter='data')
            apply_overlay(historical, cls.repo, tag, sha)
            sources.append((tag, historical / relative))
        cls.results = {}
        for name, source in sources:
            for flagged in [False, True]:
                binary = cls.root / (name + ('-probe' if flagged else '-production'))
                flags = ['-D', 'ENCRYPTED_MEMORIES_UPGRADE_TEST'] if flagged else []
                cls.run_command(['xcrun', 'swiftc', '-O', *flags, '-I', str(cls.root),
                    '-L', str(cls.root), '-lMetal', '-Xlinker', '-rpath', '-Xlinker', str(cls.root),
                    str(source), str(main), '-o', str(binary)])
                cls.results[name, flagged] = cls.run_command([str(binary)]).stdout.splitlines()

    @classmethod
    def run_command(cls, args):
        return subprocess.run(args, cwd=cls.repo, check=True, capture_output=True, text=True)

    def test_native_hardware_report_contains_device_names_and_exact_family_answers(self):
        report = json.loads(self.run_command(['xcrun', 'swift',
            str(self.repo / 'scripts/upgrade-test/metal_devices.swift')]).stdout)
        self.assertIsInstance(report['allDevices'], list)
        devices = report['allDevices'] + ([report['defaultDevice']] if report['defaultDevice'] else [])
        for device in devices:
            self.assertIsInstance(device['name'], str)
            self.assertIs(type(device['supportsFamilyMetal3']), bool)

    def test_candidate_without_flag_requires_a_metal3_device(self):
        self.assertEqual(self.results['candidate', False], ['false', 'false', 'true', 'false', 'true'])

    def test_every_historical_overlay_is_covered(self):
        self.assertEqual(self.tags, ['v1.0.5', 'v1.1.0-beta.3'])

    def test_historical_without_flag_requires_a_metal3_device(self):
        for tag in self.tags:
            with self.subTest(tag=tag):
                self.assertEqual(self.results[tag, False], ['false', 'false', 'true', 'false', 'true'])

    def test_candidate_probe_admits_missing_and_unsupported_devices_without_relaxing_renderer_query(self):
        self.assertEqual(self.results['candidate', True], ['true', 'true', 'true', 'false', 'true'])

    def test_historical_probe_admits_missing_and_unsupported_devices_without_relaxing_renderer_query(self):
        for tag in self.tags:
            with self.subTest(tag=tag):
                self.assertEqual(self.results[tag, True], ['true', 'true', 'true', 'false', 'true'])


if __name__ == '__main__':
    unittest.main()
