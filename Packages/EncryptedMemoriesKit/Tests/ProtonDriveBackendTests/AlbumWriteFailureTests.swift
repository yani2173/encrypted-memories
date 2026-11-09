import AlbumCore
import PhotosCore
import ProtonAuth
import XCTest

@testable import ProtonDriveBackend
@testable import UploadCore

private struct FailingAlbumBackend: AlbumCatalogBackend, AlbumWriteBackend {
    let failure: any Error
    func listAlbums() async throws -> [AlbumSummary] { [] }
    func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary] { [] }
    func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {}
    func albumMemberships(for photoUIDs: [PhotoUID]) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] { [:] }
    func createAlbum(name: String) async throws -> AlbumID { "a" }
    func deleteAlbum(albumID: AlbumID) async throws {}
    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws { throw failure }
    func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws {}
    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {}
}

final class AlbumWriteFailureTests: XCTestCase {
    private func backend(throwing error: any Error) -> HTTPAlbumWriteBackend {
        HTTPAlbumWriteBackend(
            setCoverProvider: { _, _ in throw error }, createProvider: { _ in throw error },
            deleteProvider: { _ in throw error }, addProvider: { _, _ in throw error },
            removeProvider: { _, _ in throw error })
    }

    func testHTTPStatusAndTransientClassificationSurviveAlbumWrites() async {
        for status in [408, 429, 500, 503, 403, 404] {
            let original = ProtonAuthError.apiError(code: status, message: "failed")
            do {
                try await backend(throwing: original).addPhotos([PhotoUID(volumeID: "v", nodeID: "p")], to: "a")
                XCTFail("the write must fail")
            } catch let AlbumError.requestFailed(cause) {
                XCTAssertEqual(cause.kind, .http(status: status))
                XCTAssertEqual(cause.isTransient, status == 408 || status == 429 || status >= 500)
                XCTAssertNotNil(cause.underlyingError as? ProtonAuthError)
            } catch {
                XCTFail("the HTTP cause must remain typed: \(error)")
            }
        }
    }

    func testCancellationPassesTheHTTPAdapter() async {
        do {
            try await backend(throwing: CancellationError()).addPhotos([], to: "a")
            XCTFail("the write must fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testMixedAndMissingItemOutcomesNeverBecomeSuccess() {
        let photos = [
            PhotoUID(volumeID: "v", nodeID: "a"), PhotoUID(volumeID: "v", nodeID: "b"),
            PhotoUID(volumeID: "v", nodeID: "c"),
        ]
        let result = AlbumAttachResult(outcomes: ["a": .attached, "b": .failed(code: 429, message: "later")])
        do {
            try result.requireComplete(for: photos)
            XCTFail("one failure and one missing answer must stop the write")
        } catch let AlbumError.partialAddWithCauses(succeeded, total, _, failures) {
            XCTAssertEqual(succeeded, 1)
            XCTAssertEqual(total, 3)
            XCTAssertEqual(failures.map(\.linkID), ["b", "c"])
            XCTAssertEqual(failures.map(\.code), [429, nil])
        } catch {
            XCTFail("the item causes must remain available: \(error)")
        }
    }

    func testConfirmedAndAlreadyPresentItemsBothSucceed() throws {
        let photos = [PhotoUID(volumeID: "v", nodeID: "a"), PhotoUID(volumeID: "v", nodeID: "b")]
        let result = AlbumAttachResult(outcomes: ["a": .attached, "b": .alreadyMember])
        XCTAssertNoThrow(try result.requireComplete(for: photos))
    }

    func testCarryOverAdapterRetainsNetworkAndServerRetrySignals() async {
        let errors: [AlbumError] = [
            .requestFailed(AlbumWriteCause(URLError(.notConnectedToInternet))),
            .requestFailed(AlbumWriteCause(URLError(.timedOut))),
            .requestFailed(AlbumWriteCause(ProtonAuthError.apiError(code: 429, message: "later"), httpStatus: 429)),
            .requestFailed(AlbumWriteCause(ProtonAuthError.apiError(code: 503, message: "later"), httpStatus: 503)),
        ]
        for original in errors {
            let backend = FailingAlbumBackend(failure: original)
            let repo = AlbumsRepository(catalogBackend: backend, writeBackend: backend)
            let carryOver = AlbumRepositorySeriesCarryOver(repository: repo)
            do {
                try await carryOver.addPhotos([PhotoUID(volumeID: "v", nodeID: "p")], toOwnAlbum: "a")
                XCTFail("the album add must stop")
            } catch {
                if original.writeCause?.kind == .network(code: URLError.notConnectedToInternet.rawValue)
                    || original.writeCause?.kind == .network(code: URLError.timedOut.rawValue)
                {
                    XCTAssertTrue(BackupSyncRunner.isTransientNetwork(error))
                } else if case UploadError.retryableBackend(let code, _) = error {
                    XCTAssertTrue(code == 429 || code == 503)
                } else {
                    XCTFail("the runner must see a retryable service failure: \(error)")
                }
            }
        }
    }

    func testCarryOverAdapterKeepsCancellationAndUnknownFailures() async {
        let unknown = AlbumError.partialAddWithCauses(
            succeeded: 1, total: 2, message: "unknown",
            failures: [AlbumWriteItemFailure(linkID: "p", code: nil, message: "unknown")])
        let forbidden = AlbumError.requestFailed(
            AlbumWriteCause(ProtonAuthError.apiError(code: 403, message: "forbidden"), httpStatus: 403))
        for failure in [CancellationError() as any Error, unknown, forbidden] {
            let backend = FailingAlbumBackend(failure: failure)
            let carryOver = AlbumRepositorySeriesCarryOver(
                repository: AlbumsRepository(catalogBackend: backend, writeBackend: backend))
            do {
                try await carryOver.addPhotos([PhotoUID(volumeID: "v", nodeID: "p")], toOwnAlbum: "a")
                XCTFail("the add must stop")
            } catch {
                if failure is CancellationError {
                    XCTAssertTrue(error is CancellationError)
                } else {
                    XCTAssertEqual(error as? AlbumError, failure as? AlbumError)
                }
            }
        }
    }
}
