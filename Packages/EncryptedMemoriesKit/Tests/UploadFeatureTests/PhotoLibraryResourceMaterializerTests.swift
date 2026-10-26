import Foundation
import Photos
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// The deferred export of a resource reads its owner again. Only the missing-owner paths run here, because a test
/// cannot create a `PHAsset`: they show which of the two lookups each role uses and which error follows.
final class PhotoLibraryResourceMaterializerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-resource-materializer-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Lookups: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func record(_ entry: String) { lock.withLock { stored.append(entry) } }
        var entries: [String] { lock.withLock { stored } }
    }

    /// Both lookups find nothing and record which one ran with which identifier.
    private func refetch(recording lookups: Lookups) -> PhotoLibraryResourceResolver.MaterializationRefetch {
        .init(
            primary: {
                lookups.record("primary:\($0)")
                return nil
            },
            secondary: {
                lookups.record("secondary:\($0)")
                return nil
            }
        )
    }

    private func materialize(
        _ kind: PhotoLibraryResourceResolver.ResourceMaterialization.Kind, ownerIdentifier: String, filename: String,
        lookups: Lookups
    ) async -> Error? {
        let tempStore = BackupTempFileStore(
            directory: directory, maximumBytes: 1 << 20, minimumFreeBytes: 0,
            availableCapacity: { _ in 1 << 40 }, now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let materializer = PhotoLibraryResourceResolver.makeMaterializer(
            .init(
                kind: kind, ownerIdentifier: ownerIdentifier, role: .originalPhoto, ordinal: 0, filename: filename,
                expectedByteCount: 10,
                source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "entry"),
                stableDate: Date(timeIntervalSince1970: 1), modifiedAtResolve: nil, resourceIndex: 0, resourceCount: 1
            ),
            refetch: refetch(recording: lookups),
            staged: .init(nil),
            tempStore: tempStore,
            tracking: .init(),
            readAdmission: {}
        )
        do {
            _ = try await materializer(BackupResourcePreparationReporter { _ in })
            return nil
        } catch {
            return error
        }
    }

    func testThePrimaryResourceReadsItsAssetWithTheDefaultLookupAndReportsAMissingFile() async {
        let lookups = Lookups()

        let error = await materialize(.primary, ownerIdentifier: "main", filename: "IMG_1.HEIC", lookups: lookups)

        XCTAssertEqual(lookups.entries, ["primary:main"])
        guard case .fileMissing("IMG_1.HEIC")? = error as? UploadError else {
            return XCTFail("expected fileMissing, got \(String(describing: error))")
        }
    }

    func testASecondaryResourceReadsItsOwnerWithTheLookupThatListsSeriesMembers() async {
        let lookups = Lookups()

        let error = await materialize(
            .secondary(isBurstMember: false), ownerIdentifier: "main", filename: "IMG_1.MOV", lookups: lookups)

        XCTAssertEqual(lookups.entries, ["secondary:main"])
        guard case .fileMissing("IMG_1.MOV")? = error as? UploadError else {
            return XCTFail("expected fileMissing, got \(String(describing: error))")
        }
    }

    func testASeriesMemberThatPhotosNoLongerListsIsReportedAsAMissingSourceNotAMissingFile() async {
        let lookups = Lookups()

        let error = await materialize(
            .secondary(isBurstMember: true), ownerIdentifier: "member", filename: "IMG_2.HEIC", lookups: lookups)

        XCTAssertEqual(lookups.entries, ["secondary:member"])
        guard case .sourceReportedMissing("IMG_2.HEIC")? = error as? UploadError else {
            return XCTFail("expected sourceReportedMissing, got \(String(describing: error))")
        }
    }
}
