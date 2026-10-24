import Foundation
import Photos
import XCTest

@testable import PhotoLibraryBackupAdapter

@MainActor
final class SharedPhotoLibraryObservationTests: XCTestCase {
    func testIndependentMonitorsKeepIndependentSnapshotsAndCallbacks() async throws {
        let probe = PhotoChangeOperationsProbe()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = PhotoLibraryChangeMonitor(
            tokenURL: directory.appendingPathComponent("first"), operations: probe.operations)
        let second = PhotoLibraryChangeMonitor(
            tokenURL: directory.appendingPathComponent("second"), operations: probe.operations)
        defer {
            first.stopObserving()
            second.stopObserving()
        }
        let calls = ChangeCallCounter()
        first.startObserving { calls.increment("first") }
        second.startObserving { calls.increment("second") }
        await changeCondition { probe.registeredCount == 2 }
        XCTAssertEqual(probe.fetchCount, 2)
        probe.emit()
        XCTAssertEqual(calls.value("first"), 1)
        XCTAssertEqual(calls.value("second"), 1)
        XCTAssertEqual(probe.detailCount, 2)
        first.stopObserving()
        probe.emit()
        XCTAssertEqual(calls.value("first"), 1)
        XCTAssertEqual(calls.value("second"), 2)
    }

    func testLegacyStartReplacesOnlyItsCallbackAndNilDetailsDoNotNotify() async throws {
        let probe = PhotoChangeOperationsProbe()
        let monitor = PhotoLibraryChangeMonitor(
            tokenURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            operations: probe.operations)
        defer { monitor.stopObserving() }
        let calls = ChangeCallCounter()
        monitor.startObserving { calls.increment("old") }
        monitor.startObserving { calls.increment("current") }
        await changeCondition { probe.registeredCount == 1 }
        probe.emit()
        XCTAssertEqual(calls.value("old"), 0)
        XCTAssertEqual(calls.value("current"), 1)
        probe.hasDetails = false
        probe.emit()
        XCTAssertEqual(calls.value("current"), 1)
        XCTAssertEqual(probe.fetchCount, 1)
    }
    func testSubscriptionsAndLegacyObservationCancelIndependentlyAndCanReenter() async throws {
        let probe = PhotoChangeOperationsProbe()
        let monitor = PhotoLibraryChangeMonitor(
            tokenURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            operations: probe.operations)
        let calls = ChangeCallCounter()
        let holder = PhotoSubscriptionHolder()
        holder.subscription = monitor.subscribe {
            calls.increment("once")
            holder.cancel()
        }
        let other = monitor.subscribe { calls.increment("other") }
        defer {
            holder.cancel()
            other.cancel()
            monitor.stopObserving()
        }
        monitor.startObserving { calls.increment("legacy") }
        await changeCondition { probe.registeredCount == 1 }
        probe.emit()
        monitor.stopObserving()
        probe.emit()
        XCTAssertEqual(calls.value("once"), 1)
        XCTAssertEqual(calls.value("other"), 2)
        XCTAssertEqual(calls.value("legacy"), 1)
        XCTAssertEqual(probe.fetchCount, 1)
        XCTAssertEqual(probe.detailCount, 2)
        other.cancel()
        other.cancel()
        XCTAssertEqual(probe.registeredCount, 0)
        probe.emitRetired()
        XCTAssertEqual(calls.value("other"), 2)
    }

    func testCancellationDuringDeliveryRevokesTheOtherUndeliveredCallback() async throws {
        let probe = PhotoChangeOperationsProbe()
        let monitor = PhotoLibraryChangeMonitor(
            tokenURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            operations: probe.operations)
        let first = PhotoSubscriptionHolder()
        let second = PhotoSubscriptionHolder()
        let calls = ChangeCallCounter()
        first.subscription = monitor.subscribe {
            calls.increment("first")
            second.cancel()
        }
        second.subscription = monitor.subscribe {
            calls.increment("second")
            first.cancel()
        }
        defer {
            first.cancel()
            second.cancel()
        }
        await changeCondition { probe.registeredCount == 1 }
        probe.emit()
        XCTAssertEqual(calls.value("first") + calls.value("second"), 1)
        probe.emit()
        XCTAssertEqual(calls.value("first") + calls.value("second"), 2)
    }

