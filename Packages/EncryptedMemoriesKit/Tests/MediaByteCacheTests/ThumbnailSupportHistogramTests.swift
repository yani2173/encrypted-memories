import Foundation
import PhotosCore
import Testing

@testable import MediaByteCache

@Suite struct ThumbnailSupportHistogramTests {
    #if DEBUG
        @Test func unknownRegularFileTypeReportsReadError() async throws {
            let (root, cache) = try fixture(derivative: "thumbnail", sizes: [1])
            defer { try? FileManager.default.removeItem(at: root) }
            let iterator = ThumbnailSupportMetadataIterator(directory: root.appendingPathComponent("test.enc")) {
                false
            }
            let actual = try root.appendingPathComponent("test.enc/private-0.blob")
                .resourceValues(forKeys: [.isRegularFileKey])
            guard iterator.available, actual.isRegularFile == true else {
                Issue.record("INVALID: fixture metadata is unavailable")
                return
            }
            iterator.forceUnknownRegularFileForTesting()
            let result = await cache.thumbnailCacheSupportSnapshot(
                deadline: .now.advanced(by: .seconds(30)),
                nextBlobSize: { try iterator.next() },
                shouldStop: { false })
            #expect(result.availability == .partial)
            #expect(result.caches.first?.blobCount == 0)
            #expect(result.caches.first?.readErrors == 1)
        }
    #endif

    @Test func stoppedBeforeRootDoesNotReadMetadata() throws {
        let (root, _) = try fixture(derivative: "thumbnail", sizes: [1])
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = IteratorProbe(stopInitially: true)
        let iterator = ThumbnailSupportMetadataIterator(
            directory: root.appendingPathComponent("test.enc"),
            probe: { probe.observe($0) }, shouldStop: { probe.stopped })
        #expect(!iterator.available)
        #expect(try iterator.next() == nil)
        #expect(probe.rootReads == 0)
        #expect(probe.enumeratorAttempts == 0)
        #expect(probe.nextAttempts == 0)
        #expect(probe.entryReads == 0)
    }

    @Test func stoppedDuringEnumeratorCreationDoesNotAdmitScan() throws {
        let (root, _) = try fixture(derivative: "thumbnail", sizes: [1])
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = IteratorProbe(stopAt: .enumeratorCreated)
        let iterator = ThumbnailSupportMetadataIterator(
            directory: root.appendingPathComponent("test.enc"),
            probe: { probe.observe($0) }, shouldStop: { probe.stopped })
        #expect(probe.rootReads == 1)
        #expect(!iterator.available)
        #expect(try iterator.next() == nil)
        #expect(probe.enumeratorAttempts == 1)
        #expect(probe.nextAttempts == 0)
        #expect(probe.entryReads == 0)
    }

    @Test func stoppedDuringNextObjectDoesNotReadEntryMetadata() throws {
        let (root, _) = try fixture(derivative: "thumbnail", sizes: [1])
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = IteratorProbe(stopAt: .nextObject)
        let iterator = ThumbnailSupportMetadataIterator(
            directory: root.appendingPathComponent("test.enc"),
            probe: { probe.observe($0) }, shouldStop: { probe.stopped })
        #expect(iterator.available)
        #expect(probe.enumeratorAttempts == 1)
        #expect(throws: ThumbnailSupportMetadataIterator.Stopped.self) { try iterator.next() }
        #expect(probe.nextAttempts == 1)
        #expect(probe.entryReads == 0)
    }

    @Test func stoppedAfterRootDoesNotCreateEnumerator() throws {
        let (root, _) = try fixture(derivative: "thumbnail", sizes: [1])
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = IteratorProbe(stopAt: .rootReadCompleted)
        let iterator = ThumbnailSupportMetadataIterator(
            directory: root.appendingPathComponent("test.enc"),
            probe: { probe.observe($0) }, shouldStop: { probe.stopped })
        #expect(probe.rootReads == 1)
        #expect(!iterator.available)
        #expect(try iterator.next() == nil)
        #expect(probe.enumeratorAttempts == 0)
        #expect(probe.nextAttempts == 0)
        #expect(probe.entryReads == 0)
    }

