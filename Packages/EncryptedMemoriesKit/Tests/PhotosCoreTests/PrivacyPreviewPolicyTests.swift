import Foundation
import PhotosCore
import XCTest

final class PrivacyPreviewPolicyTests: XCTestCase {
    func testPreviewCoverRequiresEnabledPreferenceAndInactiveScene() {
        XCTAssertFalse(PrivacyPreviewPolicy.shouldCover(enabled: false, isSceneActive: false, isWindowVisible: true))
        XCTAssertFalse(PrivacyPreviewPolicy.shouldCover(enabled: true, isSceneActive: true, isWindowVisible: true))
        XCTAssertTrue(PrivacyPreviewPolicy.shouldCover(enabled: true, isSceneActive: false, isWindowVisible: true))
        XCTAssertTrue(PrivacyPreviewPolicy.shouldCover(enabled: true, isSceneActive: true, isWindowVisible: false))
    }

    func testPreviewCoverDefaultsOnAndReadsSavedPreference() throws {
        let suiteName = "PrivacyPreviewPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(PrivacyPreviewPolicy.isEnabled(defaults: defaults))
        defaults.set(true, forKey: AppSettingsKey.blurAppPreview)
        XCTAssertTrue(PrivacyPreviewPolicy.isEnabled(defaults: defaults))
        defaults.set(false, forKey: AppSettingsKey.blurAppPreview)
        XCTAssertFalse(PrivacyPreviewPolicy.isEnabled(defaults: defaults))
    }
}
