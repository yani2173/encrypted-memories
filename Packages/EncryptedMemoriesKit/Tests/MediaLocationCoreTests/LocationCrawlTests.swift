import CryptoKit
import Foundation
import PhotosCore
import Testing

@testable import MediaLocationCore

private func uid(_ n: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: n) }
private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("crawltest-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
private func makeStore(_ dir: URL) -> PhotoLocationStore {
    let store = PhotoLocationStore(directory: dir)
    store.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
    return store
}

/// Thread-safe flag/counter boxes for the `@Sendable` probe closures.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.withLock { value = v } }
    func get() -> Bool { lock.withLock { value } }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
    func value() -> Int { lock.withLock { count } }
}

private actor CrawlLatch {
    private var released = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func hasEntered() -> Bool { entered }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func wait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CompletionLatch {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

private func yieldToScheduledWork() async {
    for _ in 0..<20 { await Task.yield() }
}

private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor @Sendable () async -> Bool) async throws
{
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met within \(timeout)")
}

@Suite struct LocationCrawlTests {
    @Test func cancelAwaitsAnInFlightProbe() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero)
        let probeGate = CrawlLatch()
        let cancellationFinished = CompletionLatch()

        await crawl.start(
            uids: [uid("blocked")],
            captureDates: [:],
            location: { _ in
                await probeGate.wait()
                return .found(latitude: 47.8, longitude: 13.0)
            },
            index: index,
            store: store
        )
        await probeGate.waitUntilEntered()

        let cancellation = Task {
            await crawl.cancel()
            await cancellationFinished.markCompleted()
        }
        await yieldToScheduledWork()
        let finishedBeforeRelease = await cancellationFinished.isCompleted()
        #expect(!finishedBeforeRelease, "cancel must join an in-flight provider call")

        await probeGate.release()
        await cancellation.value
        #expect(await cancellationFinished.isCompleted())
    }

    @Test func restartingCrawlJoinsThePreviousGeneration() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero)
        let firstGate = CrawlLatch()
        let secondGate = CrawlLatch()
        let first = uid("first")
        let second = uid("second")

        await crawl.start(
            uids: [first],
            captureDates: [:],
            location: { _ in
                await firstGate.wait()
                return .found(latitude: 47.0, longitude: 13.0)
            },
            index: index,
            store: store
        )
        await firstGate.waitUntilEntered()

        let restart = Task {
            await crawl.start(
                uids: [second],
                captureDates: [:],
                location: { _ in
                    await secondGate.wait()
                    return .found(latitude: 48.0, longitude: 14.0)
                },
                index: index,
                store: store
            )
        }
        await yieldToScheduledWork()
        let secondEnteredBeforeRelease = await secondGate.hasEntered()
        #expect(!secondEnteredBeforeRelease, "a replacement crawl must wait for the old generation")

        await firstGate.release()
        await restart.value
        await secondGate.waitUntilEntered()
        await secondGate.release()
        try await waitUntil { await index.scanProgress.phase == .completed }

        let coordinates = await index.coordinates
        #expect(coordinates.map(\.uid) == [second], "a canceled generation must not publish coordinates")
    }

    @Test func concurrentReplacementStartsCoalesceToNewestGeneration() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero)
        let oldProbeGate = CrawlLatch()
        let firstRequestReady = CompletionLatch()
        let old = uid("old")
        let first = uid("first-replacement")
        let newest = uid("newest-replacement")

        await crawl.start(
            uids: [old],
            captureDates: [:],
            location: { _ in
                await oldProbeGate.wait()
                return .found(latitude: 47.0, longitude: 13.0)
            },
            index: index,
            store: store
        )
        await oldProbeGate.waitUntilEntered()

        let firstReplacement = Task {
            await firstRequestReady.markCompleted()
            await crawl.start(
                uids: [first],
                captureDates: [:],
                location: { _ in .found(latitude: 48.0, longitude: 14.0) },
                index: index,
                store: store
            )
        }
        try await waitUntil { await firstRequestReady.isCompleted() }
        await yieldToScheduledWork()

        let newestReplacement = Task {
            await crawl.start(
                uids: [newest],
                captureDates: [:],
                location: { _ in .found(latitude: 49.0, longitude: 15.0) },
                index: index,
                store: store
            )
        }
        await yieldToScheduledWork()
        let coordinatesBeforeRelease = await index.coordinates
        #expect(
            !coordinatesBeforeRelease.contains { $0.uid == first },
            "the first replacement must wait for the old probe")
        #expect(
            !coordinatesBeforeRelease.contains { $0.uid == newest },
            "the newest replacement must wait for the old probe")

        await oldProbeGate.release()
        await firstReplacement.value
        await newestReplacement.value
        try await waitUntil { await index.scanProgress.phase == .completed }

        let coordinates = await index.coordinates
        #expect(coordinates.map(\.uid) == [newest], "only the newest replacement may publish")
    }

    @Test func canceledAccountACrawlCannotWriteAccountBState() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero)
        let probeGate = CrawlLatch()
        let probeReturned = CompletionLatch()
        let accountBKey = SymmetricKey(size: .bits256)

        await crawl.start(
            uids: [uid("account-a")],
            captureDates: [:],
            location: { _ in
                await probeGate.wait()
                await probeReturned.markCompleted()
                return .found(latitude: 47.0, longitude: 13.0)
            },
            index: index,
            store: store
        )
        await probeGate.waitUntilEntered()

        let cancellation = Task { await crawl.cancel() }
        await yieldToScheduledWork()
        store.configure(accountUID: "account-b", key: accountBKey)
        await index.replaceAll([])
        await probeGate.release()
        await cancellation.value
        await yieldToScheduledWork()

        #expect(await probeReturned.isCompleted())
        #expect(await index.coordinates.isEmpty, "account A must not merge into account B's index")
        #expect(store.load().isEmpty, "account A must not persist through account B's configured store")
    }

    @Test func crawlInsertsCoordinatesPersistsAndCompletes() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero, mergeEvery: 2, saveEvery: 2)

        let uids = [uid("a"), uid("b"), uid("c")]
        await crawl.start(
            uids: uids,
            captureDates: [uid("a"): Date(timeIntervalSince1970: 1)],
            location: { u in
                u == uid("b") ? .noLocation : .found(latitude: 47.8, longitude: 13.0)
            },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .completed }

        let progress = await index.scanProgress
        #expect(await index.coordinates.count == 2)
        #expect(progress.scanned == 3)
        #expect(progress.total == 3)
        #expect(progress.found == 2)
        #expect(progress.noLocation == 1)
        #expect(progress.failed == 0)
        // Persisted (encrypted) snapshot round-trips.
        let reopened = PhotoLocationStore(directory: dir)
        #expect(reopened.load().isEmpty)  // wrong key/unconfigured reads empty
        #expect(store.load().count == 2)
    }

    @Test func emptyAndFailedProbesDoNotCrashAndAreCounted() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero)

        await crawl.start(
            uids: [uid("x"), uid("y")],
            captureDates: [:],
            location: { u in u == uid("x") ? .noLocation : .failed(category: "http-429") },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .completed }

        let progress = await index.scanProgress
        #expect(await index.coordinates.isEmpty)
        #expect(progress.noLocation == 1)
        #expect(progress.failed == 1)
        #expect(progress.phase == .completed)  // mixed outcome is a completed scan, not a failure
    }

    @Test func allProbesFailingReportsFailurePhaseNotNoPlaces() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero)

        await crawl.start(
            uids: [uid("x"), uid("y")],
            captureDates: [:],
            location: { _ in .failed(category: "offline") },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .failed }
        #expect(await index.scanProgress.phase == .failed)
    }

    @Test func firstCoordinatesPublishBeforeAllCandidatesAreScanned() async throws {
        // The map must fill progressively - pins appear after the first merged batch, not once the whole
        // run (or the thumbnail crawl) finishes.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero, mergeEvery: 1)
        let gate = Flag()  // blocks probes after the first, keeping the run "still scanning"

        let uids = (0..<5).map { uid("p\($0)") }
        await crawl.start(
            uids: uids,
            captureDates: [:],
            location: { u in
                if u != uids[0] {
                    while !gate.get() { try? await Task.sleep(for: .milliseconds(5)) }
                }
                return .found(latitude: 47.8, longitude: 13.0)
            },
            index: index,
            store: store
        )

        // First coordinate lands while the crawl is provably still running (scanning, 4 items left).
        try await waitUntil { await !index.coordinates.isEmpty }
        let midRun = await index.scanProgress
        #expect(midRun.phase == .scanning, "index must publish while the crawl is still scanning")
        #expect(midRun.scanned < uids.count)
        #expect(await index.revision > 0)

        gate.set(true)
        try await waitUntil { await index.scanProgress.phase == .completed }
        #expect(await index.coordinates.count == uids.count)
    }

    @Test func scanningStateIsVisibleWhileRunningWithZeroFound() async throws {
        // With zero finds so far, the UI must be able to say
        // "scanning", and may say "no geotagged photos" only after the crawl completes.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero)
        let gate = Flag()

        await crawl.start(
            uids: [uid("a"), uid("b")],
            captureDates: [:],
            location: { _ in
                while !gate.get() { try? await Task.sleep(for: .milliseconds(5)) }
                return .noLocation
            },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .scanning }
        #expect(await index.coordinates.isEmpty)
        #expect(await index.scanProgress.phase == .scanning)  // UI: "scanning", not "no places yet"

        gate.set(true)
        try await waitUntil { await index.scanProgress.phase == .completed }
        #expect(await index.scanProgress.found == 0)  // UI: now honestly "no geotagged photos"
    }

    @Test func probesRunInParallelUpToTheLimitAndEveryResultCounts() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero, mergeEvery: 1, probeConcurrency: 3)
        let entered = Counter()
        let gate = Flag()
        let uids = (0..<5).map { uid("c\($0)") }

        await crawl.start(
            uids: uids,
            captureDates: [:],
            location: { _ in
                _ = entered.increment()
                while !gate.get() { try? await Task.sleep(for: .milliseconds(5)) }
                return .found(latitude: 47.8, longitude: 13.0)
            },
            index: index,
            store: store
        )
        try await waitUntil { entered.value() == 3 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(entered.value() == 3, "three probes run at once, and no more")

        gate.set(true)
        try await waitUntil { await index.scanProgress.phase == .completed }
        #expect(await index.coordinates.count == uids.count)
        #expect(await index.scanProgress.scanned == uids.count)
        #expect(entered.value() == uids.count, "each photo is probed once")
    }

    @Test func theScannedCountPublishesBeforeThePlacesOfABatch() async throws {
        // A map that already shows places must still learn how many photos are left.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero, progressEvery: 2)
        let gate = Flag()
        let uids = (0..<5).map { uid("s\($0)") }

        await crawl.start(
            uids: uids,
            captureDates: [:],
            location: { value in
                if value != uids[0], value != uids[1] {
                    while !gate.get() { try? await Task.sleep(for: .milliseconds(5)) }
                }
                return .noLocation
            },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.scanned == 2 }
        let midRun = await index.scanProgress
        #expect(midRun.phase == .scanning)
        #expect(midRun.total == uids.count)
        #expect(midRun.fractionScanned == 0.4)

        gate.set(true)
        try await waitUntil { await index.scanProgress.phase == .completed }
        #expect(await index.scanProgress.fractionScanned == nil, "a finished scan shows no progress")
    }

    @Test func scanProgressFractionExistsOnlyWhileAScanRuns() {
        #expect(PhotoLocationScanProgress(phase: .scanning, scanned: 25, total: 100).fractionScanned == 0.25)
        #expect(PhotoLocationScanProgress(phase: .scanning, scanned: 120, total: 100).fractionScanned == 1)
        #expect(PhotoLocationScanProgress(phase: .scanning, scanned: 0, total: 0).fractionScanned == nil)
        #expect(PhotoLocationScanProgress(phase: .completed, scanned: 100, total: 100).fractionScanned == nil)
        #expect(PhotoLocationScanProgress(phase: .idle).fractionScanned == nil)
    }

    @Test func visibleDemandPausesCrawlWithoutPermanentStarvation() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero, backoff: .milliseconds(10))
        let demand = Flag()
        demand.set(true)  // visible thumbnail pressure active from the start
        let probes = Counter()

        await crawl.start(
            uids: [uid("a"), uid("b")],
            captureDates: [:],
            location: { _ in
                _ = probes.increment()
                return .noLocation
            },
            index: index,
            store: store,
            shouldYield: { demand.get() }
        )
        try await waitUntil { await index.scanProgress.phase == .scanning }
        try await Task.sleep(for: .milliseconds(80))
        #expect(probes.value() == 0, "crawl must back off while visible demand is active")

        demand.set(false)  // When demand subsides, the crawl resumes on its own.
        try await waitUntil { await index.scanProgress.phase == .completed }
        #expect(probes.value() == 2, "crawl must resume and finish once demand subsides")
    }

    @Test func crawlSkipsAlreadyIndexedUIDs() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        await index.replaceAll([PhotoCoordinate(uid: uid("done"), latitude: 1, longitude: 2, date: .distantPast)])
        let crawl = LocationCrawl(throttle: .zero)
        let probes = Counter()

        await crawl.start(
            uids: [uid("done"), uid("new")],
            captureDates: [:],
            location: { _ in
                _ = probes.increment()
                return .found(latitude: 3, longitude: 4)
            },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .completed }
        #expect(probes.value() == 1, "already-indexed uids must not be re-probed (resumable crawl)")
        #expect(await index.coordinates.count == 2)
    }

    @Test func checkpointInventoryIncludesAUIDAddedAfterTheInitialSnapshot() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero, mergeEvery: 1, saveEvery: 1)
        let first = uid("initial")
        let added = uid("added")
        let inventoryCalls = Counter()
        let probes = Counter()

        await crawl.start(
            uids: [first],
            captureDates: [:],
            location: { _ in
                _ = probes.increment()
                return .found(latitude: 47.8, longitude: 13.0)
            },
            index: index,
            store: store,
            inventory: {
                let call = inventoryCalls.increment()
                return LocationCrawlInventory(uids: call == 1 ? [first] : [first, added])
            }
        )
        try await waitUntil { await index.scanProgress.phase == .completed }

        #expect(probes.value() == 2)
        let coordinates = await index.coordinates
        #expect(Set(coordinates.map(\.uid)) == Set([first, added]))
    }

    @Test func noLocationResultsPersistAndSkipTheNextCrawl() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let missing = uid("missing")
        let crawl = LocationCrawl(throttle: .zero, saveEvery: 1)

        await crawl.start(
            uids: [missing],
            captureDates: [:],
            location: { _ in .noLocation },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .completed }
        #expect(store.loadSnapshot().noLocationUIDs == [missing])

        let reloadedIndex = await PhotoLocationIndex()
        await reloadedIndex.replaceAll(store.loadSnapshot())
        let secondProbeCount = Counter()
        await crawl.start(
            uids: [missing],
            captureDates: [:],
            location: { _ in
                _ = secondProbeCount.increment()
                return .noLocation
            },
            index: reloadedIndex,
            store: store
        )
        try await waitUntil { await reloadedIndex.scanProgress.phase == .completed }

        #expect(secondProbeCount.value() == 0)
        #expect(await reloadedIndex.scanProgress.total == 0)
    }

    @Test func checkpointPersistenceAppendsDeltasBeforeBoundedCompaction() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PhotoLocationStore(directory: dir, journalCompactionThresholdBytes: Int.max)
        store.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero, mergeEvery: 1, saveEvery: 1)
        let uids = (0..<8).map { uid("p\($0)") }

        await crawl.start(
            uids: uids,
            captureDates: [:],
            location: { value in
                .found(latitude: 47.0, longitude: Double(String(value.nodeID.dropFirst(1)))! / 10)
            },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .completed }

        #expect(store.persistenceMetrics().baseRewrites == 1)
        #expect(store.persistenceMetrics().journalAppends == uids.count - 1)
        #expect(store.load().count == uids.count)
    }

    @Test func incompleteJournalTailIsRepairedBeforeTheNextDelta() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let first = uid("first")
        let second = uid("second")
        let initialStore = PhotoLocationStore(directory: dir, journalCompactionThresholdBytes: Int.max)
        initialStore.configure(accountUID: "acct", key: key)
        let initialIndex = await PhotoLocationIndex()
        let initialCrawl = LocationCrawl(throttle: .zero, saveEvery: 1)

        await initialCrawl.start(
            uids: [first],
            captureDates: [:],
            location: { _ in .found(latitude: 47.8, longitude: 13.0) },
            index: initialIndex,
            store: initialStore
        )
        try await waitUntil { await initialIndex.scanProgress.phase == .completed }

        let journal = try #require(
            try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "log" }))
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xFF]))
        try handle.close()

        let store = PhotoLocationStore(directory: dir, journalCompactionThresholdBytes: Int.max)
        store.configure(accountUID: "acct", key: key)
        let index = await PhotoLocationIndex()
        await index.replaceAll(store.loadSnapshot())
        let crawl = LocationCrawl(throttle: .zero, saveEvery: 1)
        await crawl.start(
            uids: [first, second],
            captureDates: [:],
            location: { _ in .found(latitude: 48.0, longitude: 14.0) },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .completed }

        #expect(Set(store.load().map(\.uid)) == Set([first, second]))
    }
}
