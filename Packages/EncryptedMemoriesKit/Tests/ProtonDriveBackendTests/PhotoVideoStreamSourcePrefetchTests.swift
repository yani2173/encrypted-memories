import Foundation
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoGoInterface
import ProtonCoreCryptoPatchedGoImplementation
import Testing

@testable import ProtonDriveBackend

/// A Live Photo motion is prefetched, then prepared for playback. The second step reuses the first step's answer
/// once, for the same clip, within a short window. Every other `prepare` resolves the file again.
@Suite(.serialized)
struct PhotoVideoStreamSourcePrefetchTests {
    private let motion = PhotoUID(volumeID: "volume", nodeID: "motion")

    @Test func prepareAfterAPrefetchReusesItsAnswerOnceWithTheSameResult() async throws {
        let fixture = try makeFixture()

        try await fixture.source.prefetchEncrypted(uid: motion)
        let reused = try await fixture.source.prepare(uid: motion)
        let again = try await fixture.source.prepare(uid: motion)

        #expect(await fixture.resolver.count == 2, "one resolve for prefetch and playback, one for the later prepare")
        #expect(reused.uid == motion && reused.totalSize == 0 && reused.blocks.isEmpty)
        #expect(again.uid == reused.uid && again.totalSize == reused.totalSize)
        #expect(again.blocks.count == reused.blocks.count && again.contentTypeUTI == reused.contentTypeUTI)
    }

    @Test func withoutAPrefetchEveryPrepareResolvesTheFile() async throws {
        let fixture = try makeFixture()

        _ = try await fixture.source.prepare(uid: motion)
        _ = try await fixture.source.prepare(uid: motion)

        #expect(await fixture.resolver.count == 2)
    }

    @Test func aPrefetchAnswerIsNotReusedAfterTheWindow() async throws {
        let fixture = try makeFixture()
        try await fixture.source.prefetchEncrypted(uid: motion)

        fixture.clock.advance(PhotoVideoStreamSource.prefetchReuseWindow + .seconds(1))
        _ = try await fixture.source.prepare(uid: motion)

        #expect(await fixture.resolver.count == 2)
    }

    @Test func aPrefetchAnswerIsNotReusedForAnotherClip() async throws {
        let fixture = try makeFixture()
        try await fixture.source.prefetchEncrypted(uid: motion)

        let other = PhotoUID(volumeID: "volume", nodeID: "other")
        let prepared = try await fixture.source.prepare(uid: other)

        #expect(prepared.uid == other)
        #expect(await fixture.resolver.count == 2)
    }

    @Test func aFailedPrefetchLeavesNothingToReuse() async throws {
        let fixture = try makeFixture(failFirst: true)

        await #expect(throws: (any Error).self) { try await fixture.source.prefetchEncrypted(uid: motion) }
        _ = try await fixture.source.prepare(uid: motion)

        #expect(await fixture.resolver.count == 2)
    }

    @Test func aPrefetchWhoseBlockDownloadFailsLeavesNothingToReuse() async throws {
        let clip = PhotoUID(volumeID: "volume", nodeID: "block-\(UUID().uuidString)")
        let fixture = try makeFixture(blockCount: 1, protocols: [FailingBlockProtocol.self])

        await #expect(throws: (any Error).self) { try await fixture.source.prefetchEncrypted(uid: clip) }
        _ = try await fixture.source.prepare(uid: clip)

        #expect(await fixture.resolver.count == 2, "the answer is kept only after the last block was cached")
    }

    @Test func aSecondPrefetchResolvesTheClipAgainInsteadOfRenewingTheFirstAnswer() async throws {
        let fixture = try makeFixture()
        try await fixture.source.prefetchEncrypted(uid: motion)

        fixture.clock.advance(.seconds(15))
        try await fixture.source.prefetchEncrypted(uid: motion)
        fixture.clock.advance(.seconds(10))
        _ = try await fixture.source.prepare(uid: motion)

        #expect(await fixture.resolver.count == 2, "the second prefetch resolved fresh; the playback reused that one")
    }

    @Test func theWindowCountsFromTheStartOfTheResolution() async throws {
        let fixture = try makeFixture(resolutionTakes: PhotoVideoStreamSource.prefetchReuseWindow + .seconds(5))

        try await fixture.source.prefetchEncrypted(uid: motion)
        _ = try await fixture.source.prepare(uid: motion)

        #expect(await fixture.resolver.count == 2, "a resolution that outlasts the window leaves nothing to reuse")
    }

    private struct Fixture {
        let source: PhotoVideoStreamSource
        let resolver: Resolver
        let clock: TestInstantClock
    }

    private func makeFixture(
        failFirst: Bool = false, blockCount: Int = 0, resolutionTakes: Duration = .zero,
        protocols: [AnyClass] = []
    ) throws -> Fixture {
        injectDefaultCryptoImplementation()
        let key = try #require(CryptoGo.CryptoNewSessionKeyFromToken(Data(repeating: 5, count: 32), "aes256"))
        let clock = TestInstantClock()
        let resolver = Resolver(
            sessionKey: key, failFirst: failFirst, blockCount: blockCount,
            onResolve: { clock.advance(resolutionTakes) })
        let session = DriveSession(
            session: ProtonSession(uid: "test", accessToken: "", refreshToken: "", keyPassword: ""),
            store: SessionKeychainStore(service: "tests.prefetch-reuse.unused"),
            accountCacheDirectory: FileManager.default.temporaryDirectory, urlProtocolClasses: protocols)
        let source = PhotoVideoStreamSource(
            session: session, crypto: DriveCrypto(addressKeys: [], signers: []), shareID: "share",
            prepareFile: { try await resolver.resolve($0) }, now: { clock.now })
        return Fixture(source: source, resolver: resolver, clock: clock)
    }

    private actor Resolver {
        struct Failure: Error {}
        private let sessionKey: CryptoSessionKey
        private var failFirst: Bool
        private let blockCount: Int
        private let onResolve: @Sendable () -> Void
        private(set) var count = 0

        init(sessionKey: CryptoSessionKey, failFirst: Bool, blockCount: Int, onResolve: @escaping @Sendable () -> Void)
        {
            self.sessionKey = sessionKey
            self.failFirst = failFirst
            self.blockCount = blockCount
            self.onResolve = onResolve
        }

        func resolve(_ uid: PhotoUID) throws -> PreparedVideo {
            count += 1
            onResolve()
            if failFirst {
                failFirst = false
                throw Failure()
            }
            let blocks = (1...max(blockCount, 1)).prefix(blockCount).map {
                VideoBlock(
                    index: $0, url: "https://example.invalid/block\($0)", token: nil, clearOffset: 0, clearSize: 16)
            }
            return PreparedVideo(
                uid: uid, totalSize: 16 * blockCount, contentTypeUTI: "com.apple.quicktime-movie", blocks: blocks,
                sessionKey: sessionKey)
        }
    }

    /// Every request fails as if the device were offline.
    private final class FailingBlockProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    private final class TestInstantClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { value } }
        func advance(_ duration: Duration) { lock.withLock { value = value.advanced(by: duration) } }
    }
}
