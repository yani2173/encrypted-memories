import AlbumCore
import Foundation
import PhotosCore
import ProtonAuth
import Testing
import UploadCore

@testable import ProtonDriveBackend
@testable import ProtonDriveSDK

/// A restore that runs before this session listed the trash: the replay of a pending restore after a relaunch and the
/// recovery of Album Sync. Related photos that version 1.1.0 trashed with their main photo come back with it, as after
/// a restore from Recently Deleted.
extension DriveSessionStubSuite {
    @Suite struct RestoreWithoutTrashListingTests {
        private static let trashRoute = "GET /drive/volumes/own-volume/trash"
        private static let metadataRoute = "POST /drive/shares/share/links/fetch_metadata"
        private static let restoreRoute = "PUT /drive/v2/volumes/own-volume/trash/restore_multiple"
        private let main = PhotoUID(volumeID: "own-volume", nodeID: "main")

        // MARK: Replay after a relaunch

        @Test func theReplayOfARestoreAfterARelaunchBringsTheFramesBackWithTheMainPhoto() async throws {
            let fixture = try await Fixture(frameTrashTime: 1001)
            defer { fixture.close() }
            let result = await fixture.effects.restore([main])
            #expect(result == .done)
            #expect(try fixture.restoredLinkIDs() == [["main"], ["frame"]])
            #expect(fixture.listings() == 1, "one trash listing before the restore")
        }

        @Test func aFrameTrashedLaterThanTheWindowStaysInTheTrash() async throws {
            let fixture = try await Fixture(frameTrashTime: 1000 + 301)
            defer { fixture.close() }
            let result = await fixture.effects.restore([main])
            #expect(result == .done)
            #expect(try fixture.restoredLinkIDs() == [["main"]])
        }

        @Test func aFrameTrashedAtTheEdgeOfTheWindowComesBack() async throws {
            let fixture = try await Fixture(frameTrashTime: 1000 + 300)
            defer { fixture.close() }
            _ = await fixture.effects.restore([main])
            #expect(try fixture.restoredLinkIDs() == [["main"], ["frame"]])
        }

        @Test func theAlbumSyncRecoveryRestoreUsesTheSameRoute() async throws {
            let fixture = try await Fixture(frameTrashTime: 1001)
            defer { fixture.close() }
            try await fixture.bridge.restore([main])
            #expect(try fixture.restoredLinkIDs() == [["main"], ["frame"]])
        }

        // MARK: When the listing is not needed

        @Test func checkedCandidatesWithoutAFrameCostNoListing() async throws {
            let fixture = try await Fixture(frameTrashTime: 1001, checkedCandidates: [:])
            defer { fixture.close() }
            _ = await fixture.effects.restore([main])
            #expect(fixture.listings() == 0)
            #expect(try fixture.restoredLinkIDs() == [["main"]], "the checked listing knew no frame")
        }

        @Test func aKnownFrameCostsNoListing() async throws {
            let fixture = try await Fixture(
                frameTrashTime: 1001,
                checkedCandidates: [main: [PhotoUID(volumeID: "own-volume", nodeID: "frame")]])
            defer { fixture.close() }
            _ = await fixture.effects.restore([main])
            #expect(fixture.listings() == 0)
            #expect(try fixture.restoredLinkIDs() == [["main"], ["frame"]])
        }

        @Test func theListingAfterTheFirstRestoreIsNotRepeated() async throws {
            let fixture = try await Fixture(frameTrashTime: 1001)
            defer { fixture.close() }
            _ = await fixture.effects.restore([main])
            _ = await fixture.effects.restore([PhotoUID(volumeID: "own-volume", nodeID: "other")])
            #expect(fixture.listings() == 1)
        }

        // MARK: When the listing fails

        @Test func aFailedListingFailsTheRestoreBeforeAnyPhotoChanges() async throws {
            let fixture = try await Fixture(frameTrashTime: 1001, listingStatus: 500)
            defer { fixture.close() }
            let result = await fixture.effects.restore([main])
            #expect(result != .done)
            #expect(try fixture.restoredLinkIDs().isEmpty)
            #expect(fixture.listings() == 1)
        }

