import AlbumSyncCore
import Testing

@testable import PhotoLibraryBackupAdapter

@Suite struct AlbumPickerContentTests {
    private static let holidays = LocalAlbumSummary(id: "a", title: "Holidays", assetCount: 12)
    private static let family = LocalAlbumSummary(id: "b", title: "Family", assetCount: 3)
    private static let all = [holidays, family]

    private static func content(
        albums: [LocalAlbumSummary] = all, query: String = "", isLoading: Bool = false, didLoad: Bool = true,
        access: PhotoBackupAccessState = .full
    ) -> AlbumPickerContent {
        AlbumPickerContent.resolve(
            albums: albums, query: query, isLoading: isLoading, didLoad: didLoad, accessState: access)
    }

    @Test func aBlankQueryKeepsEveryAlbum() {
        for query in ["", " ", "   \t"] {
            #expect(AlbumPickerContent.albums(Self.all, matching: query) == Self.all, "\(query.debugDescription)")
        }
    }

    @Test func aQueryMatchesTheTitleWithoutCaseAndIgnoresSurroundingSpaces() {
        #expect(AlbumPickerContent.albums(Self.all, matching: "holi") == [Self.holidays])
        #expect(AlbumPickerContent.albums(Self.all, matching: "  FAMILY ") == [Self.family])
        #expect(AlbumPickerContent.albums(Self.all, matching: "i") == Self.all)
        #expect(AlbumPickerContent.albums(Self.all, matching: "nothing like it").isEmpty)
    }

    @Test func loadingShowsUntilTheFirstLoadFinishes() {
        #expect(Self.content(isLoading: true, didLoad: false) == .loading)
        // Once the sheet has loaded, a refresh in the background keeps the albums on screen.
        #expect(Self.content(isLoading: true, didLoad: true) == .list(Self.all))
        // Not loading, not yet marked as loaded: the sheet shows what it has.
        #expect(Self.content(isLoading: false, didLoad: false) == .list(Self.all))
    }

    @Test func loadingWinsOverDeniedAccess() {
        #expect(Self.content(isLoading: true, didLoad: false, access: .denied) == .loading)
        #expect(Self.content(isLoading: true, didLoad: false, access: .restricted) == .loading)
    }

    @Test func deniedOrRestrictedAccessWinsOverTheAlbums() {
        #expect(Self.content(access: .denied) == .accessDenied)
        #expect(Self.content(access: .restricted) == .accessDenied)
        // Without any album the sheet still says that access is missing, not that nothing exists.
        #expect(Self.content(albums: [], access: .denied) == .accessDenied)
        #expect(Self.content(albums: [], isLoading: false, didLoad: true, access: .restricted) == .accessDenied)
    }

    @Test func everyOtherAccessStateShowsTheAlbums() {
        for access in [PhotoBackupAccessState.notDetermined, .limited, .full] {
            #expect(Self.content(access: access) == .list(Self.all), "\(access)")
        }
    }

    @Test func noAlbumOrNoMatchShowsTheEmptyState() {
        #expect(Self.content(albums: []) == .empty)
        #expect(Self.content(query: "zzz") == .empty)
        #expect(Self.content(query: "holi") == .list([Self.holidays]))
    }
}
