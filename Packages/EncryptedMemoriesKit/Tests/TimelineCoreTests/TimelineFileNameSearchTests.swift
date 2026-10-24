import Foundation
import PhotosCore
import Synchronization
import Testing

@testable import TimelineCore

@Suite struct TimelineFileNameSearchTests {
    private let named = PhotoItem(
        uid: PhotoUID(volumeID: "v", nodeID: "kx"), captureTime: Date(timeIntervalSince1970: 10),
        mediaType: "image/heic")
    private let renamed = PhotoItem(
        uid: PhotoUID(volumeID: "v", nodeID: "ky"), captureTime: Date(timeIntervalSince1970: 20),
        mediaType: "image/jpeg")
    private let unnamed = PhotoItem(
        uid: PhotoUID(volumeID: "v", nodeID: "kz"), captureTime: Date(timeIntervalSince1970: 30),
        mediaType: "image/jpeg")

    private var names: PhotoNameIndex {
        PhotoNameIndex(names: [named.uid: "IMG_3350.HEIC", renamed.uid: "Ärger am Strand.jpg"], revision: 1)
    }

    @Test(arguments: ["IMG_3350", "img_33", "3350", ".HEIC", "heic", "IMG_3350.HEIC", "img 3350"])
    func aNameOrPartOfItFindsThePhotoInAnyCase(query: String) {
        #expect(uids(query, names: names).contains(named.uid))
        #expect(!uids(query, names: names).contains(unnamed.uid))
    }

    /// A kind word inside a file name does not filter the named photo out: a JPEG named film_001.jpg is found.
    @Test(arguments: [
        ("film_001.jpg", "film_001"), ("film_001.jpg", "FILM_001.JPG"), ("raw_0001.jpg", "raw_0001"),
        ("video_2.jpg", "video"), ("herz.jpg", "herz.jpg"), ("Favorite 3.jpg", "favorite"),
    ])
    func aKindWordInTheNameFindsTheNamedPhoto(name: String, query: String) {
        let index = PhotoNameIndex(names: [renamed.uid: name], revision: 1)
        #expect(uids(query, names: index).contains(renamed.uid))
    }

