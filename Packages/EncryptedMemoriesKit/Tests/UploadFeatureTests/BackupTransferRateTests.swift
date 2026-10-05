import Foundation
import XCTest

@testable import UploadCore

/// The upload speed that the backup status shows: the growth of the sent bytes over the last seconds.
final class BackupTransferRateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    func testTheSpeedIsTheGrowthOfTheSentBytes() throws {
        var rate = BackupTransferRate()
        rate.record(bytes: 0, at: start)
        rate.record(bytes: 1_000_000, at: start.addingTimeInterval(1))
        XCTAssertNil(rate.bytesPerSecond, "one second is too short for a speed")

        rate.record(bytes: 4_000_000, at: start.addingTimeInterval(2))
        XCTAssertEqual(try XCTUnwrap(rate.bytesPerSecond), 2_000_000, accuracy: 1)
    }

    func testOnlyTheLastSecondsCount() throws {
        var rate = BackupTransferRate(window: 10)
        rate.record(bytes: 0, at: start)
        for second in 1...30 {
            // 1 MB per second for 20 seconds, then 100 KB per second.
            let bytes = second <= 20 ? Int64(second) * 1_000_000 : 20_000_000 + Int64(second - 20) * 100_000
            rate.record(bytes: bytes, at: start.addingTimeInterval(TimeInterval(second)))
        }
        XCTAssertEqual(try XCTUnwrap(rate.bytesPerSecond), 100_000, accuracy: 1)
    }

    func testFrequentUpdatesKeepTheSpeedExact() throws {
        var rate = BackupTransferRate()
        for tick in 0...400 {
            // 1 MB per second, reported every 10 ms.
            rate.record(bytes: Int64(tick) * 10_000, at: start.addingTimeInterval(TimeInterval(tick) / 100))
        }
        XCTAssertEqual(try XCTUnwrap(rate.bytesPerSecond), 1_000_000, accuracy: 1)
    }

    func testASmallerTotalStartsANewMeasurement() {
        var rate = BackupTransferRate()
        rate.record(bytes: 0, at: start)
        rate.record(bytes: 9_000_000, at: start.addingTimeInterval(3))
        XCTAssertNotNil(rate.bytesPerSecond)

        rate.record(bytes: 100, at: start.addingTimeInterval(4))
        XCTAssertNil(rate.bytesPerSecond, "a new runner counts from zero again")
    }
}
