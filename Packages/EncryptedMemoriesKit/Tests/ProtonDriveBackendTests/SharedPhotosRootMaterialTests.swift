import CryptoKit
import Foundation
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoPatchedGoImplementation
import ProtonDriveSDK
import Testing
import UploadCore

@testable import ProtonDriveBackend

@Suite("Shared Photos root material", .serialized)
struct SharedPhotosRootMaterialTests {
    @Test func twoColdServicesShareBootstrapAndRootDecryption() async throws {
        injectDefaultCryptoImplementation()
        let fixture = try RootMaterialFixture()
        RootMaterialHTTP.install(fixture)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try #require(UploadIdentityManifestStore(url: directory.appendingPathComponent("manifest.sqlite")))
        defer {
            fixture.release()
            RootMaterialHTTP.clear()
            store.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let session = DriveSession(
            session: ProtonSession(uid: "root-fixture", accessToken: "synthetic", refreshToken: "", keyPassword: ""),
            store: SessionKeychainStore(service: "root-fixture", account: "fixture", keychain: DenyingKeychainStore()),
            accountCacheDirectory: directory, urlProtocolClasses: [RootMaterialHTTP.self])
        let resolver = PhotosRootMaterialResolver()
        let album = ProtonAlbumWriteService(session: session, crypto: fixture.crypto, rootMaterialResolver: resolver) {
            fixture.context()
        }
        let dedupe = ProtonUploadDedupeService(
            session: session, crypto: fixture.crypto, rootMaterialResolver: resolver,
            photosClient: RootMaterialUnusedSDK(), contentIndexStore: store
        ) { fixture.context() }
        let albumTask = Task { try await album.resolveRootMaterial() }
        let dedupeTask = Task { try await dedupe.hashKeyEpoch() }
        let end = ContinuousClock.now + .seconds(5)
        while !fixture.bothConsumersReachedBootstrap && ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let ready = fixture.bothConsumersReachedBootstrap
        fixture.release()
        let albumResult = await albumTask.result
        let dedupeResult = await dedupeTask.result
        await resolver.shutdown()
        await dedupe.shutdown()
        do {
            let root = try albumResult.get()
            let epoch = try dedupeResult.get()
            // Validate both service results before asserting the transport counts.
            try #require(ready, "both real services must enter before the first bootstrap answer")
            try #require(root.context == fixture.shareContext)
            try #require(root.rootHashKey == Data(fixture.hashToken.utf8))
            try #require(root.signer.addressID == "address")
            let expectedEpoch = SHA256.hash(data: Data(fixture.hashToken.utf8)).prefix(8)
                .map { String(format: "%02x", $0) }.joined()
            try #require(epoch == expectedEpoch)
        } catch {
            try fixture.writeEvidence(status: "setup-unverified")
            Issue.record("ROOT_MATERIAL_SETUP_FAILURE: no valid two-service measurement")
            return
        }
        try fixture.writeEvidence(status: "both-services-decrypted")
        #expect(fixture.paths.filter { $0 == RootMaterialFixture.sharePath }.count == 1)
        #expect(fixture.paths.filter { $0 == RootMaterialFixture.rootPath }.count == 1)
        #expect(fixture.paths.count == 2)
    }

    @Test func singleConsumerKeepsTwoRequestsAndItsCompletedCache() async throws {
        try await withRootEnvironment { env in
            env.fixture.release()
            let album = env.album()
            _ = try await album.resolveRootMaterial()
            _ = try await album.resolveRootMaterial()
            #expect(env.fixture.paths.count == 2)
        }
    }

    enum Consumer: CaseIterable, Sendable { case album, dedupe }

    @Test(arguments: Consumer.allCases)
    func sameServiceColdCallsKeepOneContextAndRequestPair(consumer: Consumer) async throws {
        try await withRootEnvironment { env in
            let context = RootContextGate(context: env.fixture.shareContext)
            defer { context.release() }
            let operation: @Sendable () async throws -> Void
            switch consumer {
            case .album:
                let album = env.album(contextProvider: { await context.read() })
                operation = { _ = try await album.resolveRootMaterial() }
            case .dedupe:
                let dedupe = env.dedupe(contextProvider: { await context.read() })
                operation = { _ = try await dedupe.hashKeyEpoch() }
            }
            let first = env.start(operation)
            try #require(await eventually(timeout: .seconds(2)) { env.fixture.paths.count == 1 })
            let second = env.start(operation)
            // A second context lookup, if attempted, stays held until the first caller fills its cache.
            _ = await eventually(timeout: .milliseconds(200)) { context.calls == 2 }
            env.fixture.release()
            await first.join()
            context.release()
            await second.join()
            #expect(first.succeeded && second.succeeded)
            #expect(context.calls == 1)
            #expect(env.fixture.paths == [RootMaterialFixture.sharePath, RootMaterialFixture.rootPath])
        }
    }

    @Test(arguments: Consumer.allCases)
    func sameServiceWaiterCancellationKeepsOtherCallAlive(consumer: Consumer) async throws {
        try await withRootEnvironment { env in
            let operation: @Sendable () async throws -> Void
            switch consumer {
            case .album:
                let album = env.album()
                operation = { _ = try await album.resolveRootMaterial() }
            case .dedupe:
                let dedupe = env.dedupe()
                operation = { _ = try await dedupe.hashKeyEpoch() }
            }
            let first = env.start(operation)
            try #require(await eventually(timeout: .seconds(2)) { env.fixture.paths.count == 1 })
            let second = env.start(operation)
            first.cancel()
            #expect(await eventually(timeout: .seconds(2)) { first.finished })
            env.fixture.release()
            await first.join()
            await second.join()
            #expect(first.cancelled && second.succeeded)
            #expect(env.fixture.paths == [RootMaterialFixture.sharePath, RootMaterialFixture.rootPath])
        }
    }

    @Test(arguments: Consumer.allCases)
    func serviceShutdownJoinsContextLookupBeforeReturning(consumer: Consumer) async throws {
        try await withRootEnvironment { env in
            let context = RootContextGate(context: env.fixture.shareContext, holdingCall: 1)
            defer { context.release() }
            let work: RootWork
            let shutdownOperation: @Sendable () async -> Void
            switch consumer {
            case .album:
                let album = env.album(contextProvider: { await context.read() })
                work = env.start { _ = try await album.resolveRootMaterial() }
                shutdownOperation = { await env.albumAdmission.closeAdmissionAndJoin() }
            case .dedupe:
                let dedupe = env.dedupe(contextProvider: { await context.read() })
                work = env.start { _ = try await dedupe.hashKeyEpoch() }
                shutdownOperation = { await dedupe.shutdown() }
            }
            try #require(await eventually(timeout: .seconds(2)) { context.calls == 1 })
            let shutdown = env.start { await shutdownOperation() }
            let returnedWhileHeld = await eventually(timeout: .milliseconds(200)) { shutdown.finished }
            #expect(!returnedWhileHeld)
            context.release()
            env.fixture.release()
            await shutdown.join()
            await work.join()
            #expect(work.cancelled)
            #expect(env.fixture.paths.isEmpty)
        }
    }

    @Test func completedMaterialIsNotSharedAcrossLaterColdConsumers() async throws {
        try await withRootEnvironment { env in
            env.fixture.release()
            let album = env.album()
            let dedupe = env.dedupe()
            _ = try await album.resolveRootMaterial()
            _ = try await dedupe.hashKeyEpoch()
            _ = try await album.resolveRootMaterial()
            _ = try await dedupe.hashKeyEpoch()
            #expect(env.fixture.paths.count == 4)
            #expect(await env.resolver.activeResolutionCount == 0)
        }
    }

    enum ScopeChange: CaseIterable, Equatable, Sendable { case session, crypto, volume, share, root }

    @Test(arguments: ScopeChange.allCases)
    func differentAccountCryptoAndRootScopesNeverJoin(change: ScopeChange) async throws {
        try await withRootEnvironment { env in
            let first = env.start {
                _ = try await env.resolver.resolve(
                    session: env.session, crypto: env.fixture.crypto, context: env.fixture.shareContext)
            }
            try #require(await eventually(timeout: .seconds(2)) { env.fixture.paths.count == 1 })
            let otherSession = change == .session ? env.makeSession() : env.session
            let otherCrypto = change == .crypto ? DriveCrypto(addressKeys: [], signers: []) : env.fixture.crypto
            let context = PhotosShareContext(
                volumeID: change == .volume ? "volume-other" : "volume",
                shareID: change == .share ? "share-other" : "share",
                rootLinkID: change == .root ? "root-other" : "root")
            let second = env.start {
                let value = try await env.resolver.resolve(session: otherSession, crypto: otherCrypto, context: context)
                #expect(value.context == context)
                let expectedHash = change == .session ? env.fixture.otherHashToken : env.fixture.hashToken
                #expect(value.hashKey == Data(expectedHash.utf8))
            }
            try #require(await eventually(timeout: .seconds(2)) { await env.resolver.waitingCount == 2 })
            #expect(await env.resolver.activeResolutionCount == 2)
            env.fixture.release()
            await first.join()
            await second.join()
            #expect(first.succeeded)
            if change == .crypto {
                #expect(!second.succeeded, "unrelated decryption keys must not receive another consumer's material")
                #expect(env.fixture.paths.count == 3)
            } else {
                #expect(second.succeeded)
                #expect(env.fixture.paths.count == 4)
            }
        }
    }

    @Test func cancelledWaiterFinishesWhileAnotherWaiterStillNeedsTheRoot() async throws {
        try await withRootEnvironment { env in
            let operation: @Sendable () async throws -> Void = {
                _ = try await env.resolver.resolve(
                    session: env.session, crypto: env.fixture.crypto, context: env.fixture.shareContext)
            }
            let first = env.start(operation)
            let second = env.start(operation)
            try #require(await eventually(timeout: .seconds(2)) { await env.resolver.waitingCount == 2 })
            first.cancel()
            let cancelledWhileHeld = await eventually(timeout: .seconds(2)) { first.finished }
            #expect(cancelledWhileHeld)
            #expect(!second.finished)
            #expect(await env.resolver.activeResolutionCount == 1)
            env.fixture.release()
            await first.join()
            await second.join()
            #expect(first.cancelled && second.succeeded)
            #expect(env.fixture.paths.count == 2)
        }
    }

    @Test func preCancelledWaiterStartsNoResolution() async throws {
        try await withRootEnvironment { env in
            let work = env.start {
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await env.resolver.resolve(
                    session: env.session, crypto: env.fixture.crypto, context: env.fixture.shareContext)
            }
            try #require(await eventually(timeout: .seconds(2)) { work.finished })
            #expect(work.cancelled)
            #expect(await env.resolver.activeResolutionCount == 0)
            #expect(env.fixture.paths.isEmpty)
        }
    }

    @Test func shutdownJoinsHeldCompletionRejectsLateDeliveryAndClosesAdmission() async throws {
        try await withRootEnvironment(holdCompletion: true) { env in
            env.fixture.release()
            let work = env.start {
                _ = try await env.resolver.resolve(
                    session: env.session, crypto: env.fixture.crypto, context: env.fixture.shareContext)
            }
            try #require(await eventually(timeout: .seconds(2)) { env.completion.entered })
            let shutdown = env.start { await env.resolver.shutdown() }
            try #require(await eventually(timeout: .seconds(2)) { await env.resolver.isClosed })
            let shutdownReturnedWhileHeld = await eventually(timeout: .milliseconds(200)) { shutdown.finished }
            #expect(!shutdownReturnedWhileHeld)
            env.completion.release()
            await shutdown.join()
            await work.join()
            #expect(work.cancelled)
            #expect(await env.resolver.activeResolutionCount == 0)
            let late = env.start {
                _ = try await env.resolver.resolve(
                    session: env.session, crypto: env.fixture.crypto, context: env.fixture.shareContext)
            }
            await late.join()
            #expect(late.cancelled)
            #expect(env.fixture.paths.count == 2)
        }
    }

    @Test func missingHashKeyKeepsConsumerErrorsAndFailedResolutionRetryable() async throws {
        try await withRootEnvironment { env in
            env.fixture.release()
            env.fixture.omitHashKey(true)
            let album = env.album()
            let dedupe = env.dedupe()
            let first = env.start { _ = try await album.resolveRootMaterial() }
            await first.join()
            let second = env.start { _ = try await dedupe.hashKeyEpoch() }
            await second.join()
            if case .missingRootHashKey? = first.error as? ProtonAlbumWriteError {
            } else {
                Issue.record("album error mapping changed")
            }
            if case .missingRootHashKey? = second.error as? ProtonUploadDedupeError {
            } else {
                Issue.record("dedupe error mapping changed")
            }
            env.fixture.omitHashKey(false)
            let albumRetry = env.start { _ = try await album.resolveRootMaterial() }
            await albumRetry.join()
            let dedupeRetry = env.start { _ = try await dedupe.hashKeyEpoch() }
            await dedupeRetry.join()
            #expect(albumRetry.succeeded && dedupeRetry.succeeded)
            #expect(env.fixture.paths.count == 8)
        }
    }

    @Test func dedupeWithoutSignerDoesNotAcquireTheAlbumSignerRequirement() async throws {
        try await withRootEnvironment { env in
            let album = env.album(crypto: env.fixture.noSignerCrypto)
            let dedupe = env.dedupe(crypto: env.fixture.noSignerCrypto)
            let albumWork = env.start { _ = try await album.resolveRootMaterial() }
            let dedupeWork = env.start { _ = try await dedupe.hashKeyEpoch() }
            try #require(await eventually(timeout: .seconds(2)) { await env.resolver.waitingCount == 2 })
            env.fixture.release()
            await albumWork.join()
            await dedupeWork.join()
            if case .noSigningKey? = albumWork.error as? ProtonAlbumWriteError {
            } else {
                Issue.record("album must require its signer")
            }
            #expect(dedupeWork.succeeded)
            #expect(env.fixture.paths.count == 2)
        }
    }

    @Test func dedupeShutdownLeavesTheAlbumWaiterRunning() async throws {
        try await withRootEnvironment { env in
            let album = env.album()
            let dedupe = env.dedupe()
            let albumWork = env.start { _ = try await album.resolveRootMaterial() }
            let dedupeWork = env.start { _ = try await dedupe.hashKeyEpoch() }
            try #require(await eventually(timeout: .seconds(2)) { await env.resolver.waitingCount == 2 })
            let shutdown = env.start { await dedupe.shutdown() }
            let dedupeFinishedWhileHeld = await eventually(timeout: .seconds(2)) {
                dedupeWork.finished && shutdown.finished
            }
            #expect(dedupeFinishedWhileHeld)
            #expect(!albumWork.finished)
            env.fixture.release()
            await albumWork.join()
            await dedupeWork.join()
            await shutdown.join()
            #expect(albumWork.succeeded && dedupeWork.cancelled)
            #expect(env.fixture.paths.count == 2)
        }
    }

    @Test func ownedResolverEndsAtDedupeShutdownAndWarmCacheStaysClosed() async throws {
        try await withRootEnvironment { env in
            let dedupe = env.dedupe(shared: false)
            let work = env.start { _ = try await dedupe.hashKeyEpoch() }
            try #require(await eventually(timeout: .seconds(2)) { env.fixture.paths.count == 1 })
            let shutdown = env.start { await dedupe.shutdown() }
            let stoppedWhileHeld = await eventually(timeout: .seconds(2)) { shutdown.finished }
            #expect(stoppedWhileHeld)
            #expect(await dedupe.rootMaterialResolver.activeResolutionCount == 0)
            env.fixture.release()
            await shutdown.join()
            await work.join()
            #expect(work.cancelled)
        }
        try await withRootEnvironment { env in
            env.fixture.release()
            let dedupe = env.dedupe()
            _ = try await dedupe.hashKeyEpoch()
            await dedupe.shutdown()
            let late = env.start { _ = try await dedupe.hashKeyEpoch() }
            await late.join()
            #expect(late.cancelled)
            #expect(env.fixture.paths.count == 2)
        }
    }
}

private func withRootEnvironment(
    holdCompletion: Bool = false, _ body: (RootEnvironment) async throws -> Void
) async throws {
    let env = try RootEnvironment(holdCompletion: holdCompletion)
    do {
        try await body(env)
    } catch {
        await env.close()
        throw error
    }
    await env.close()
}

private final class RootCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    private var released: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(holding: Bool) { released = !holding }
    var entered: Bool { lock.withLock { didEnter } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                didEnter = true
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func release() {
        let pending = lock.withLock {
            released = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

private final class RootContextGate: @unchecked Sendable {
    private let lock = NSLock()
    private let context: PhotosShareContext
    private let holdingCall: Int
    private var count = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(context: PhotosShareContext, holdingCall: Int = 2) {
        self.context = context
        self.holdingCall = holdingCall
    }
    var calls: Int { lock.withLock { count } }
    func read() async -> PhotosShareContext {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                count += 1
                if count != holdingCall || released { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
        return context
    }
    func release() {
        let pending = lock.withLock {
            released = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

private final class RootOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var failure: (any Error)?
    var finished: Bool { lock.withLock { done } }
    var succeeded: Bool { lock.withLock { done && failure == nil } }
    var error: (any Error)? { lock.withLock { failure } }
    func finish(_ error: (any Error)?) {
        lock.withLock {
            failure = error
            done = true
        }
    }
}

private final class RootWork: Sendable {
    private let outcome: RootOutcome
    private let task: Task<Void, Never>
    init(_ operation: @escaping @Sendable () async throws -> Void) {
        let outcome = RootOutcome()
        self.outcome = outcome
        task = Task {
            do {
                try await operation()
                outcome.finish(nil)
            } catch { outcome.finish(error) }
        }
    }
    var finished: Bool { outcome.finished }
    var succeeded: Bool { outcome.succeeded }
    var error: (any Error)? { outcome.error }
    var cancelled: Bool { error is CancellationError }
    func cancel() { task.cancel() }
    func join() async { await task.value }
}

private final class RootEnvironment: @unchecked Sendable {
    let fixture: RootMaterialFixture
    let directory: URL
    let store: UploadIdentityManifestStore
    let session: DriveSession
    let resolver: PhotosRootMaterialResolver
    let completion: RootCompletionGate
    let albumAdmission = JoinedShutdownGate()
    private var work: [RootWork] = []
    private var dedupeServices: [ProtonUploadDedupeService] = []

    init(holdCompletion: Bool) throws {
        injectDefaultCryptoImplementation()
        fixture = try RootMaterialFixture()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try #require(UploadIdentityManifestStore(url: directory.appendingPathComponent("manifest.sqlite")))
        let completion = RootCompletionGate(holding: holdCompletion)
        self.completion = completion
        resolver = PhotosRootMaterialResolver { await completion.wait() }
        session = Self.session(directory)
        RootMaterialHTTP.install(fixture)
    }

    private static func session(_ directory: URL, uid: String = "root-fixture") -> DriveSession {
        DriveSession(
            session: ProtonSession(uid: uid, accessToken: "synthetic", refreshToken: "", keyPassword: ""),
            store: SessionKeychainStore(service: "root-fixture", account: "fixture", keychain: DenyingKeychainStore()),
            accountCacheDirectory: directory, urlProtocolClasses: [RootMaterialHTTP.self])
    }
    func makeSession() -> DriveSession { Self.session(directory, uid: "root-other-fixture") }
    func album(
        crypto: DriveCrypto? = nil,
        contextProvider: (@Sendable () async throws -> PhotosShareContext)? = nil
    ) -> ProtonAlbumWriteService {
        let context = fixture.shareContext
        return ProtonAlbumWriteService(
            session: session, crypto: crypto ?? fixture.crypto, rootMaterialResolver: resolver,
            admission: albumAdmission
        ) { try await contextProvider?() ?? context }
    }
    func dedupe(
        crypto: DriveCrypto? = nil, shared: Bool = true,
        contextProvider: (@Sendable () async throws -> PhotosShareContext)? = nil
    ) -> ProtonUploadDedupeService {
        let context = fixture.shareContext
        let service = ProtonUploadDedupeService(
            session: session, crypto: crypto ?? fixture.crypto, rootMaterialResolver: shared ? resolver : nil,
            photosClient: RootMaterialUnusedSDK(), contentIndexStore: store
        ) { try await contextProvider?() ?? context }
        dedupeServices.append(service)
        return service
    }
    func start(_ operation: @escaping @Sendable () async throws -> Void) -> RootWork {
        let running = RootWork(operation)
        work.append(running)
        return running
    }
    func close() async {
        fixture.release()
        completion.release()
        await albumAdmission.closeAdmissionAndJoin()
        for running in work { await running.join() }
        await resolver.shutdown()
        for service in dedupeServices {
            await service.rootMaterialResolver.shutdown()
            await service.shutdown()
            #expect(
                await eventually(timeout: .seconds(2)) { await service.rootMaterialResolver.activeResolutionCount == 0 }
            )
        }
        #expect(await eventually(timeout: .seconds(2)) { await resolver.activeResolutionCount == 0 })
        store.close()
        RootMaterialHTTP.clear()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class RootMaterialFixture: @unchecked Sendable {
    static let sharePath = "/drive/shares/share"
    static let rootPath = "/drive/shares/share/links/root"
    let shareContext = PhotosShareContext(volumeID: "volume", shareID: "share", rootLinkID: "root")
    let crypto: DriveCrypto
    let noSignerCrypto: DriveCrypto
    let hashToken = "synthetic-root-hash"
    let otherHashToken = "synthetic-other-root-hash"
    let shareResponse: Data
    let rootResponse: Data
    let missingHashResponse: Data
    let otherRootResponse: Data
    private let lock = NSLock()
    private var contextCalls = 0
    private var recorded: [String] = []
    private var held: [@Sendable () -> Void] = []
    private var holding = true
    private var omitsHash = false
    var paths: [String] { lock.withLock { recorded } }
    var bothConsumersReachedBootstrap: Bool {
        lock.withLock { contextCalls == 2 && recorded.contains(Self.sharePath) }
    }

    init() throws {
        let boot = DriveCrypto(addressKeys: [], signers: [])
        func key(_ passphrase: String) throws -> UnlockableKey {
            UnlockableKey(armored: try boot.generateLockedNodeKey(passphrase: passphrase), passphrase: passphrase)
        }
        let address = try key("address-pass")
        let share = try key("share-pass")
        let root = try key("root-pass")
        crypto = DriveCrypto(
            addressKeys: [address],
            signers: [.init(addressID: "address", addressKeyID: "key", email: "fixture@example.com", key: address)])
        noSignerCrypto = DriveCrypto(addressKeys: [address], signers: [])
        shareResponse = try JSONSerialization.data(withJSONObject: [
            "Key": share.armored, "Passphrase": crypto.encrypt(text: share.passphrase, to: address),
            "AddressID": "address",
        ])
        rootResponse = try JSONSerialization.data(withJSONObject: [
            "Link": [
                "NodeKey": root.armored, "NodePassphrase": crypto.encrypt(text: root.passphrase, to: share),
                "FolderProperties": ["NodeHashKey": crypto.encrypt(text: hashToken, to: root)],
            ]
        ])
        missingHashResponse = try JSONSerialization.data(withJSONObject: [
            "Link": [
                "NodeKey": root.armored, "NodePassphrase": crypto.encrypt(text: root.passphrase, to: share),
                "FolderProperties": [:],
            ]
        ])
        otherRootResponse = try JSONSerialization.data(withJSONObject: [
            "Link": [
                "NodeKey": root.armored, "NodePassphrase": crypto.encrypt(text: root.passphrase, to: share),
                "FolderProperties": ["NodeHashKey": crypto.encrypt(text: otherHashToken, to: root)],
            ]
        ])
    }

    func context() -> PhotosShareContext {
        lock.withLock { contextCalls += 1 }
        return shareContext
    }

    func answer(path: String, accountUID: String?, reply: @escaping @Sendable (Data?) -> Void) {
        let parts = path.split(separator: "/")
        let isShare = parts.count == 3 && parts[0] == "drive" && parts[1] == "shares"
        let isRoot = parts.count == 5 && parts[0] == "drive" && parts[1] == "shares" && parts[3] == "links"
        let data =
            isShare
            ? shareResponse
            : isRoot
                ? lock.withLock({
                    omitsHash
                        ? missingHashResponse : accountUID == "root-other-fixture" ? otherRootResponse : rootResponse
                }) : nil
        let waits = lock.withLock {
            recorded.append(path)
            if holding && isShare {
                held.append { reply(data) }
                return true
            }
            return false
        }
        if !waits { reply(data) }
    }

    func omitHashKey(_ value: Bool) { lock.withLock { omitsHash = value } }

    func release() {
        let replies = lock.withLock {
            holding = false
            defer { held.removeAll() }
            return held
        }
        replies.forEach { $0() }
    }

    func writeEvidence(status: String) throws {
        let values = paths
        print("ROOT_MATERIAL_MEASUREMENT \(status): " + values.joined(separator: " | "))
        if let path = ProcessInfo.processInfo.environment["ROOT_MATERIAL_EVIDENCE"] {
            let data = try JSONSerialization.data(
                withJSONObject: ["status": status, "paths": values], options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
    }
}

private final class RootMaterialHTTP: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture: RootMaterialFixture?
    static func install(_ value: RootMaterialFixture) { lock.withLock { fixture = value } }
    static func clear() { lock.withLock { fixture = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.lock.withLock({ Self.fixture }), let url = request.url, request.httpMethod == "GET"
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        fixture.answer(path: url.path, accountUID: request.value(forHTTPHeaderField: "x-pm-uid")) { [self] data in
            guard let data else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private struct RootMaterialUnusedSDK: SDKPhotoDuplicatesClient {
    func findPhotoDuplicates(name: String, sha1: Data, cancellationToken: UUID) async throws -> [SDKNodeUid] {
        throw URLError(.unsupportedURL)
    }
    func cancelFindPhotoDuplicates(cancellationToken: UUID) async throws {}
}
