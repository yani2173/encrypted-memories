import AlbumSyncCore
import Foundation
import PhotosCore
import ProtonAuth
import Testing
import UploadCore

@testable import ProtonDriveBackend
@testable import ProtonDriveSDK

@Suite struct AlbumSyncPhotoRecoveryRemoteOpsTests {
    @Test func contextUsesOwnVolumeAndCurrentKeyEpoch() async throws {
        let checker = RecoveryChecker()
        let ops = makeOps(checker: checker)
        let context = try #require(try await ops.photoRecoveryContext())
        #expect(context.volumeID == "own-volume")
        #expect(context.hashKeyEpoch == "epoch")
        #expect(context.sessionID == ops.recoverySessionID)
    }

    @Test func exactTrashRequiresFreshCompleteStateTwo() async throws {
        let checker = RecoveryChecker()
        let ops = makeOps(checker: checker)
        #expect(try await ops.photoRecoveryState(for: record()) == .trashed)
        #expect(checker.metadataReads == 1)
        #expect(checker.nameReads == 1)
    }

    @Test func explicitTrashWinsOverAnotherActiveCopy() async throws {
        let checker = RecoveryChecker(otherActiveCopy: true)
        #expect(try await makeOps(checker: checker).photoRecoveryState(for: record()) == .trashed)
        #expect(checker.metadataReads == 1)
    }

    @Test func activeExactLinkConverges() async throws {
        let checker = RecoveryChecker(state: 1, duplicateState: .active)
        #expect(try await makeOps(checker: checker).photoRecoveryState(for: record()) == .active)
    }

    @Test(arguments: [0, 3, -1]) func otherStatesStayUnavailable(state: Int) async throws {
        let checker = RecoveryChecker(state: state)
        #expect(try await makeOps(checker: checker).photoRecoveryState(for: record()) == .unavailable)
    }

    @Test func partialMetadataStaysUnavailable() async throws {
        let checker = RecoveryChecker(complete: false)
        #expect(try await makeOps(checker: checker).photoRecoveryState(for: record()) == .unavailable)
    }

    @Test func missingStateStaysUnavailable() async throws {
        let checker = RecoveryChecker(state: nil)
        #expect(try await makeOps(checker: checker).photoRecoveryState(for: record()) == .unavailable)
    }

    @Test func differentContentStaysUnavailable() async throws {
        let checker = RecoveryChecker(contentHash: "other")
        #expect(try await makeOps(checker: checker).photoRecoveryState(for: record()) == .unavailable)
    }

    @Test func restoreDispatchesOnlyAfterAdmission() async throws {
        let calls = RecoveryCalls()
        var ops = makeOps(checker: RecoveryChecker())
        ops.recoveryRestore = { uid in await calls.restore(uid) }
        let context = AlbumSyncPhotoRecovery.Context(
            sessionID: ops.recoverySessionID, volumeID: "own-volume", hashKeyEpoch: "epoch")
        let uid = PhotoUID(volumeID: "own-volume", nodeID: "trash")
        try await ops.restorePhoto(uid, context: context) { await calls.admit() }
        #expect(await calls.events == ["admit", "restore"])
        #expect(await calls.uids == [uid])
    }

