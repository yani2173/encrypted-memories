import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

@Suite("Video byte-range cache generations")
struct VideoByteRangeCacheTests {
    @Test func staleLookupTicketCannotWriteWithCurrentOwner() {
        let fixture = makeCache()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = fixture.cache
        let photo = uid("stale-ticket-current-owner")
        let staleTicket = cache.lookup(uid: photo, block: 1).ticket
        cache.clearAll()
        let currentOwner = cache.captureOwnerGeneration()

        #expect(
            !cache.store(
                uid: photo, block: 1, encrypted: Data([42]), ticket: staleTicket,
                ownerGeneration: currentOwner))
        #expect(cache.lookup(uid: photo, block: 1).encrypted == nil)
    }

    @Test func defaultPolicyBudgetControlsEvictionAndPreservesCurrentVideo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = VideoByteRangeCache(rootDirectory: root, policyBudget: { _ in 10 })
        let old = uid("policy-old")
        let current = uid("policy-current")
        let oldTicket = cache.lookup(uid: old, block: 0).ticket
        #expect(
            cache.store(
                uid: old, block: 0, encrypted: Data(repeating: 1, count: 6), ticket: oldTicket,
                ownerGeneration: oldTicket))
        let currentTicket = cache.lookup(uid: current, block: 0).ticket
        #expect(
            cache.store(
                uid: current, block: 0, encrypted: Data(repeating: 2, count: 11), ticket: currentTicket,
                ownerGeneration: currentTicket))
        #expect(cache.lookup(uid: old, block: 0).encrypted == nil)
        #expect(cache.lookup(uid: current, block: 0).encrypted == Data(repeating: 2, count: 11))
    }

    @Test func defaultBudgetAndExplicitOverrideStayUnchanged() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = DiskCacheBudgetPolicy(platform: .mobile)
        let cache = VideoByteRangeCache(rootDirectory: root)
        #expect(policy.videoBudget == .bytes(512 * 1024 * 1024))
        #expect(cache.budgetBytes == 512 * 1024 * 1024)
        #expect(VideoByteRangeCache.shared.budgetBytes == 512 * 1024 * 1024)
        let override = VideoByteRangeCache(budgetBytes: 23, rootDirectory: root, policyBudget: { _ in 10 })
        #expect(override.budgetBytes == 23)
        #expect(VideoByteRangeCache.byteLimit(for: .unlimited) == Int.max)
        #expect(VideoByteRangeCache.byteLimit(for: .bytes(17)) == 17)
    }

    @Test func evictionStartsOnlyAboveBudgetAndRemovesOldest() throws {
        let fixture = makeCache(budgetBytes: 10)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = fixture.cache
        let oldest = uid("oldest")
        let newer = uid("newer")
        let exact = uid("exact")
        let trigger = uid("trigger")
        func put(_ photo: PhotoUID, _ size: Int) {
            let ticket = cache.lookup(uid: photo, block: 0).ticket
            #expect(
                cache.store(
                    uid: photo, block: 0, encrypted: Data(repeating: 1, count: size), ticket: ticket,
                    ownerGeneration: ticket))
        }
        put(oldest, 4)
        let firstDirectory = try #require(
            FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil).first)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: firstDirectory.path)
        put(newer, 4)
        put(exact, 2)
        #expect(cache.lookup(uid: oldest, block: 0).encrypted != nil)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: firstDirectory.path)
        put(trigger, 2)
        #expect(cache.lookup(uid: oldest, block: 0).encrypted == nil)
        #expect(cache.lookup(uid: newer, block: 0).encrypted != nil)
        #expect(cache.lookup(uid: exact, block: 0).encrypted != nil)
        #expect(cache.lookup(uid: trigger, block: 0).encrypted != nil)
    }

    @Test func storagePressurePausesWritesAndEvictsAtCritical() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedMemories-video-pressure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LibraryRuntimeState()
        let cache = VideoByteRangeCache(rootDirectory: root, runtimeState: runtime)
        let photo = uid("pressure")
        let first = cache.lookup(uid: photo, block: 1)
        #expect(
            cache.store(
                uid: photo, block: 1, encrypted: Data([1]), ticket: first.ticket,
                ownerGeneration: first.ticket))

        runtime.update { $0.storagePressure = .low }
        let low = cache.lookup(uid: photo, block: 2)
        #expect(
            !cache.store(
                uid: photo, block: 2, encrypted: Data([2]), ticket: low.ticket,
                ownerGeneration: low.ticket))
        #expect(cache.lookup(uid: photo, block: 1).encrypted == Data([1]))

        runtime.update { $0.storagePressure = .critical }
        for _ in 0..<100 where cache.lookup(uid: photo, block: 1).encrypted != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cache.lookup(uid: photo, block: 1).encrypted == nil)
        runtime.update { $0.storagePressure = .normal }
        let recovered = cache.lookup(uid: photo, block: 3)
        #expect(
            cache.store(
                uid: photo, block: 3, encrypted: Data([3]), ticket: recovered.ticket,
                ownerGeneration: first.ticket))
    }
    @Test func closedPlayerCannotPublishQueuedBytesOrInvalidateAnotherPlayer() async {
        let fixture = makeCache()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = fixture.cache
        let photo = uid("closed-player")
        let owner = VideoCacheWriteOwner()
        let other = VideoCacheWriteOwner()
        let generation = cache.captureOwnerGeneration()
        let lookup = cache.lookup(uid: photo, block: 1)
        let queue = DispatchQueue(label: "tests.video-cache.queued-write")
        queue.suspend()
        let stored = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: cache.store(
                        uid: photo, block: 1, encrypted: Data([1]), ticket: lookup.ticket,
                        ownerGeneration: generation, publicationOwner: owner))
            }
            owner.close()
            queue.resume()
        }
        #expect(stored == false)
        #expect(cache.lookup(uid: photo, block: 1).encrypted == nil)
        #expect(
            await cache.storeAsync(
                uid: photo, block: 1, encrypted: Data([2]), ticket: lookup.ticket,
                ownerGeneration: generation, publicationOwner: other))
        #expect(cache.lookup(uid: photo, block: 1).encrypted == Data([2]))
    }

    private func makeCache(budgetBytes: Int = 1024 * 1024) -> (cache: VideoByteRangeCache, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EncryptedMemories-VideoByteRangeCacheTests-\(UUID().uuidString)", isDirectory: true)
        return (VideoByteRangeCache(budgetBytes: budgetBytes, rootDirectory: root), root)
    }

    private func uid(_ id: String) -> PhotoUID {
        PhotoUID(volumeID: "video-cache-test-volume", nodeID: id)
    }

    @Test func newerRequestWinsWhenOlderRequestCompletesLast() {
        let fixture = makeCache()
        let cache = fixture.cache
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let photo = uid("new-first-old-last")

        let oldOwner = cache.captureOwnerGeneration()
        let oldRequest = cache.lookup(uid: photo, block: 1)
        #expect(oldRequest.encrypted == nil)

        cache.clearAll()
        let newOwner = cache.captureOwnerGeneration()
        let newRequest = cache.lookup(uid: photo, block: 1)
        #expect(newRequest.encrypted == nil)
        #expect(
            cache.store(
                uid: photo,
                block: 1,
                encrypted: Data("new".utf8),
                ticket: newRequest.ticket,
                ownerGeneration: newOwner
            ))
        #expect(
            cache.store(
                uid: photo,
                block: 1,
                encrypted: Data("old".utf8),
                ticket: oldRequest.ticket,
                ownerGeneration: oldOwner
            ) == false)

        #expect(cache.lookup(uid: photo, block: 1).encrypted == Data("new".utf8))
    }

    @Test func abandonedMissDoesNotReserveOrConsumeTheNextRequest() {
        let fixture = makeCache()
        let cache = fixture.cache
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let photo = uid("abandoned-miss")

        let owner = cache.captureOwnerGeneration()
        // This request models a failed or cancelled network operation. It captures no cache-side
        // reservation, and therefore has no state that the next successful request can consume.
        _ = cache.lookup(uid: photo, block: 2)
        let successfulRequest = cache.lookup(uid: photo, block: 2)

        #expect(
            cache.store(
                uid: photo,
                block: 2,
                encrypted: Data("survivor".utf8),
                ticket: successfulRequest.ticket,
                ownerGeneration: owner
            ))
        #expect(cache.lookup(uid: photo, block: 2).encrypted == Data("survivor".utf8))
    }

    @Test func staleOwnerCannotUsePostClearLookup() {
        let fixture = makeCache()
        let cache = fixture.cache
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let photo = uid("stale-owner-post-clear")

        let staleOwner = cache.captureOwnerGeneration()
        cache.clearAll()
        let freshOwner = cache.captureOwnerGeneration()
        let freshLookup = cache.lookup(uid: photo, block: 3)

        #expect(
            cache.store(
                uid: photo,
                block: 3,
                encrypted: Data("stale".utf8),
                ticket: freshLookup.ticket,
                ownerGeneration: staleOwner
            ) == false)
        #expect(cache.lookup(uid: photo, block: 3).encrypted == nil)
        #expect(
            cache.store(
                uid: photo,
                block: 3,
                encrypted: Data("fresh".utf8),
                ticket: freshLookup.ticket,
                ownerGeneration: freshOwner
            ))
        #expect(cache.lookup(uid: photo, block: 3).encrypted == Data("fresh".utf8))
    }

    @Test func concurrentStoresDoNotInvertGenerationAndCacheLocks() {
        let fixture = makeCache(budgetBytes: 1)
        let cache = fixture.cache
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let queue = DispatchQueue(
            label: "EncryptedMemories.VideoByteRangeCacheTests.lock-order",
            attributes: .concurrent
        )
        let group = DispatchGroup()

        for round in 0..<8 {
            for block in 0..<4 {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    let owner = cache.captureOwnerGeneration()
                    let lookup = cache.lookup(uid: uid("lock-order-\(round)-\(block)"), block: block)
                    _ = cache.store(
                        uid: uid("lock-order-\(round)-\(block)"),
                        block: block,
                        encrypted: Data("payload-\(round)-\(block)".utf8),
                        ticket: lookup.ticket,
                        ownerGeneration: owner
                    )
                }
            }
        }

        #expect(
            // The deadline fails if concurrent budget enforcement deadlocks.
            group.wait(timeout: .now() + 10) == .success,
            "concurrent cache stores must not deadlock during budget enforcement"
        )
    }

    @Test func asyncRangeCacheRoundTripUsesTheSameGenerationContract() async {
        let fixture = makeCache()
        let cache = fixture.cache
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let photo = uid("async-round-trip")
        let owner = cache.captureOwnerGeneration()
        let lookup = await cache.lookupAsync(uid: photo, block: 1)

        #expect(
            await cache.storeAsync(
                uid: photo,
                block: 1,
                encrypted: Data("async-payload".utf8),
                ticket: lookup.ticket,
                ownerGeneration: owner
            ))
        let result = await cache.lookupAsync(uid: photo, block: 1)
        #expect(result.encrypted == Data("async-payload".utf8))
    }
}