    #if DEBUG
        @Test func actualStopPredicatesPreventEnumeratorCreation() async throws {
            for mode in 0..<3 {
                let (root, cache) = try fixture(derivative: "thumbnail", sizes: [1])
                defer { try? FileManager.default.removeItem(at: root) }
                let probe = IteratorProbe()
                let start = ContinuousClock.now
                let deadline = start.advanced(by: .seconds(30))
                let task = Task {
                    await cache.supportSnapshotForTesting(
                        deadline: deadline, onEntry: {},
                        iteratorProbe: { step in
                            probe.observe(step)
                            if step == .rootReadCompleted {
                                if mode == 0 { withUnsafeCurrentTask { $0?.cancel() } }
                                if mode == 1 { probe.advanceClock() }
                                if mode == 2 { cache.clearForSignOut() }
                            }
                        }, now: { probe.clockAdvanced ? deadline : start })
                }
                _ = await task.value
                #expect(probe.rootReads == 1)
                #expect(probe.enumeratorAttempts == 0)
                #expect(probe.nextAttempts == 0)
                #expect(probe.entryReads == 0)
            }
        }
    #endif

    #if DEBUG
        @Test func cancelledAdmissionNeverCapturesLease() async throws {
            let (root, cache) = try fixture(derivative: "thumbnail", sizes: [1])
            defer { try? FileManager.default.removeItem(at: root) }
            let probe = IteratorProbe()
            let result = await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await cache.supportSnapshotForTesting(
                    deadline: .now.advanced(by: .seconds(30)), onEntry: {},
                    afterLease: { probe.observe(.rootRead) })
            }.value
            #expect(result == .unavailable)
            #expect(probe.rootReads == 0)
        }
    #endif

    @Test func negativeSizeReportsErrorWithoutCountingBlob() async throws {
        let (root, cache) = try fixture(derivative: "thumbnail", sizes: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = SizeFeed([-1])
        let result = await cache.thumbnailCacheSupportSnapshot(
            deadline: .now.advanced(by: .seconds(30)), nextBlobSize: { feed.next() }, shouldStop: { false })
        #expect(result.availability == .partial)
        #expect(result.caches.first?.readErrors == 1)
        #expect(result.caches.first?.blobCount == 0)
    }

    @Test func totalSizeSaturatesOnOverflow() async throws {
        let (root, cache) = try fixture(derivative: "thumbnail", sizes: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = SizeFeed([Int64.max, 1])
        let result = await cache.thumbnailCacheSupportSnapshot(
            deadline: .now.advanced(by: .seconds(30)), nextBlobSize: { feed.next() }, shouldStop: { false })
        #expect(result.availability == .complete)
        #expect(result.caches.first?.blobCount == 2)
        #expect(result.caches.first?.totalMiB == Int64.max / 1_048_576 + 1)
    }

    @Test func fileAtCacheRootIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0x01]).write(to: root.appendingPathComponent("test.enc"))
        let cache = ThumbnailCache(namespace: "test", rootDirectory: root)
        let result = await cache.thumbnailCacheSupportSnapshot(deadline: .now.advanced(by: .seconds(30)))
        #expect(result == .unavailable)
    }

    private func fixture(derivative: String, sizes: [Int64]) throws -> (URL, ThumbnailCache) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = ThumbnailCache(
            namespace: "test", derivative: derivative,
            configuration: ThumbnailCacheConfiguration(diskByteBudgetBytes: 1_000_000_000), rootDirectory: root)
        let directory = root.appendingPathComponent("test.enc")
        for (index, size) in sizes.enumerated() {
            let file = directory.appendingPathComponent("private-\(index).blob")
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
        }
        return (root, cache)
    }

    @Test func binsEveryBoundaryAndRoundsTotal() async throws {
        let sizes: [Int64] = [
            0, 16_383, 16_384, 65_535, 65_536, 262_143, 262_144,
            1_048_575, 1_048_576, 4_194_303, 4_194_304,
        ]
        let (root, cache) = try fixture(derivative: "thumbnail", sizes: sizes)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await cache.thumbnailCacheSupportSnapshot(deadline: ContinuousClock.now.advanced(by: .seconds(30)))
        #expect(
            result
                == ThumbnailCacheSupportSnapshot(
                    availability: .complete,
                    caches: [
                        .init(
                            kind: .thumbnail, blobCount: 11, buckets: [2, 2, 2, 2, 2, 1], totalMiB: 11, readErrors: 0)
                    ]))
    }

    @Test func roundsNonemptyByteTotalsUpToMiB() async throws {
        let (root, cache) = try fixture(derivative: "thumbnail", sizes: [1, 1_048_576])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await cache.thumbnailCacheSupportSnapshot(deadline: ContinuousClock.now.advanced(by: .seconds(30)))
        #expect(
            result
                == ThumbnailCacheSupportSnapshot(
                    availability: .complete,
                    caches: [
                        .init(kind: .thumbnail, blobCount: 2, buckets: [1, 0, 0, 0, 1, 0], totalMiB: 2, readErrors: 0)
                    ]))
    }

    @Test func reportsTheActualCacheKind() async throws {
        for (derivative, kind) in [
            ("thumbnail", ThumbnailCacheSupportSnapshot.Kind.thumbnail),
            ("preview", .preview), ("original", .original),
        ] {
            let (root, cache) = try fixture(derivative: derivative, sizes: [1])
            defer { try? FileManager.default.removeItem(at: root) }
            let result = await cache.thumbnailCacheSupportSnapshot(
                deadline: ContinuousClock.now.advanced(by: .seconds(30)))
            #expect(
                result
                    == ThumbnailCacheSupportSnapshot(
                        availability: .complete,
                        caches: [
                            .init(kind: kind, blobCount: 1, buckets: [1, 0, 0, 0, 0, 0], totalMiB: 1, readErrors: 0)
                        ]))
        }
    }

    @Test func scansMetadataWithoutExportingNamesOrChangingBlobs() async throws {
        let (root, cache) = try fixture(derivative: "thumbnail", sizes: [20])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.enc/private-0.blob")
        let contents = Data("private-payload-value".utf8)
        try contents.write(to: file)
        let before = try Data(contentsOf: file)
        let result = await cache.thumbnailCacheSupportSnapshot(deadline: ContinuousClock.now.advanced(by: .seconds(30)))
        #expect(
            result
                == ThumbnailCacheSupportSnapshot(
                    availability: .complete,
                    caches: [
                        .init(kind: .thumbnail, blobCount: 1, buckets: [1, 0, 0, 0, 0, 0], totalMiB: 1, readErrors: 0)
                    ]))
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!text.contains("private-0"))
        #expect(!text.contains("private-payload-value"))
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func populatedExportOmitsBlobNameAndPayload() async throws {
        let (root, cache) = try fixture(derivative: "thumbnail", sizes: [20])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.enc/private-0.blob")
        try Data("private-payload-value".utf8).write(to: file)
        let unrelated = root.appendingPathComponent("test.enc/private-ignored.txt")
        try Data("ignored".utf8).write(to: unrelated)
        let source = ThumbnailCacheSupportGroup([cache])
        let sources = SupportDiagnosticsSources(trail: SupportEventTrail())
        sources.registerThumbnailCaches(source)
        let runtime = LibraryRuntimeState()
        let data = try await SupportDiagnosticsExporter.makeJSONData(
            runtimeState: runtime, resourceCoordinator: LibraryResourceCoordinator(runtimeState: runtime),
            diagnostics: PhotoDiagnostics(), sources: sources, trail: SupportEventTrail())
        let report = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let section = try #require(report["thumbnailCaches"] as? [String: Any])
        let caches = try #require(section["caches"] as? [[String: Any]])
        #expect(section["availability"] as? Int == 0)
        #expect(caches.count == 1)
        let entry = try #require(caches.first)
        let blobCount = entry["blobCount"] as? Int
        let buckets = entry["buckets"] as? [Int]
        #expect(blobCount == 1)
        #expect(buckets == [1, 0, 0, 0, 0, 0])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("private-0"))
        #expect(!text.contains("private-payload-value"))
        #expect(!text.contains("private-ignored"))
        #expect(try Data(contentsOf: file) == Data("private-payload-value".utf8))
    }

    @Test func readFailureAfterOneBlobReportsPartialAndError() async throws {
        let (root, cache) = try fixture(derivative: "thumbnail", sizes: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = MetadataFeed(failAfterFirst: true)
        let result = await cache.thumbnailCacheSupportSnapshot(
            deadline: ContinuousClock.now.advanced(by: .seconds(30)),
            nextBlobSize: { try await feed.next() }, shouldStop: { false })
        #expect(
            result
                == ThumbnailCacheSupportSnapshot(
                    availability: .partial,
                    caches: [
                        .init(kind: .thumbnail, blobCount: 1, buckets: [1, 0, 0, 0, 0, 0], totalMiB: 1, readErrors: 1)
                    ]))
    }

    @Test func cancellationAfterOneBlobReportsPartial() async throws {
        let (root, cache) = try fixture(derivative: "thumbnail", sizes: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = MetadataFeed(failAfterFirst: false)
        let task = Task {
            await cache.thumbnailCacheSupportSnapshot(
                deadline: ContinuousClock.now.advanced(by: .seconds(30)),
                nextBlobSize: {
                    let size = try await feed.next()
                    withUnsafeCurrentTask { $0?.cancel() }
                    return size
                }, shouldStop: { false })
        }
        let result = await task.value
        #expect(
            result
                == ThumbnailCacheSupportSnapshot(
                    availability: .partial,
                    caches: [
                        .init(kind: .thumbnail, blobCount: 1, buckets: [1, 0, 0, 0, 0, 0], totalMiB: 1, readErrors: 0)
                    ]))
        #expect(feed.readCount == 1)
    }

    @Test func deadlineAfterOneBlobReportsPartial() async throws {
        let (root, cache) = try fixture(derivative: "thumbnail", sizes: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = MetadataFeed(failAfterFirst: false)
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .seconds(1))
        let result = await cache.thumbnailCacheSupportSnapshot(
            deadline: deadline, nextBlobSize: { try await feed.next() }, shouldStop: { false },
            now: { feed.hasReadOne ? deadline : start })
        #expect(
            result
                == ThumbnailCacheSupportSnapshot(
                    availability: .partial,
                    caches: [
                        .init(kind: .thumbnail, blobCount: 1, buckets: [1, 0, 0, 0, 0, 0], totalMiB: 1, readErrors: 0)
                    ]))
        #expect(feed.readCount == 1)
    }

    @Test func cancellationDuringFinalReadDoesNotReportComplete() async throws {
        let (root, cache) = try fixture(derivative: "thumbnail", sizes: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = MetadataFeed(failAfterFirst: false)
        let task = Task {
            await cache.thumbnailCacheSupportSnapshot(
                deadline: ContinuousClock.now.advanced(by: .seconds(30)),
                nextBlobSize: {
                    _ = try await feed.next()
                    withUnsafeCurrentTask { $0?.cancel() }
                    return nil
                }, shouldStop: { false })
        }
        let result = await task.value
        #expect(result.availability == .partial)
        #expect(feed.readCount == 1)
    }

    @Test func deadlineDuringFinalReadDoesNotReportComplete() async throws {
        let (root, cache) = try fixture(derivative: "thumbnail", sizes: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = MetadataFeed(failAfterFirst: false)
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .seconds(1))
        let result = await cache.thumbnailCacheSupportSnapshot(
            deadline: deadline,
            nextBlobSize: {
                _ = try await feed.next()
                return nil
            }, shouldStop: { false },
            now: { feed.hasReadOne ? deadline : start })
        #expect(result.availability == .partial)
        #expect(feed.readCount == 1)
    }

    @Test func stopAfterOneBlobReportsPartial() async throws {
        let (root, cache) = try fixture(derivative: "thumbnail", sizes: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = MetadataFeed(failAfterFirst: false)
        let result = await cache.thumbnailCacheSupportSnapshot(
            deadline: ContinuousClock.now.advanced(by: .seconds(30)),
            nextBlobSize: { try await feed.next() }, shouldStop: { feed.hasReadOne })
        #expect(
            result
                == ThumbnailCacheSupportSnapshot(
                    availability: .partial,
                    caches: [
                        .init(kind: .thumbnail, blobCount: 1, buckets: [1, 0, 0, 0, 0, 0], totalMiB: 1, readErrors: 0)
                    ]))
        #expect(feed.readCount == 1)
    }
}