    @Test func foreignVolumeNeverDispatches() async {
        let calls = RecoveryCalls()
        var ops = makeOps(checker: RecoveryChecker())
        ops.recoveryRestore = { uid in await calls.restore(uid) }
        let context = AlbumSyncPhotoRecovery.Context(
            sessionID: ops.recoverySessionID, volumeID: "own-volume", hashKeyEpoch: "epoch")
        await #expect(throws: AlbumSyncPhotoRecovery.Error.unavailable) {
            try await ops.restorePhoto(.init(volumeID: "foreign", nodeID: "trash"), context: context) {}
        }
        #expect(await calls.events.isEmpty)
    }

    @Test(arguments: ["missing", "related", "implicit", "active"])
    func unprovenMainRoleStaysUnavailable(role: String) async throws {
        let checker = RecoveryChecker(role: role)
        #expect(try await makeOps(checker: checker).photoRecoveryState(for: record()) == .unavailable)
    }

    @Test(arguments: ["name", "role", "metadata"])
    func evidenceReadErrorPropagates(stage: String) async {
        let checker = RecoveryChecker(failureStage: stage)
        await #expect(throws: URLError.self) {
            try await makeOps(checker: checker).photoRecoveryState(for: record())
        }
    }

    @Test func rejectedFinalAdmissionNeverDispatches() async throws {
        let calls = RecoveryCalls()
        var ops = makeOps(checker: RecoveryChecker())
        ops.recoveryRestore = { uid in await calls.restore(uid) }
        let context = try #require(try await ops.photoRecoveryContext())
        await #expect(throws: CancellationError.self) {
            try await ops.restorePhoto(.init(volumeID: "own-volume", nodeID: "trash"), context: context) {
                throw CancellationError()
            }
        }
        #expect(await calls.events.isEmpty)
    }

    @Test func retiredProblemSessionNeverDispatches() async throws {
        let calls = RecoveryCalls()
        var ops = makeOps(checker: RecoveryChecker())
        ops.recoveryRestore = { uid in await calls.restore(uid) }
        let context = AlbumSyncPhotoRecovery.Context(sessionID: UUID(), volumeID: "own-volume", hashKeyEpoch: "epoch")
        await #expect(throws: AlbumSyncPhotoRecovery.Error.unavailable) {
            try await ops.restorePhoto(.init(volumeID: "own-volume", nodeID: "trash"), context: context) {}
        }
        #expect(await calls.events.isEmpty)
    }

    @Test func changedEpochCannotSupplyEvidence() async throws {
        #expect(
            try await makeOps(checker: RecoveryChecker(epoch: "changed")).photoRecoveryState(for: record())
                == .unavailable)
    }

    @Test func differentNameCannotSupplyEvidence() async throws {
        #expect(
            try await makeOps(checker: RecoveryChecker(rowNameHash: "other")).photoRecoveryState(for: record())
                == .unavailable)
    }

    @Test(arguments: [nil, RemotePhotoDuplicate.LinkState.draft])
    func missingOrDraftDuplicateStateIsUnavailable(state: RemotePhotoDuplicate.LinkState?) async throws {
        #expect(
            try await makeOps(checker: RecoveryChecker(state: state?.rawValue ?? 2, duplicateState: state))
                .photoRecoveryState(for: record()) == .unavailable)
    }

    @Test func conflictingExactRowsCannotSupplyEvidence() async throws {
        #expect(
            try await makeOps(checker: RecoveryChecker(conflictingRow: true)).photoRecoveryState(for: record())
                == .unavailable)
    }

    @Test(arguments: ["volume", "epoch"])
    func emptyAdapterContextIsUnavailable(field: String) async throws {
        var ops = makeOps(checker: RecoveryChecker(epoch: field == "epoch" ? "" : "epoch"))
        if field == "volume" { ops.recoveryVolumeProvider = { "" } }
        #expect(try await ops.photoRecoveryContext() == nil)
    }

    @Test func emptyNodeCannotDispatch() async throws {
        let calls = RecoveryCalls()
        var ops = makeOps(checker: RecoveryChecker())
        ops.recoveryRestore = { await calls.restore($0) }
        let context = try #require(try await ops.photoRecoveryContext())
        await #expect(throws: AlbumSyncPhotoRecovery.Error.unavailable) {
            try await ops.restorePhoto(.init(volumeID: "own-volume", nodeID: ""), context: context) {}
        }
        #expect(await calls.events.isEmpty)
    }

    private func record() -> UploadIdentityRecord {
        .init(
            source: .init(kind: .photoLibraryAsset, identifier: "asset"), filename: "photo",
            correctedName: "photo", fileSize: 4, modificationDate: .distantPast,
            sha1Hex: String(repeating: "01", count: 20), nameHash: "name", contentHash: "content",
            hashKeyEpoch: "epoch", remoteVolumeID: "own-volume", remoteLinkID: "trash",
            outcome: "duplicateTrashed", updatedAt: .distantPast)
    }

    private func makeOps(checker: any UploadDuplicateChecking) -> ProtonAlbumSyncRemoteOps {
        let session = DriveSession(
            session: ProtonSession(uid: "test", accessToken: "", refreshToken: "", keyPassword: ""),
            store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
            accountCacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let service = ProtonAlbumWriteService(session: session, crypto: DriveCrypto(addressKeys: [], signers: [])) {
            PhotosShareContext(volumeID: "own-volume", shareID: "share", rootLinkID: "root")
        }
        return ProtonAlbumSyncRemoteOps(
            service: service, listProvider: { [] }, duplicateChecker: checker,
            recoveryVolumeProvider: { "own-volume" }, recoveryRestore: { _ in })
    }
}

