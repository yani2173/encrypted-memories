import PhotosCore
import Testing

@testable import DesignSystemCore

@Suite struct MediaLoadingSpinnerTests {
    @Test func theRingShowsOnlyBetweenTheFirstAndTheLastPercentWhileBytesArrive() {
        let inside: [Double] = [0.0011, 0.01, 0.5, 0.994, 0.994999]
        for progress in inside {
            #expect(MediaLoadingSpinner.visibleFraction(progress, isDownloading: true) == progress, "\(progress)")
        }
        // Both bounds are exclusive: a download that has not started or has nearly finished shows the calm spinner.
        let outside: [Double] = [-1, 0, 0.001, 0.995, 0.9951, 1, 2, .infinity, -.infinity, .nan]
        for progress in outside {
            #expect(MediaLoadingSpinner.visibleFraction(progress, isDownloading: true) == nil, "\(progress)")
        }
    }

    @Test func withoutADownloadTheSpinnerStaysIndeterminate() {
        for progress in [0, 0.001, 0.5, 0.995, 1] as [Double] {
            #expect(MediaLoadingSpinner.visibleFraction(progress, isDownloading: false) == nil, "\(progress)")
        }
    }

    @Test func theRingKeepsTheExactProgressWithoutRounding() {
        #expect(MediaLoadingSpinner.visibleFraction(0.123456789, isDownloading: true) == 0.123456789)
    }

    @Test func voiceOverNamesTheSpinnerLoading() {
        #expect(MediaLoadingSpinner.accessibilityName == L10n.string("loading.content"))
        // A key that the catalog lacks would show up as itself.
        #expect(MediaLoadingSpinner.accessibilityName != "loading.content")
    }
}
