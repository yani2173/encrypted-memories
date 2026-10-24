import Foundation
import PhotosCore
import ProtonAuth
import Testing
import UploadCore

@testable import EncryptedMemoriesMobile

/// The library after a merge of exact duplicates on iPhone and iPad.
@MainActor @Suite struct MobileDuplicatesMergeTests {
    @Test func theRescanFixtureDropsTheLastGroupOnTheFirstScreenRefresh() async {
        let members = (0..<4).map { PhotoUID(volumeID: "fixture", nodeID: "copy-\($0)") }
        let finder = MobileFixtureDuplicates(
            groups: [Array(members.prefix(2)), Array(members.suffix(2))], rescanDropsLastGroup: true)
        let model = ExactDuplicatesModel(finder: finder)
        await model.loadCountIfNeeded()
        await model.load()
        #expect(model.groups.count == 2)

        await model.load()

        #expect(model.groups.map(\.members) == [Array(members.prefix(2))])
    }

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

    @Test(arguments: [false, true], [false, true])
    func accountTeardownStopsTheOldMerge(paused: Bool, switchingAccount: Bool) async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 20)
        defer { fixture.removeCache() }
        let library = MobileLibraryModel()
        fixture.install(into: library)
        let items = fixture.items
        let members = stride(from: 0, to: items.count, by: 2).map { [items[$0].uid, items[$0 + 1].uid] }
        let finder = HeldAccountDuplicates(groups: members)
        library.installIsolatedDuplicatesForTesting(finder)
        var duplicates: ExactDuplicatesModel? = try #require(library.duplicates)
        weak var released: ExactDuplicatesModel? = duplicates
        await duplicates?.load()
        var finished = false
        let merge = Task { [duplicates] in
            await duplicates?.mergeAll()
            finished = true
        }
        #expect(await eventually { await finder.isHeld })
        if paused {
            duplicates?.pauseMerging()
            await finder.release()
            await duplicates?.runningMergeWorkEnded()
        }

        let store = SessionKeychainStore()
        if switchingAccount {
            library.configure(
                session: ProtonSession(
                    uid: "second-account", accessToken: "access-b", refreshToken: "refresh-b", keyPassword: "key-b"),
                store: store)
            #expect(duplicates?.isStoppingMergeAll == true, "Account replacement itself must stop the old run")
        }
        // Cancel the replacement composition before it can open a network backend.
        library.configure(session: nil, store: store)
        if !paused {
            #expect(!finished, "Account teardown must let the running batch finish")
            await finder.release()
        }
        // Replace the local reference before checking the old account's ownership.
        // The merge task and library are the only possible owners now.
        duplicates = nil
        #expect(await eventually { finished })
        #expect(await finder.batches == 1, "No batch starts after account teardown")
        #expect(await eventually { released == nil }, "The old account must release its model")

        // The negative control must also finish a paused run.
        released?.stopMergeAll()
        await finder.release()
        await merge.value
    }

    @Test func aRetiredBatchCannotPublishIntoTheReplacementAccount() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 2)
        let replacement = try await MobileSignedInFixture(itemsPerSection: 2)
        defer {
            fixture.removeCache()
            replacement.removeCache()
        }
        let library = MobileLibraryModel()
        fixture.install(into: library)
        let members = fixture.sections[0].items.map(\.uid)
        let finder = HeldAccountDuplicates(groups: [members])
        library.installIsolatedDuplicatesForTesting(finder)
        let duplicates = try #require(library.duplicates)
        await duplicates.load()
        let merge = Task { await duplicates.mergeAll() }
        #expect(await eventually { await finder.isHeld })

        let store = SessionKeychainStore()
        library.configure(session: nil, store: store)
        library.installIsolatedLibrary(
            session: ProtonSession(
                uid: "replacement-account", accessToken: "access-b", refreshToken: "refresh-b", keyPassword: "key-b"),
            store: store, backend: replacement.backend, sections: replacement.sections,
            thumbnailFeed: replacement.feed, thumbnailCache: replacement.cache)
        await finder.release()
        await merge.value

        #expect(library.snapshot.count == replacement.items.count)
        #expect(shows(members[1], in: library), "The retired batch cannot remove a replacement account's photo")
        library.configure(session: nil, store: store)
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
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

private actor HeldAccountDuplicates: ExactDuplicateMerging {
    private let base: MobileFixtureDuplicates
    private var waiter: CheckedContinuation<Void, Never>?
    private var open = false
    private(set) var batches = 0
    var isHeld: Bool { waiter != nil }

    init(groups: [[PhotoUID]]) { base = MobileFixtureDuplicates(groups: groups) }

    func duplicateGroups(
        progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
    ) async throws -> ExactDuplicateScan { try await base.duplicateGroups(progress: progress) }

    func prepareIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws -> Bool { try await base.prepareIndex(progress: progress) }

    func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
        await base.fallbackMembers(of: groups)
    }

    func rankMembers(
        of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
    ) async { await base.rankMembers(of: groups, ranked: ranked) }

    func merge(_ requests: [ExactDuplicateMergeRequest]) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
        batches += 1
        if !open { await withCheckedContinuation { waiter = $0 } }
        return await base.merge(requests)
    }

    func release() {
        open = true
        let pending = waiter
        waiter = nil
        pending?.resume()
    }
}
