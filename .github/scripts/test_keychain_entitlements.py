#!/usr/bin/env python3
"""Behavior checks for the release entitlement comparison."""
import unittest
from pathlib import Path
import tempfile
import plistlib
from keychain_entitlements import compare_groups, snapshot, EntitlementError


class KeychainEntitlementTests(unittest.TestCase):
    def test_configuration_resolves_explicit_and_implicit_groups(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'App').mkdir()
            (root / 'App/EncryptedMemories.entitlements').write_bytes(plistlib.dumps({
                'keychain-access-groups': ['$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)']}))
            (root / 'project.yml').write_text("""targets:
  EncryptedMemories:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: example.photos
        CODE_SIGN_ENTITLEMENTS: App/EncryptedMemories.entitlements
  EncryptedMemoriesMobile:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: example.photos
""")
            original = snapshot(root)
            self.assertEqual(list(original.values()), [['$(AppIdentifierPrefix)example.photos']] * 2)
            (root / 'project.yml').write_text((root / 'project.yml').read_text().replace(
                'example.photos', 'example.changed'))
            with self.assertRaisesRegex(EntitlementError, 'App/EncryptedMemories.entitlements'):
                compare_groups(original, snapshot(root))

    def test_same_groups_preserve_the_release_contract(self):
        compare_groups({'App/EncryptedMemories.entitlements': ['$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)'],
                        'iOS (implicit)': []},
                       {'App/EncryptedMemories.entitlements': ['$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)'],
                        'iOS (implicit)': []})

    def test_changed_group_fails_and_names_the_file(self):
        with self.assertRaisesRegex(EntitlementError, 'App/EncryptedMemories.entitlements'):
            compare_groups({'App/EncryptedMemories.entitlements': ['shared-group']},
                           {'App/EncryptedMemories.entitlements': ['different-group']})

    def test_new_ios_group_fails(self):
        with self.assertRaisesRegex(EntitlementError, 'iOS'):
            compare_groups({'iOS': []}, {'iOS': ['new-group']})

    def test_removing_an_explicit_group_fails(self):
        with self.assertRaises(EntitlementError):
            compare_groups({'macOS': ['group']}, {'macOS': []})


if __name__ == '__main__':
    unittest.main()
