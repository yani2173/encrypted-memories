import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

@Suite("Series frames")
struct BurstFrameVerdictsTests {
    private struct ReadFailure: Error {}
    private typealias RelatedFile = BurstFrameVerdicts.RelatedFile

    /// The bursts listing lists only the main photo; the frame and the adjustment data of an edit are related files.
    private let members = ["main", "frame", "edit-data"]
    private let listed: Set<String> = ["main"]

    /// Related files whose names did not decrypt, so only their MIME types are known.
    private static func typed(_ mimeTypes: [String: String]) -> [String: RelatedFile] {
        mimeTypes.mapValues { RelatedFile(mimeType: $0, name: nil) }
    }

    @Test("the adjustment data of an edit is no frame of its series")
    func adjustmentDataIsHidden() async {
        var requested: [[String]] = []
        let result = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: BurstFrameVerdicts()) {
            requested.append($0)
            return Self.typed(["frame": "image/heic", "edit-data": "application/xml"])
        }
        #expect(result.frames == ["main", "frame"])
        #expect(requested == [["frame", "edit-data"]])
    }

    @Test("a related file of an unknown type stays a frame")
    func unknownTypeStays() async {
        let result = await BurstFrameVerdicts.frames(
            of: ["main", "frame", "untyped", "edit-data"], listed: listed, verdicts: BurstFrameVerdicts()
        ) { _ in
            Self.typed(["untyped": "", "edit-data": "application/xml"])
        }
        #expect(result.frames == ["main", "frame", "untyped"])
    }

    @Test("a related file of an undetected binary type stays a frame")
    func octetStreamStays() async {
        let result = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: BurstFrameVerdicts()) { _ in
            Self.typed(["frame": "application/octet-stream", "edit-data": "application/xml"])
        }
        #expect(result.frames == ["main", "frame"])
    }

    @Test(
        "a related file of a type that names no frame is hidden",
        arguments: [
            "application/xml", "text/xml", "application/x-plist", "application/json", "audio/mp4",
            " Application/XML; charset=utf-8",
        ])
    func nonFrameTypeIsHidden(mimeType: String) async {
        let result = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: BurstFrameVerdicts()) { _ in
            Self.typed(["frame": "image/heic", "edit-data": mimeType])
        }
        #expect(result.frames == ["main", "frame"])
    }

    @Test(
        "the adjustment data of an edit is hidden by its name although the backup uploads it as a binary",
        arguments: ["IMG_0001.AAE", "IMG_0001.aae", "Info.plist", "IMG_0001.xmp", "meta.json", "meta.XML"])
    func nonFrameNameIsHidden(name: String) async {
        let result = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: BurstFrameVerdicts()) { _ in
            [
                "frame": RelatedFile(mimeType: "application/octet-stream", name: "IMG_0002.HEIC"),
                "edit-data": RelatedFile(mimeType: "application/octet-stream", name: name),
            ]
        }
        #expect(result.frames == ["main", "frame"])
    }

    @Test("a related file with an image or video name stays a frame, whatever its type")
    func imageNameStays() async {
        let result = await BurstFrameVerdicts.frames(
            of: ["main", "frame", "clip", "edit-data"], listed: listed, verdicts: BurstFrameVerdicts()
        ) { _ in
            [
                "frame": RelatedFile(mimeType: "application/octet-stream", name: "IMG_0001.HEIC"),
                "clip": RelatedFile(mimeType: "application/xml", name: "IMG_0001.MOV"),
                "edit-data": RelatedFile(mimeType: "application/octet-stream", name: "IMG_0001.AAE"),
            ]
        }
        #expect(result.frames == ["main", "frame", "clip"])
    }

    @Test("a related file whose name does not decrypt or has no extension stays a frame")
    func unknownNameStays() async {
        let result = await BurstFrameVerdicts.frames(
            of: ["main", "frame", "no-extension", "edit-data"], listed: listed, verdicts: BurstFrameVerdicts()
        ) { _ in
            [
                "frame": RelatedFile(mimeType: "application/octet-stream", name: nil),
                "no-extension": RelatedFile(mimeType: "application/octet-stream", name: "IMG_0001"),
                "edit-data": RelatedFile(mimeType: "application/octet-stream", name: "IMG_0001.AAE"),
            ]
        }
        #expect(result.frames == ["main", "frame", "no-extension"])
    }

    @Test("a failed type read keeps every member and reads again on the next open")
    func failedReadKeepsEveryMember() async {
        let failed = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: BurstFrameVerdicts()) { _ in
            throw ReadFailure()
        }
        #expect(failed.frames == members)

        var requested: [[String]] = []
        let retried = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: failed.verdicts) {
            requested.append($0)
            return Self.typed(["frame": "image/heic", "edit-data": "application/xml"])
        }
        #expect(requested == [["frame", "edit-data"]])
        #expect(retried.frames == ["main", "frame"])
    }

    @Test("a second open of the series reads no metadata")
    func secondOpenReadsNothing() async {
        var requested: [[String]] = []
        let first = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: BurstFrameVerdicts()) {
            requested.append($0)
            return Self.typed(["edit-data": "application/xml"])
        }
        var cached = BurstFrameVerdicts()
        cached.merge(first.verdicts)

        let second = await BurstFrameVerdicts.frames(of: members, listed: listed, verdicts: cached) {
            requested.append($0)
            return [:]
        }
        #expect(requested == [["frame", "edit-data"]])
        #expect(second.frames == ["main", "frame"])
    }

    /// The bursts listing names the photo and the adjustment data of its edit.
    private static let photoWithEditData = PhotosListEntry(
        linkID: "main", captureTime: 700, tags: [PhotosCore.PhotoTag.bursts.rawValue],
        relatedPhotos: [.init(linkID: "edit-data")])

    @Test("a photo whose only other related file is no frame answers as itself")
    func loneFrameAnswersWithThePhoto() async {
        let checked = await BurstFrameVerdicts.frames(
            of: ["main", "edit-data"], listed: ["main"], verdicts: BurstFrameVerdicts()
        ) { _ in Self.typed(["edit-data": "application/xml"]) }
        #expect(checked.frames == ["main"])

        let answer = DriveSDKBridge.seriesAnswer(
            frames: checked.frames, containing: "main", entriesByID: ["main": Self.photoWithEditData],
            burstEntries: [Self.photoWithEditData], volumeID: "v")
        #expect(answer.map(\.uid) == [PhotoUID(volumeID: "v", nodeID: "main")])
        #expect(answer.first?.burstMemberIDs == ["main"])
    }

    @Test("no answer when no frame of the photo is left")
    func noFrameOfThePhotoAnswersNothing() {
        let answer = DriveSDKBridge.seriesAnswer(
            frames: [], containing: "main", entriesByID: ["main": Self.photoWithEditData],
            burstEntries: [Self.photoWithEditData], volumeID: "v")
        #expect(answer.isEmpty)
    }
}
