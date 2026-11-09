import Foundation
import PhotosCore
import ProtonAuth
import Testing
import UploadCore

@testable import ProtonDriveBackend
@testable import ProtonDriveSDK

@Suite("Account refresh sharing", .serialized)
struct DriveSDKAccountInfoRefreshTests {
    @Test func overlappingAutomaticCallersShareOnePairButALaterCallFetchesAgain() async throws {
        try await withBridge { bridge, governor in
            let first = refresh(bridge, cause: .foregroundActivation)
            try await waitUntil { AccountRefreshHTTP.count == 2 }
            let second = refresh(bridge, cause: .visibleSettings)
            try await bothCallersStarted(bridge)
            AccountRefreshHTTP.release()
            try await first.value
            try await second.value
            #expect(AccountRefreshHTTP.paths.sorted() == ["/core/v4/addresses", "/core/v4/users"])
            try await refresh(bridge, cause: .visibleSettings).value
            #expect(AccountRefreshHTTP.count == 4)
            let records = await governor.requestSupportSnapshot().recentRequests
            #expect(records.count == 4)
            #expect(records.allSatisfy { $0.status == "2xx" })
        }
    }

    @Test func cancellingOneAutomaticCallerDoesNotCancelTheOther() async throws {
        try await withBridge { bridge, _ in
            let first = refresh(bridge, cause: .foregroundActivation)
            try await waitUntil { AccountRefreshHTTP.count == 2 }
            let second = refresh(bridge, cause: .visibleSettings)
            try await bothCallersStarted(bridge)
            first.cancel()
            await #expect(throws: (any Error).self) { try await first.value }
            AccountRefreshHTTP.release()
            try await second.value
            #expect(AccountRefreshHTTP.count == 2)
            try await refresh(bridge, cause: .visibleSettings).value
            #expect(AccountRefreshHTTP.count == 4)
        }
    }

    @Test func failedFlightReachesBothCallersAndDoesNotPoisonTheNextCall() async throws {
        try await withBridge { bridge, _ in
            let first = refresh(bridge, cause: .foregroundActivation)
            try await waitUntil { AccountRefreshHTTP.count == 2 }
            let second = refresh(bridge, cause: .visibleSettings)
            try await bothCallersStarted(bridge)
            AccountRefreshHTTP.release(failing: true)
            await #expect(throws: (any Error).self) { try await first.value }
            await #expect(throws: (any Error).self) { try await second.value }
            AccountRefreshHTTP.release()
            try await refresh(bridge, cause: .foregroundActivation).value
            #expect(AccountRefreshHTTP.count == 4)
        }
    }

    @Test func cancellingTheOnlyCallerDoesNotPoisonTheNextCall() async throws {
        try await withBridge { bridge, _ in
            let first = refresh(bridge, cause: .foregroundActivation)
            try await waitUntil { AccountRefreshHTTP.count == 2 }
            first.cancel()
            await #expect(throws: (any Error).self) { try await first.value }
            AccountRefreshHTTP.release()
            try await refresh(bridge, cause: .visibleSettings).value
            #expect(AccountRefreshHTTP.count == 4)
        }
    }

    @Test func anUnscopedFreshRefreshDoesNotJoinAnAutomaticPair() async throws {
        try await withBridge { bridge, governor in
            let automatic = refresh(bridge, cause: .foregroundActivation)
            try await waitUntil { AccountRefreshHTTP.count == 2 }
            let fresh = Task { try await bridge.refreshAccountInfo() }
            try await waitUntil { AccountRefreshHTTP.count == 4 }
            let laterAutomatic = refresh(bridge, cause: .visibleSettings)
            // Production admission has four API slots. The newer pair must queue instead of joining the old one.
            try await waitUntil { await governor.snapshot().api.queued == 2 }
            AccountRefreshHTTP.release()
            try await automatic.value
            try await fresh.value
            try await laterAutomatic.value
            #expect(AccountRefreshHTTP.count == 6)
        }
    }

    @Test func shutdownCancelsAndJoinsThePairAndRejectsNewRefreshes() async throws {
        try await withBridge { bridge, _ in
            let first = refresh(bridge, cause: .foregroundActivation)
            try await waitUntil { AccountRefreshHTTP.count == 2 }
            await bridge.shutdown()
            await #expect(throws: (any Error).self) { try await first.value }
            await #expect(throws: CancellationError.self) { try await bridge.refreshAccountInfo() }
            #expect(AccountRefreshHTTP.count == 2)
        }
    }

    @Test func anUploadDuringTheFlightRequiresANewAutomaticPair() async throws {
        try await withBridge { bridge, _ in
            let first = refresh(bridge, cause: .foregroundActivation)
            try await waitUntil { AccountRefreshHTTP.count == 2 }
            await bridge.recordCompletedUpload(bytes: 40)
            let second = refresh(bridge, cause: .visibleSettings)
            try await waitUntil { AccountRefreshHTTP.count == 4 }
            AccountRefreshHTTP.release()
            try await first.value
            try await second.value
        }
    }

