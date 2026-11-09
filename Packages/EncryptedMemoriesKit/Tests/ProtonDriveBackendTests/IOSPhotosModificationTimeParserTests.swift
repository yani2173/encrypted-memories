import Foundation
import Testing

@testable import ProtonDriveBackend

struct IOSPhotosModificationTimeParserTests {
    private let parser = IOSPhotosModificationTimeParser()

    @Test func acceptsWholeSecondAndFractionalSecondForms() throws {
        let whole = try #require(parser.date(from: "2026-01-02T03:04:05Z"))
        let fractional = try #require(parser.date(from: "2026-01-02T03:04:05.250Z"))

        #expect(whole.timeIntervalSince1970 == 1_767_323_045)
        #expect(fractional.timeIntervalSince(whole) == 0.25)
    }

    @Test func readsAnOffsetAsTheSameInstant() throws {
        let utc = try #require(parser.date(from: "2026-01-02T03:04:05Z"))
        let offset = try #require(parser.date(from: "2026-01-02T04:04:05+01:00"))

        #expect(utc == offset)
    }

    @Test func rejectsTextThatIsNoTimestamp() {
        #expect(parser.date(from: "") == nil)
        #expect(parser.date(from: "yesterday") == nil)
        #expect(parser.date(from: "2026-01-02") == nil)
    }
}