        @Test(arguments: [Fixture.RateLimited.listPage, .metadata])
        func aRateLimitedPreflightIsNotRetriedAndRestoresNothing(limited: Fixture.RateLimited) async throws {
            let fixture = try await Fixture(frameTrashTime: 1001, rateLimited: limited)
            defer { fixture.close() }
            let result = await fixture.effects.restore([main])
            #expect(result != .done)
            #expect(try fixture.restoredLinkIDs().isEmpty, "no retry; the main photo stays in trash")
            #expect(fixture.listings() == 1, "the listing page was asked for once")
            #expect(fixture.metadataReads() == (limited == .metadata ? 1 : 0))
        }

        @Test func aListingThatFailedIsReadAgainByTheNextRestore() async throws {
            let fixture = try await Fixture(frameTrashTime: 1001, listingStatus: 500)
            defer { fixture.close() }
            _ = await fixture.effects.restore([main])
            _ = await fixture.effects.restore([PhotoUID(volumeID: "own-volume", nodeID: "other")])
            #expect(fixture.listings() == 2, "a failed listing does not count as the listing of this session")
        }

        @Test func aCancelDuringTheListingRestoresNothing() async throws {
            let fixture = try await Fixture(frameTrashTime: 1001, hangListing: true)
            defer { fixture.close() }
            let task = Task { try await fixture.bridge.restore([main]) }
            try await waitUntil { fixture.listings() > 0 }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try fixture.restoredLinkIDs().isEmpty)
        }

        @Test func theListingStepEndsWithACancelWhileTheRequestIsInFlight() async throws {
            let fixture = try await Fixture(frameTrashTime: 1001, hangListing: true)
            defer { fixture.close() }
            let task = Task { try await fixture.bridge.listTrashForRelatedPhotos(of: [main]) }
            try await waitUntil { fixture.listings() > 0 }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }

        @Test func theListingStepEndsWithACancelThatArrivedBeforeTheRequest() async throws {
            let fixture = try await Fixture(frameTrashTime: 1001)
            defer { fixture.close() }
            let task = Task {
                while !Task.isCancelled { await Task.yield() }
                try await fixture.bridge.listTrashForRelatedPhotos(of: [main])
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }

        // MARK: Fixture

        private func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            #expect(condition())
        }

        /// A bridge for an account whose trash holds `main` and `frame`; the bridge has not listed the trash yet.
        struct Fixture {
            /// The read of the trash listing that answers 429 once; a retry would then succeed.
            enum RateLimited: Sendable { case listPage, metadata }

            let bridge: DriveSDKBridge
            let effects: ProtonPendingRemoteEffects
            let directory: URL
            private let removesDirectoryOnClose: Bool

