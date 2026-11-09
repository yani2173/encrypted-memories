import PhotosCore
import XCTest

@testable import UploadCore

final class EditedPhotoRevertServiceTests: XCTestCase {
    private let mainUID = PhotoUID(volumeID: "own", nodeID: "edited")
    private let originalUID = PhotoUID(volumeID: "own", nodeID: "original")
    private var main: PhotoItem {
        PhotoItem(uid: mainUID, captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/jpeg")
    }
    private var original: PhotoItem {
        PhotoItem(uid: originalUID, captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/heic")
    }

    private func makeService(
        provider: SpyOriginals, reverter: SpyReverter = SpyReverter(), names: SpyNames = SpyNames()
    ) -> EditedPhotoRevertService {
        EditedPhotoRevertService(revert: reverter, originals: provider, names: { await names.read($0, $1) })
    }

    func testAProvenPairStartsOneRevertWithTheRestoredName() async throws {
        let reverter = SpyReverter()
        let service = makeService(provider: SpyOriginals(answer: original), reverter: reverter)

        try await service.revertToOriginal(of: main, original: original)

        let calls = await reverter.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.editedMain, mainUID)
        XCTAssertEqual(calls.first?.original, originalUID)
        XCTAssertEqual(calls.first?.restoredName, "IMG_0001 (original).heic")
    }

    func testAPairThatTheBackendDoesNotProveStartsNothing() async throws {
        let other = PhotoItem(
            uid: PhotoUID(volumeID: "own", nodeID: "other"), captureTime: .now, mediaType: "image/heic")
        for answer: PhotoItem? in [nil, other] {
            let reverter = SpyReverter()
            let names = SpyNames()
            let service = makeService(provider: SpyOriginals(answer: answer), reverter: reverter, names: names)

            do {
                try await service.revertToOriginal(of: main, original: original)
                XCTFail("an unproven pair must not revert")
            } catch let error as EditedPhotoRevertService.ServiceError {
                XCTAssertEqual(error, .originalNotProven)
            }
            let reverterCalls = await reverter.calls
            let nameReads = await names.reads
            XCTAssertTrue(reverterCalls.isEmpty)
            XCTAssertEqual(nameReads, 0, "no name is read for an unproven pair")
        }
    }

    func testALivePhotoIsNeverAskedAndNeverReverted() async throws {
        let live = PhotoItem(
            uid: mainUID, captureTime: .now, mediaType: "image/heic", isLivePhoto: true)
        let provider = SpyOriginals(answer: original)
        let reverter = SpyReverter()
        let service = makeService(provider: provider, reverter: reverter)

        do {
            try await service.revertToOriginal(of: live, original: original)
            XCTFail("a Live Photo has no revertible original")
        } catch let error as EditedPhotoRevertService.ServiceError {
            XCTAssertEqual(error, .originalNotProven)
        }
        let asked = await provider.asked
        let reverterCalls = await reverter.calls
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(reverterCalls.isEmpty)
    }

    func testASeriesIsNeverAskedAndNeverReverted() async throws {
        let series = PhotoItem(
            uid: mainUID, captureTime: .now, mediaType: "image/heic", tags: [.bursts], burstMemberIDs: ["a", "b"])
        let provider = SpyOriginals(answer: original)
        let reverter = SpyReverter()
        let service = makeService(provider: provider, reverter: reverter)

        do {
            try await service.revertToOriginal(of: series, original: original)
            XCTFail("a series has no revertible original")
        } catch let error as EditedPhotoRevertService.ServiceError {
            XCTAssertEqual(error, .originalNotProven)
        }
        let asked = await provider.asked
        let reverterCalls = await reverter.calls
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(reverterCalls.isEmpty)
    }

    func testMissingOrInvalidNamesStartNothing() async throws {
        for names in [SpyNames(answer: nil), SpyNames(answer: .init(main: "", original: "x.heic"))] {
            let reverter = SpyReverter()
            let service = makeService(provider: SpyOriginals(answer: original), reverter: reverter, names: names)

            do {
                try await service.revertToOriginal(of: main, original: original)
                XCTFail("without a name nothing may be written")
            } catch let error as EditedPhotoRevertService.ServiceError {
                XCTAssertEqual(error, .restoredNameUnavailable)
            }
            let reverterCalls = await reverter.calls
            XCTAssertTrue(reverterCalls.isEmpty)
        }
    }

    func testTheRevertErrorReachesTheCaller() async throws {
        let reverter = SpyReverter(error: EditedOriginalRevert.RevertError.blockedByForeignDraft("IMG_0001.heic"))
        let service = makeService(provider: SpyOriginals(answer: original), reverter: reverter)

        do {
            try await service.revertToOriginal(of: main, original: original)
            XCTFail("the error must reach the caller")
        } catch let error as EditedOriginalRevert.RevertError {
            XCTAssertEqual(error, .blockedByForeignDraft("IMG_0001.heic"))
        }
    }

    func testTheHiddenOriginalSourceKeepsTheMetadataOfTheSeriesMemberSource() {
        let member = SeriesMemberSource(
            filename: "IMG_0001-originalPhoto-1.heic", mediaType: "image/heic",
            captureTime: Date(timeIntervalSince1970: 10), modificationDate: Date(timeIntervalSince1970: 20),
            additionalMetadata: [PhotoUploadAdditionalMetadata(name: "Camera", utf8JsonValue: Data("{}".utf8))])
        let source = EditedOriginalSource(member)
        XCTAssertEqual(source.filename, member.filename)
        XCTAssertEqual(source.mediaType, member.mediaType)
        XCTAssertEqual(source.captureTime, member.captureTime)
        XCTAssertEqual(source.modificationDate, member.modificationDate)
        XCTAssertEqual(source.additionalMetadata, member.additionalMetadata)
    }
}

private actor SpyReverter: EditedOriginalReverting {
    struct Call: Equatable {
        let editedMain: PhotoUID
        let original: PhotoUID
        let restoredName: String
    }
    private(set) var calls: [Call] = []
    private let error: (any Error)?

    init(error: (any Error)? = nil) { self.error = error }

    func revert(
        editedMain: PhotoUID, original: PhotoUID, restoredName: String, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> PhotoUID {
        calls.append(Call(editedMain: editedMain, original: original, restoredName: restoredName))
        if let error { throw error }
        return PhotoUID(volumeID: editedMain.volumeID, nodeID: "copy")
    }
}

private actor SpyOriginals: EditedPhotoOriginalProviding {
    private(set) var asked = 0
    private let answer: PhotoItem?

    init(answer: PhotoItem?) { self.answer = answer }

    func editedOriginal(of item: PhotoItem) async throws -> PhotoItem? {
        asked += 1
        return answer
    }
}

private actor SpyNames {
    private(set) var reads = 0
    private let answer: EditedPhotoRevertNames?

    init(
        answer: EditedPhotoRevertNames? = .init(main: "IMG_0001.jpg", original: "IMG_0001-originalPhoto-1.heic")
    ) { self.answer = answer }

    func read(_ main: PhotoUID, _ original: PhotoUID) -> EditedPhotoRevertNames? {
        reads += 1
        return answer
    }
}