private actor RecoveryCalls {
    var events: [String] = []
    var uids: [PhotoUID] = []
    func admit() { events.append("admit") }
    func restore(_ uid: PhotoUID) {
        events.append("restore")
        uids.append(uid)
    }
}

private final class RecoveryChecker: UploadDuplicateChecking, @unchecked Sendable {
    let state: Int?
    let complete: Bool
    let contentHash: String
    let duplicateState: RemotePhotoDuplicate.LinkState?
    let role: String
    let failureStage: String?
    let otherActiveCopy: Bool
    let epoch: String
    let rowNameHash: String
    let conflictingRow: Bool
    private let lock = NSLock()
    private var reads = (metadata: 0, name: 0)
    var metadataReads: Int { lock.withLock { reads.metadata } }
    var nameReads: Int { lock.withLock { reads.name } }
    init(
        state: Int? = 2, complete: Bool = true, contentHash: String = "content",
        duplicateState: RemotePhotoDuplicate.LinkState? = .trashed, role: String = "main", failureStage: String? = nil,
        otherActiveCopy: Bool = false, epoch: String = "epoch", rowNameHash: String = "name",
        conflictingRow: Bool = false
    ) {
        self.state = state
        self.complete = complete
        self.contentHash = contentHash
        self.duplicateState = duplicateState
        self.role = role
        self.failureStage = failureStage
        self.otherActiveCopy = otherActiveCopy
        self.epoch = epoch
        self.rowNameHash = rowNameHash
        self.conflictingRow = conflictingRow
    }
    func hashKeyEpoch() async throws -> String { epoch }
    func nameHash(forCorrectedName name: String) async throws -> String { "name" }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { contentHash }
    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        if failureStage == "name" { throw URLError(.notConnectedToInternet) }
        lock.withLock { reads.name += 1 }
        var rows = [
            RemotePhotoDuplicate(
                nameHash: rowNameHash, contentHash: contentHash, linkState: duplicateState, linkID: "trash")
        ]
        if otherActiveCopy {
            rows.insert(.init(nameHash: "name", contentHash: contentHash, linkState: .active, linkID: "other"), at: 0)
        }
        if conflictingRow {
            rows.append(.init(nameHash: "name", contentHash: contentHash, linkState: .active, linkID: "trash"))
        }
        return rows
    }
    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? { nil }
    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> { [] }
    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
        if failureStage == "role" { throw URLError(.notConnectedToInternet) }
        if role == "missing" { return [:] }
        return [
            "trash": .init(
                isActive: role == "active" || state == 1,
                mainPhotoLinkID: role == "related" ? "other" : nil,
                hasExplicitPhotoState: role != "implicit")
        ]
    }
    func linkStateSnapshot(of linkIDs: [String]) async throws -> UploadLinkStateSnapshot {
        if failureStage == "metadata" { throw URLError(.notConnectedToInternet) }
        lock.withLock { reads.metadata += 1 }
        return .init(states: state.map { ["trash": $0] } ?? [:], complete: complete)
    }
}

