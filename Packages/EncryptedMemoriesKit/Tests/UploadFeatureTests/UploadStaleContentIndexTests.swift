import CryptoKit
import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// The content index can serve a row for a short time after another client trashed or deleted its photo. A photo is
/// counted as backed up by such a row only when a state read in the same check says the copy is active (#553).
final class UploadStaleContentIndexTests: XCTestCase {
    private let bytes = Data(repeating: 1, count: 20)

    private func descriptor(_ name: String = "current.heic") -> UploadResourceDescriptor {
        let url = URL(fileURLWithPath: "/fixture/\(name)")
        return UploadResourceDescriptor(
            source: .file(url), fileURL: url, filename: name, fileSize: 20,
            modificationDate: Date(timeIntervalSince1970: 1_720_000_000), precomputedSHA1Digest: bytes)
    }

    private func pipeline(
        _ server: EditScenarioServer, store: FakeIdentityStore = FakeIdentityStore()
    ) -> UploadDedupePipeline {
        UploadDedupePipeline(store: store, checker: server, currentClientUID: "this-uploader")
    }

    private func row(of uid: PhotoUID, on server: EditScenarioServer) throws -> RemotePhotoDuplicate {
        try XCTUnwrap(server.links.first { $0.uid == uid }).duplicate
    }

    private func burstFrame(under main: PhotoUID) -> UploadResourceDescriptor {
        let url = URL(fileURLWithPath: "/fixture/member.heic")
        return UploadResourceDescriptor(
            source: .file(url, resource: .burstMember(ordinal: 1)), fileURL: url, filename: "member.heic",
            fileSize: 20, modificationDate: Date(timeIntervalSince1970: 1_720_000_000),
            precomputedSHA1Digest: bytes, mainRemoteLinkID: main.nodeID)
    }

    /// What a current index decides: it has no row for a photo that left the library.
    private func freshDecision(
        removal: (EditScenarioServer, PhotoUID) -> Void
    ) async throws -> UploadDuplicateDecision {
        let server = EditScenarioServer()
        let copy = server.seedLink(digest: bytes)
        removal(server, copy)
        server.setContentLookupRows([])
        return try await pipeline(server).resolve(descriptor()).decision
    }

    func testAStaleRowOfATrashedCopyDecidesLikeACurrentIndex() async throws {
        try await assertStaleRowDecidesLikeACurrentIndex { server, copy in server.personTrash(copy) }
    }

    func testAStaleRowOfADeletedCopyDecidesLikeACurrentIndex() async throws {
        try await assertStaleRowDecidesLikeACurrentIndex { server, copy in
            server.personTrash(copy)
            server.personEmptyTrash()
        }
    }

