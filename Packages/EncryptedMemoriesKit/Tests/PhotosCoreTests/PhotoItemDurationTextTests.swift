import Foundation
import PhotosCore
import Testing

/// The grid and the Duplicates screen show the length of a video with the same text.
@Suite struct PhotoItemDurationTextTests {
    private func item(_ mediaType: String, seconds: Double?) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: "node"), captureTime: Date(timeIntervalSince1970: 0),
            mediaType: mediaType, durationSeconds: seconds)
    }

    @Test func aVideoShowsItsLengthAndAPhotoShowsNone() {
        #expect(item("video/quicktime", seconds: 42).durationText == "0:42")
        #expect(item("video/mp4", seconds: 3_661).durationText == "1:01:01")
        #expect(item("video/mp4", seconds: nil).durationText == nil, "an unknown length shows nothing")
        #expect(item("image/jpeg", seconds: 42).durationText == nil)
    }

    @Test func theLengthRoundsToWholeSecondsAndLeavesOutInvalidValues() {
        #expect(PhotoItem.durationText(for: 59.6) == "1:00")
        #expect(PhotoItem.durationText(for: 0) == nil)
        #expect(PhotoItem.durationText(for: .nan) == nil)
        #expect(PhotoItem.durationText(for: .infinity) == nil)
    }
}
