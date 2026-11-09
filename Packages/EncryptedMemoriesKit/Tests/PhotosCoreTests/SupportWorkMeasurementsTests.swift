import Foundation
import XCTest

@testable import PhotosCore

final class SupportWorkMeasurementsTests: XCTestCase {
    func testUnavailableSourceDiffersFromAnAvailableZeroMeasurement() {
        let disabled = SupportWorkMeasurements(enabled: false)
        XCTAssertNil(disabled.begin(.indexRebuild))
        XCTAssertEqual(disabled.workMeasurementSupportSnapshot(), .unavailable)

        let active = SupportWorkMeasurements().workMeasurementSupportSnapshot()
        XCTAssertEqual(active.availability, 1)
        XCTAssertEqual(active.passes.count, SupportMeasurementKind.allCases.count)
        XCTAssertTrue(active.passes.allSatisfy { $0.started == 0 && $0.completed == 0 })
        XCTAssertTrue(active.governorWaits.allSatisfy { $0.admitted.reduce(0, +) == 0 })
    }

    func testOverlappingPassesKeepTheirCountsAndCompletionOrder() throws {
        let collector = SupportWorkMeasurements()
        let earlier = try XCTUnwrap(collector.begin(.eventUpdate))
        let later = try XCTUnwrap(collector.begin(.eventUpdate))
        earlier.record(.unlockSucceeded, count: 3)
        later.record(.unlockSucceeded, count: 7)
        let held = collector.workMeasurementSupportSnapshot().passes[SupportMeasurementKind.eventUpdate.rawValue]
        XCTAssertEqual(held.started, 2)
        XCTAssertEqual(held.inProgress, 2)
        XCTAssertEqual(held.completed, 0)
        XCTAssertTrue(held.samples.isEmpty)

        later.finish(.failure)
        earlier.finish(.success)
        let completed = collector.workMeasurementSupportSnapshot().passes[SupportMeasurementKind.eventUpdate.rawValue]
        XCTAssertEqual(completed.inProgress, 0)
        XCTAssertEqual(completed.completed, 2)
        XCTAssertEqual(completed.counters[SupportMeasurementCounter.unlockSucceeded.rawValue], 10)
        XCTAssertEqual(completed.samples.map(\.outcome), [2, 0])
        XCTAssertEqual(completed.samples.map { $0.counters[0] }, [7, 3])
    }

    func testCompletedPassIgnoresLateCountersAndDoubleFinish() throws {
        let collector = SupportWorkMeasurements()
        let pass = try XCTUnwrap(collector.begin(.nodeFactsBatch))
        pass.record(.nodeCallsStarted)
        pass.finish(.success)
        let before = collector.workMeasurementSupportSnapshot()
        pass.record(.nodeCallsStarted)
        pass.setTimelineSource(.sdkCache)
        pass.endPhase(.tags, since: .zero)
        pass.finish(.failure)
        XCTAssertEqual(collector.workMeasurementSupportSnapshot(), before)
    }

    func testClosedCollectorRejectsLateCompletionAndNewAdmission() throws {
        let collector = SupportWorkMeasurements()
        let old = try XCTUnwrap(collector.begin(.indexRebuild))
        collector.close()
        old.record(.decryptSucceeded)
        old.finish(.success)
        collector.recordQueueWait(.api, since: .zero, cancelled: false)
        XCTAssertNil(collector.begin(.indexRebuild))
        XCTAssertEqual(collector.workMeasurementSupportSnapshot(), .unavailable)
        XCTAssertEqual(SupportWorkMeasurements().workMeasurementSupportSnapshot().passes[0].completed, 0)
    }

    func testPassHistoryIsBoundedWithoutLosingTotalCounts() throws {
        let collector = SupportWorkMeasurements()
        for value in 0..<10 {
            let pass = try XCTUnwrap(collector.begin(.lineageRepair))
            pass.record(.nodesRequested, count: value)
            pass.finish(.success)
        }
        let state = collector.workMeasurementSupportSnapshot().passes[SupportMeasurementKind.lineageRepair.rawValue]
        XCTAssertEqual(state.started, 10)
        XCTAssertEqual(state.completed, 10)
        XCTAssertEqual(state.samples.count, 8)
        XCTAssertEqual(state.droppedSamples, 2)
        XCTAssertEqual(state.counters[SupportMeasurementCounter.nodesRequested.rawValue], 45)
        XCTAssertEqual(state.samples.map { $0.counters[2] }, Array(2..<10))
    }

