import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// The record of another photo with the same bytes, and a name row from `prime`, can outlive their copy like an index
/// row (#553): another device can trash the copy. A photo counts as backed up by them only when a current state read
/// says that the copy is an active main photo (#879). A record that says so is never checked again.
final class UploadStaleAdoptionTests: XCTestCase {
    private let bytes = Data(repeating: 1, count: 20)

    private func descriptor(_ name: String, bytes: Data? = nil) -> UploadResourceDescriptor {
        let url = URL(fileURLWithPath: "/fixture/\(name)")
        return UploadResourceDescriptor(
            source: .file(url), fileURL: url, filename: name, fileSize: 20,
            modificationDate: Date(timeIntervalSince1970: 1_720_000_000), precomputedSHA1Digest: bytes ?? self.bytes)
    }

    private func pipeline(
        _ server: EditScenarioServer, store: FakeIdentityStore = FakeIdentityStore(), clock: StepClock = StepClock()
    ) -> UploadDedupePipeline {
        UploadDedupePipeline(store: store, checker: server, currentClientUID: "this-uploader", now: { clock.now })
    }

    // MARK: - The record of another photo

    func testTheRecordOfAnotherPhotoWhoseCopyWasTrashedIsNoBackup() async throws {
        try await assertAnotherPhotosRecordIsNoBackup { server, copy in server.personTrash(copy) }
    }

    func testTheRecordOfAnotherPhotoWhoseCopyWasDeletedIsNoBackup() async throws {
        try await assertAnotherPhotosRecordIsNoBackup { server, copy in
            server.personTrash(copy)
            server.personEmptyTrash()
        }
    }

    /// Two local copies with different names. Another device trashes the copy that the first one found; the second one
    /// decides as if the first one had no record.
    private func assertAnotherPhotosRecordIsNoBackup(
        removal: (EditScenarioServer, PhotoUID) -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let server = EditScenarioServer()
        let store = FakeIdentityStore()
        let checks = pipeline(server, store: store)
        let copy = server.seedLink(digest: bytes)
        let first = try await checks.resolve(descriptor("first.heic"))
        XCTAssertEqual(first.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID), file: file, line: line)
        removal(server, copy)

        let second = try await checks.resolve(descriptor("second.heic"))