            init(
                frameTrashTime: Int64, checkedCandidates: [PhotoUID: [PhotoUID]]? = nil,
                listingStatus: Int = 200, rateLimited: RateLimited? = nil, hangListing: Bool = false,
                ownedDirectory: URL? = nil, seriesRestoreRetry: BackupRetryPolicy = .init(baseDelay: 60, maxDelay: 900)
            ) async throws {
                StubURLProtocol.reset()
                let share = #"{"ShareID":"share","VolumeID":"own-volume","LinkID":"root","State":1}"#
                StubURLProtocol.route("GET /drive/shares", json: #"{"Code":1000,"Shares":[\#(share)]}"#)
                if hangListing {
                    StubURLProtocol.hang(RestoreWithoutTrashListingTests.trashRoute)
                } else {
                    let page = #"{"Code":1000,"Trash":[{"ShareID":"share","LinkIDs":["main","frame"]}]}"#
                    StubURLProtocol.routeSequence(
                        RestoreWithoutTrashListingTests.trashRoute,
                        responses: rateLimited == .listPage
                            ? [(429, #"{"Code":429}"#), (listingStatus, page)] : [(listingStatus, page)])
                }
                let metadata = """
                    {"Code":1000,"Links":[
                      {"LinkID":"main","Type":2,"State":2,"Trashed":1000,
                       "FileProperties":{"ActiveRevision":{"Photo":{}}}},
                      {"LinkID":"frame","Type":2,"State":2,"Trashed":\(frameTrashTime),
                       "FileProperties":{"ActiveRevision":{"Photo":{"MainPhotoLinkID":"main"}}}}
                    ]}
                    """
                let activeMetadata = metadata.replacingOccurrences(
                    of: "\"LinkID\":\"main\",\"Type\":2,\"State\":2", with: "\"LinkID\":\"main\",\"Type\":2,\"State\":1"
                )
                let preflightReads = checkedCandidates == nil ? 2 : 1
                StubURLProtocol.routeSequence(
                    RestoreWithoutTrashListingTests.metadataRoute,
                    responses: rateLimited == .metadata
                        ? [(429, #"{"Code":429}"#), (200, metadata)]
                        : Array(repeating: (200, metadata), count: preflightReads) + [(200, activeMetadata)])
                StubURLProtocol.routeSequence(
                    RestoreWithoutTrashListingTests.restoreRoute,
                    responses: [
                        (200, #"{"Code":1000,"Responses":[{"LinkID":"main","Response":{"Code":1000}}]}"#),
                        (200, #"{"Code":1000,"Responses":[{"LinkID":"frame","Response":{"Code":1000}}]}"#),
                    ])
                directory =
                    ownedDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                removesDirectoryOnClose = ownedDirectory == nil
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let governor = ProtonRequestGovernor()
                let session = DriveSession(
                    session: ProtonSession(uid: "test", accessToken: "", refreshToken: "", keyPassword: ""),
                    store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
                    accountCacheDirectory: directory, requestGovernor: governor,
                    urlProtocolClasses: [StubURLProtocol.self])
                let client = try await EncryptedMemoriesClient(
                    configuration: ProtonDriveClientConfiguration(
                        baseURL: "https://fixture.invalid/", clientUID: "fixture"),
                    httpClient: SDKHttpClient(
                        driveSession: session, requestGovernor: governor, urlProtocolClasses: [StubURLProtocol.self]),
                    accountClient: SDKAccountClient(addresses: [], unlockedByKeyID: [:]),
                    logCallback: { _ in }, featureFlagProviderCallback: { _, completion in completion(false) },
                    recordMetricEventCallback: { _ in })
                let crypto = DriveCrypto(addressKeys: [], signers: [])
                let gate = TimelineMetadataStartGate()
                bridge = DriveSDKBridge(
                    prepared: .init(
                        photosClient: client, uploadClientUID: "fixture", driveSession: session,
                        requestGovernor: governor, expensiveUploadAccess: ExpensiveUploadAccess(),
                        timelineStore: nil, timelineOrderStore: nil, firstIndexBuildGate: gate,
                        metadataReconciliation: TimelineMetadataReconciliation(startGate: gate),
                        crypto: crypto,
                        photosVolumeBootstrap: PhotosVolumeBootstrapService(session: session, crypto: crypto),
                        recentlyDeletedStore: RecentlyDeletedListingStore(
                            directory: directory, accountUID: "fixture", keyPassword: ""),
                        photoNames: nil, recentlyDeleted: RecentlyDeletedIdentities(listing: nil),
                        uploadManifestURL: directory.appendingPathComponent("manifest.sqlite"),
                        uploadManifestPolicy: .conservative), seriesRestoreRetry: seriesRestoreRetry,
                    checkedSeriesRestoreCandidates: checkedCandidates)
                let albums = NoAlbumBackend()
                effects = ProtonPendingRemoteEffects(
                    trashProvider: bridge, favorites: nil,
                    albums: AlbumsRepository(catalogBackend: albums, writeBackend: albums))
            }

            func close() {
                let directory = directory
                let removesDirectory = removesDirectoryOnClose
                let bridge = bridge
                Task {
                    await bridge.shutdown()
                    if removesDirectory { try? FileManager.default.removeItem(at: directory) }
                }
            }

            func listings() -> Int {
                StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/own-volume/trash") }.count
            }

            func metadataReads() -> Int {
                StubURLProtocol.requests().filter { $0.path == "/drive/shares/share/links/fetch_metadata" }.count
            }

            /// The link IDs of each restore request, in request order.
            func restoredLinkIDs() throws -> [[String]] {
                try StubURLProtocol.requests().filter { $0.method == "PUT" }.map { request in
                    let body = try #require(request.body)
                    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: [String]])
                    return try #require(object["LinkIDs"])
                }
            }
        }
    }
}

private struct NoAlbumBackend: AlbumCatalogBackend, AlbumWriteBackend {
    func listAlbums() async throws -> [AlbumSummary] { [] }
    func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary] { [] }
    func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {}
    func albumMemberships(for photoUIDs: [PhotoUID]) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] { [:] }
    func createAlbum(name: String) async throws -> AlbumID { "a" }
    func deleteAlbum(albumID: AlbumID) async throws {}
    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws {}
    func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws {}
    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {}
}
