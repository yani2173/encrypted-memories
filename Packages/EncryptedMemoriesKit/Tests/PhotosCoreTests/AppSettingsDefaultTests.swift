import Foundation
import PhotosCore
import SwiftUI
import XCTest

final class AppSettingsDefaultTests: XCTestCase {
    func testUnsetMobileDataWaitsForWiFiAndPreservesSavedValues() throws {
        try assertPreference(
            key: AppSettingsKey.backupUsesMobileData,
            fallback: AppSettingsDefault.backupUsesMobileData,
            expected: false, read: BackupMobileDataPolicy.isEnabled)
    }

    func testUnsetSharingRemovesLocationAndPreservesSavedValues() throws {
        try assertPreference(
            key: AppSettingsKey.removeLocationWhenSharing,
            fallback: AppSettingsDefault.removeLocationWhenSharing,
            expected: true, read: PrivacyExportPolicy.isEnabled)
    }

    func testUnsetPreviewIsCoveredAndPreservesSavedValues() throws {
        try assertPreference(
            key: AppSettingsKey.blurAppPreview,
            fallback: AppSettingsDefault.blurAppPreview,
            expected: true, read: PrivacyPreviewPolicy.isEnabled)
    }

    func testUnsetMapAndPlacesStayEnabledAndPreserveSavedValues() throws {
        try assertPreference(
            key: AppSettingsKey.mapAndPlacesEnabled,
            fallback: AppSettingsDefault.mapAndPlacesEnabled,
            expected: true, read: MapAndPlacesPolicy.isEnabled)
    }

    private func assertPreference(
        key: String, fallback: Bool, expected: Bool, read: (UserDefaults) -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(fallback, expected, file: file, line: line)
        for existingInstall in [false, true] {
            for storedValue: Bool? in [nil, true, false] {
                let suite = "AppSettingsDefaultTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                if existingInstall { defaults.set(true, forKey: "existingPreference") }
                if let storedValue { defaults.set(storedValue, forKey: key) }

                let settings = AppStorage(wrappedValue: fallback, key, store: defaults)
                let value = storedValue ?? expected
                XCTAssertEqual(read(defaults), value, file: file, line: line)
                XCTAssertEqual(settings.wrappedValue, value, file: file, line: line)
                XCTAssertEqual(
                    defaults.persistentDomain(forName: suite)?[key] as? Bool,
                    storedValue, "reading a preference must not write or migrate it", file: file, line: line)
            }
        }
    }
}
