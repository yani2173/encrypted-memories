import Foundation
import ProtonDriveSDK
import Testing
import UploadCore

@testable import ProtonDriveBackend

@Suite("SDK modification time")
struct SDKModificationTimeTests {
    // MARK: Writing

    @Test func writesTheInstantInUTCWithSevenFractionalDigits() throws {
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSince1970: 1_761_040_500))
                == "2025-10-21T09:55:00.0000000Z")
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSince1970: 1_761_040_500.125))
                == "2025-10-21T09:55:00.1250000Z")
    }

    /// The earlier API rounded the date to whole nanoseconds, and the native core then kept 100-nanosecond ticks.
    @Test func roundsToNanosecondsThenKeepsWholeTicks() throws {
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSinceReferenceDate: 0.000_000_15))
                == "2001-01-01T00:00:00.0000001Z", "150 ns is one whole tick")
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSinceReferenceDate: 0.000_000_05))
                == "2001-01-01T00:00:00.0000000Z", "50 ns is less than one tick")
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSinceReferenceDate: 0.000_000_099_6))
                == "2001-01-01T00:00:00.0000001Z", "99.6 ns rounds to 100 ns before the tick cut")
    }

    @Test func writesDatesBefore1970WithAPositiveFraction() throws {
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSince1970: -0.5))
                == "1969-12-31T23:59:59.5000000Z")
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSince1970: -2_203_891_200))
                == "1900-03-01T00:00:00.0000000Z")
    }

    @Test func writesLeapDaysAndCenturyYears() throws {
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSince1970: 951_825_600))
                == "2000-02-29T12:00:00.0000000Z")
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSince1970: 4_107_542_400))
                == "2100-03-01T00:00:00.0000000Z")
    }

    /// The native core counts in the proleptic Gregorian calendar; Foundation's Gregorian calendar switches to
    /// Julian dates before 1582-10-15.
    @Test func usesTheProlepticGregorianCalendar() throws {
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSince1970: -12_219_292_800))
                == "1582-10-15T00:00:00.0000000Z")
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSince1970: -12_219_379_200))
                == "1582-10-14T00:00:00.0000000Z")
    }

    @Test func writesTheFirstAndLastSecondTheSDKAccepts() throws {
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSince1970: -62_135_596_800))
                == "0001-01-01T00:00:00.0000000Z")
        #expect(
            try SDKModificationTime.string(from: Date(timeIntervalSince1970: 253_402_300_799))
                == "9999-12-31T23:59:59.0000000Z")
    }

    @Test(arguments: [-62_135_596_801, 253_402_300_800, -Double.greatestFiniteMagnitude, .infinity, .nan])
    func refusesDatesOutsideTheSDKRange(seconds: Double) {
        #expect(throws: SDKModificationTime.FormatError.outOfRange) {
            try SDKModificationTime.string(from: Date(timeIntervalSince1970: seconds))
        }
    }

    // MARK: Reading

    @Test func readsAPositiveNegativeAndHalfHourOffset() {
        let instant = Date(timeIntervalSince1970: 1_792_547_700)  // 2026-10-21T01:55:00Z
        #expect(SDKModificationTime.date(from: "2026-10-21T09:55:00+08:00") == instant)
        #expect(SDKModificationTime.date(from: "2026-10-20T20:55:00-05:00") == instant)
        #expect(SDKModificationTime.date(from: "2026-10-21T07:25:00+05:30") == instant)
        #expect(SDKModificationTime.date(from: "2026-10-21T01:55:00Z") == instant)
        #expect(SDKModificationTime.date(from: "2026-10-21T01:55:00+00:00") == instant)
        #expect(SDKModificationTime.date(from: "2026-10-21T15:55:00+14:00") == instant)
    }

    @Test func readsUpToSevenFractionalDigitsLikeTheTimestampItReplaces() {
        #expect(
            SDKModificationTime.date(from: "2026-10-21T09:55:00.0000000+08:00")
                == Date(timeIntervalSince1970: 1_792_547_700))
        // The earlier API returned `Double(seconds) + Double(nanos) / 1e9` of the protobuf timestamp.
        #expect(
            SDKModificationTime.date(from: "2026-10-21T09:55:00.1234567+08:00")
                == Date(timeIntervalSince1970: TimeInterval(1_792_547_700) + TimeInterval(123_456_700) / 1e9))
        #expect(
            SDKModificationTime.date(from: "2026-10-21T09:55:00.5+08:00")
                == Date(timeIntervalSince1970: 1_792_547_700.5))
    }

    @Test func readsUploadsThatTheSDKReportsInUTC() {
        #expect(
            SDKModificationTime.date(from: "1970-01-01T00:02:03.0000000+00:00") == Date(timeIntervalSince1970: 123))
    }

    @Test func readsDatesBefore1970() {
        #expect(
            SDKModificationTime.date(from: "1969-12-31T23:59:59.5000000+00:00") == Date(timeIntervalSince1970: -0.5))
        #expect(
            SDKModificationTime.date(from: "0001-01-01T00:00:00.0000000+00:00")
                == Date(timeIntervalSince1970: -62_135_596_800))
        #expect(
            SDKModificationTime.date(from: "1582-10-14T00:00:00.0000000+00:00")
                == Date(timeIntervalSince1970: -12_219_379_200))
    }

    @Test func readsLeapDaysAndBothSidesOfADaylightSavingChange() throws {
        #expect(
            SDKModificationTime.date(from: "2024-02-29T12:00:00+00:00") == Date(timeIntervalSince1970: 1_709_208_000))
        // Central Europe moved from +01:00 to +02:00 at 2026-03-29T01:00:00Z.
        let before = try #require(SDKModificationTime.date(from: "2026-03-29T01:59:59+01:00"))
        let after = try #require(SDKModificationTime.date(from: "2026-03-29T03:00:00+02:00"))
        #expect(after.timeIntervalSince(before) == 1)
        #expect(after == Date(timeIntervalSince1970: 1_774_746_000))
    }

    @Test(arguments: [
        "", "garbage", "2026-10-21", "2026-10-21T09:55+08:00", "2026-10-21T09:55:00",
        "2026-10-21T09:55:00.+08:00", "2026-10-21T09:55:00.12345678+08:00", "2026-10-21 09:55:00+08:00",
        "2026-10-21t09:55:00+08:00", "2026-10-21T09:55:00z", "2026-10-21T09:55:00+0800", "2026-10-21T09:55:00+08",
        "2026-10-21T09:55:00+14:01", "2026-10-21T09:55:00+08:60", "2026-13-01T00:00:00Z", "2025-02-29T00:00:00Z",
        "2026-04-31T00:00:00Z", "2026-10-21T24:00:00Z", "2026-10-21T09:60:00Z", "2026-10-21T09:55:60Z",
        "0000-01-01T00:00:00Z", "26-10-21T09:55:00Z", "+2026-10-21T09:55:00Z", "2026-10-21T09:55:00Z ",
        " 2026-10-21T09:55:00Z", "2026-10-21T09:55:00+08:00\n", "２０２６-10-21T09:55:00Z",
    ])
    func returnsNothingForAnyOtherForm(text: String) {
        #expect(SDKModificationTime.date(from: text) == nil)
    }

    @Test(arguments: [-62_135_596_800, -0.5, 0, 0.000_000_15, 1_761_040_500.123_456_7, 253_402_300_799.5])
    func readsWhatItWritesAtTickPrecision(seconds: Double) throws {
        let text = try SDKModificationTime.string(from: Date(timeIntervalSince1970: seconds))
        let date = try #require(SDKModificationTime.date(from: text))
        #expect(try SDKModificationTime.string(from: date) == text)
        #expect(abs(date.timeIntervalSince1970 - seconds) < 0.000_000_2 + abs(seconds) * 1e-15)
    }

    // MARK: Metadata comparison

    /// The same instant written with a device offset and written in UTC must give the same metadata and duplicate
    /// fingerprint, as the comparison reads the instant and never the text.
    @Test func anOffsetAndUTCOfTheSameInstantCompareEqual() {
        let withOffset = revision(modificationTime: "2026-10-21T09:55:00.0000000+08:00")
        let inUTC = revision(modificationTime: "2026-10-21T01:55:00.0000000+00:00")
        let withZulu = revision(modificationTime: "2026-10-21T01:55:00Z")

        let offsetMetadata = SDKPhotoMetadataReader.metadata(
            name: .success("photo.heic"), mimeType: "image/heic", revision: withOffset)
        #expect(offsetMetadata.modificationTime == Date(timeIntervalSince1970: 1_792_547_700))
        #expect(
            offsetMetadata
                == SDKPhotoMetadataReader.metadata(
                    name: .success("photo.heic"), mimeType: "image/heic", revision: inUTC))
        #expect(
            offsetMetadata
                == SDKPhotoMetadataReader.metadata(
                    name: .success("photo.heic"), mimeType: "image/heic", revision: withZulu))

        let fingerprint = SDKPhotoMetadataReader.fingerprint(
            captureTime: 1_792_547_700, name: .success("photo.heic"), mimeType: "image/heic", revision: withOffset)
        #expect(
            fingerprint
                == SDKPhotoMetadataReader.fingerprint(
                    captureTime: 1_792_547_700, name: .success("photo.heic"), mimeType: "image/heic",
                    revision: inUTC))

        #expect(
            SDKPhotoMetadataReader.seriesMemberSource(
                name: "IMG.HEIC", mimeType: "image/heic", captureTime: 100, revision: withOffset)
                == SDKPhotoMetadataReader.seriesMemberSource(
                    name: "IMG.HEIC", mimeType: "image/heic", captureTime: 100, revision: inUTC))
    }

    @Test func differentInstantsStillDiffer() {
        let first = SDKPhotoMetadataReader.metadata(
            name: .success("photo.heic"), mimeType: "image/heic",
            revision: revision(modificationTime: "2026-10-21T09:55:00+08:00"))
        let second = SDKPhotoMetadataReader.metadata(
            name: .success("photo.heic"), mimeType: "image/heic",
            revision: revision(modificationTime: "2026-10-21T09:55:00+00:00"))
        #expect(first != second)
    }

    /// An unreadable value behaves like the absent value of the earlier API: no modification time in the metadata,
    /// and a series copy keeps its capture time.
    @Test func anUnreadableValueGivesNoDate() {
        let unreadable = revision(modificationTime: "2026-10-21T09:55:00")
        let metadata = SDKPhotoMetadataReader.metadata(
            name: .success("photo.heic"), mimeType: "image/heic", revision: unreadable)
        #expect(metadata.modificationTime == nil)
        #expect(
            metadata
                == SDKPhotoMetadataReader.metadata(
                    name: .success("photo.heic"), mimeType: "image/heic", revision: revision(modificationTime: nil)))

        let source = SDKPhotoMetadataReader.seriesMemberSource(
            name: "IMG.HEIC", mimeType: "image/heic", captureTime: 100, revision: unreadable)
        #expect(source.modificationDate == Date(timeIntervalSince1970: 100))
    }

    private func revision(modificationTime: String?) -> FileRevision {
        FileRevision(
            uid: SDKRevisionUid(volumeID: "volume", nodeID: "photo", revisionID: "revision"),
            state: .active, creationTime: 1, storageSize: 10, claimedSize: 10,
            claimedDigests: FileContentDigests(sha1: nil, sha1Verified: false),
            claimedModificationTime: modificationTime, thumbnails: [], claimedAdditionalMetadata: [],
            contentAuthor: nil)
    }
}
