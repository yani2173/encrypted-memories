import AlbumSyncCore
import Foundation
import XCTest

@testable import UploadCore

/// Two devices sync the same shared album into one Proton album. Each device holds its own copy of a shared photo:
/// the same bytes under another local identifier, another file name and no common iCloud identity.
final class AlbumSyncSharedAlbumScenarioTests: XCTestCase {
    func testSecondDeviceAddsTheFirstDevicesCopyOneAfterTheOther() async throws {
        let (deviceA, deviceB) = try makeDevices()
        defer {
            try? deviceA.cleanup()
            try? deviceB.cleanup()
        }

        let first = try await deviceA.syncAlbum(["asset-1"], backup: EditScenarioAlbumBackup(device: deviceA))
        let second = try await deviceB.syncAlbum(["asset-1"], backup: EditScenarioAlbumBackup(device: deviceB))

        XCTAssertEqual(first.attached, 1)
        XCTAssertEqual(second.attached, 0)
        XCTAssertEqual(second.alreadyMember, 1)
        let members = try await deviceA.server.childMainLinkIDs(albumID: "own-album")
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(deviceA.server.uploadRequestCount, 1, "The second device uploads nothing")
    }

    /// Device A's upload holds before its commit while device B syncs, so both devices upload their copy. The library
    /// keeps both copies; the album gets one of them. The scenario server does not report an open upload draft in its
    /// content lookup, so this race may not occur against Proton in the same way.
    func testTwoDevicesSyncingAtTheSameTimeLeaveOnePhotoInTheAlbum() async throws {
        let (deviceA, deviceB) = try makeDevices()
        defer {
            try? deviceA.cleanup()
            try? deviceB.cleanup()
        }
        await deviceA.server.uploadGate.arm(generation: 1)
        let heldA = HeldDevice(device: deviceA)
        let runA = Task {
            try await heldA.device.syncAlbum(["asset-1"], backup: EditScenarioAlbumBackup(device: heldA.device))
        }
        await deviceA.server.uploadGate.waitUntilSuspended()
        let reportB: AlbumSyncReport
        do {
            reportB = try await deviceB.syncAlbum(["asset-1"], backup: EditScenarioAlbumBackup(device: deviceB))
        } catch {
            await deviceA.server.uploadGate.release()
            _ = try? await runA.value
            throw error
        }
        await deviceA.server.uploadGate.release()
        let reportA = try await runA.value

        XCTAssertEqual(deviceA.server.uploadRequestCount, 2, "Both devices uploaded their copy before either commit")
        XCTAssertEqual(reportB.attached, 1)
        XCTAssertEqual(reportA.attached, 0, "A copy with the same bytes is already in the album")
        XCTAssertEqual(reportA.alreadyMember, 1)
        XCTAssertTrue(reportA.isFullySynced)
        let members = try await deviceA.server.childMainLinkIDs(albumID: "own-album")
        XCTAssertEqual(members.count, 1, "The shared photo is once in the Proton album")
        let activeCopies = deviceA.server.links.filter { $0.state == .active && $0.mainLinkID == nil }
        XCTAssertEqual(activeCopies.count, 2, "Album Sync deletes no copy")
    }

    /// Both libraries hold the same bytes. Device B names the photo differently and has another iCloud identity.
    private func makeDevices() throws -> (EditScenarioHarness, EditScenarioHarness) {
        let deviceA = try EditScenarioHarness()
        do {
            let deviceB = try EditScenarioHarness(basename: "IMG_9", server: deviceA.server)
            deviceB.library.shareCloudIdentifier("shared-copy-b", between: ["asset-1"])
            XCTAssertEqual(deviceA.library.snapshot.first?.original, deviceB.library.snapshot.first?.original)
            return (deviceA, deviceB)
        } catch {
            try? deviceA.cleanup()
            throw error
        }
    }
}

/// Device A's run continues in a task while the test drives device B; the test joins it before cleanup.
private struct HeldDevice: @unchecked Sendable {
    let device: EditScenarioHarness
}
