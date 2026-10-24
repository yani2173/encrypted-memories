import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// The "N left · speed" line of the backup status: when it shows, what it says, and that no phase that waits
/// ever shows a speed.
final class BackupLeftAndSpeedPresentationTests: XCTestCase {
    /// Seven rows left: five queued for upload and two uploading. This makes the phase `.uploading`.
    private func runningProgress() -> BackupSyncProgress {
        var progress = BackupSyncProgress()
        progress.total = 10
        progress.waiting = 5
        progress.uploadQueued = 5
        progress.uploading = 2
        progress.uploaded = 3
        progress.isRunning = true
        return progress
    }

    private func presentation(
        _ progress: BackupSyncProgress, isUserPaused: Bool = false, speed: Double?
    ) -> BackupStatusPresentation {
        var status = BackupStatus(progress: progress, isScanning: false, isUserPaused: isUserPaused)
        status.uploadSpeedBytesPerSecond = speed
        return BackupStatusPresentation(status)
    }

    func testRemainingCountIsWaitingPlusCheckingPlusUploading() {
        var progress = runningProgress()
        progress.checking = 4
        progress.blocked = 6
        progress.failed = 8
        progress.dismissedFailures = 9
        progress.sourceMissing = 11
        XCTAssertEqual(BackupStatus(progress: progress, isScanning: false).remainingCount, 5 + 4 + 2)
    }

    func testUploadingShowsLeftAndSpeedInOneLineAndOneSpokenSentence() throws {
        let display = presentation(runningProgress(), speed: 3_200_000)
        let size = L10n.fileSize(3_200_000)
        XCTAssertEqual(display.headlineKey, "backup.phase_uploading")
        XCTAssertEqual(display.localizedLeftLine, L10n.string("backup.detail_left_speed \(7) \(size)"))
        let spoken = try XCTUnwrap(display.localizedLeftAccessibilityLabel)
        XCTAssertEqual(spoken, L10n.string("backup.detail_left_speed_spoken \(7) \(size)"))
        XCTAssertTrue(spoken.contains(size) && spoken.contains("7"), "both values in one sentence")
        XCTAssertNotEqual(spoken, display.localizedLeftLine, "VoiceOver reads a sentence, not the symbol text")
    }

    func testWithoutSpeedTheLineShowsOnlyTheCount() {
        let display = presentation(runningProgress(), speed: nil)
        XCTAssertEqual(display.localizedLeftLine, L10n.string("backup.detail_left \(7)"))
        XCTAssertEqual(display.localizedLeftAccessibilityLabel, display.localizedLeftLine)
        XCTAssertEqual(
            presentation(runningProgress(), speed: 0.4).localizedLeftLine, display.localizedLeftLine,
            "less than one byte per second is no speed")
    }

    func testCheckingShowsTheSpeedToo() {
        var progress = runningProgress()
        progress.uploadQueued = 0
        progress.uploading = 0
        progress.checking = 2
        let display = presentation(progress, speed: 1_000_000)
        XCTAssertEqual(display.headlineKey, "backup.phase_checking")
        XCTAssertEqual(
            display.localizedLeftLine, L10n.string("backup.detail_left_speed \(7) \(L10n.fileSize(1_000_000))"))
    }

    func testPausedKeepsTheCountButNeverShowsASpeed() {
        let policy = {
            var progress = self.runningProgress()
            progress.isPausedByPolicy = true
            return progress
        }()
        for display in [
            presentation(policy, speed: 5_000_000),
            presentation(runningProgress(), isUserPaused: true, speed: 5_000_000),
        ] {
            XCTAssertEqual(display.headlineKey, "backup.phase_paused")
            XCTAssertEqual(display.localizedLeftLine, L10n.string("backup.detail_left \(7)"))
        }
    }

