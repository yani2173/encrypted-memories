import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class UploadRemoteDeletionLookupTests: XCTestCase {
    func testMetadataAbsenceStaysUnknownWithoutAnAllStateContentHashQuery() async throws {
        let checker = DeletionEvidenceChecker()
        let absent = try await UploadRemoteDeletionLookup.states(for: ["link"], checker: checker)
        XCTAssertTrue(absent.isEmpty, "G1 requires an all-state ContentHash query, which is not available")
        XCTAssertEqual(checker.duplicateRequests, 0)
    }

    func testExplicitTrashWinsWithoutADuplicateQuery() async throws {
        let checker = DeletionEvidenceChecker()
        checker.metadata = .init(states: ["link": 2], complete: true)
        let states = try await UploadRemoteDeletionLookup.states(for: ["link"], checker: checker)
        XCTAssertEqual(states, ["link": .trashed])
        XCTAssertEqual(checker.duplicateRequests, 0)
    }

    func testFailedOrPartialMetadataStaysUnknownEvenWithATrashRow() async throws {
        for fails in [false, true] {
            let checker = DeletionEvidenceChecker()
            checker.failMetadata = fails
            checker.metadata = .init(states: ["link": 2], complete: false)
            let states = try await UploadRemoteDeletionLookup.states(for: ["link"], checker: checker)
            XCTAssertTrue(states.isEmpty)
        }
    }

    func testTransportAndTypedCancellationAreRethrownWithoutTaskCancellation() async throws {
        let errors: [any Error] = [
            URLError(.cancelled), UploadError.cancelled,
            UploadError.transport(code: URLError.cancelled.rawValue, message: "cancelled"),
        ]
        for error in errors {
            let checker = DeletionEvidenceChecker()
            checker.metadataError = error
            do {
                _ = try await UploadRemoteDeletionLookup.states(for: ["link"], checker: checker)
                XCTFail("cancellation must not become an optional metadata miss")
            } catch {
                XCTAssertFalse(Task.isCancelled, "the error itself must propagate")
            }
        }
    }

    func testOtherExplicitStatesStayUnknown() async throws {
        for state in [0, 1, 3, 4] {
            let checker = DeletionEvidenceChecker()
            checker.metadata = .init(states: ["link": state], complete: true)
            let states = try await UploadRemoteDeletionLookup.states(for: ["link"], checker: checker)
            XCTAssertTrue(states.isEmpty)
            XCTAssertEqual(checker.duplicateRequests, 0)
        }
    }

    func testBatches150AndEmptyInputMakesNoRequest() async throws {
        let checker = DeletionEvidenceChecker()
        let links = (0..<301).map { String(format: "%03d", $0) }
        checker.metadata = .init(
            states: Dictionary(uniqueKeysWithValues: links.prefix(151).map { ($0, 2) }), complete: true)
        let states = try await UploadRemoteDeletionLookup.states(for: links, checker: checker)
        XCTAssertEqual(states.count, 151)
        XCTAssertEqual(checker.metadataRequests.map(\.count), [150, 150, 1])
        XCTAssertEqual(checker.duplicateRequests, 0)
        let emptyChecker = DeletionEvidenceChecker()
        _ = try await UploadRemoteDeletionLookup.states(for: [], checker: emptyChecker)
        XCTAssertTrue(emptyChecker.metadataRequests.isEmpty)
    }
}

private final class DeletionEvidenceChecker: UploadDuplicateChecking, @unchecked Sendable {
    var metadata = UploadLinkStateSnapshot(states: [:], complete: true)
    var metadataError: (any Error)?
    var failMetadata = false
    var metadataRequests: [[String]] = []
    var duplicateRequests = 0

    func linkStateSnapshot(of linkIDs: [String]) async throws -> UploadLinkStateSnapshot {
        metadataRequests.append(linkIDs)
        if let metadataError { throw metadataError }
        if failMetadata { throw UploadError.backend("metadata unavailable") }
        return .init(states: metadata.states.filter { linkIDs.contains($0.key) }, complete: metadata.complete)
    }
    func nameHash(forCorrectedName name: String) async throws -> String { name }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { sha1Hex }
    func hashKeyEpoch() async throws -> String { "epoch" }
    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        duplicateRequests += 1
        return []
    }
    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? {
        duplicateRequests += 1
        return nil
    }
    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> { [] }
    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] { [:] }
}
