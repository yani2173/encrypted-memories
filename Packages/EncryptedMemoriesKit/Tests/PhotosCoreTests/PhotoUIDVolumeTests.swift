import Testing

@testable import PhotosCore

struct PhotoUIDVolumeTests {
    @Test func anEmptyVolumeTakesTheGivenVolume() {
        #expect(
            PhotoUID(volumeID: "", nodeID: "node").inVolume("photos") == PhotoUID(volumeID: "photos", nodeID: "node"))
    }

    @Test func aNamedVolumeStays() {
        let uid = PhotoUID(volumeID: "shared", nodeID: "node")
        #expect(uid.inVolume("photos") == uid)
    }
}