extension DriveSessionStubSuite {
    @Suite struct AlbumSyncPhotoRecoveryBridgeTests {
        @Test func existingBridgeRestoresTheMainAndRelatedPhotoAndRejectsRetiredSession() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "GET /drive/shares",
                json: #"{"Code":1000,"Shares":[{"ShareID":"share","VolumeID":"own-volume","LinkID":"root","State":1}]}"#
            )
            let before = #"""
                {"Code":1000,"Links":[
                  {"LinkID":"trash","State":2,"Trashed":1000,"FileProperties":{"ActiveRevision":{"Photo":{}}}},
                  {"LinkID":"frame","State":2,"Trashed":1001,"FileProperties":{"ActiveRevision":{"Photo":{"MainPhotoLinkID":"trash"}}}}
                ]}
                """#
            let after = before.replacingOccurrences(
                of: "\"LinkID\":\"trash\",\"State\":2", with: "\"LinkID\":\"trash\",\"State\":1")
            StubURLProtocol.routeSequence(
                "POST /drive/shares/share/links/fetch_metadata", responses: [(200, before), (200, after)])
            StubURLProtocol.routeSequence(
                "PUT /drive/v2/volumes/own-volume/trash/restore_multiple",
                responses: [
                    (200, #"{"Code":1000,"Responses":[{"LinkID":"trash","Response":{"Code":1000}}]}"#),
                    (200, #"{"Code":1000,"Responses":[{"LinkID":"frame","Response":{"Code":1000}}]}"#),
                ])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let governor = ProtonRequestGovernor()
            let session = DriveSession(
                session: ProtonSession(uid: "test", accessToken: "", refreshToken: "", keyPassword: ""),
                store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
                accountCacheDirectory: directory, requestGovernor: governor, urlProtocolClasses: [StubURLProtocol.self])
            let client = try await EncryptedMemoriesClient(
                configuration: ProtonDriveClientConfiguration(
                    baseURL: "https://fixture.invalid/", clientUID: "fixture"),
                httpClient: SDKHttpClient(
                    driveSession: session, requestGovernor: governor,
                    urlProtocolClasses: [StubURLProtocol.self]),
                accountClient: SDKAccountClient(addresses: [], unlockedByKeyID: [:]),
                logCallback: { _ in }, featureFlagProviderCallback: { _, completion in completion(false) },
                recordMetricEventCallback: { _ in })
            let crypto = DriveCrypto(addressKeys: [], signers: [])
            let gate = TimelineMetadataStartGate()
            let main = PhotoUID(volumeID: "own-volume", nodeID: "trash")
            let bridge = DriveSDKBridge(
                prepared: .init(
                    photosClient: client, uploadClientUID: "fixture", driveSession: session, requestGovernor: governor,
                    expensiveUploadAccess: ExpensiveUploadAccess(), timelineStore: nil, timelineOrderStore: nil,
                    firstIndexBuildGate: gate, metadataReconciliation: TimelineMetadataReconciliation(startGate: gate),
                    crypto: crypto,
                    photosVolumeBootstrap: PhotosVolumeBootstrapService(session: session, crypto: crypto),
                    recentlyDeletedStore: RecentlyDeletedListingStore(
                        directory: directory, accountUID: "fixture", keyPassword: ""),
                    photoNames: nil, recentlyDeleted: RecentlyDeletedIdentities(listing: nil),
                    uploadManifestURL: directory.appendingPathComponent("manifest.sqlite"),
                    uploadManifestPolicy: .conservative),
                checkedSeriesRestoreCandidates: [main: [.init(volumeID: "own-volume", nodeID: "frame")]])
            let service = ProtonAlbumWriteService(session: session, crypto: crypto) {
                try await bridge.photosShareContext()
            }
            let ops = ProtonAlbumSyncRemoteOps.withRecovery(
                service: service, listProvider: { [] }, duplicateChecker: RecoveryChecker(), bridge: bridge)
            do {
                let context = try #require(try await ops.photoRecoveryContext())
                try await ops.restorePhoto(main, context: context) {}
                let writes = StubURLProtocol.requests().filter { $0.method == "PUT" }
                let ids = try writes.map { request -> [String] in
                    let body = try #require(request.body)
                    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: [String]])
                    return try #require(object["LinkIDs"])
                }
                #expect(ids == [["trash"], ["frame"]])
                #expect(writes.allSatisfy { $0.path == "/drive/v2/volumes/own-volume/trash/restore_multiple" })
                await bridge.shutdown()
                let count = StubURLProtocol.requests().count
                await #expect(throws: CancellationError.self) {
                    try await ops.restorePhoto(main, context: context) {}
                }
                #expect(StubURLProtocol.requests().count == count)
            } catch {
                await bridge.shutdown()
                throw error
            }
        }
    }
}