    private func assertStaleRowDecidesLikeACurrentIndex(
        removal: @escaping (EditScenarioServer, PhotoUID) -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let server = EditScenarioServer()
        let store = FakeIdentityStore()
        let copy = server.seedLink(digest: bytes)
        let staleRow = try row(of: copy, on: server)
        removal(server, copy)
        server.setContentLookupRows([staleRow])

        let result = try await pipeline(server, store: store).resolve(descriptor())

        XCTAssertEqual(staleRow.linkState, .active, file: file, line: line)
        XCTAssertNotEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID), file: file, line: line)
        let fresh = try await freshDecision(removal: removal)
        XCTAssertEqual(result.decision, fresh, file: file, line: line)
        XCTAssertNotEqual(store.record(for: descriptor().source)?.remoteLinkID, copy.nodeID, file: file, line: line)
    }

    /// An earlier check of the same view read the copy as active; the person trashed it since.
    func testAStateThatAnEarlierCheckReadIsReadAgainBeforeTheCopyCounts() async throws {
        let server = EditScenarioServer()
        let store = FakeIdentityStore()
        let checks = pipeline(server, store: store)
        let copy = server.seedLink(digest: bytes)
        let earlier = try await checks.resolve(descriptor("earlier.heic"))
        XCTAssertEqual(earlier.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID))
        // The later check must reach the content index, not the record of the earlier one.
        XCTAssertTrue(store.forgetRemoteLinks([copy.nodeID], of: descriptor("earlier.heic").source))
        let staleRow = try row(of: copy, on: server)
        server.personTrash(copy)
        server.setContentLookupRows([staleRow])

        let later = try await checks.resolve(descriptor("later.heic"))

        XCTAssertNotEqual(later.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID))
    }

    func testACopyThatLeftTheLibraryDoesNotHideTheNextActiveCopy() async throws {
        let server = EditScenarioServer()
        let trashed = server.seedLink(digest: bytes)
        let active = server.seedLink(digest: bytes)
        let rows = [try row(of: trashed, on: server), try row(of: active, on: server)]
        server.personTrash(trashed)
        server.setContentLookupRows(rows)

        let result = try await pipeline(server).resolve(descriptor())

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: active.nodeID))
    }

    /// The normal case reads the state of the copy once, in the same read that already finds related files.
    func testAnActiveCopyCountsWithOneStateRead() async throws {
        let server = EditScenarioServer()
        let copy = server.seedLink(digest: bytes)

        let result = try await pipeline(server).resolve(descriptor())

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID))
        XCTAssertEqual(server.readCounts.visibility, 1)
    }

    func testAFailedStateReadDoesNotSettleThePhoto() async throws {
        let server = EditScenarioServer()
        let store = FakeIdentityStore()
        let copy = server.seedLink(digest: bytes)
        server.setVisibilityError(URLError(.timedOut), whenAskingFor: copy.nodeID)

        do {
            let result = try await pipeline(server, store: store).resolve(descriptor())
            XCTFail("A failed state read must not settle the photo: \(result.decision)")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertNil(store.record(for: descriptor().source)?.remoteLinkID)
        XCTAssertNil(store.record(for: descriptor().source)?.outcome)
    }

    func testAnEarlierActiveCopyIsReadAgainAndStillCountsInTheSameGeneration() async throws {
        let server = EditScenarioServer()
        let store = FakeIdentityStore()
        let checks = pipeline(server, store: store)
        let copy = server.seedLink(digest: bytes)
        let earlier = try await checks.resolve(descriptor("earlier.heic"))
        XCTAssertEqual(earlier.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID))
        XCTAssertTrue(store.forgetRemoteLinks([copy.nodeID], of: descriptor("earlier.heic").source))
        let before = server.readCounts.visibility

        let later = try await checks.resolve(descriptor("later.heic"))

        XCTAssertEqual(later.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID))
        XCTAssertEqual(server.readCounts.visibility, before + 1)
        XCTAssertEqual(store.record(for: descriptor("later.heic").source)?.remoteLinkID, copy.nodeID)
    }

    func testAFailedPrimeCannotMakeARootAdoptAnotherPhotosActiveFrame() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let digest = Data(Insecure.SHA1.hash(data: asset.current))
        let other = harness.server.seedLink(digest: Data(repeating: 2, count: 20))
        let frame = harness.server.seedLink(digest: digest, main: other)
        harness.server.setContentLookupRows([try row(of: frame, on: harness.server)])
        let entry = try await harness.enqueue()
        let current = UploadResourceDescriptor(
            source: asset.source, fileURL: URL(fileURLWithPath: "/fixture/current.heic"),
            filename: "current.heic", fileSize: Int64(asset.current.count),
            modificationDate: asset.modificationDate, precomputedSHA1Digest: digest)
        let checks = UploadDedupePipeline(
            store: harness.identities, checker: harness.server, currentClientUID: "this-uploader")
        harness.server.setVisibilityError(URLError(.timedOut), whenAskingFor: frame.nodeID)
        await checks.prime([descriptor(frame.nodeID)])
        harness.server.setVisibilityError(nil, whenAskingFor: frame.nodeID)
        let before = harness.server.readCounts.visibility

        let result = try await checks.resolve(current)

        XCTAssertEqual(result.decision, .upload)
        XCTAssertEqual(harness.server.readCounts.visibility, before + 1)
        XCTAssertNil(harness.identities.record(for: current.source)?.remoteLinkID)
        XCTAssertNil(harness.identities.record(for: current.source)?.outcome)
        await checks.uploadDidFail(current)
        await harness.pass()
        XCTAssertEqual(harness.state(of: entry), .completed)
        XCTAssertEqual(harness.server.uploadRequestCount, 1)
        XCTAssertNotEqual(harness.identities.record(for: current.source)?.remoteLinkID, frame.nodeID)
    }

    func testCancellationAtTheStateReadStopsBeforeTheNextCandidateRead() async throws {
        let server = EditScenarioServer()
        let store = FakeIdentityStore()
        let checks = pipeline(server, store: store)
        let first = server.seedLink(digest: bytes)
        let second = server.seedLink(digest: bytes)
        server.setContentLookupRows([try row(of: first, on: server), try row(of: second, on: server)])
        server.setVisibilityError(URLError(.timedOut), whenAskingFor: first.nodeID)
        await checks.prime([descriptor(first.nodeID), descriptor(second.nodeID)])
        server.setVisibilityError(nil, whenAskingFor: first.nodeID)
        server.setVisibility(.init(isActive: false, mainPhotoLinkID: nil), for: first.nodeID)
        let before = server.readCounts.visibility
        server.cancelCallerAtVisibility(true)

        let current = descriptor()
        let task = Task { try await checks.resolve(current) }
        do {
            _ = try await task.value
            XCTFail("Cancellation at the state read must propagate")
        } catch {
            XCTAssertTrue(UploadError.isCancellation(error))
        }
        server.cancelCallerAtVisibility(false)

        XCTAssertEqual(server.readCounts.visibility, before + 1, "Stop must prevent the next candidate read")
        XCTAssertNil(store.record(for: descriptor().source)?.remoteLinkID)
        XCTAssertNil(store.record(for: descriptor().source)?.outcome)
    }

    // MARK: - Backup passes

    /// A network or busy-service failure of the state read keeps the photo waiting without an attempt; the next pass
    /// settles it.
    func testATransientStateReadFailureWaitsAndTheNextPassBacksThePhotoUp() async throws {
        for failure in [URLError(.timedOut), UploadError.retryableBackend(code: 503, message: "busy")] as [any Error] {
            let harness = try EditScenarioHarness()
            defer { try? harness.cleanup() }
            let asset = try XCTUnwrap(harness.library.snapshot.first)
            let copy = harness.server.seedLink(digest: Data(Insecure.SHA1.hash(data: asset.current)))
            harness.server.setVisibilityError(failure, whenAskingFor: copy.nodeID)
            let entry = try await harness.enqueue()

            await harness.pass()

            let waiting = try harness.queue.entry(for: entry.source, revision: entry.revision)
            XCTAssertEqual(waiting?.state, .discovered, "\(failure)")
            XCTAssertEqual(waiting?.attempts, entry.attempts, "\(failure)")
            XCTAssertNil(harness.identities.record(for: entry.source)?.outcome, "\(failure)")
            XCTAssertEqual(harness.server.uploadRequestCount, 0, "\(failure)")

            harness.server.setVisibilityError(nil, whenAskingFor: copy.nodeID)
            _ = await harness.makeRetryableWorkEligibleNow()
            await harness.pass()

            XCTAssertEqual(harness.state(of: entry), .alreadyBackedUp, "\(failure)")
            XCTAssertEqual(harness.identities.record(for: entry.source)?.remoteLinkID, copy.nodeID, "\(failure)")
            XCTAssertEqual(harness.server.uploadRequestCount, 0, "\(failure)")
        }
    }

    /// Any other failure of the state read counts against the retry budget like any other check failure, and the
    /// photo needs attention when the budget is used up. Nothing is uploaded and nothing counts as backed up.
    func testAnotherStateReadFailureUsesTheRetryBudget() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let copy = harness.server.seedLink(digest: Data(Insecure.SHA1.hash(data: asset.current)))
        harness.server.setVisibilityError(UploadError.backend("HTTP 400"), whenAskingFor: copy.nodeID)
        let entry = try await harness.enqueue()

        for _ in 0..<6 where harness.state(of: entry) != .failed {
            await harness.pass()
            // The harness caps its retry delay at eight seconds. Advance beyond every retry deadline.
            harness.clock.advance(by: 9)
        }

        XCTAssertEqual(harness.state(of: entry), .failed)
        XCTAssertEqual(try harness.queue.entry(for: entry.source, revision: entry.revision)?.attempts, 4)
        XCTAssertNil(harness.identities.record(for: entry.source)?.outcome)
        XCTAssertEqual(harness.server.uploadRequestCount, 0)
    }

    func testAStaleBurstMemberRowNeedsAnActiveCopyInThisCheck() async throws {
        let server = EditScenarioServer()
        let store = FakeIdentityStore()
        let main = server.seedLink(digest: Data(repeating: 2, count: 20))
        let member = server.seedLink(digest: bytes, main: main)
        server.setContentLookupRows([try row(of: member, on: server)])
        server.setVisibility(.init(isActive: false, mainPhotoLinkID: main.nodeID), for: member.nodeID)
        let frame = burstFrame(under: main)

        let result = try await pipeline(server, store: store).resolve(frame)

        XCTAssertEqual(result.decision, .upload)
        XCTAssertNil(store.record(for: frame.source)?.outcome)
    }

    func testABurstMemberRowWithoutAStateInThisCheckIsNoActiveCopy() async throws {
        let server = EditScenarioServer()
        let store = FakeIdentityStore()
        let main = server.seedLink(digest: Data(repeating: 2, count: 20))
        let member = server.seedLink(digest: bytes, main: main)
        server.setContentLookupRows([try row(of: member, on: server)])
        server.omitVisibility(of: [member.nodeID])
        let frame = burstFrame(under: main)

        let result = try await pipeline(server, store: store).resolve(frame)

        XCTAssertEqual(result.decision, .upload)
        XCTAssertNil(store.record(for: frame.source)?.outcome)
    }

    func testAFailedStateReadOfABurstMemberRowDoesNotSettleTheFrame() async throws {
        let server = EditScenarioServer()
        let store = FakeIdentityStore()
        let main = server.seedLink(digest: Data(repeating: 2, count: 20))
        let member = server.seedLink(digest: bytes, main: main)
        server.setContentLookupRows([try row(of: member, on: server)])
        server.setVisibilityError(URLError(.timedOut), whenAskingFor: member.nodeID)
        let frame = burstFrame(under: main)

        do {
            let result = try await pipeline(server, store: store).resolve(frame)
            XCTFail("A failed state read must not settle the frame: \(result.decision)")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertNil(store.record(for: frame.source)?.remoteLinkID)
        XCTAssertNil(store.record(for: frame.source)?.outcome)
    }
}
