import Foundation
import XCTest

@testable import UploadCore

/// The speed estimator under an injected clock: every timestamp comes from the test.
final class BackupUploadSpeedEstimatorTests: XCTestCase {
    private let megabyte: Int64 = 1_000_000

    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// One megabyte per second: a baseline at 0 s, then one megabyte every second up to `end`.
    private func steady(until end: Int, rate: Int64 = 1_000_000) -> BackupUploadSpeedEstimator {
        var estimator = BackupUploadSpeedEstimator()
        estimator.record(bytes: 0, at: at(0))
        for second in 1...end {
            estimator.record(bytes: Int64(second) * rate, at: at(TimeInterval(second)))
        }
        return estimator
    }

    func testNoSpeedBeforeAnyMovement() {
        var estimator = BackupUploadSpeedEstimator()
        XCTAssertNil(estimator.speed(at: at(0)))
        estimator.record(bytes: 5 * megabyte, at: at(0))
        XCTAssertNil(estimator.speed(at: at(10)), "a baseline alone is not a speed")
    }

    func testSteadyRateAppearsAfterWarmUpOnly() throws {
        var estimator = steady(until: 3)
        XCTAssertNil(estimator.speed(at: at(3)), "two seconds of known movement are not enough")
        estimator.record(bytes: 4 * megabyte, at: at(4))
        let speed = try XCTUnwrap(estimator.speed(at: at(4)))
        XCTAssertEqual(speed, Double(megabyte), accuracy: 1)
    }

    func testSpeedStaysThroughShortPauseAndGoesAfterEightSeconds() throws {
        var estimator = steady(until: 10)
        let before = try XCTUnwrap(estimator.speed(at: at(10)))
        XCTAssertEqual(try XCTUnwrap(estimator.speed(at: at(15))), before, "a pause does not drag the speed down")
        XCTAssertEqual(try XCTUnwrap(estimator.speed(at: at(17.9))), before)
        XCTAssertNil(estimator.speed(at: at(18.1)), "after eight seconds without bytes the speed is hidden")
    }

    func testMovementAfterLongGapStartsANewRun() throws {
        var estimator = steady(until: 10)
        _ = estimator.speed(at: at(10))
        // 20 seconds of silence, then a new rate of 5 MB/s. The old 1 MB/s must not blend in.
        var bytes = 10 * megabyte
        var time: TimeInterval = 30
        for _ in 0..<7 {
            time += 1
            bytes += 5 * megabyte
            estimator.record(bytes: bytes, at: at(time))
        }
        let speed = try XCTUnwrap(estimator.speed(at: at(time)))
        XCTAssertEqual(speed, Double(5 * megabyte), accuracy: 1)
    }

    func testNewRunNeedsItsOwnWarmUp() {
        var estimator = steady(until: 10)
        _ = estimator.speed(at: at(10))
        estimator.record(bytes: 20 * megabyte, at: at(40))
        estimator.record(bytes: 21 * megabyte, at: at(41))
        XCTAssertNil(estimator.speed(at: at(41)), "the old run is gone and the new one is not warm yet")
    }

    func testCoarseCounterStepsRaiseTheGapTolerance() throws {
        // A large video moves the counter in steps of one percent: here 10 MB every 20 s.
        var estimator = BackupUploadSpeedEstimator()
        estimator.record(bytes: 0, at: at(0))
        for step in 1...4 {
            estimator.record(bytes: Int64(step) * 10 * megabyte, at: at(TimeInterval(step) * 20))
        }
        XCTAssertEqual(try XCTUnwrap(estimator.speed(at: at(100))), 500_000, accuracy: 1)
        XCTAssertNotNil(estimator.speed(at: at(119)), "a step is due: twice the last interval is still calm")
        XCTAssertNil(estimator.speed(at: at(121)))
    }

    func testNewRateBlendsIntoTheAverageWithTheTimeConstant() throws {
        var estimator = steady(until: 10)
        var bytes = 10 * megabyte
        for second in 11...25 {
            bytes += 3 * megabyte
            estimator.record(bytes: bytes, at: at(TimeInterval(second)))
        }
        // 15 seconds at 3 MB/s after 1 MB/s: one time constant moves 1 - 1/e of the way.
        let expected = Double(megabyte) + 2 * Double(megabyte) * (1 - exp(-1.0))
        let speed = try XCTUnwrap(estimator.speed(at: at(25)))
        XCTAssertEqual(speed, expected, accuracy: expected * 0.01)
        XCTAssertGreaterThan(speed, Double(megabyte))
        XCTAssertLessThan(speed, Double(3 * megabyte))
    }

    func testResetForgetsEverythingAndTheNextSampleIsOnlyABaseline() {
        var estimator = steady(until: 10)
        XCTAssertNotNil(estimator.speed(at: at(10)))
        estimator.reset()
        XCTAssertNil(estimator.speed(at: at(10)))
        estimator.record(bytes: 50 * megabyte, at: at(11))
        estimator.record(bytes: 51 * megabyte, at: at(12))
        XCTAssertNil(estimator.speed(at: at(12)), "a resume starts fresh and warms up again")
    }

    func testCounterThatMovesBackwardIsANewRunner() {
        var estimator = steady(until: 10)
        XCTAssertNotNil(estimator.speed(at: at(10)))
        estimator.record(bytes: 100, at: at(11))
        XCTAssertNil(estimator.speed(at: at(11)))
    }

    func testShownValueChangesAtMostOncePerSecond() throws {
        var estimator = steady(until: 10)
        let first = try XCTUnwrap(estimator.speed(at: at(10)))
        estimator.record(bytes: 10 * megabyte + 5 * megabyte, at: at(10.4))
        XCTAssertEqual(try XCTUnwrap(estimator.speed(at: at(10.5))), first, "held within the display interval")
        let later = try XCTUnwrap(estimator.speed(at: at(11)))
        XCTAssertGreaterThan(later, first)
    }
}
