import Foundation
import XCTest

@testable import UploadCore

/// Both resource kinds materialize the same way: no materializer returns the descriptor, a plain
/// materializer runs without progress, and a progress materializer wins and receives the handler.
final class BackupResourceMaterializationTests: XCTestCase {
    private let source = UploadSourceIdentity(kind: .fileURL, identifier: "/tmp/materialization.jpg")
    private let modified = Date(timeIntervalSince1970: 1_700_000_000)

    private func descriptor(_ filename: String) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: source,
            fileURL: URL(fileURLWithPath: "/tmp/\(filename)"),
            filename: filename,
            fileSize: 3,
            modificationDate: modified
        )
    }

    private func resolved(
        materialize: (@Sendable () async throws -> UploadResourceDescriptor)? = nil,
        materializeWithProgress: (
            @Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor
        )? = nil
    ) -> BackupResolvedResource {
        let snapshot = UploadBackupAssetSnapshot(
            source: source, revision: UploadBackupRevision(date: modified), editRevision: .unavailable,
            resourceCount: 1)
        return BackupResolvedResource(
            candidate: UploadBackupAssetCandidate(snapshot: snapshot, originalFilename: "identity.jpg", byteCount: 3),
            descriptor: descriptor("identity.jpg"),
            mediaType: "image/jpeg",
            captureDate: modified,
            materialize: materialize,
            materializeWithProgress: materializeWithProgress
        )
    }

    private func secondary(
        materialize: (@Sendable () async throws -> UploadResourceDescriptor)? = nil,
        materializeWithProgress: (
            @Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor
        )? = nil
    ) -> BackupSecondaryResource {
        BackupSecondaryResource(
            descriptor: descriptor("identity.jpg"),
            mediaType: "image/jpeg",
            materialize: materialize,
            materializeWithProgress: materializeWithProgress
        )
    }

    func testResourceWithoutMaterializerReturnsItsDescriptor() async throws {
        let primary = resolved()
        XCTAssertFalse(primary.hasDeferredMaterialization)
        let primaryResult = try await primary.materializedDescriptor()
        XCTAssertEqual(primaryResult.filename, primary.descriptor.filename)

        let paired = secondary()
        XCTAssertFalse(paired.hasDeferredMaterialization)
        let pairedResult = try await paired.materializedDescriptor()
        XCTAssertEqual(pairedResult.filename, "identity.jpg")
    }

    func testPlainMaterializerRunsWithoutProgress() async throws {
        let exported = descriptor("exported.jpg")
        let progress = ProgressRecorder()

        let primary = resolved(materialize: { exported })
        XCTAssertTrue(primary.hasDeferredMaterialization)
        let primaryResult = try await primary.materializedDescriptor(onPreparationProgress: progress.record)
        XCTAssertEqual(primaryResult.filename, "exported.jpg")

        let paired = secondary(materialize: { exported })
        XCTAssertTrue(paired.hasDeferredMaterialization)
        let pairedResult = try await paired.materializedDescriptor(onPreparationProgress: progress.record)
        XCTAssertEqual(pairedResult.filename, "exported.jpg")

        XCTAssertEqual(progress.fractions, [])
    }

    func testProgressMaterializerWinsAndReceivesTheHandler() async throws {
        let exported = descriptor("progress.jpg")
        let ignored = descriptor("ignored.jpg")
        let materializeWithProgress:
            @Sendable (BackupResourcePreparationReporter) async throws -> UploadResourceDescriptor = { reporter in
                reporter(.init(phase: .materializing, fraction: 0.5))
                return exported
            }
        let progress = ProgressRecorder()

        let primary = resolved(materialize: { ignored }, materializeWithProgress: materializeWithProgress)
        XCTAssertTrue(primary.hasDeferredMaterialization)
        let primaryResult = try await primary.materializedDescriptor(onPreparationProgress: progress.record)
        XCTAssertEqual(primaryResult.filename, "progress.jpg")

        let paired = secondary(materialize: { ignored }, materializeWithProgress: materializeWithProgress)
        XCTAssertTrue(paired.hasDeferredMaterialization)
        let pairedResult = try await paired.materializedDescriptor(onPreparationProgress: progress.record)
        XCTAssertEqual(pairedResult.filename, "progress.jpg")

        XCTAssertEqual(progress.fractions, [0.5, 0.5])
    }

    func testMaterializerErrorPropagates() async {
        struct ExportFailed: Error {}
        do {
            _ = try await resolved(materialize: { throw ExportFailed() }).materializedDescriptor()
            XCTFail("expected the primary materializer error")
        } catch {
            XCTAssertTrue(error is ExportFailed)
        }
        do {
            _ = try await secondary(materialize: { throw ExportFailed() }).materializedDescriptor()
            XCTFail("expected the secondary materializer error")
        } catch {
            XCTAssertTrue(error is ExportFailed)
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    var fractions: [Double] { lock.withLock { values } }

    var record: BackupResourcePreparationHandler {
        { [self] progress in lock.withLock { values.append(progress.fraction) } }
    }
}