    func testReleasingAReplacedOrStoppedCallbackCanCancelItsCapturedSubscription() async throws {
        let probe = PhotoChangeOperationsProbe()
        let monitor = PhotoLibraryChangeMonitor(
            tokenURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            operations: probe.operations)
        func installCapturedSubscription() {
            let captured = PhotoSubscriptionHolder()
            captured.subscription = monitor.subscribe {}
            monitor.startObserving { _ = captured.subscription }
        }
        installCapturedSubscription()
        await changeCondition { probe.registeredCount == 1 }
        monitor.startObserving {}
        XCTAssertEqual(probe.registeredCount, 1)
        monitor.stopObserving()
        XCTAssertEqual(probe.registeredCount, 0)
        installCapturedSubscription()
        await changeCondition { probe.registeredCount == 1 }
        monitor.stopObserving()
        XCTAssertEqual(probe.registeredCount, 0)
    }

    func testAStoppedStartupCannotReplaceTheNextSubscriptionsSnapshot() async throws {
        let probe = PhotoChangeOperationsProbe()
        let gate = PhotoSnapshotGate()
        var operations = probe.operations
        operations.fetch = { gate.fetch() }
        let monitor = PhotoLibraryChangeMonitor(
            tokenURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            operations: operations)
        let calls = ChangeCallCounter()
        let old = monitor.subscribe { calls.increment("old") }
        defer {
            old.cancel()
            gate.releaseAll()
        }
        await changeCondition { gate.started == 1 }
        old.cancel()
        let current = monitor.subscribe { calls.increment("current") }
        defer { current.cancel() }
        await changeCondition { gate.started == 2 }
        gate.release(1)
        await changeCondition { gate.releasedSnapshot(1) }
        XCTAssertEqual(probe.registeredCount, 0, "The retired snapshot must never register")
        gate.release(2)
        await changeCondition { probe.registeredCount == 1 }
        probe.emit()
        XCTAssertEqual(calls.value("old"), 0)
        XCTAssertEqual(calls.value("current"), 1)
    }

    func testLateRegistrationCleanupCannotUnregisterAReplacement() async throws {
        let probe = PhotoChangeOperationsProbe()
        let gate = PhotoRegistrationGate()
        var operations = probe.operations
        let register = operations.register
        operations.register = { observer in
            gate.enter()
            register(observer)
        }
        let monitor = PhotoLibraryChangeMonitor(
            tokenURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            operations: operations)
        let calls = ChangeCallCounter()
        let old = monitor.subscribe { calls.increment("old") }
        defer {
            old.cancel()
            gate.release()
        }
        await changeCondition { gate.entered == 1 }
        old.cancel()
        let current = monitor.subscribe { calls.increment("current") }
        defer { current.cancel() }
        await changeCondition { probe.registeredCount == 1 && gate.entered == 2 }
        gate.release()
        await changeCondition { probe.unregisterCount >= 2 }
        XCTAssertEqual(probe.registeredCount, 1)
        probe.emit()
        XCTAssertEqual(calls.value("current"), 1, "The replacement must remain physically registered")
        probe.emitRetired()
        XCTAssertEqual(calls.value("old"), 0)
        XCTAssertEqual(calls.value("current"), 2, "Only the current registration may read and notify")
        XCTAssertEqual(probe.detailCount, 2)
    }
}

@MainActor
func changeCondition(
    file: StaticString = #filePath, line: UInt = #line,
    _ predicate: @escaping @MainActor () async -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else {
            XCTFail("The controlled operation did not reach its expected boundary", file: file, line: line)
            return
        }
        await Task.yield()
    }
}