    @Test func aJoinedWaiterCannotCountAnUploadAsPartOfAnOlderQuotaResponse() async throws {
        try await withBridge { bridge, _ in
            await MainActor.run { AccountInfo.shared.beginSession(accountUID: "account-fixture") }
            let first = refresh(bridge, cause: .foregroundActivation)
            try await waitUntil { AccountRefreshHTTP.count == 2 }
            let second = refresh(bridge, cause: .visibleSettings)
            try await bothCallersStarted(bridge)
            await bridge.recordCompletedUpload(bytes: 40)
            AccountRefreshHTTP.release()
            try await first.value
            try await second.value
            // The old quota has 100 free bytes, but the 40 uploaded during its request still count locally.
            // The capacity check must refresh, then reject 61 bytes against the fresh 60-byte remainder.
            AccountRefreshHTTP.setUsedBytes(40)
            let result: Result<Void, any Error>
            do { result = .success(try await bridge.ensureRemoteCapacity(forBytes: 61, filename: "fixture")) } catch {
                result = .failure(error)
            }
            await MainActor.run { AccountInfo.shared.clear() }
            #expect(throws: UploadError.self) { try result.get() }
            #expect(AccountRefreshHTTP.count == 4)
        }
    }

    @Test func differentBridgesNeverShareARefresh() async throws {
        try await withBridge { firstBridge, _ in
            let first = refresh(firstBridge, cause: .foregroundActivation)
            try await waitUntil { AccountRefreshHTTP.count == 2 }
            try await withBridge(resetHTTP: false) { secondBridge, _ in
                let second = refresh(secondBridge, cause: .visibleSettings)
                try await waitUntil { AccountRefreshHTTP.count == 4 }
                AccountRefreshHTTP.release()
                try await first.value
                try await second.value
            }
        }
    }

    private func refresh(
        _ bridge: DriveSDKBridge, cause: ProtonAccountInfoRequestCause
    ) -> Task<Void, any Error> {
        Task { try await cause.run { try await bridge.refreshAccountInfo() } }
    }

    private func bothCallersStarted(_ bridge: DriveSDKBridge) async throws {
        try await waitUntil { await bridge.accountInfoRefreshes.waitingCallers == 2 }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await condition())
    }

    private func withBridge(
        resetHTTP: Bool = true,
        _ body: (DriveSDKBridge, ProtonRequestGovernor) async throws -> Void
    ) async throws {
        if resetHTTP { AccountRefreshHTTP.reset() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let governor = ProtonRequestGovernor(summaryLog: { _ in })
        let session = DriveSession(
            session: ProtonSession(uid: "account-fixture", accessToken: "", refreshToken: "", keyPassword: ""),
            store: SessionKeychainStore(service: "account-refresh-fixture"),
            accountCacheDirectory: directory, requestGovernor: governor,
            urlProtocolClasses: [AccountRefreshHTTP.self])
        let client = try await EncryptedMemoriesClient(
            configuration: ProtonDriveClientConfiguration(baseURL: "https://fixture.invalid/", clientUID: "fixture"),
            httpClient: SDKHttpClient(
                driveSession: session, requestGovernor: governor, urlProtocolClasses: [AccountRefreshHTTP.self]),
            accountClient: SDKAccountClient(addresses: [], unlockedByKeyID: [:]),
            logCallback: { _ in }, featureFlagProviderCallback: { _, completion in completion(false) },
            recordMetricEventCallback: { _ in })
        let crypto = DriveCrypto(addressKeys: [], signers: [])
        let gate = TimelineMetadataStartGate()
        let bridge = DriveSDKBridge(
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
        do {
            try await body(bridge, governor)
        } catch {
            AccountRefreshHTTP.release()
            await bridge.shutdown()
            throw error
        }
        AccountRefreshHTTP.release()
        await bridge.shutdown()
    }
}

private final class AccountRefreshHTTP: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [AccountRefreshHTTP] = []
    nonisolated(unsafe) private static var requests: [String] = []
    nonisolated(unsafe) private static var released = false
    nonisolated(unsafe) private static var failure = false
    nonisolated(unsafe) private static var usedBytes = 0

    static var count: Int { lock.withLock { requests.count } }
    static var paths: [String] { lock.withLock { requests } }

    static func reset() {
        lock.withLock {
            pending = []
            requests = []
            released = false
            failure = false
            usedBytes = 0
        }
    }

    static func setUsedBytes(_ bytes: Int) { lock.withLock { usedBytes = bytes } }

    static func release(failing: Bool = false) {
        let held = lock.withLock {
            released = true
            failure = failing
            defer { pending.removeAll() }
            return pending
        }
        for request in held { request.respond(failing: failing) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer: Bool? = Self.lock.withLock {
            Self.requests.append(request.url?.path ?? "<missing>")
            if Self.released { return Self.failure }
            Self.pending.append(self)
            return nil
        }
        if let answer { respond(failing: answer) }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.pending.removeAll { $0 === self } }
    }

    private func respond(failing: Bool) {
        if failing {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: String
        switch url.path {
        case "/core/v4/users":
            let used = Self.lock.withLock { Self.usedBytes }
            body = "{\"User\":{\"Keys\":[],\"UsedSpace\":\(used),\"MaxSpace\":100}}"
        case "/core/v4/addresses": body = "{\"Addresses\":[]}"
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
