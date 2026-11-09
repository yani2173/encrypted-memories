import Foundation
import PhotosCore
import ProtonAuth
import Testing

@testable import ProtonDriveBackend
@testable import ProtonDriveSDK

/// A viewer or export read holds new uploads while it runs. When it fails, its priority scope must still end, so a
/// waiting upload continues (#590).
@Suite("Drive SDK bridge priority scopes", .serialized)
struct DriveSDKBridgePriorityScopeTests {
    enum Entry: String, CaseIterable, Sendable {
        case originalData, streamOriginalBytes, writeOriginal, preview, prefetchEncrypted, streamingAsset
    }

    @Test func failedTimelineMeasuresTotalWithoutInventingEnumerationOrTags() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let governor = ProtonRequestGovernor()
        let bridge = try await Self.makeBridge(directory: directory, governor: governor)
        await #expect(throws: (any Error).self) { try await bridge.loadTimelineSnapshot() }
        let state = governor.workMeasurements.workMeasurementSupportSnapshot().passes[
            SupportMeasurementKind.timelineLoad.rawValue]
        let sample = try #require(state.samples.first)
        #expect(state.started == 1 && state.completed == 1 && state.inProgress == 0)
        #expect(sample.outcome == 2)
        #expect(sample.enumerationClass == -1 && sample.tagsClass == -1)
        #expect(sample.totalClass >= 0)
        await bridge.shutdown()
        #expect(governor.workMeasurements.workMeasurementSupportSnapshot().availability == 0)
    }

    @Test(arguments: Entry.allCases)
    func aFailedReadEndsItsPriorityScope(entry: Entry) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let governor = ProtonRequestGovernor()
        let bridge = try await Self.makeBridge(directory: directory, governor: governor)
        let uid = PhotoUID(volumeID: "vol", nodeID: "photo")

        await #expect(throws: (any Error).self) { try await read(entry, of: uid, from: bridge, in: directory) }

        // An upload acquire waits while any scope that holds uploads is open.
        let upload = Task { try await governor.acquire(scope: .storageUpload, priority: .background) }
        let admitted = await eventually(timeout: .seconds(5)) {
            await governor.snapshot().storageUpload.inFlight == 1
        }
        #expect(admitted, "the failed \(entry.rawValue) read left its priority scope open")
        // A held acquire would never return; only an admitted one is awaited and finished.
        guard admitted else { return upload.cancel() }
        await governor.finish(try await upload.value, statusCode: 200)
    }

    private func read(_ entry: Entry, of uid: PhotoUID, from bridge: DriveSDKBridge, in directory: URL) async throws {
        switch entry {
        case .originalData: _ = try await bridge.originalData(for: uid, onProgress: { _ in })
        case .streamOriginalBytes:
            try await bridge.streamOriginalBytes(for: uid, onChunk: { _ in }, onProgress: { _ in })
        case .writeOriginal:
            try await bridge.writeOriginal(
                for: uid, to: directory.appendingPathComponent("export.jpg"), onProgress: { _ in })
        case .preview: _ = try await bridge.preview(for: uid)
        case .prefetchEncrypted: try await bridge.prefetchEncrypted(for: uid)
        case .streamingAsset: _ = try await bridge.makeStreamingAsset(for: uid)
        }
    }

    /// A bridge whose every request fails as if the device were offline. Other bridge suites reuse it.
    static func makeBridge(directory: URL, governor: ProtonRequestGovernor) async throws -> DriveSDKBridge {
        let session = DriveSession(
            session: ProtonSession(uid: "scope-fixture", accessToken: "", refreshToken: "", keyPassword: ""),
            store: SessionKeychainStore(service: "scope-fixture", account: "fixture", keychain: DenyingKeychainStore()),
            accountCacheDirectory: directory, requestGovernor: governor, urlProtocolClasses: [ScopeDenyHTTP.self])
        let client = try await EncryptedMemoriesClient(
            configuration: ProtonDriveClientConfiguration(baseURL: "https://fixture.invalid/", clientUID: "fixture"),
            httpClient: SDKHttpClient(
                driveSession: session, requestGovernor: governor, urlProtocolClasses: [ScopeDenyHTTP.self]),
            accountClient: SDKAccountClient(addresses: [], unlockedByKeyID: [:]),
            logCallback: { _ in },
            featureFlagProviderCallback: { _, completion in completion(false) },
            recordMetricEventCallback: { _ in })
        let crypto = DriveCrypto(addressKeys: [], signers: [])
        let gate = TimelineMetadataStartGate()
        return DriveSDKBridge(
            prepared: DriveSDKBridge.PreparedSession(
                photosClient: client, uploadClientUID: "fixture", driveSession: session,
                requestGovernor: governor, expensiveUploadAccess: ExpensiveUploadAccess(),
                timelineStore: nil, timelineOrderStore: nil, firstIndexBuildGate: gate,
                metadataReconciliation: TimelineMetadataReconciliation(startGate: gate), crypto: crypto,
                photosVolumeBootstrap: PhotosVolumeBootstrapService(session: session, crypto: crypto),
                recentlyDeletedStore: RecentlyDeletedListingStore(
                    directory: directory, accountUID: "fixture", keyPassword: ""),
                photoNames: nil, recentlyDeleted: RecentlyDeletedIdentities(listing: nil),
                uploadManifestURL: directory.appendingPathComponent("manifest.sqlite"),
                uploadManifestPolicy: .conservative))
    }
}

/// Every request fails as if the device were offline.
final class ScopeDenyHTTP: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