        let withoutRecord = try await pipeline(server).resolve(descriptor("second.heic"))
        XCTAssertEqual(second.decision, withoutRecord.decision, file: file, line: line)
        XCTAssertNotEqual(
            store.record(for: descriptor("second.heic").source)?.remoteLinkID, copy.nodeID, file: file, line: line)
    }

    /// A file that is no main photo of its own, for example the video of a Live Photo whose photo is not on Proton
    /// yet, takes the same rule.
    func testTheRecordOfAnotherVideoWhoseCopyWasTrashedIsNoBackup() async throws {
        let server = EditScenarioServer()
        let store = FakeIdentityStore()
        let checks = pipeline(server, store: store)
        let copy = server.seedLink(digest: bytes)
        let first = try await checks.resolve(video("first.mov"))
        XCTAssertEqual(first.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID))
        server.personTrash(copy)

        let second = try await checks.resolve(video("second.mov"))

        XCTAssertNotEqual(second.decision, .skip(.knownFromManifest, remoteLinkID: copy.nodeID))
        XCTAssertNotEqual(store.record(for: video("second.mov").source)?.remoteLinkID, copy.nodeID)
    }

    private func video(_ name: String) -> UploadResourceDescriptor {
        let url = URL(fileURLWithPath: "/fixture/\(name)")
        return UploadResourceDescriptor(
            source: .file(url, resource: .livePairedVideo), fileURL: url, filename: name, fileSize: 20,
            modificationDate: Date(timeIntervalSince1970: 1_720_000_000), precomputedSHA1Digest: bytes)
    }

    func testTheRecordOfAnotherPhotoWithAnActiveCopyStillCounts() async throws {
        let server = EditScenarioServer()
        let checks = pipeline(server)
        let copy = server.seedLink(digest: bytes)
        _ = try await checks.resolve(descriptor("first.heic"))

        let second = try await checks.resolve(descriptor("second.heic"))

        XCTAssertEqual(second.decision, .skip(.knownFromManifest, remoteLinkID: copy.nodeID))
    }

    /// A failed state read of the record adopts nothing and fails nothing: the normal check decides with its own read.
    func testAFailedStateReadOfAnotherPhotosRecordAdoptsNothing() async throws {
        let server = EditScenarioServer()
        let store = FakeIdentityStore()
        let checks = pipeline(server, store: store)
        let copy = server.seedLink(digest: bytes)
        _ = try await checks.resolve(descriptor("first.heic"))
        server.failNextVisibilityReads(1)

        let second = try await checks.resolve(descriptor("second.heic"))

        XCTAssertEqual(
            second.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID),
            "the normal check read the copy itself")
    }

    /// Another device trashes the copy after the record's state was read, for example while this photo waits for
    /// another upload of its name. The name row is read again before it counts.
    func testACopyTrashedAfterTheRecordWasReadIsReadAgainForTheNameRow() async throws {
        let server = EditScenarioServer()
        let clock = StepClock()
        let checks = pipeline(server, clock: clock)
        let (copy, photo) = namedCopy(on: server)
        // A trashed copy with the same name and bytes keeps the record of the other photo from deciding alone.
        let earlier = server.seedLink(digest: bytes)
        server.rename(earlier, to: copy.nodeID)
        server.personTrash(earlier)
        _ = try await checks.resolve(descriptor("first.heic"))
        await checks.prime([photo])
        clock.advance(by: UploadDedupePipeline.primedStateLifetime + 1)
        server.afterNextVisibilityRead { server.personTrash(copy) }

        let result = try await checks.resolve(photo)

        XCTAssertNotEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID))
        XCTAssertNotEqual(result.decision, .skip(.knownFromManifest, remoteLinkID: copy.nodeID))
    }

    /// A finished refresh is never reused: a state that has grown old again is read again.
    func testAStateThatGrewOldAgainIsReadAgain() async throws {
        let server = EditScenarioServer()
        let clock = StepClock()
        let checks = pipeline(server, clock: clock)
        let (copy, photo) = namedCopy(on: server)
        await checks.prime([photo])
        clock.advance(by: UploadDedupePipeline.primedStateLifetime + 1)
        let first = try await checks.resolve(photo)
        XCTAssertEqual(first.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID))
        clock.advance(by: UploadDedupePipeline.primedStateLifetime + 1)
        server.personTrash(copy)
        let url = URL(fileURLWithPath: "/fixture/other/\(copy.nodeID)")
        let sameName = UploadResourceDescriptor(
            source: .file(url), fileURL: url, filename: copy.nodeID, fileSize: 20,
            modificationDate: Date(timeIntervalSince1970: 1_720_000_000), precomputedSHA1Digest: bytes)

        let second = try await checks.resolve(sameName)

        XCTAssertEqual(second.decision, .skip(.trashedDuplicate, remoteLinkID: copy.nodeID), "the person's deletion")
    }

    /// Two checks need the same old state at the same time: they share one read.
    func testChecksThatNeedTheSameOldStateShareOneRead() async throws {
        let server = EditScenarioServer()
        let clock = StepClock()
        let checks = pipeline(server, clock: clock)
        let digests = [Data(repeating: 2, count: 20), Data(repeating: 3, count: 20)]
        let copies = server.seedLinks(digests: digests)
        let photos = zip(copies, digests).map { descriptor($0.nodeID, bytes: $1) }
        await checks.prime(photos)
        let primed = server.readCounts.visibility
        clock.advance(by: UploadDedupePipeline.primedStateLifetime + 1)
        server.holdVisibilityReads()
        let joinedBefore = PhotoDiagnostics.shared.counter("upload.stateRefreshJoined")

        let first = Task { try await checks.resolve(photos[0]) }
        await assertEventually({ server.heldVisibilityReads == 1 }, "the first check reads both old states")
        let second = Task { try await checks.resolve(photos[1]) }
        await assertEventually(
            { PhotoDiagnostics.shared.counter("upload.stateRefreshJoined") > joinedBefore },
            "the second check waits for that read")
        server.releaseVisibilityReads()

        let results = [try await first.value, try await second.value]
        XCTAssertEqual(results.map(\.decision), copies.map { .skip(.activeDuplicate, remoteLinkID: $0.nodeID) })
        XCTAssertEqual(server.readCounts.visibility - primed, 1, "one read for both checks")
    }

    /// A copy in a state that is neither active nor in the trash is unknown: the photo neither uploads nor counts as
    /// deleted by the person.
    func testANameRowOfACopyInAnotherInactiveStateIsUnknown() async throws {
        let server = EditScenarioServer()
        let clock = StepClock()
        let checks = pipeline(server, clock: clock)
        let (copy, photo) = namedCopy(on: server)
        await checks.prime([photo])
        clock.advance(by: UploadDedupePipeline.primedStateLifetime + 1)
        server.setVisibility(RemoteLinkVisibility(isActive: false, mainPhotoLinkID: nil), for: copy.nodeID)

        let result = try await checks.resolve(photo)

        XCTAssertEqual(result.decision, .skip(.inconsistentRemoteState, remoteLinkID: copy.nodeID))
    }

    // MARK: - A name row from prime

    /// The local photo has the name and the bytes of the copy, so its name row decides.
    private func namedCopy(on server: EditScenarioServer) -> (PhotoUID, UploadResourceDescriptor) {
        let copy = server.seedLink(digest: bytes)
        return (copy, descriptor(copy.nodeID))
    }

    func testANameRowWhoseCopyWasTrashedAfterThePrimeIsReadAgain() async throws {
        let server = EditScenarioServer()
        let clock = StepClock()
        let checks = pipeline(server, clock: clock)
        let (copy, photo) = namedCopy(on: server)
        await checks.prime([photo])
        clock.advance(by: UploadDedupePipeline.primedStateLifetime + 1)
        server.personTrash(copy)

        let result = try await checks.resolve(photo)

        XCTAssertEqual(result.decision, .skip(.trashedDuplicate, remoteLinkID: copy.nodeID), "the person's deletion")
    }

    func testANameRowWhoseCopyWasDeletedAfterThePrimeIsNoBackup() async throws {
        let server = EditScenarioServer()
        let clock = StepClock()
        let checks = pipeline(server, clock: clock)
        let (copy, photo) = namedCopy(on: server)
        await checks.prime([photo])
        clock.advance(by: UploadDedupePipeline.primedStateLifetime + 1)
        server.personTrash(copy)
        server.personEmptyTrash()

        let result = try await checks.resolve(photo)

        XCTAssertNotEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID))
        XCTAssertEqual(result.decision, .upload, "no copy is left")
    }

    func testAFailedReadOfAnOldNameRowDoesNotSettleThePhoto() async throws {
        let server = EditScenarioServer()
        let store = FakeIdentityStore()
        let clock = StepClock()
        let checks = pipeline(server, store: store, clock: clock)
        let (copy, photo) = namedCopy(on: server)
        await checks.prime([photo])
        clock.advance(by: UploadDedupePipeline.primedStateLifetime + 1)
        server.setVisibilityError(URLError(.timedOut), whenAskingFor: copy.nodeID)

        do {
            let result = try await checks.resolve(photo)
            XCTFail("A failed state read must not settle the photo: \(result.decision)")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertNil(store.record(for: photo.source)?.remoteLinkID)
        XCTAssertNil(store.record(for: photo.source)?.outcome)
    }

    /// Within its lifetime, the state that `prime` read proves the copy without another request.
    func testACurrentNameRowStateCostsNoRequest() async throws {
        let server = EditScenarioServer()
        let clock = StepClock()
        let checks = pipeline(server, clock: clock)
        let (copy, photo) = namedCopy(on: server)
        await checks.prime([photo])
        let primed = server.readCounts.visibility
        clock.advance(by: UploadDedupePipeline.primedStateLifetime)

        let result = try await checks.resolve(photo)

        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID))
        XCTAssertEqual(server.readCounts.visibility, primed)
    }

    /// A new device with a large library: every photo is found by its name row. The reads of old states go out in
    /// batches like the reads of `prime`, never one request for each photo. The bound holds for each 150 photos, so
    /// 10,000 photos stand for a library of any size; the fakes scan every row and would make 50,000 slow.
    func testALargeLibraryReadsOldNameRowStatesInBatches() async throws {
        let count = 10_000
        let server = EditScenarioServer()
        let clock = StepClock()
        let checks = pipeline(server, clock: clock)
        let digests = (0..<count).map { index in
            Data((0..<20).map { UInt8(truncatingIfNeeded: index >> ($0 % 4 * 8)) ^ UInt8($0) })
        }
        let copies = server.seedLinks(digests: digests)
        let photos = zip(copies, digests).map { descriptor($0.nodeID, bytes: $1) }
        await checks.prime(photos)
        let primed = server.readCounts.visibility
        XCTAssertEqual(primed, (count + 149) / 150)

        for (copy, photo) in zip(copies, photos) {
            // Hashing makes the check of each photo take time, so the answers of prime grow old.
            clock.advance(by: 0.1)
            let result = try await checks.resolve(photo)
            XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: copy.nodeID))
        }

        XCTAssertLessThanOrEqual(server.largestVisibilityRead, 150)
        XCTAssertLessThanOrEqual(server.readCounts.visibility - primed, primed, "at most one more read per 150 photos")
    }
}

/// A clock that moves only when the test moves it.
private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_780_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}
