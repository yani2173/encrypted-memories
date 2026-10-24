import XCTest

@testable import PhotosCore

/// Verifies that explicit sign-out arms the purge and failed cleanup remains pending.
final class BackupLocalDataPurgeTests: XCTestCase {
    private actor Gate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "purge-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url.appendingPathComponent("queue.sqlite"))
        return url
    }

    func testPurgeRunsOnlyWhenArmedThenDisarms() throws {
        let root = try makeTempRoot()

        // An unarmed purge must not touch local data.
        XCTAssertFalse(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: [root]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "an un-armed purge must not delete anything")

        // Explicit sign-out arms the purge, which then purges and disarms.
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        XCTAssertTrue(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: [root]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "an armed purge removes the account root")

        // After disarming, a second teardown is a no-op.
        let root2 = try makeTempRoot()
        XCTAssertFalse(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: [root2]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root2.path))
    }

    func testLogoutClearsPersistentDomainButRetainsRecoveryMarker() throws {
        defaults.set("bookmark", forKey: "backup.folderBookmarks.v1")
        BackupLocalDataPurge.requestPurgeOnSignOut(
            defaults: defaults,
            persistentDomainName: suiteName
        )

        XCTAssertNil(defaults.string(forKey: "backup.folderBookmarks.v1"))
        XCTAssertTrue(BackupLocalDataPurge.isPurgePending(defaults: defaults))
    }

    func testSettingsResetClearsPreferencesAndHandsOffToOneResumablePurge() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(12345, forKey: "thumbnail.cachedBytes")
        defaults.set(true, forKey: "ml.enabled")
        XCTAssertFalse(
            BackupLocalDataPurge.prepareRequestedResetForLaunch(
                defaults: defaults, persistentDomainName: suiteName
            ))
        XCTAssertEqual(defaults.integer(forKey: "thumbnail.cachedBytes"), 12345)

        defaults.set(true, forKey: BackupLocalDataPurge.resetOnNextLaunchKey)
        XCTAssertTrue(
            BackupLocalDataPurge.prepareRequestedResetForLaunch(
                defaults: defaults, persistentDomainName: suiteName
            ))
        XCTAssertFalse(defaults.bool(forKey: BackupLocalDataPurge.resetOnNextLaunchKey))
        XCTAssertEqual(
            defaults.persistentDomain(forName: suiteName)?[BackupLocalDataPurge.resetOnNextLaunchKey] as? Bool,
            false
        )
        XCTAssertNil(defaults.object(forKey: "thumbnail.cachedBytes"))
        XCTAssertNil(defaults.object(forKey: "ml.enabled"))
        XCTAssertTrue(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "Arming must not do UI-thread filesystem work")

        // A second launch must retain the already-armed transaction rather than clear its retry marker.
        XCTAssertFalse(
            BackupLocalDataPurge.prepareRequestedResetForLaunch(
                defaults: defaults, persistentDomainName: suiteName
            ))
        let claim = try XCTUnwrap(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))
        XCTAssertTrue(claim.perform(defaults: defaults).succeeded)
        XCTAssertFalse(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(defaults.object(forKey: BackupLocalDataPurge.resetOnNextLaunchKey) as? Bool, false)
    }

    func testFailedClaimKeepsPendingMarkerForNextLaunch() throws {
        let root = try makeTempRoot()
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try XCTUnwrap(
            BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root])
        )

        let result = claim.perform(
            defaults: defaults,
            completesRequestOnSuccess: true,
            removeItem: { _ in throw CocoaError(.fileWriteNoPermission) }
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failedRoots, [root])
        XCTAssertTrue(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testClaimWaitsForExplicitPerformanceAndCompletesMarker() throws {
        let root = try makeTempRoot()
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)

        let claim = try XCTUnwrap(
            BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root])
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "claiming must not race open stores")
        let result = claim.perform(defaults: defaults)
        XCTAssertEqual(result.removedRoots, [root])
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: [root]))
    }

    private typealias MetadataFixture = (
        sandbox: URL, parent: URL, root: URL, otherRoot: URL, permissions: NSNumber
    )

    private func makeMetadataFixture() throws -> MetadataFixture {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("purge-metadata-\(UUID().uuidString)")
        let parent = sandbox.appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = parent.appendingPathComponent("EncryptedMemories", isDirectory: true)
        let otherRoot = sandbox.appendingPathComponent("Library/Caches/EncryptedMemories", isDirectory: true)
        for directory in [root, otherRoot] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("queue.sqlite"))
        }
        let permissions = try XCTUnwrap(fm.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber)
        return (sandbox, parent, root, otherRoot, permissions)
    }

    private func cleanUpMetadataFixture(_ fixture: MetadataFixture) {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: fixture.permissions], ofItemAtPath: fixture.parent.path)
        } catch {
            XCTFail("Could not restore the owned account-root permission fixture")
        }
        do {
            try FileManager.default.removeItem(at: fixture.sandbox)
        } catch {
            XCTFail("Could not remove the restored UUID account-root fixture")
        }
    }

    func testUnreadableRootMetadataKeepsClaimPendingAndContinuesOtherRoots() throws {
        let fm = FileManager.default
        let fixture = try makeMetadataFixture()
        defer { cleanUpMetadataFixture(fixture) }
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try XCTUnwrap(
            BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [fixture.root, fixture.otherRoot]))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.parent.path)
        do {
            _ = try fm.attributesOfItem(atPath: fixture.root.path)
            XCTFail("Pre-read fixture did not cause the required metadata permission error")
            return
        } catch {
            guard let error = error as? CocoaError, error.code == .fileReadNoPermission else {
                XCTFail("Pre-read fixture caused an unexpected metadata error")
                return
            }
            print("605 account-root PRE probe: verified non-missing CocoaError.fileReadNoPermission")
        }

        let result = claim.perform(defaults: defaults)
        try fm.setAttributes([.posixPermissions: fixture.permissions], ofItemAtPath: fixture.parent.path)

        XCTAssertFalse(result.succeeded, "Uncertain pre-read absence must fail the account-root claim")
        XCTAssertEqual(result.failedRoots, [fixture.root])
        XCTAssertEqual(result.removedRoots, [fixture.otherRoot], "A refused root must not stop the other root")
        XCTAssertTrue(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("queue.sqlite")), Data([1, 2, 3]))
        XCTAssertFalse(fm.fileExists(atPath: fixture.otherRoot.path))
    }

    func testUnverifiableAbsenceAfterRemovalKeepsClaimPendingAndContinuesOtherRoots() throws {
        let fm = FileManager.default
        let fixture = try makeMetadataFixture()
        defer { cleanUpMetadataFixture(fixture) }
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try XCTUnwrap(
            BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [fixture.root, fixture.otherRoot]))
        var attempted: [URL] = []
        var observedError: CocoaError.Code?
        let result = claim.perform(
            defaults: defaults, completesRequestOnSuccess: true,
            removeItem: { root in
                attempted.append(root)
                guard root == fixture.root else {
                    try fm.removeItem(at: root)
                    return
                }
                try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.parent.path)
                do {
                    _ = try fm.attributesOfItem(atPath: fixture.root.path)
                    XCTFail("Post-removal fixture did not cause the required metadata permission error")
                } catch {
                    observedError = (error as? CocoaError)?.code
                    if observedError == .fileReadNoPermission {
                        print("605 account-root POST probe: verified non-missing CocoaError.fileReadNoPermission")
                    } else {
                        XCTFail("Post-removal fixture caused an unexpected metadata error")
                    }
                }
            })
        try fm.setAttributes([.posixPermissions: fixture.permissions], ofItemAtPath: fixture.parent.path)

        XCTAssertEqual(observedError, .fileReadNoPermission)
        XCTAssertEqual(attempted, [fixture.root, fixture.otherRoot])
        XCTAssertFalse(result.succeeded, "Unverifiable post-removal absence must fail the account-root claim")
        XCTAssertEqual(result.failedRoots, [fixture.root])
        XCTAssertEqual(result.removedRoots, [fixture.otherRoot])
        XCTAssertTrue(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("queue.sqlite")), Data([1, 2, 3]))
        XCTAssertFalse(fm.fileExists(atPath: fixture.otherRoot.path))
    }

    func testRemovalFailureStillAttemptsOtherRootsAndRetainsClaim() throws {
        let fixture = try makeMetadataFixture()
        defer { cleanUpMetadataFixture(fixture) }
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try XCTUnwrap(
            BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [fixture.root, fixture.otherRoot]))
        var attempted: [URL] = []
        let result = claim.perform(
            defaults: defaults, completesRequestOnSuccess: true,
            removeItem: { root in
                attempted.append(root)
                if root == fixture.root { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: root)
            })
        XCTAssertEqual(attempted, [fixture.root, fixture.otherRoot])
        XCTAssertEqual(result.failedRoots, [fixture.root])
        XCTAssertEqual(result.removedRoots, [fixture.otherRoot])
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("queue.sqlite")), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.otherRoot.path))
    }

    private func assertConfirmedMissing(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTFail("The owned root entry must be positively absent", file: file, line: line)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }

    private func verifyFinalAccountRootLink(pointsToExistingDirectory: Bool) throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("purge-final-link-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: sandbox) }
        let destination = sandbox.appendingPathComponent("outside-root", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("must-survive")
        try Data([7]).write(to: sentinel)
        let root = sandbox.appendingPathComponent("account-root")
        try fm.createSymbolicLink(
            at: root,
            withDestinationURL: pointsToExistingDirectory ? destination : destination.appendingPathComponent("missing"))
        XCTAssertEqual(try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType, .typeSymbolicLink)
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try XCTUnwrap(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]))

        let result = claim.perform(defaults: defaults)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.removedRoots, [root])
        XCTAssertTrue(result.failedRoots.isEmpty)
        XCTAssertFalse(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        try assertConfirmedMissing(root)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([7]))
    }

    func testFinalAccountRootLinkRemovesOnlyTheLink() throws {
        try verifyFinalAccountRootLink(pointsToExistingDirectory: true)
    }

    func testDanglingFinalAccountRootLinkIsRemovedAndVerifiedAbsent() throws {
        try verifyFinalAccountRootLink(pointsToExistingDirectory: false)
    }

    func testNoOpRemovalCannotCompleteClaimWhileTheRootRemains() throws {
        let fixture = try makeMetadataFixture()
        defer { cleanUpMetadataFixture(fixture) }
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try XCTUnwrap(
            BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [fixture.root, fixture.otherRoot]))
        let result = claim.perform(
            defaults: defaults, completesRequestOnSuccess: true,
            removeItem: { root in
                if root != fixture.root { try FileManager.default.removeItem(at: root) }
            })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failedRoots, [fixture.root])
        XCTAssertEqual(result.removedRoots, [fixture.otherRoot])
        XCTAssertTrue(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("queue.sqlite")), Data([1, 2, 3]))
        try assertConfirmedMissing(fixture.otherRoot)
    }

    func testRemovalErrorAfterRemovingRootStillKeepsClaimPending() throws {
        let fixture = try makeMetadataFixture()
        defer { cleanUpMetadataFixture(fixture) }
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let claim = try XCTUnwrap(BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [fixture.root]))
        let result = claim.perform(
            defaults: defaults, completesRequestOnSuccess: true,
            removeItem: { root in
                try FileManager.default.removeItem(at: root)
                throw CocoaError(.fileWriteUnknown)
            })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failedRoots, [fixture.root])
        XCTAssertTrue(result.removedRoots.isEmpty)
        XCTAssertTrue(BackupLocalDataPurge.isPurgePending(defaults: defaults))
        try assertConfirmedMissing(fixture.root)
    }

    func testPurgeAllIsIdempotentOverMissingRoots() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            "does-not-exist-\(UUID().uuidString)")
        let result = BackupLocalDataPurge.purgeAllLocalAccountData(roots: [missing])
        XCTAssertTrue(result.succeeded, "missing roots are ignored, not errors")
        XCTAssertTrue(result.removedRoots.isEmpty)
    }

    func testTransientShareExportPurgeDeletesOnlyCanonicalChildWithoutFollowingSymlinks() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("transient-purge-\(UUID().uuidString)", isDirectory: true)
        let exports = parent.appendingPathComponent("ShareExports", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("transient-purge-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("must-survive.txt")
        try Data("private".utf8).write(to: outsideFile)
        try Data("export".utf8).write(to: exports.appendingPathComponent("stale.jpg"))
        try FileManager.default.createSymbolicLink(
            at: exports.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )

        let result = TransientPlaintextPurge.purgeShareExports(temporaryDirectory: parent)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.directory, exports.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testDisplayWakePolicyRequiresExplicitForegroundActiveBackup() {
        for optedIn in [false, true] {
            for foreground in [false, true] {
                for active in [false, true] {
                    XCTAssertEqual(
                        BackupDisplayWakePolicy.shouldKeepDisplayAwake(
                            userOptedIn: optedIn,
                            applicationIsForegroundActive: foreground,
                            backupIsActivelyProcessing: active
                        ),
                        optedIn && foreground && active
                    )
                }
            }
        }
        XCTAssertFalse(AppSettingsDefault.keepDisplayAwakeDuringForegroundBackup)
    }

    @MainActor
    func testSignOutBarrierRejectsOverlapAndWaitsForCleanup() async {
        let barrier = AccountSignOutBarrier()
        let gate = Gate()
        var completed = 0

        XCTAssertTrue(
            barrier.begin {
                await gate.wait()
                completed += 1
            })
        XCTAssertTrue(barrier.isRunning)
        XCTAssertFalse(barrier.begin { completed += 100 })

        await gate.open()
        await barrier.waitUntilFinished()

        XCTAssertFalse(barrier.isRunning)
        XCTAssertEqual(completed, 1)
    }
}
