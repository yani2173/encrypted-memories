import PhotosCore
import Testing

@testable import DesignSystemCore

@Suite struct ProgressSpinnerTests {
    @Test func spinnerReadsLoadingUnlessTheCallerNamesWhatLoads() {
        #expect(ProgressSpinner.label(nil) == L10n.string("loading.content"))
        #expect(ProgressSpinner.label("") == L10n.string("loading.content"))
        #expect(ProgressSpinner.label("Albums") == "Albums")
    }
}