final class ChangeCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func increment(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
    func value(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
}

final class PhotoChangeOperationsProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [ObjectIdentifier: any PHPhotoLibraryChangeObserver] = [:]
    private var registrations: [any PHPhotoLibraryChangeObserver] = []
    private var unregisters = 0
    private var fetches = 0
    private var details = 0
    private var returnsDetails = true
    var hasDetails: Bool {
        get { lock.withLock { returnsDetails } }
        set { lock.withLock { returnsDetails = newValue } }
    }
    var unregisterCount: Int { lock.withLock { unregisters } }
    var fetchCount: Int { lock.withLock { fetches } }
    var detailCount: Int { lock.withLock { details } }
    var registeredCount: Int { lock.withLock { observers.count } }
    var operations: PhotoLibraryChangeMonitor.Operations {
        .init(
            fetch: { [self] in
                lock.withLock { fetches += 1 }
                return PHFetchResult<PHAsset>()
            },
            register: { [self] observer in
                lock.withLock {
                    observers[ObjectIdentifier(observer)] = observer
                    registrations.append(observer)
                }
            },
            unregister: { [self] observer in
                lock.withLock {
                    unregisters += 1
                    observers[ObjectIdentifier(observer)] = nil
                }
            },
            details: { [self] _, assets in
                lock.withLock {
                    details += 1
                    return returnsDetails
                        ? .init(assets: assets, changed: ["changed"], deleted: [], requiresFullRescan: false) : nil
                }
            })
    }
    func emitRetired() {
        let current = lock.withLock { registrations }
        for observer in current { observer.photoLibraryDidChange(PHChange()) }
    }
    func emit() {
        let current = lock.withLock { Array(observers.values) }
        let event = PHChange()
        for observer in current { observer.photoLibraryDidChange(event) }
    }
}

final class PhotoChangeSleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<UUID> = []
    private var requests: [Duration] = []
    func requestCount(_ duration: Duration) -> Int { lock.withLock { requests.filter { $0 == duration }.count } }
    func count(_ duration: Duration) -> Int {
        lock.withLock { waits.values.filter { $0.0 == duration }.count }
    }
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let refuse = lock.withLock {
                    if cancelled.remove(id) != nil || Task.isCancelled { return true }
                    requests.append(duration)
                    waits[id] = (duration, continuation)
                    return false
                }
                if refuse { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock {
                self.cancelled.insert(id)
                return self.waits.removeValue(forKey: id)?.1
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
    func release(_ duration: Duration) {
        let continuations = lock.withLock {
            let ids = waits.filter { $0.value.0 == duration }.map(\.key)
            return ids.compactMap { waits.removeValue(forKey: $0)?.1 }
        }
        for continuation in continuations { continuation.resume() }
    }
    func releaseAll() {
        let continuations = lock.withLock {
            let result = waits.values.map(\.1)
            waits.removeAll()
            return result
        }
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

private final class PhotoSubscriptionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PhotoLibraryChangeMonitor.Subscription?
    var subscription: PhotoLibraryChangeMonitor.Subscription? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func cancel() { subscription?.cancel() }
}

private final class PhotoSnapshotGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var starts = 0
    private var permits: Set<Int> = []
    private var released: Set<Int> = []
    private var open = false
    var started: Int { condition.withLock { starts } }
    func releasedSnapshot(_ index: Int) -> Bool { condition.withLock { released.contains(index) } }
    func fetch() -> PHFetchResult<PHAsset> {
        condition.lock()
        starts += 1
        let index = starts
        while !open && !permits.contains(index) { condition.wait() }
        condition.unlock()
        return PhotoCompletionFetchResult { [self] in _ = condition.withLock { released.insert(index) } }
    }
    func release(_ index: Int) {
        condition.withLock {
            _ = permits.insert(index)
            condition.broadcast()
        }
    }
    func releaseAll() {
        condition.withLock {
            open = true
            condition.broadcast()
        }
    }
}

private final class PhotoCompletionFetchResult: PHFetchResult<PHAsset>, @unchecked Sendable {
    private let completed: @Sendable () -> Void
    init(_ completed: @escaping @Sendable () -> Void) {
        self.completed = completed
        super.init()
    }
    deinit { completed() }
}

private final class PhotoRegistrationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0
    private var open = false
    var entered: Int { condition.withLock { count } }
    func enter() {
        condition.lock()
        count += 1
        while count == 1 && !open { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.withLock {
            open = true
            condition.broadcast()
        }
    }
}
