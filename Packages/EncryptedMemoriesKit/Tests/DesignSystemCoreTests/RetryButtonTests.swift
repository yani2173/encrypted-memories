import PhotosCore
import Testing

@testable import DesignSystemCore

@Suite struct RetryButtonTests {
    /// Every style reads `action.retry`. Without a compiled catalog (plain SwiftPM) both sides resolve to the raw key,
    /// so a button that read any other key fails here in every build. The catalog value is checked by
    /// `LocalizationTests.testEveryRetryActionHasOneTryAgainTitle`.
    @Test func everyRetryButtonReadsTheSharedRetryKey() {
        #expect(RetryButton.title == L10n.string("action.retry"))
    }
}
