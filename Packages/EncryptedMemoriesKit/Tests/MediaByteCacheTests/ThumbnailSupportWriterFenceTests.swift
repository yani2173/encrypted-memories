#if DEBUG
    import Darwin
    import Foundation
    import PhotosCore
    import Testing

    @testable import MediaByteCache

    @Suite struct ThumbnailSupportWriterFenceTests {
        @Test func retiredSessionDiscardsScanAfterLeaseCapture() async throws {
            var path = Array((NSTemporaryDirectory() + "issue919-retire-XXXXXXXX").utf8CString)
            let root = try path.withUnsafeMutableBufferPointer { bytes -> URL in
                guard let base = bytes.baseAddress, let result = mkdtemp(base) else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return URL(fileURLWithPath: String(cString: result), isDirectory: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = ThumbnailCache(namespace: "test", rootDirectory: root)
            let calls = LeaseRetirementCalls()
            let result = await cache.supportSnapshotForTesting(
                deadline: .now.advanced(by: .seconds(30)), onEntry: {},
                afterLease: {
                    calls.increment()
                    cache.clearForSignOut()
                })
            #expect(calls.value == 1)
            #expect(result == .unavailable)
        }

        @Test func diagnosticLeaseRetiresAcrossClearAndSessionChange() throws {
            let generation = CacheWriterGeneration()
            let before = try #require(generation.tryCaptureDiagnosticLease())
            generation.invalidateAndPerform {
                #expect(generation.tryCaptureDiagnosticLease() == nil)
                #expect(!generation.isCurrentDiagnosticLease(before))
            }
            #expect(!generation.isCurrentDiagnosticLease(before))
            let afterClear = try #require(generation.tryCaptureDiagnosticLease())
            #expect(generation.isCurrentDiagnosticLease(afterClear))
            generation.invalidateAndPerform(invalidatesSession: true) {
                #expect(generation.tryCaptureDiagnosticLease() == nil)
                #expect(!generation.isCurrentDiagnosticLease(afterClear))
            }
            #expect(!generation.isCurrentDiagnosticLease(afterClear))
            let afterSession = try #require(generation.tryCaptureDiagnosticLease())
            #expect(generation.isCurrentDiagnosticLease(afterSession))
        }

        @Test func writerFenceDoesNotSelectBlockingSessionPath() async throws {
            var path = Array((NSTemporaryDirectory() + "issue919-writer-XXXXXXXX").utf8CString)
            let root = try path.withUnsafeMutableBufferPointer { bytes -> URL in
                guard let base = bytes.baseAddress, let result = mkdtemp(base) else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return URL(fileURLWithPath: String(cString: result), isDirectory: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            let runtime = LibraryRuntimeState()
            let cache = ThumbnailCache(
                namespace: "test", derivative: "thumbnail",
                rootDirectory: root, runtimeState: runtime)
            await cache.flushAutomaticDiskCap()
            let empty = ThumbnailCacheSupportSnapshot(
                availability: .complete,
                caches: [
                    .init(kind: .thumbnail, blobCount: 0, buckets: [0, 0, 0, 0, 0, 0], totalMiB: 0, readErrors: 0)
                ])
            let control = await cache.thumbnailCacheSupportSnapshot(deadline: .now.advanced(by: .seconds(30)))
            guard control == empty else {
                Issue.record("INVALID: control snapshot")
                return
            }
            let generation = cache.captureWriterGeneration()
            let gate = WriterFenceGate()
            let writer = Task.detached {
                cache.storeToDisk(
                    Data([1]), for: PhotoUID(volumeID: "fixture", nodeID: "fixture"),
                    ifCurrent: generation, authorizing: { gate.authorize() })
            }
            guard await boundedWait(gate.entered), gate.isHeld else {
                gate.release.signal()
                _ = await writer.value
                Issue.record("INVALID: writer did not hold fence")
                return
            }
            let token = UUID()
            let events = WriterFenceEvents(token: token)
            cache.setSupportLockProbeForTesting { path, observedToken in
                events.recordProbe(path, token: observedToken)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            let scanner = Task.detached {
                await SupportLockProbeScope.$token.withValue(token) {
                    let value = await cache.supportSnapshotForTesting(deadline: deadline) {
                        events.recordEntry(token: SupportLockProbeScope.token)
                    }
                    events.recordResult(value, token: SupportLockProbeScope.token, cancelled: Task.isCancelled)
                    return value
                }
            }
            let entered = await boundedWait(events.entry)
            let eventReady = await boundedWait(events.firstEvent)
            let evidence = events.snapshot()
            var isDirectory: ObjCBool = false
            let rootValid =
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("test.enc").path, isDirectory: &isDirectory)
                && isDirectory.boolValue
            let heldAtEvent = gate.isHeld
            gate.release.signal()
            let writerResult = await writer.value
            let scanResult = await scanner.value
            cache.setSupportLockProbeForTesting(nil)
            let finalEvidence = events.snapshot()
            guard entered, eventReady, rootValid, heldAtEvent, writerResult == .stored,
                evidence.entryToken == token, let entryTime = evidence.entryTime,
                let eventTime = evidence.eventTime, entryTime <= eventTime,
                entryTime < deadline, eventTime < deadline, ContinuousClock.now < deadline,
                finalEvidence.foreignCount == 0, !finalEvidence.cancelled,
                scanResult.availability != .partial, let first = evidence.first
            else {
                Issue.record("INVALID: setup, foreign event, deadline, cancellation, writer, or root")
                return
            }
            switch first {
            case .capture:
                Issue.record("blocking capture lock path was selected while writer held the fence")
            case .validate:
                Issue.record("blocking validation lock path was selected while writer held the fence")
            case .result(let value):
                guard value == .unavailable || value == empty else {
                    Issue.record("INVALID: result is neither unavailable nor the valid empty snapshot")
                    return
                }
                #expect(value == scanResult)
            case .foreign:
                Issue.record("INVALID: foreign probe event")
            }
        }
    }

    private final class LeaseRetirementCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private func boundedWait(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    private final class WriterFenceGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        private var held = false
        var isHeld: Bool { lock.withLock { held } }
        func authorize() -> Bool {
            let second = lock.withLock {
                calls += 1
                return calls == 2
            }
            if second {
                lock.withLock { held = true }
                entered.signal()
                release.wait()
                lock.withLock { held = false }
            }
            return true
        }
    }

    private final class WriterFenceEvents: @unchecked Sendable {
        enum First {
            case capture, validate
            case result(ThumbnailCacheSupportSnapshot)
            case foreign
        }
        struct Snapshot {
            let first: First?
            let entryToken: UUID?
            let entryTime: ContinuousClock.Instant?
            let eventTime: ContinuousClock.Instant?
            let foreignCount: Int
            let cancelled: Bool
        }
        let entry = DispatchSemaphore(value: 0)
        let firstEvent = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let expected: UUID
        private var first: First?
        private var entryToken: UUID?
        private var entryTime: ContinuousClock.Instant?
        private var eventTime: ContinuousClock.Instant?
        private var foreignCount = 0
        private var cancelled = false
        init(token: UUID) { expected = token }
        func recordEntry(token: UUID?) {
            lock.withLock {
                entryToken = token
                entryTime = .now
            }
            entry.signal()
        }
        func recordProbe(_ path: SupportLockPath, token: UUID?) {
            record(token == expected ? (path == .capture ? .capture : .validate) : .foreign, token: token)
        }
        func recordResult(_ value: ThumbnailCacheSupportSnapshot, token: UUID?, cancelled: Bool) {
            lock.withLock { self.cancelled = cancelled }
            record(token == expected ? .result(value) : .foreign, token: token)
        }
        private func record(_ event: First, token: UUID?) {
            let signal = lock.withLock {
                if token != expected { foreignCount += 1 }
                guard first == nil else { return false }
                first = event
                eventTime = .now
                return true
            }
            if signal { firstEvent.signal() }
        }
        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(
                    first: first, entryToken: entryToken, entryTime: entryTime,
                    eventTime: eventTime, foreignCount: foreignCount, cancelled: cancelled)
            }
        }
    }
#endif
