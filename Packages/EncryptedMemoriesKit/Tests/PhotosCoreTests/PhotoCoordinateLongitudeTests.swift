import Testing

@testable import PhotosCore

@Suite struct PhotoCoordinateLongitudeTests {
    @Test func longitudeInsideTheRangeStaysUnchanged() {
        #expect(PhotoCoordinate.normalizedLongitude(0) == 0)
        #expect(PhotoCoordinate.normalizedLongitude(-180) == -180)
        #expect(PhotoCoordinate.normalizedLongitude(179.5) == 179.5)
    }

    @Test func longitudeOutsideTheRangeWrapsAround() {
        #expect(PhotoCoordinate.normalizedLongitude(180) == -180)
        #expect(PhotoCoordinate.normalizedLongitude(190) == -170)
        #expect(PhotoCoordinate.normalizedLongitude(-190) == 170)
        #expect(PhotoCoordinate.normalizedLongitude(540) == -180)
        #expect(PhotoCoordinate.normalizedLongitude(-540) == -180)
    }
}