    func testWaitingForWiFiOfflineWaitingCompletedAndScanningShowNoSpeedAndNoLine() {
        var wifi = runningProgress()
        wifi.isPausedByPolicy = true
        wifi.isWaitingForWiFi = true
        var waiting = runningProgress()
        waiting.isRunning = false
        waiting.uploading = 0
        var completed = BackupSyncProgress()
        completed.total = 4
        completed.uploaded = 4
        for progress in [wifi, waiting, completed] {
            let display = presentation(progress, speed: 5_000_000)
            XCTAssertNil(display.uploadSpeedBytesPerSecond, "\(display.headlineKey) carries no speed")
            XCTAssertNil(display.localizedLeftLine, "\(display.headlineKey) has no left line")
        }
        var scanning = BackupStatus(progress: runningProgress(), isScanning: true)
        scanning.uploadSpeedBytesPerSecond = 5_000_000
        let display = BackupStatusPresentation(scanning)
        XCTAssertNil(display.uploadSpeedBytesPerSecond)
        XCTAssertNil(display.localizedLeftLine)
    }

    func testNothingLeftShowsNoLine() {
        var progress = runningProgress()
        progress.waiting = 0
        progress.uploadQueued = 0
        progress.uploading = 0
        progress.checking = 0
        progress.pendingSourceRechecks = 1
        XCTAssertNil(presentation(progress, speed: 1_000_000).localizedLeftLine)
    }
}

/// The projector measures the speed from the runner's counter with its injected clock.
final class BackupSpeedProjectorTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSinceReferenceDate: 0)
        var now: Date { lock.withLock { time } }
        func set(_ seconds: TimeInterval) { lock.withLock { time = Date(timeIntervalSinceReferenceDate: seconds) } }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [BackupStatusProjection] = []
        func append(_ projection: BackupStatusProjection) { lock.withLock { storage.append(projection) } }
        var last: BackupStatusProjection? { lock.withLock { storage.last } }
    }

    private var tempDirectory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-speed-projector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDirectory.appendingPathComponent("queue.sqlite")))
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "moving", resource: .primary),
                    revision: UploadBackupRevision(date: Date(timeIntervalSinceReferenceDate: 42)),
                    originalFilename: "moving.heic",
                    state: .uploading,
                    updatedAt: Date()
                )))
    }

    override func tearDownWithError() throws {
        queue?.close()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func runnerProgress(bytes: Int64) -> BackupSyncProgress {
        var progress = BackupSyncProgress(summary: queue.summary(), isRunning: true)
        progress.transferredByteCount = bytes
        return progress
    }

    func testSpeedAppearsFromTheCounterAndPauseHidesItAndAResumeStartsFresh() async throws {
        let clock = Clock()
        let projector = BackupStatusProjector(queue: queue, now: { clock.now })
        let generation = UUID()
        let recorder = Recorder()
        await projector.start(generation: generation, context: BackupStatusProjectionContext(isRunning: true)) {
            recorder.append($0)
        }

        // One megabyte per second. The counter values are distinct so a published projection proves the sample.
        for second in 0...5 {
            clock.set(TimeInterval(second))
            let bytes = 1_000 + Int64(second) * 1_000_000
            projector.submit(runnerProgress(bytes: bytes), generation: generation)
            let seen = await waitUntil { recorder.last?.progress.transferredByteCount == bytes }
            XCTAssertTrue(seen, "second \(second) was not published")
        }
        _ = await projector.projectNow(
            context: BackupStatusProjectionContext(isRunning: true), generation: generation, revision: 1)
        let running = try XCTUnwrap(recorder.last)
        XCTAssertEqual(running.status.phase, .uploading)
        XCTAssertEqual(try XCTUnwrap(running.status.uploadSpeedBytesPerSecond), 1_000_000, accuracy: 1)

        // A user pause hides the speed at once and forgets the history.
        clock.set(6)
        let pausedProjection = await projector.projectNow(
            context: BackupStatusProjectionContext(isRunning: true, isUserPaused: true),
            generation: generation, revision: 2)
        let paused = try XCTUnwrap(pausedProjection)
        XCTAssertEqual(paused.status.phase, .paused)
        XCTAssertNil(paused.status.uploadSpeedBytesPerSecond)

        // After the resume the first samples are only a baseline: no stale speed comes back.
        clock.set(7)
        projector.submit(runnerProgress(bytes: 7_000_000), generation: generation)
        let resumedProjection = await projector.projectNow(
            context: BackupStatusProjectionContext(isRunning: true), generation: generation, revision: 3)
        let resumed = try XCTUnwrap(resumedProjection)
        XCTAssertEqual(resumed.status.phase, .uploading)
        XCTAssertNil(resumed.status.uploadSpeedBytesPerSecond)
        await projector.stop()
    }
}