    @Test func aKindWordStillFindsItsKindWithoutAName() {
        let video = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "kv"), captureTime: Date(timeIntervalSince1970: 40),
            mediaType: "video/quicktime")
        let found = TimelineSearch.filter(
            [section([named, video])], query: "film", context: TimelineSearchContext(photoNames: names)
        ).flatMap(\.items).map(\.uid)
        #expect(found == [video.uid])
    }

    @Test func diacriticsAndCaseFoldInTheName() {
        #expect(uids("arger", names: names) == [renamed.uid])
        #expect(uids("ÄRGER STRAND", names: names) == [renamed.uid])
    }

    @Test func withoutNamesTheSameQueryFindsNothingByName() {
        #expect(uids("3350", names: nil).isEmpty)
        #expect(uids("arger", names: nil).isEmpty)
    }

    @Test func aRenamedPhotoIsFoundByItsNewNameOnly() {
        let before = PhotoNameIndex(names: [renamed.uid: "IMG_0001.JPG"], revision: 1)
        let after = PhotoNameIndex(names: [renamed.uid: "Strand.jpg"], revision: 2)
        #expect(uids("IMG_0001", names: before) == [renamed.uid])
        #expect(uids("IMG_0001", names: after).isEmpty)
        #expect(uids("strand", names: after) == [renamed.uid])
    }

    @Test func aRemovedNameNoLongerMatches() {
        let after = PhotoNameIndex(names: [renamed.uid: "Ärger am Strand.jpg"], revision: 2)
        #expect(uids("3350", names: after).isEmpty)
    }

    @Test func anEmptyNameMarksAnUnreadableNameAndNeverMatches() {
        let index = PhotoNameIndex(names: [named.uid: ""], revision: 1)
        #expect(index.isEmpty)
        #expect(index.normalizedName(of: named.uid) == nil)
    }

    /// A query that matches no name keeps today's result: the text and Smart Search union in date order.
    @Test func aQueryWithoutANameMatchKeepsTheResultOfToday() {
        for query in ["sunset", "1970", "photo", "favorites", "paris 2019"] {
            let semantic: Set<PhotoUID> = [unnamed.uid]
            let without = projection(query, names: nil, semantic: semantic)
            let with = projection(query, names: names, semantic: semantic)
            #expect(with.presentationItems == without.presentationItems, "query \(query)")
            #expect(with.sections.flatMap(\.items) == without.sections.flatMap(\.items), "query \(query)")
        }
    }

    @Test(arguments: [
        ("IMG_33", true), ("3350", true), (".HEIC", true), ("DSC01234", true), ("img_3350.heic", true),
        (" IMG_33 ", true), ("20190512_123456", true),
        ("sunset", false), ("paris 2019", false), ("IMG 3350", false), ("HEIC", false), ("", false),
        ("2019", false), ("5", false), ("12", false), ("2019-05", false), ("2019-05-01", false),
        ("1.5.2019", false), ("01.05.2019", false),
    ])
    func whichQueriesReadAsAFileName(query: String, expected: Bool) {
        #expect(TimelineSearchQuery.looksLikeFileName(query) == expected)
    }

    /// For a query that reads as a file name, name hits lead (newest first), then the other results in date order.
    @Test func nameHitsLeadWhenTheQueryReadsAsAFileName() {
        let older = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "kw"), captureTime: Date(timeIntervalSince1970: 5),
            mediaType: "image/heic")
        let index = PhotoNameIndex(names: [older.uid: "IMG_3350 copy.HEIC", named.uid: "IMG_3350.HEIC"], revision: 1)
        // The newest photo is a Smart Search result only; it follows the name hits.
        let result = projection("IMG_3350", names: index, semantic: [unnamed.uid], items: [older, named, unnamed])
        #expect(result.presentationItems.map(\.uid) == [named.uid, older.uid, unnamed.uid])
        // The canonical snapshot and sections keep their date order.
        #expect(result.snapshot.items.map(\.uid) == [older.uid, named.uid, unnamed.uid])
    }

    @Test func otherQueriesKeepTheDateOrder() {
        // "IMG 3350" does not read as a file name: the name hit stays in its date position.
        let result = projection("img 3350", names: names, semantic: [unnamed.uid])
        #expect(result.presentationItems.map(\.uid) == [unnamed.uid, named.uid])
    }

    /// The name part of one search costs one lookup per photo for the match and one per result for the order,
    /// whatever the library size.
    @Test func oneSearchLooksUpEachNameAtMostTwice() {
        let count = 100_000
        var items: [PhotoItem] = []
        var source: [PhotoUID: String] = [:]
        items.reserveCapacity(count)
        for index in 0..<count {
            let uid = PhotoUID(volumeID: "v", nodeID: "k\(index)")
            items.append(PhotoItem(uid: uid, captureTime: Date(timeIntervalSince1970: Double(index)), mediaType: "x"))
            source[uid] = "IMG_\(index).HEIC"
        }
        let lookups = Atomic<Int>(0)
        let index = PhotoNameIndex(names: source, revision: 1).observingLookups {
            lookups.add(1, ordering: .relaxed)
        }
        let result = projection("IMG_12345.", names: index, semantic: nil, items: items)

        #expect(result.presentationItems.count == 1)
        #expect(lookups.load(ordering: .relaxed) == count + 1)
    }

    /// A screen asks for names only while its query has search terms; an empty query ends the backend's search.
    @Test func theNameSourceEndsTheSearchWhenTheQueryEnds() async {
        let index = names
        let provider = RecordingNameProvider(index: index)
        #expect(await TimelineFileNameSearchSource.names(forQuery: "3350", from: provider) == index)
        #expect(await TimelineFileNameSearchSource.names(forQuery: "  ", from: provider) == nil)
        #expect(await TimelineFileNameSearchSource.names(forQuery: "x", from: "not a provider") == nil)
        #expect(provider.calls == ["index", "end"])
    }

    private func uids(_ query: String, names: PhotoNameIndex?) -> Set<PhotoUID> {
        Set(
            TimelineSearch.filter(
                [section([named, renamed, unnamed])], query: query,
                context: TimelineSearchContext(photoNames: names)
            ).flatMap(\.items).map(\.uid))
    }

    private func projection(
        _ query: String, names: PhotoNameIndex?, semantic: Set<PhotoUID>?, items: [PhotoItem]? = nil
    ) -> TimelineSearchProjection {
        TimelineSearchProjection(
            key: TimelineSearchProjectionKey(
                sourceRevision: 1, query: query, context: TimelineSearchContext(photoNames: names),
                semanticMatches: semantic),
            sections: [section(items ?? [named, renamed, unnamed])])
    }

    private func section(_ items: [PhotoItem]) -> TimelineSection {
        TimelineSection(id: "library", date: .distantPast, title: "", items: items)
    }
}

private final class RecordingNameProvider: PhotoNameSearchProvider, @unchecked Sendable {
    private let index: PhotoNameIndex
    private let lock = NSLock()
    private var recorded: [String] = []

    init(index: PhotoNameIndex) { self.index = index }

    var calls: [String] { lock.withLock { recorded } }

    func photoNameIndex() async -> PhotoNameIndex {
        lock.withLock { recorded.append("index") }
        return index
    }

    func endPhotoNameSearch() async {
        lock.withLock { recorded.append("end") }
    }
}
