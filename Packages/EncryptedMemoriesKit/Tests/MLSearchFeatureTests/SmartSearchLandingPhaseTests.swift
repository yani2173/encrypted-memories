import Testing

@testable import MLSearchFeature

/// What the Search landing shows while the suggestions load, wait or have nothing to offer.
@Suite struct SmartSearchLandingPhaseTests {
    private func phase(
        hasSuggestions: Bool = false, hasComputed: Bool = false, isComputing: Bool = false,
        libraryIsEmpty: Bool = false
    ) -> SmartSearchLandingPhase {
        SmartSearchDiscoveryModel.landingPhase(
            hasSuggestions: hasSuggestions, hasComputed: hasComputed, isComputing: isComputing,
            libraryIsEmpty: libraryIsEmpty)
    }

    @Test func suggestionsShowWhateverElseIsGoingOn() {
        for computed in [false, true] {
            for computing in [false, true] {
                #expect(
                    phase(hasSuggestions: true, hasComputed: computed, isComputing: computing) == .suggestions)
            }
        }
    }

    @Test func anUncomputedLibraryShowsPlaceholdersFromTheFirstFrame() {
        #expect(phase(isComputing: true) == .loading)
    }

    @Test func blockedWorkShowsPlaceholdersAndTheShortNoteNotTheEmptyState() {
        #expect(phase(isComputing: false) == .preparing)
    }

    @Test func theEmptyStateNeedsAFinishedResultOrALibraryWithoutPhotos() {
        #expect(phase(hasComputed: true) == .empty)
        #expect(phase(hasComputed: true, isComputing: true) == .empty)
        #expect(phase(libraryIsEmpty: true) == .empty)
        #expect(phase(isComputing: true, libraryIsEmpty: true) == .empty)
    }

    @Test func theEmptyStateIsUnreachableWhileNothingIsComputedAndTheLibraryHasPhotos() {
        for computing in [false, true] {
            #expect(phase(isComputing: computing) != .empty)
        }
    }
}
