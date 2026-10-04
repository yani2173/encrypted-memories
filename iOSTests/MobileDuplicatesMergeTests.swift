import Foundation
import PhotosCore
import Testing
import UploadCore

@testable import EncryptedMemoriesMobile

/// The library after a merge of exact duplicates on iPhone and iPad.
@MainActor @Suite struct MobileDuplicatesMergeTests {
    /// A library whose first two photos are one group of copies, with the first one as the favorite on the server.
    private func makeLibrary() async throws -> (MobileSignedInFixture, MobileLibraryModel, [PhotoUID]) {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 2)
        let members = fixture.sections[0].items.map(\.uid)
        let favorite = members[0]
        let backend = MobileFixtureBackend(
            sections: fixture.sections, thumbnails: [:], favoriteLoader: { [favorite] })
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: backend, sections: fixture.sections, thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        model.installIsolatedDuplicatesForTesting(MobileFixtureDuplicates(groups: [members]))
        return (fixture, model, members)
    }

    private func shows(_ uid: PhotoUID, in model: MobileLibraryModel) -> Bool {
        model.snapshot.items.contains { $0.uid == uid }
    }

    @Test func aMergeShowsTheFavoriteThatTheKeptPhotoCarriesNow() async throws {
        let (fixture, model, members) = try await makeLibrary()
        defer { fixture.removeCache() }
        let duplicates = try #require(model.duplicates)
        await duplicates.load()

        await duplicates.merge(groupID: "fixture-copies-0")

        #expect(model.favoriteUIDs == [members[0]])
        #expect(!shows(members[1], in: model))
    }

    @Test func aMergeDuringTheInitialLoadWaitsForThatLoad() async throws {
        let (fixture, model, members) = try await makeLibrary()
        defer { fixture.removeCache() }
        let duplicates = try #require(model.duplicates)
        await duplicates.load()
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        model.installIsolatedInitialLoadForTesting {
            for await _ in gate { break }
        }

        let merge = Task { await duplicates.merge(groupID: "fixture-copies-0") }
        try await Task.sleep(for: .milliseconds(300))
        // The removal would advance the mutation generation and reject the load in flight.
        #expect(shows(members[1], in: model), "the library keeps the photo until the initial load settles")

        open.yield()
        open.finish()
        await merge.value
        #expect(!shows(members[1], in: model))
    }
}
