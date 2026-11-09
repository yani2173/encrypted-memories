#if os(macOS)
    import Darwin
    import Foundation
    import XCTest

    @testable import UploadCore

    final class BackupProblemSnapshotMeasurementTests: XCTestCase {
        private struct WriterSample: Codable, Sendable {
            let lockHeldMilliseconds: Double
            let writerCallMilliseconds: Double
            let writerStartedDuringRead: Bool
            let writerFinishedAfterRead: Bool
            let writeSucceeded: Bool
        }

        #if DEBUG
            func testMeasureConcurrentWriterWaitAtFiveThousandPhotos() async throws {
                let samples = try await Task.detached(priority: .userInitiated) {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let queue = try XCTUnwrap(
                        UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue")))
                    defer { queue.close() }
                    let entries = (0..<5_000).map { index in
                        UploadBackupSyncQueueEntry(
                            source: .init(kind: .photoLibraryAsset, identifier: "photo-\(index)"),
                            revision: .init(rawValue: Int64(index)), originalFilename: "photo-\(index).heic",
                            state: .failedPermanent,
                            lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Reason").persistedValue,
                            updatedAt: Date(timeIntervalSince1970: 0))
                    }
                    XCTAssertTrue(queue.upsertBatch(entries))
                    var samples: [WriterSample] = []
                    for _ in 0..<10 {
                        let probe = WriterProbe()
                        queue.onProblemReadEvent = {
                            switch $0 {
                            case .didLock: probe.begin(queue: queue, entry: entries[0])
                            case .didUnlock: probe.readEnded()
                            default: break
                            }
                        }
                        XCTAssertEqual(BackupProblemSnapshot.backup(in: queue)?.rows.count, 5_000)
                        let sample = try XCTUnwrap(probe.finish())
                        samples.append(sample)
                        queue.onProblemReadEvent = nil
                    }
                    return samples
                }.value
                XCTAssertEqual(samples.count, 10)
                for sample in samples {
                    XCTAssertTrue(sample.writeSucceeded)
                    XCTAssertTrue(sample.writerStartedDuringRead)
                    XCTAssertTrue(sample.writerFinishedAfterRead)
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let base = ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_PROBLEM_MEASUREMENT_FILE"]
                let url =
                    base.map { URL(fileURLWithPath: $0 + ".writer.json") }
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                        "backup-problem-writer-measurements.json")
                try encoder.encode(samples).write(to: url)
            }
        #endif

        private final class WriterProbe: @unchecked Sendable {
            private let lock = NSLock()
            private let finished = DispatchSemaphore(value: 0)
            private var readStart: UInt64 = 0
            private var readEnd: UInt64 = 0
            private var writerStart: UInt64 = 0
            private var writerEnd: UInt64 = 0
            private var succeeded = false

            func begin(queue: UploadBackupSyncQueueManifestStore, entry: UploadBackupSyncQueueEntry) {
                lock.withLock { readStart = DispatchTime.now().uptimeNanoseconds }
                DispatchQueue.global(qos: .userInitiated).async {
                    self.lock.withLock { self.writerStart = DispatchTime.now().uptimeNanoseconds }
                    let result = queue.upsert(entry)
                    self.lock.withLock {
                        self.succeeded = result
                        self.writerEnd = DispatchTime.now().uptimeNanoseconds
                    }
                    self.finished.signal()
                }
            }

            func readEnded() { lock.withLock { readEnd = DispatchTime.now().uptimeNanoseconds } }

            func finish() -> WriterSample? {
                guard finished.wait(timeout: .now() + 5) == .success else { return nil }
                return lock.withLock {
                    WriterSample(
                        lockHeldMilliseconds: milliseconds(readEnd - readStart),
                        writerCallMilliseconds: milliseconds(writerEnd - writerStart),
                        writerStartedDuringRead: writerStart >= readStart && writerStart < readEnd,
                        writerFinishedAfterRead: writerEnd >= readEnd, writeSucceeded: succeeded)
                }
            }
        }

        private struct Sample: Codable, Sendable {
            let photos: Int
            let unrelated: Int
            let retained: Int
            let snapshotMilliseconds: Double
            let firstPageMilliseconds: Double
            let laterPageMilliseconds: [Double]
            let cursorStatements: Int
            let cursorStepCalls: Int
            let cursorRows: Int
            let healthProbeCalls: Int
            let pageReadEvents: Int
            let lockWaitMilliseconds: Double
            let lockHeldMilliseconds: Double
            let residentBefore: UInt64
            let residentAfter: UInt64
            let sampledPeakResident: UInt64
            let ranOnMainThread: Bool
        }

        #if DEBUG
            func testMeasureRealStoreSnapshotsAndMetadataPages() async throws {
                let samples = try await Task.detached(priority: .userInitiated) {
                    var samples: [Sample] = []
                    for (photos, unrelated) in [(200, 0), (1_000, 0), (5_000, 0), (5_000, 50_000)] {
                        samples += try Self.measure(photos: photos, unrelated: unrelated)
                    }
                    return samples
                }.value
                XCTAssertEqual(samples.count, 40)
                for sample in samples {
                    XCTAssertFalse(sample.ranOnMainThread)
                    XCTAssertEqual(sample.retained, sample.photos + min(200, sample.unrelated))
                    XCTAssertEqual(sample.cursorStatements, 1)
                    XCTAssertEqual(sample.cursorStepCalls, sample.photos + sample.unrelated + 1)
                    XCTAssertEqual(sample.cursorRows, sample.photos + sample.unrelated)
                    XCTAssertEqual(sample.healthProbeCalls, 2)
                    XCTAssertEqual(sample.pageReadEvents, 0)
                    XCTAssertGreaterThan(sample.residentBefore, 0)
                    XCTAssertGreaterThanOrEqual(sample.sampledPeakResident, sample.residentAfter)
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(samples)
                let url =
                    ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_PROBLEM_MEASUREMENT_FILE"].map {
                        URL(fileURLWithPath: $0)
                    }
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                        "backup-problem-snapshot-measurements.json")
                try data.write(to: url)
                print("Problem snapshot measurements: \(url.path)")
            }
        #endif

        #if DEBUG
            private static func measure(photos: Int, unrelated: Int) throws -> [Sample] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let queue = try XCTUnwrap(
                    UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue")))
                defer { queue.close() }
                func entry(_ index: Int, decision: Bool) -> UploadBackupSyncQueueEntry {
                    .init(
                        source: .init(kind: .photoLibraryAsset, identifier: "photo-\(index)"),
                        revision: .init(rawValue: Int64(index)), originalFilename: "photo-\(index).heic",
                        state: decision ? .failedPermanent : .failed,
                        lastError: BackupIssueRecord(kind: decision ? .deletedElsewhere : .permission, detail: "Reason")
                            .persistedValue,
                        updatedAt: Date(timeIntervalSince1970: 0))
                }
                XCTAssertTrue(queue.upsertBatch((0..<photos).map { entry($0, decision: true) }))
                if unrelated > 0 {
                    XCTAssertTrue(queue.upsertBatch((100_000..<100_000 + unrelated).map { entry($0, decision: false) }))
                }
                var results: [Sample] = []
                for _ in 0..<10 {
                    var statements = 0
                    var steps = 0
                    var readRows = 0
                    var probes = 0
                    var events = 0
                    var lockRequested: UInt64 = 0
                    var lockAcquired: UInt64 = 0
                    var lockReleased: UInt64 = 0
                    queue.onProblemReadEvent = { event in
                        events += 1
                        switch event {
                        case .statement: statements += 1
                        case .step: steps += 1
                        case .row: readRows += 1
                        case .healthProbe: probes += 1
                        case .willLock: lockRequested = DispatchTime.now().uptimeNanoseconds
                        case .didLock: lockAcquired = DispatchTime.now().uptimeNanoseconds
                        case .didUnlock: lockReleased = DispatchTime.now().uptimeNanoseconds
                        }
                    }
                    let memory = ResidentSampler()
                    let began = DispatchTime.now().uptimeNanoseconds
                    let snapshot = try XCTUnwrap(BackupProblemSnapshot.backup(in: queue))
                    let captured = DispatchTime.now().uptimeNanoseconds
                    let first = try XCTUnwrap(snapshot.page())
                    let firstReady = DispatchTime.now().uptimeNanoseconds
                    let resident = memory.finish()
                    let readEvents = events
                    var page = first
                    var pageTimes: [Double] = []
                    while let cursor = page.next {
                        let started = DispatchTime.now().uptimeNanoseconds
                        page = try XCTUnwrap(snapshot.page(after: cursor))
                        pageTimes.append(milliseconds(DispatchTime.now().uptimeNanoseconds - started))
                    }
                    results.append(
                        Sample(
                            photos: photos, unrelated: unrelated, retained: snapshot.rows.count,
                            snapshotMilliseconds: milliseconds(captured - began),
                            firstPageMilliseconds: milliseconds(firstReady - began),
                            laterPageMilliseconds: pageTimes, cursorStatements: statements, cursorStepCalls: steps,
                            cursorRows: readRows, healthProbeCalls: probes, pageReadEvents: events - readEvents,
                            lockWaitMilliseconds: milliseconds(lockAcquired - lockRequested),
                            lockHeldMilliseconds: milliseconds(lockReleased - lockAcquired),
                            residentBefore: resident.before, residentAfter: resident.after,
                            sampledPeakResident: resident.peak,
                            ranOnMainThread: Thread.isMainThread))
                    queue.onProblemReadEvent = nil
                }
                return results
            }
        #endif

        private static func milliseconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }

        private final class ResidentSampler: @unchecked Sendable {
            private let lock = NSLock()
            private let queue = DispatchQueue(label: "backup-problem-memory-sample")
            private let timer: DispatchSourceTimer
            private let before: UInt64
            private var peak: UInt64

            init() {
                before = Self.resident()
                peak = before
                timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.sample() }
                timer.resume()
            }

            private func sample() {
                let current = Self.resident()
                lock.withLock { peak = max(peak, current) }
            }

            func finish() -> (before: UInt64, after: UInt64, peak: UInt64) {
                timer.cancel()
                queue.sync {}
                let after = Self.resident()
                return lock.withLock { (before, after, max(peak, after)) }
            }

            private static func resident() -> UInt64 {
                var info = mach_task_basic_info()
                var count = mach_msg_type_number_t(
                    MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
                let result = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                    }
                }
                return result == KERN_SUCCESS ? info.resident_size : 0
            }
        }
    }
#endif
