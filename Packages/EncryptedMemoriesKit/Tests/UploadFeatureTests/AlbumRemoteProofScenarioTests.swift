import AlbumSyncCore
import Foundation
import XCTest

@testable import UploadCore

final class AlbumRemoteProofScenarioTests: XCTestCase {
    func testSecondDeviceAttachesRemotelyProvenPhotoWithoutResolvingBytes() async throws {
        let deviceA = try EditScenarioHarness()
        defer { try? deviceA.cleanup() }
        try await deviceA.enqueue()
        await deviceA.drain()
        let original = try deviceA.liveMain()
        let deviceB = try EditScenarioHarness(server: deviceA.server, library: deviceA.library)
        defer { try? deviceB.cleanup() }
        let uploads = deviceA.server.steps.filter { $0.action.hasPrefix("upload") }.count
        let resolutions = deviceB.library.resolutions.count
        let row = try await deviceB.enqueue()
        XCTAssertEqual(deviceB.lastScan.alreadyBackedUp, 1)
        XCTAssertEqual(deviceB.state(of: row), .alreadyBackedUp)

        let report = try await syncAlbum(on: deviceB)

        XCTAssertEqual(report.attached, 1)
        XCTAssertEqual(report.unattachable, 0)
        let members = try await deviceB.server.childMainLinkIDs(albumID: "own-album")
        XCTAssertEqual(members, [original.nodeID])
        XCTAssertEqual(deviceB.library.resolutions.count, resolutions)
        XCTAssertEqual(deviceA.server.steps.filter { $0.action.hasPrefix("upload") }.count, uploads)
    }

    func testFirstLaunchWithV110SettledRowKeepsManifestUnchangedAndConverges() async throws {
        let deviceA = try EditScenarioHarness(live: true)
        defer { try? deviceA.cleanup() }
        try await deviceA.enqueue()
        await deviceA.drain()
        let original = try deviceA.liveMain()
        let deviceB = try EditScenarioHarness(server: deviceA.server, library: deviceA.library)
        defer { try? deviceB.cleanup() }
        let candidate = try deviceB.library.candidate()
        // 1.1.0 could hash before another device uploaded, then settle only its queue through remote proof.
        var manifest = try XCTUnwrap(deviceA.identities.record(for: candidate.snapshot.source))
        manifest.remoteLinkID = nil
        manifest.remoteVolumeID = nil
        manifest.outcome = nil
        XCTAssertTrue(deviceB.identities.upsert(manifest))
        let stored = UploadBackupSyncQueueEntry(
            source: candidate.snapshot.source, revision: candidate.snapshot.revision,
            originalFilename: candidate.originalFilename, state: .alreadyBackedUp, updatedAt: deviceB.clock.now)
        XCTAssertTrue(deviceB.queue.upsert(stored))
        try deviceB.relaunch()
        let resolutions = deviceB.library.resolutions.count
        let uploads = deviceB.server.steps.filter { $0.action.hasPrefix("upload") }.count

        let first = try await syncAlbum(on: deviceB, recheckBackup: false)
        let second = try await syncAlbum(on: deviceB, recheckBackup: false)

        XCTAssertEqual(first.attached, 1)
        XCTAssertEqual(first.unattachable, 0)
        XCTAssertEqual(second.attached, 0)
        XCTAssertEqual(second.alreadyMember, 1)
        let members = try await deviceB.server.childMainLinkIDs(albumID: "own-album")
        XCTAssertEqual(members, [original.nodeID], "The compound main attaches; its related video is never a member")
        XCTAssertEqual(deviceB.queue.entry(for: stored.source, revision: stored.revision), stored)
        XCTAssertEqual(deviceB.identities.record(for: stored.source), manifest)
        XCTAssertEqual(deviceB.library.resolutions.count, resolutions)
        XCTAssertEqual(deviceB.server.steps.filter { $0.action.hasPrefix("upload") }.count, uploads)
        try deviceB.relaunch()
        XCTAssertEqual(deviceB.queue.entry(for: stored.source, revision: stored.revision), stored)
        XCTAssertEqual(deviceB.identities.record(for: stored.source), manifest)
    }

    func testUnavailableOrAmbiguousRemoteProofStillReportsTheMissingAlbumMember() async throws {
        let deviceA = try EditScenarioHarness()
        defer { try? deviceA.cleanup() }
        let uploaded = try await deviceA.enqueue()
        await deviceA.drain()
        let deviceB = try EditScenarioHarness(server: deviceA.server, library: deviceA.library)
        defer { try? deviceB.cleanup() }
        try await deviceB.enqueue()
        deviceB.index.setProofLookupsFail(true)
        let unavailable = try await syncAlbum(on: deviceB, recheckBackup: false)
        XCTAssertEqual(unavailable.attached, 0)
        XCTAssertEqual(unavailable.unattachable, 1)
        XCTAssertEqual(unavailable.problems.count, 1)
        deviceB.index.setProofLookupsFail(false)

        let candidate = try deviceB.library.candidate()
        let identity = try XCTUnwrap(candidate.snapshot.externalIdentity)
        let resolved = try await deviceA.library.resolve(uploaded, now: deviceA.clock.now)
        let resource = try XCTUnwrap(resolved)
        let record = try XCTUnwrap(deviceA.identities.record(for: candidate.snapshot.source))
        _ = deviceA.server.seedV105Upload(
            resource.descriptor, digest: try XCTUnwrap(UploadContentSHA1.digest(fromHex: record.sha1Hex)),
            asset: try XCTUnwrap(deviceA.library.snapshot.first), main: nil, externalIdentifier: identity.identifier)
        deviceB.index.refreshProofs()
        XCTAssertNil(
            deviceA.server.allRemoteAssetProofs()[identity], "Two active compounds make the identity ambiguous")
        let resolutions = deviceB.library.resolutions.count
        let ambiguous = try await syncAlbum(on: deviceB, recheckBackup: false)
        XCTAssertEqual(ambiguous.attached, 0)
        XCTAssertEqual(ambiguous.unattachable, 1)
        XCTAssertEqual(ambiguous.problems.count, 1)
        XCTAssertEqual(deviceB.library.resolutions.count, resolutions)
        let members = try await deviceB.server.childMainLinkIDs(albumID: "own-album")
        XCTAssertTrue(members.isEmpty)
    }

    private func syncAlbum(on device: EditScenarioHarness, recheckBackup: Bool = true) async throws -> AlbumSyncReport {
        try await device.syncAlbum(
            ["asset-1"], backup: ScenarioAlbumBackup(device: device, recheckBackup: recheckBackup))
    }
}

private final class ScenarioAlbumBackup: AlbumSyncBackupExecuting, @unchecked Sendable {
    let device: EditScenarioHarness
    let recheckBackup: Bool
    init(device: EditScenarioHarness, recheckBackup: Bool) {
        self.device = device
        self.recheckBackup = recheckBackup
    }
    func ensureBackedUp(
        localIdentifiers: [String], onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        let row: UploadBackupSyncQueueEntry
        if recheckBackup {
            row = try await device.enqueue()
            await device.pass()
        } else {
            let candidate = try device.library.candidate()
            row = try XCTUnwrap(
                device.queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        }
        return AlbumSyncBackupReport(
            total: 1, backedUp: device.state(of: row) == .alreadyBackedUp ? 1 : 0,
            failed: 0, sourceMissing: 0, skippedRemoteDeletion: 0)
    }
    func remoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink] {
        try await AlbumSyncRemoteProofLookup.remoteLinks(
            for: localIdentifiers, catalog: device.library, queue: device.queue, resolver: device.identityResolver)
    }
    func stop() async {}
}