    func testDurationAndWaitClassesKeepEveryBoundary() {
        let durations: [Duration] = [.seconds(1), .seconds(5), .seconds(15), .seconds(30), .seconds(60), .seconds(120)]
        for (index, value) in durations.enumerated() {
            XCTAssertEqual(SupportWorkMeasurements.durationClass(value - .nanoseconds(1)), index)
            XCTAssertEqual(SupportWorkMeasurements.durationClass(value), index + 1)
        }
        let waits: [Duration] = [
            .milliseconds(1), .milliseconds(10), .milliseconds(100), .seconds(1), .seconds(10), .seconds(60),
        ]
        for (index, value) in waits.enumerated() {
            XCTAssertEqual(SupportWorkMeasurements.waitClass(value - .nanoseconds(1)), index)
            XCTAssertEqual(SupportWorkMeasurements.waitClass(value), index + 1)
        }
    }

    func testAbsentPhaseIsNotAnInstantlyCompletedPhase() throws {
        let clock = MeasurementClock()
        let collector = SupportWorkMeasurements(now: { clock.value })
        let pass = try XCTUnwrap(collector.begin(.timelineLoad))
        let start = pass.instant()
        clock.advance(.milliseconds(500))
        pass.endPhase(.enumeration, since: start)
        pass.setTimelineSource(.sdkCache)
        pass.finish(.partial)
        let sample = try XCTUnwrap(
            collector.workMeasurementSupportSnapshot().passes[SupportMeasurementKind.timelineLoad.rawValue].samples
                .first)
        XCTAssertEqual(sample.enumerationClass, 0)
        XCTAssertEqual(sample.tagsClass, -1)
        XCTAssertEqual(sample.totalClass, 0)
        XCTAssertEqual(sample.timelineSource, 1)
        XCTAssertEqual(sample.outcome, 1)
    }

    func testAdmittedAndCancelledWaitsStaySeparate() {
        let clock = MeasurementClock()
        let collector = SupportWorkMeasurements(now: { clock.value })
        let first = collector.instant()
        clock.advance(.milliseconds(10))
        collector.recordQueueWait(.api, since: first, cancelled: false)
        let second = collector.instant()
        clock.advance(.seconds(2))
        collector.recordQueueWait(.api, since: second, cancelled: true)
        let state = collector.workMeasurementSupportSnapshot().governorWaits[0]
        XCTAssertEqual(state.admitted, [0, 0, 1, 0, 0, 0, 0])
        XCTAssertEqual(state.cancelled, [0, 0, 0, 0, 1, 0, 0])
    }

    func testParallelChildReadsContributeExactlyOnce() async throws {
        let collector = SupportWorkMeasurements()
        let pass = try XCTUnwrap(collector.begin(.nodeFactsBatch))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    pass.record(.nodeCallsStarted)
                    pass.record(.nodeCallsReturned)
                }
            }
        }
        pass.finish(.success)
        let counters = collector.workMeasurementSupportSnapshot().passes[SupportMeasurementKind.nodeFactsBatch.rawValue]
            .counters
        XCTAssertEqual(counters[SupportMeasurementCounter.nodeCallsStarted.rawValue], 100)
        XCTAssertEqual(counters[SupportMeasurementCounter.nodeCallsReturned.rawValue], 100)
    }

    func testCounterSaturatesWithoutWrappingOrAcceptingNegativeInput() throws {
        let collector = SupportWorkMeasurements()
        let pass = try XCTUnwrap(collector.begin(.timelineReconcile))
        pass.record(.unlockSucceeded, count: Int.max)
        pass.record(.unlockSucceeded)
        pass.record(.decryptSucceeded, count: -1)
        pass.finish(.success)
        let counters = collector.workMeasurementSupportSnapshot().passes[
            SupportMeasurementKind.timelineReconcile.rawValue
        ].counters
        XCTAssertEqual(counters[0], Int.max)
        XCTAssertEqual(counters[1], 0)
    }
}

private final class MeasurementClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Duration.zero

    var value: Duration { lock.withLock { current } }

    func advance(_ duration: Duration) {
        lock.withLock { current += duration }
    }
}
