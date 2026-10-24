import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class BackupStatusProjectorTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [BackupStatusProjection] = []

        func append(_ projection: BackupStatusProjection) {
            lock.withLock { storage.append(projection) }
        }

        var values: [BackupStatusProjection] {
            lock.withLock { storage }
        }
    }

    private var tempDirectory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-status-projector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDirectory.appendingPathComponent("queue.sqlite")
            ))
    }

    override func tearDownWithError() throws {
        queue?.close()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testStopReleasesTheProjectorAndItsCallbackOwner() async {
        var projector: BackupStatusProjector? = BackupStatusProjector(queue: queue)
        var recorder: Recorder? = Recorder()
        weak var releasedProjector = projector
        weak var releasedRecorder = recorder
        await projector?.start(generation: UUID(), context: BackupStatusProjectionContext()) { [recorder] projection in
            recorder?.append(projection)
        }
        recorder = nil
        await projector?.stop()
        XCTAssertNil(releasedRecorder, "Stop must detach the callback owner")
        projector = nil
        XCTAssertNil(releasedProjector)
    }

    func testStartProjectsDurableQueueTruth() async throws {
        XCTAssertTrue(queue.upsert(entry(id: "durable", state: .discovered)))
        let projector = BackupStatusProjector(queue: queue)
        let generation = UUID()
        let recorder = Recorder()

        await projector.start(
            generation: generation,
            context: BackupStatusProjectionContext()
        ) { projection in
            recorder.append(projection)
        }

        let projection = try XCTUnwrap(recorder.values.last)
        XCTAssertEqual(projection.generation, generation)
        XCTAssertEqual(projection.progress.total, 1)
        XCTAssertEqual(projection.progress.waiting, 1)
        XCTAssertEqual(projection.status.phase, .waiting)
        await projector.stop()
    }

    func testStaleGenerationIsDiscarded() async throws {
        XCTAssertTrue(queue.upsert(entry(id: "generation", state: .discovered)))
        let projector = BackupStatusProjector(queue: queue)
        let generation = UUID()
        let recorder = Recorder()

        await projector.start(
            generation: generation,
            context: BackupStatusProjectionContext(isRunning: true)
        ) { projection in
            recorder.append(projection)
        }
        let initialCount = recorder.values.count

        var progress = BackupSyncProgress(summary: queue.summary(), isRunning: true)
        progress.currentItemName = "current.heic"
        projector.submit(progress, generation: UUID())
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.values.count, initialCount)

        projector.submit(progress, generation: generation)
        let accepted = await waitUntil {
            recorder.values.last?.progress.currentItemName == "current.heic"
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(recorder.values.last?.progress.currentItemName, "current.heic")
        await projector.stop()
    }

    func testCountTicksCoalesceButTerminalStatePublishesImmediately() async throws {
        let row = entry(id: "coalesce", state: .discovered)
        XCTAssertTrue(queue.upsert(row))
        let projector = BackupStatusProjector(queue: queue, coalescingInterval: 0.15)
        let generation = UUID()
        let recorder = Recorder()

        await projector.start(
            generation: generation,
            context: BackupStatusProjectionContext(isRunning: true)
        ) { projection in
            recorder.append(projection)
        }

        var progress = BackupSyncProgress(summary: queue.summary(), isRunning: true)
        progress.currentItemName = "tick-0"
        projector.submit(progress, generation: generation)
        let becameActive = await waitUntil {
            recorder.values.last?.progress.currentItemName == "tick-0"
        }
        XCTAssertTrue(becameActive)
        let countAfterPhaseChange = recorder.values.count

        for index in 1...50 {
            progress.currentItemName = "tick-\(index)"
            progress.activeExecutionItemEquivalents = Double(index) / 100
            projector.submit(progress, generation: generation)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let afterTicks = recorder.values
        XCTAssertLessThanOrEqual(afterTicks.count, countAfterPhaseChange + 2)
        XCTAssertEqual(afterTicks.last?.progress.currentItemName, "tick-50")

        XCTAssertTrue(
            queue.updateState(
                source: row.source,
                revision: row.revision,
                state: .completed,
                attempts: 0,
                lastError: nil,
                updatedAt: Date()
            ))
        progress.isRunning = false
        progress.waiting = 0
        progress.uploaded = 1
        projector.submit(progress, generation: generation)
        _ = await projector.projectNow(
            context: BackupStatusProjectionContext(isRunning: false),
            generation: generation,
            revision: 1
        )
        let becameTerminal = await waitUntil {
            recorder.values.last?.status.phase == .completed
        }
        XCTAssertTrue(becameTerminal)
        XCTAssertEqual(recorder.values.last?.progress.uploaded, 1)
        await projector.stop()
    }

    func testTerminalQueueClearsStaleTransferWhileControllerRunFinishes() async throws {
        let row = entry(id: "terminal-tail", state: .uploading)
        XCTAssertTrue(queue.upsert(row))
        let projector = BackupStatusProjector(queue: queue, coalescingInterval: 0)
        let generation = UUID()
        let recorder = Recorder()

        await projector.start(
            generation: generation,
            context: BackupStatusProjectionContext(isRunning: true)
        ) { projection in
            recorder.append(projection)
        }

        var live = BackupSyncProgress(summary: queue.summary(), isRunning: true)
        live.activeTransfer = BackupActiveTransferProgress(
            activeItemCount: 1,
            completedBytes: 75,
            totalBytes: 100,
            completedItemEquivalents: 0.75
        )
        live.activeExecutionItemEquivalents = 0.75
        projector.submit(live, generation: generation)
        let transferPublished = await waitUntil { recorder.values.last?.progress.activeTransfer != nil }
        XCTAssertTrue(transferPublished)

        XCTAssertTrue(
            queue.updateState(
                source: row.source,
                revision: row.revision,
                state: .completed,
                attempts: 0,
                lastError: nil,
                updatedAt: Date()
            ))
        let projected = await projector.projectNow(
            context: BackupStatusProjectionContext(isRunning: true),
            generation: generation,
            revision: 1
        )
        let terminal = try XCTUnwrap(projected)

        XCTAssertEqual(terminal.progress.uploaded, 1)
        XCTAssertNil(terminal.progress.activeTransfer)
        XCTAssertEqual(terminal.progress.activeExecutionItemEquivalents, 0)
        XCTAssertEqual(terminal.status.phase, .completed)
        XCTAssertFalse(terminal.status.isActive)
        await projector.stop()
    }

    func testDismissedSourceRechecksUsePhotosWordingWithoutAProblemListAction() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let due = now.addingTimeInterval(600)
        var originals: [UploadBackupSyncQueueEntry] = []
        for (index, state) in [UploadBackupSyncQueueState.discovered, .checking].enumerated() {
            var row = entry(id: "dismissed-\(index)", state: state)
            row.updatedAt = due
            row.lastError =
                BackupIssueRecord(
                    kind: .sourceMissing, detail: "source unavailable", nextAttemptAt: due,
                    automaticRetryAttempt: 3
                ).persistedValue
            XCTAssertTrue(queue.upsert(row))
            originals.append(row)
        }
        queue.close()
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDirectory.appendingPathComponent("queue.sqlite")))
        let projector = BackupStatusProjector(queue: queue, now: { now })
        let generation = UUID()
        let recorder = Recorder()
        await projector.start(generation: generation, context: .init()) { recorder.append($0) }
        let projection = try XCTUnwrap(recorder.values.last)
        let display = BackupStatusPresentation(projection.status)

        XCTAssertEqual(projection.progress.pendingSourceRechecks, 2)
        XCTAssertEqual(projection.progress.dismissedFailures, 2)
        XCTAssertTrue(projection.progress.hasOutstandingWork)
        XCTAssertEqual(projection.status.outstandingCount, 2)
        XCTAssertEqual(projection.status.nextAttemptAt, due)
        XCTAssertEqual(projection.status.phase, .waiting)
        XCTAssertEqual(projection.status.titleKey, "backup.phase_waiting_photos")
        XCTAssertNil(projection.status.localizedDetail)
        XCTAssertEqual(display.headlineKey, "backup.phase_waiting_photos")
        XCTAssertEqual(projection.status.localizedTitle, L10n.string("backup.phase_waiting_photos"))
        XCTAssertEqual(display.localizedHeadline, L10n.string("backup.phase_waiting_photos"))
        XCTAssertFalse(display.isActive)
        XCTAssertEqual(display.waitingCount, 0)
        XCTAssertNil(display.localizedWaitingDetail, "Both native hosts open the list only when this exists")
        XCTAssertNil(display.localizedAttention)
        XCTAssertEqual(display.attentionCount, 0)
        XCTAssertEqual(display.backedUp, 0)
        XCTAssertEqual(display.total, 2)
        XCTAssertEqual(display.nextAttemptAt, due)
        XCTAssertNotNil(display.localizedRetryDetail)
        try assertPhotosWording(display, english: "Waiting to check Photos", german: "Warten auf Prüfung in Fotos")
        XCTAssertEqual(
            BackupAutomaticRetryPlanner.nextAttempt(
                outstandingCount: projection.status.outstandingCount, queueDate: projection.status.nextAttemptAt,
                consecutiveNoProgressRuns: 0, now: now, retryPolicy: BackupRetryPolicy()), due)
        var failures: [BackupFailedItem] = []
        queue.forEachProblemEntry {
            failures.append(BackupFailedItem(entry: $0))
            return true
        }
        XCTAssertTrue(failures.isEmpty)
        XCTAssertFalse(failures.offersUserRetry)
        for original in originals {
            XCTAssertEqual(queue.entry(for: original.source, revision: original.revision), original)
        }

        await projector.stop()
    }

    func testActiveDismissedSourceRecheckNamesPhotosInSharedProjection() async throws {
        var marker = entry(id: "active-dismissed", state: .checking)
        marker.lastError = BackupIssueRecord(kind: .sourceMissing, detail: "source unavailable").persistedValue
        XCTAssertTrue(queue.upsert(marker))
        let projector = BackupStatusProjector(queue: queue)
        let recorder = Recorder()
        await projector.start(generation: UUID(), context: .init(isRunning: true)) { recorder.append($0) }
        let running = try XCTUnwrap(recorder.values.last)
        let active = BackupStatusPresentation(running.status)
        XCTAssertEqual(running.status.phase, .checking)
        XCTAssertEqual(running.status.titleKey, "backup.phase_checking_photos")
        XCTAssertEqual(active.headlineKey, "backup.phase_checking_photos")
        XCTAssertEqual(running.status.localizedTitle, L10n.string("backup.phase_checking_photos"))
        XCTAssertEqual(active.localizedHeadline, L10n.string("backup.phase_checking_photos"))
        XCTAssertNil(running.status.localizedDetail)
        XCTAssertTrue(active.isActive)
        XCTAssertEqual(active.detailLayout, .progress)
        XCTAssertNil(active.localizedWaitingDetail)
        XCTAssertNil(active.localizedAttention)
        XCTAssertEqual(active.backedUp, 0)
        XCTAssertEqual(active.total, 1)
        try assertPhotosWording(active, english: "Checking Photos", german: "Fotos wird geprüft")
        await projector.stop()
    }

    func testMixedRechecksKeepOrdinaryWaitingDetailsAndTheirRetryActionRules() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var marker = entry(id: "dismissed", state: .discovered)
        marker.updatedAt = now.addingTimeInterval(600)
        marker.lastError = BackupIssueRecord(kind: .sourceMissing, detail: "source unavailable").persistedValue
        var draft = entry(id: "draft", state: .blockedByDraft)
        draft.updatedAt = now.addingTimeInterval(300)
        draft.lastError =
            BackupIssueRecord(
                kind: .remoteDraft, detail: "pending upload", nextAttemptAt: draft.updatedAt
            ).persistedValue
        XCTAssertTrue(queue.upsert(marker))
        XCTAssertTrue(queue.upsert(draft))
        let projector = BackupStatusProjector(queue: queue, now: { now })
        let recorder = Recorder()
        await projector.start(generation: UUID(), context: .init()) { recorder.append($0) }
        let projection = try XCTUnwrap(recorder.values.last)
        let display = BackupStatusPresentation(projection.status)
        XCTAssertEqual(projection.progress.pendingSourceRechecks, 1)
        XCTAssertEqual(projection.status.outstandingCount, 2)
        XCTAssertEqual(display.headlineKey, "backup.phase_waiting_draft")
        XCTAssertEqual(display.waitingCount, 1)
        XCTAssertNotNil(display.localizedWaitingDetail)
        XCTAssertEqual(display.nextAttemptAt, draft.updatedAt)
        var failures: [BackupFailedItem] = []
        queue.forEachProblemEntry {
            failures.append(BackupFailedItem(entry: $0))
            return true
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.issue, .remoteDraft)
        XCTAssertFalse(failures.offersUserRetry)
        await projector.stop()
    }

    func testRemoteIndexFailureStillNamesProtonWithoutAnEmptyPerPhotoList() async throws {
        var marker = entry(id: "dismissed", state: .discovered)
        marker.lastError = BackupIssueRecord(kind: .sourceMissing, detail: "source unavailable").persistedValue
        XCTAssertTrue(queue.upsert(marker))
        XCTAssertTrue(
            queue.setRuntimeIssue(
                BackupIssueRecord(kind: .remoteService, detail: "service unavailable"),
                for: .remoteIndexPreparation))
        let projector = BackupStatusProjector(queue: queue)
        let recorder = Recorder()
        await projector.start(generation: UUID(), context: .init()) { recorder.append($0) }
        let projection = try XCTUnwrap(recorder.values.last)
        let display = BackupStatusPresentation(projection.status)
        XCTAssertEqual(projection.status.outstandingCount, 1)
        XCTAssertEqual(display.headlineKey, "backup.phase_waiting_proton")
        XCTAssertNotNil(display.localizedSystemIssue)
        XCTAssertNil(display.localizedWaitingDetail)
        XCTAssertNil(display.localizedAttention)
        await projector.stop()
    }

    func testPhotosRecheckWordingPreservesPauseScanAndRemoteIndexPrecedence() {
        var progress = BackupSyncProgress()
        progress.total = 2
        progress.uploaded = 1
        progress.dismissedFailures = 1
        progress.pendingSourceRechecks = 1
        progress.outstanding = .init(count: 1, issue: .sourceMissing)
        XCTAssertEqual(BackupStatus(progress: progress, isScanning: true).titleKey, "backup.phase_scanning")
        XCTAssertEqual(
            BackupStatus(progress: progress, isScanning: false, isUserPaused: true).titleKey, "backup.phase_paused")
        progress.isRunning = true
        progress.isPausedByPolicy = true
        XCTAssertEqual(BackupStatus(progress: progress, isScanning: false).titleKey, "backup.phase_paused")
        progress.isWaitingForWiFi = true
        XCTAssertEqual(BackupStatus(progress: progress, isScanning: false).titleKey, "backup.phase_waiting_wifi")
        progress.isPausedByPolicy = false
        progress.isWaitingForWiFi = false
        progress.remoteIndexPreparation = .init(phase: .loading)
        let preparing = BackupStatus(progress: progress, isScanning: false)
        XCTAssertEqual(preparing.titleKey, "backup.phase_checking")
        XCTAssertEqual(BackupStatusPresentation(preparing).headlineKey, "backup.phase_checking")
        XCTAssertNotNil(preparing.localizedDetail)
        progress.remoteIndexPreparation = nil
        progress.isRunning = false
        progress.remoteIndexPreparationFailed = true
        let failed = BackupStatusPresentation(BackupStatus(progress: progress, isScanning: false))
        XCTAssertEqual(failed.headlineKey, "backup.phase_waiting")
        XCTAssertNotNil(failed.localizedSystemIssue)
        progress.remoteIndexPreparationFailed = false
        progress.remoteIndexPreparationIssue = .init(kind: .remoteService, detail: "service unavailable")
        let issue = BackupStatusPresentation(BackupStatus(progress: progress, isScanning: false))
        XCTAssertEqual(issue.headlineKey, "backup.phase_waiting_proton")
    }

    func testOrdinaryCheckingKeepsItsWordingBesideADismissedRecheck() {
        var progress = BackupSyncProgress()
        progress.total = 2
        progress.dismissedFailures = 1
        progress.pendingSourceRechecks = 1
        progress.waiting = 1
        progress.outstanding = .init(count: 2)
        progress.isRunning = true
        let status = BackupStatus(progress: progress, isScanning: false)
        XCTAssertEqual(status.titleKey, "backup.phase_checking")
        XCTAssertEqual(BackupStatusPresentation(status).headlineKey, "backup.phase_checking")
        XCTAssertNotNil(status.localizedDetail)
    }

    private func assertPhotosWording(
        _ display: BackupStatusPresentation, english: String, german: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for (language, expected) in [("en", english), ("de", german)] {
            let bundle = L10n.resourceBundle
            let value: String?
            if let path = bundle.path(forResource: language, ofType: "lproj"),
                let localized = Bundle(path: path)
            {
                value = localized.localizedString(forKey: display.headlineKey, value: nil, table: nil)
            } else {
                // SwiftPM copies the catalog as data; Xcode compiles it into language bundles.
                let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "xcstrings"))
                let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                let strings = catalog["strings"] as? [String: Any]
                let entry = strings?[display.headlineKey] as? [String: Any]
                let localizations = entry?["localizations"] as? [String: Any]
                let localization = localizations?[language] as? [String: Any]
                let unit = localization?["stringUnit"] as? [String: Any]
                value = unit?["value"] as? String
            }
            XCTAssertEqual(value, expected, language, file: file, line: line)
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func entry(
        id: String,
        state: UploadBackupSyncQueueState
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(
                kind: .photoLibraryAsset,
                identifier: id,
                resource: .primary
            ),
            revision: UploadBackupRevision(date: Date(timeIntervalSinceReferenceDate: 42)),
            originalFilename: "\(id).heic",
            state: state,
            updatedAt: Date()
        )
    }
}
