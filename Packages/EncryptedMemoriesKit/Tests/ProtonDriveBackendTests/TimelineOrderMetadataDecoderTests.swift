import Foundation
import PhotosCore
import ProtonDriveSDK
import Testing

@testable import ProtonDriveBackend

@Suite("Timeline order metadata")
struct TimelineOrderMetadataDecoderTests {
    @Test func fractionalCaptureTimeAndStableIdentityTravelTogether() {
        let decoder = TimelineOrderMetadataDecoder()
        let data = Data(
            #"{"Camera":{"CaptureTime":"2023-11-14T22:13:20.125Z"},"iOS.photos":{"ICloudID":"source-photo"}}"#.utf8)
        let order = decoder.decode(data)
        #expect(order.exactCaptureTime == Date(timeIntervalSince1970: 1_700_000_000.125))
        #expect(order.stableIdentity == "source-photo")
    }

    @Test func optionalAndUnsupportedSectionsStayIndependent() {
        let decoder = TimelineOrderMetadataDecoder()
        #expect(decoder.decode(Data("unsupported".utf8)) == TimelineOrderMetadata())
        #expect(decoder.decode(Data(#"{"Camera":{"CaptureTime":123}}"#.utf8)).exactCaptureTime == nil)
        let order = decoder.decode(
            camera: Data(#"{"CaptureTime":"2023-11-14T22:13:20Z"}"#.utf8),
            source: Data("unsupported".utf8))
        #expect(order.exactCaptureTime == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(order.stableIdentity == nil)
        #expect(decoder.decode(camera: nil, source: Data(#"{"ICloudID":""}"#.utf8)).stableIdentity == nil)
    }
}
