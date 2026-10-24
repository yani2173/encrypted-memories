import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class ExactDuplicateFingerprintTests: XCTestCase {
    private let first = PhotoUID(volumeID: "v", nodeID: "first")
    private let second = PhotoUID(volumeID: "v", nodeID: "second")
    private let third = PhotoUID(volumeID: "v", nodeID: "third")

    private let complete = ExactDuplicateFingerprint(
        captureTime: Date(timeIntervalSince1970: 1_700_000_000), latitude: 10.5, longitude: -20.25,
        device: "Test Camera", pixelWidth: 4000, pixelHeight: 3000, durationSeconds: 2.5, mimeType: "video/quicktime")

    /// The fingerprint with one field changed or removed, for every field.
    private func variants(changing: Bool) -> [(String, ExactDuplicateFingerprint)] {
        let base = complete
        func with(
            captureTime: Date?? = nil, latitude: Double?? = nil, longitude: Double?? = nil, device: String?? = nil,
            pixelWidth: Int?? = nil, pixelHeight: Int?? = nil, durationSeconds: Double?? = nil,
            mimeType: String?? = nil
        ) -> ExactDuplicateFingerprint {
            ExactDuplicateFingerprint(
                captureTime: captureTime ?? base.captureTime, latitude: latitude ?? base.latitude,
                longitude: longitude ?? base.longitude, device: device ?? base.device,
                pixelWidth: pixelWidth ?? base.pixelWidth, pixelHeight: pixelHeight ?? base.pixelHeight,
                durationSeconds: durationSeconds ?? base.durationSeconds, mimeType: mimeType ?? base.mimeType)
        }
        return [
            ("capture time", with(captureTime: .some(changing ? Date(timeIntervalSince1970: 1_700_000_001) : nil))),
            ("latitude", with(latitude: .some(changing ? 10.500001 : nil))),
            ("longitude", with(longitude: .some(changing ? -20.250001 : nil))),
            ("device", with(device: .some(changing ? "Other Camera" : nil))),
            ("pixel width", with(pixelWidth: .some(changing ? 3000 : nil))),
            ("pixel height", with(pixelHeight: .some(changing ? 4000 : nil))),
            ("duration", with(durationSeconds: .some(changing ? 2.6 : nil))),
            ("MIME type", with(mimeType: .some(changing ? "video/mp4" : nil))),
        ]
    }

    private func pair(_ left: ExactDuplicateFingerprint, _ right: ExactDuplicateFingerprint) -> [ExactDuplicateGroup] {
        ExactDuplicateGroup(contentHash: "h", hashKeyEpoch: "e", members: [first, second])
            .split(by: [first: left, second: right])
    }

    func testCopiesWithEqualMetadataStayOneGroup() {
        XCTAssertEqual(pair(complete, complete).map(\.members), [[first, second]])
        XCTAssertEqual(
            pair(ExactDuplicateFingerprint(), ExactDuplicateFingerprint()).map(\.members), [[first, second]],
            "two uploads without metadata lose nothing to each other")
    }

    func testEveryShownFieldSeparatesCopies() {
        for (field, variant) in variants(changing: true) {
            XCTAssertNotEqual(variant, complete, field)
            XCTAssertEqual(pair(complete, variant), [], "another \(field) is no duplicate")
        }
    }

    func testAMissingValueNeverMatchesAPresentOne() {
        for (field, variant) in variants(changing: false) {
            XCTAssertEqual(pair(complete, variant), [], "a copy without a \(field) is no duplicate")
        }
        XCTAssertEqual(pair(complete, ExactDuplicateFingerprint()), [], "a copy without any metadata")
    }

    func testTheMetadataOfTheInfoPanelMakeTheFingerprintAndTheFileNameDoesNot() {
        let shown = PhotoMetadata(
            filename: "IMG_0001.HEIC", mimeType: "image/heic", fileSize: 10, pixelWidth: 4000, pixelHeight: 3000,
            device: "Test Camera", durationSeconds: nil, modificationTime: Date(timeIntervalSince1970: 5),
            latitude: 10.5, longitude: -20.25)
        var renamed = shown
        renamed.filename = "Copy.HEIC"
        renamed.modificationTime = Date(timeIntervalSince1970: 6)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            ExactDuplicateFingerprint(captureTime: date, metadata: shown),
            ExactDuplicateFingerprint(
                captureTime: date, latitude: 10.5, longitude: -20.25, device: "Test Camera", pixelWidth: 4000,
                pixelHeight: 3000, mimeType: "image/heic"))
        XCTAssertEqual(
            ExactDuplicateFingerprint(captureTime: date, metadata: renamed),
            ExactDuplicateFingerprint(captureTime: date, metadata: shown))
        var located = shown
        located.latitude = nil
        XCTAssertNotEqual(
            ExactDuplicateFingerprint(captureTime: date, metadata: located),
            ExactDuplicateFingerprint(captureTime: date, metadata: shown))
        var otherCamera = shown
        otherCamera.device = "Other Camera"
        XCTAssertNotEqual(
            ExactDuplicateFingerprint(captureTime: date, metadata: otherCamera),
            ExactDuplicateFingerprint(captureTime: date, metadata: shown))
    }

    func testASplitKeepsTheIDForThePartWithThePrimaryAndGivesTheOthersTheirOwn() {
        let fourth = PhotoUID(volumeID: "v", nodeID: "fourth")
        let group = ExactDuplicateGroup(contentHash: "h", hashKeyEpoch: "e", members: [first, second, third, fourth])
        let other = ExactDuplicateFingerprint(captureTime: Date(timeIntervalSince1970: 1))
        let fingerprints = [first: complete, second: complete, third: other, fourth: other]

        let parts = group.split(by: fingerprints, keepingIDWith: third)

        XCTAssertEqual(parts.map(\.members), [[first, second], [third, fourth]])
        XCTAssertEqual(parts.map(\.fingerprint), [complete, other])
        XCTAssertEqual(parts[1].id, "h", "the part with the primary keeps the ID")
        XCTAssertNotEqual(parts[0].id, "h")
        XCTAssertEqual(parts[0].contentHash, "h")
        XCTAssertEqual(
            group.split(by: fingerprints, keepingIDWith: third)[0].id, parts[0].id, "the same metadata give the same ID"
        )
        XCTAssertEqual(group.split(by: fingerprints).map(\.id).first, "h", "without a primary the first part keeps it")
    }

    func testASecondSplitNeverGivesTwoPartsTheSameID() {
        let fourth = PhotoUID(volumeID: "v", nodeID: "fourth")
        let other = ExactDuplicateFingerprint(captureTime: Date(timeIntervalSince1970: 1))
        // A part that an earlier split named after its metadata `other`; now its checked copy has other metadata.
        let part = ExactDuplicateGroup(
            contentHash: "h", hashKeyEpoch: "e", members: [first, second, third, fourth], fingerprint: other,
            id: "h/\(other.key)")
        let fingerprints = [first: complete, second: other, third: other, fourth: complete]

        let parts = part.split(by: fingerprints, keepingIDWith: fourth)

        XCTAssertEqual(parts.map(\.members), [[first, fourth], [second, third]])
        XCTAssertEqual(parts[0].id, part.id, "the part with the checked copy keeps the ID")
        XCTAssertEqual(Set(parts.map(\.id)).count, 2, "the other part gets an ID of its own")

        // The screen already shows a group under the ID that the metadata `complete` would give.
        let shown: Set<String> = ["h/\(complete.key)"]
        let both = ExactDuplicateGroup(contentHash: "h", hashKeyEpoch: "e", members: [first, second, third, fourth])
            .split(by: fingerprints, keepingIDWith: second, avoiding: shown)
        XCTAssertEqual(both.map(\.members), [[first, fourth], [second, third]])
        XCTAssertEqual(both[1].id, "h")
        XCTAssertFalse(shown.contains(both[0].id), "a part never takes an ID that the screen shows")
        XCTAssertNotEqual(both[0].id, "h")
    }

    func testANodeWithoutPhotoMetadataMatchesOnlyItself() {
        XCTAssertEqual(ExactDuplicateFingerprint.matchingOnly(first), .matchingOnly(first))
        XCTAssertNotEqual(ExactDuplicateFingerprint.matchingOnly(first), .matchingOnly(second))
        XCTAssertNotEqual(ExactDuplicateFingerprint.matchingOnly(first), ExactDuplicateFingerprint())
        let group = ExactDuplicateGroup(contentHash: "h", hashKeyEpoch: "e", members: [first, second])
        XCTAssertEqual(group.split(by: [first: .matchingOnly(first), second: .matchingOnly(second)]), [])
    }

    func testAMemberWithoutAFingerprintIsInNoGroup() {
        let group = ExactDuplicateGroup(contentHash: "h", hashKeyEpoch: "e", members: [first, second, third])

        XCTAssertEqual(group.split(by: [first: complete, third: complete]).map(\.members), [[first, third]])
        XCTAssertEqual(group.split(by: [first: complete]), [])
    }
}