private final class MetadataFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let failAfterFirst: Bool
    init(failAfterFirst: Bool) { self.failAfterFirst = failAfterFirst }
    var hasReadOne: Bool { lock.withLock { reads > 0 } }
    var readCount: Int { lock.withLock { reads } }
    func next() async throws -> Int64? {
        try lock.withLock {
            reads += 1
            if reads == 1 { return 123 }
            if failAfterFirst { throw CocoaError(.fileReadNoPermission) }
            return nil
        }
    }
}

private final class IteratorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stop: Bool
    private let stopAt: ThumbnailSupportMetadataIterator.ProbeStep?
    private var roots = 0
    private var entries = 0
    private var enumerators = 0
    private var nexts = 0
    private var advanced = false
    init(stopInitially: Bool = false, stopAt: ThumbnailSupportMetadataIterator.ProbeStep? = nil) {
        self.stop = stopInitially
        self.stopAt = stopAt
    }
    var stopped: Bool { lock.withLock { stop } }
    var rootReads: Int { lock.withLock { roots } }
    var entryReads: Int { lock.withLock { entries } }
    var enumeratorAttempts: Int { lock.withLock { enumerators } }
    var nextAttempts: Int { lock.withLock { nexts } }
    var clockAdvanced: Bool { lock.withLock { advanced } }
    func advanceClock() { lock.withLock { advanced = true } }
    func observe(_ step: ThumbnailSupportMetadataIterator.ProbeStep) {
        lock.withLock {
            if step == .rootRead { roots += 1 }
            if step == .entryRead { entries += 1 }
            if step == .enumeratorAttempt { enumerators += 1 }
            if step == .nextObjectAttempt { nexts += 1 }
            if step == stopAt { stop = true }
        }
    }
}

private final class SizeFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int64]
    init(_ sizes: [Int64]) { self.sizes = sizes }
    func next() -> Int64? { lock.withLock { sizes.isEmpty ? nil : sizes.removeFirst() } }
}
