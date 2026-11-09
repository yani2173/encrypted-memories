import Foundation
import XCTest

@testable import PhotosCore

/// The persistent record of the OS background windows: what came, and how each window ended.
final class BackgroundWindowLedgerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundWindowLedgerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("EncryptedMemories/background-windows-v1.json") }

    private func makeLedger(
        diagnostics: PhotoDiagnostics = PhotoDiagnostics(debugConsoleLogsEnabled: false),
        isPurgePending: @escaping @Sendable () -> Bool = { false },
        log: BackgroundWorkLog = BackgroundWorkLog { _, _ in }
    ) -> BackgroundWindowLedger {
        BackgroundWindowLedger(fileURL: fileURL, diagnostics: diagnostics, isPurgePending: isPurgePending, log: log)
    }

    /// Minute `index` after a fixed start.
    private func minute(_ index: Int) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 60)
    }

    private func record(
        _ ledger: BackgroundWindowLedger, _ outcome: BackgroundWindowOutcome,
        kind: BackgroundWindowKind = .photoBackup, at date: Date
    ) {
        ledger.end(ledger.begin(kind, at: date), with: outcome)
    }

    // MARK: - The device log

    func testEachWindowLogsItsStartAndItsEndOnce() {
        let lines = BackgroundLogLines()
        let ledger = makeLedger(log: BackgroundWorkLog { lines.append("\($0.rawValue) \($1)") })
        let backup = ledger.begin(.photoBackup, at: minute(0))
        let search = ledger.begin(.smartSearch, at: minute(0))
        ledger.end(backup, with: .expired)
        ledger.end(backup, with: .ran)
        ledger.end(search, with: .ran)

        XCTAssertEqual(
            lines.values,
            [
                "PhotoBackupBackground window.began kind=photoBackup",
                "SmartSearchBackground window.began kind=smartSearch",
                "PhotoBackupBackground window.ended kind=photoBackup outcome=expired",
                "SmartSearchBackground window.ended kind=smartSearch outcome=ran",
            ], "a second end of the same window logs nothing")
    }

    // MARK: - The record

    func testAWindowStartsAsUnfinishedUntilItsEndNamesTheOutcome() {
        let ledger = makeLedger()
        let started = ledger.begin(.smartSearch, at: minute(0))

        XCTAssertEqual(
            ledger.records(), [BackgroundWindowRecord(kind: .smartSearch, outcome: .unfinished, startedAt: minute(0))],
            "a process that iOS ends during the window leaves an unfinished window, not none")
        ledger.end(started, with: .ran)
        XCTAssertEqual(
            ledger.records(), [BackgroundWindowRecord(kind: .smartSearch, outcome: .ran, startedAt: minute(0))])
    }

    func testTheRecordHoldsOnlyTheKindTheOutcomeAndTheMinute() throws {
        let ledger = makeLedger()
        record(ledger, .ran, at: minute(3).addingTimeInterval(59.9))

        XCTAssertEqual(ledger.records().first?.startedAt, minute(3), "the time is rounded down to the minute")
        let file = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let records = try XCTUnwrap(file["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(Set(records[0].keys), ["kind", "outcome", "startedAt"])
        XCTAssertEqual(records[0]["kind"] as? String, "photoBackup")
        XCTAssertEqual(records[0]["outcome"] as? String, "ran")
    }

    func testTheLedgerKeepsTheNewestWindowsAndDropsTheOldestFirst() {
        let ledger = makeLedger()
        for index in 0...BackgroundWindowLedger.limit {
            record(ledger, .ran, at: minute(index))
        }

        let records = ledger.records()
        XCTAssertEqual(BackgroundWindowLedger.limit, 200)
        XCTAssertEqual(records.count, 200)
        XCTAssertEqual(records.first?.startedAt, minute(1), "the oldest window goes first")
        XCTAssertEqual(records.last?.startedAt, minute(200))
    }

    func testTheEndOfAWindowWhoseStartWasDroppedIsStillRecorded() {
        let ledger = makeLedger()
        let early = ledger.begin(.photoBackup, at: minute(0))
        for index in 1...BackgroundWindowLedger.limit {
            record(ledger, .ran, at: minute(index))
        }

        ledger.end(early, with: .expired)

        let records = ledger.records()
        XCTAssertEqual(records.count, 200)
        XCTAssertEqual(records.first?.startedAt, minute(2))
        XCTAssertEqual(
            records.last, BackgroundWindowRecord(kind: .photoBackup, outcome: .expired, startedAt: minute(0)))
    }

    func testRecordsAreInTheOrderInWhichTheirWindowsEnded() {
        let ledger = makeLedger()
        let first = ledger.begin(.photoBackup, at: minute(0))
        let second = ledger.begin(.smartSearch, at: minute(1))

        ledger.end(second, with: .ran)
        ledger.end(first, with: .expired)

        XCTAssertEqual(
            ledger.records(),
            [
                BackgroundWindowRecord(kind: .smartSearch, outcome: .ran, startedAt: minute(1)),
                BackgroundWindowRecord(kind: .photoBackup, outcome: .expired, startedAt: minute(0)),
            ])
    }

    func testTheLimitDropsTheWindowThatEndedFirstNotTheOneThatStartedFirst() {
        let ledger = makeLedger()
        let long = ledger.begin(.photoBackup, at: minute(0))
        for index in 1..<BackgroundWindowLedger.limit {
            record(ledger, .ran, at: minute(index))
        }
        ledger.end(long, with: .expired)

        record(ledger, .ran, at: minute(BackgroundWindowLedger.limit))

        let records = ledger.records()
        XCTAssertEqual(records.count, 200)
        XCTAssertEqual(records.first?.startedAt, minute(2), "the window that ended first goes first")
        XCTAssertTrue(
            records.contains(BackgroundWindowRecord(kind: .photoBackup, outcome: .expired, startedAt: minute(0))),
            "the long window ended late, so it stays")
    }

    func testAnOpenWindowIsNeverTakenForAFinishedOneOfTheSameMinute() {
        let ledger = makeLedger()
        let first = ledger.begin(.photoBackup, at: minute(0))
        record(ledger, .failed, at: minute(0))
        let later = ledger.begin(.photoBackup, at: minute(0))

        ledger.end(first, with: .failed)

        XCTAssertEqual(
            ledger.records(),
            [
                BackgroundWindowRecord(kind: .photoBackup, outcome: .failed, startedAt: minute(0)),
                later.record,
                BackgroundWindowRecord(kind: .photoBackup, outcome: .failed, startedAt: minute(0)),
            ],
            "the later window stays open at the place of its start")
        XCTAssertEqual(later.record.outcome, .unfinished)
    }

    func testTheLaterOfTwoAlikeOpenWindowsEndsItsOwnRecord() {
        let ledger = makeLedger()
        let first = ledger.begin(.photoBackup, at: minute(0))
        record(ledger, .ran, kind: .smartSearch, at: minute(0))
        let later = ledger.begin(.photoBackup, at: minute(0))

        ledger.end(later, with: .ran)

        XCTAssertEqual(
            ledger.records(),
            [
                first.record,
                BackgroundWindowRecord(kind: .smartSearch, outcome: .ran, startedAt: minute(0)),
                BackgroundWindowRecord(kind: .photoBackup, outcome: .ran, startedAt: minute(0)),
            ],
            "the earlier window, whose end never comes, keeps the place of its start")
    }

    func testASecondEndOfTheSameWindowWritesNothing() {
        let ledger = makeLedger()
        let started = ledger.begin(.photoBackup, at: minute(0))

        ledger.end(started, with: .ran)
        ledger.end(started, with: .expired)

        XCTAssertEqual(
            ledger.records(), [BackgroundWindowRecord(kind: .photoBackup, outcome: .ran, startedAt: minute(0))])
    }

    func testAStartWhoseWriteFailedWritesNothingAtItsEnd() throws {
        // Only this test's own temporary folder is made read-only, and its mode is restored on every exit.
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        var restored = false
        defer {
            if !restored {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            }
        }
        let ledger = makeLedger()
        let started = ledger.begin(.photoBackup, at: minute(0))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        restored = true
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "the start could not write")

        ledger.end(started, with: .ran)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "an unrecorded start writes nothing")
    }

    func testTwoWindowsOfTheSameMinuteEachKeepTheirOwnOutcome() {
        let ledger = makeLedger()
        let first = ledger.begin(.photoBackup, at: minute(0))
        let second = ledger.begin(.photoBackup, at: minute(0))

        ledger.end(second, with: .ran)
        ledger.end(first, with: .expired)

        XCTAssertEqual(ledger.records().map(\.outcome).sorted { $0.rawValue < $1.rawValue }, [.expired, .ran])
    }

    // MARK: - The file

    func testTheRecordsSurviveANewLedgerOnTheSameFile() {
        record(makeLedger(), .notNeeded, kind: .smartSearch, at: minute(0))

        XCTAssertEqual(
            makeLedger().records(),
            [BackgroundWindowRecord(kind: .smartSearch, outcome: .notNeeded, startedAt: minute(0))])
    }

    func testADamagedFileStartsAnEmptyLedgerAndCountsTheReset() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a ledger".utf8).write(to: fileURL)
        let diagnostics = PhotoDiagnostics(debugConsoleLogsEnabled: false)
        let ledger = makeLedger(diagnostics: diagnostics)

        record(ledger, .ran, at: minute(0))

        XCTAssertEqual(
            ledger.records(), [BackgroundWindowRecord(kind: .photoBackup, outcome: .ran, startedAt: minute(0))])
        XCTAssertEqual(diagnostics.supportSnapshot().counters, ["backgroundWindows.ledgerReset": 1])
    }

    func testAFileThatCannotBeReadSkipsTheRecordAndKeepsTheFile() throws {
        let earlier = BackgroundWindowRecord(kind: .smartSearch, outcome: .expired, startedAt: minute(0))
        record(makeLedger(), .expired, kind: .smartSearch, at: minute(0))
        // A file without read permission cannot be read. Its content is not known, so nothing may overwrite it.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fileURL.path)
        let diagnostics = PhotoDiagnostics(debugConsoleLogsEnabled: false)
        let ledger = makeLedger(diagnostics: diagnostics)

        record(ledger, .ran, at: minute(1))

        XCTAssertEqual(ledger.records(), [], "the report shows nothing it cannot read")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        XCTAssertEqual(ledger.records(), [earlier], "the unreadable file keeps its records")
        XCTAssertEqual(diagnostics.supportSnapshot().counters, [:], "an unreadable file is not a damaged file")
    }

    func testTheFileIsWrittenAtomicallyWithoutFileProtection() {
        // The Simulator and macOS do not report file protection, so the test reads the options of the write.
        XCTAssertTrue(BackgroundWindowLedger.fileWriteOptions.contains(.noFileProtection))
        XCTAssertTrue(BackgroundWindowLedger.fileWriteOptions.contains(.atomic))
    }

    func testAPendingSignOutPurgeRecordsNothing() {
        let ledger = makeLedger(isPurgePending: { true })

        record(ledger, .ran, at: minute(0))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(ledger.records(), [])
    }

    // MARK: - Sign-out

    /// A test defaults suite and the test root that holds the ledger file, for the real purge calls.
    private func makePurge() throws -> (suite: String, roots: [URL]) {
        let suite = "BackgroundWindowLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (suite, [fileURL.deletingLastPathComponent()])
    }

    private func makeLedger(purgeSuite suite: String) -> BackgroundWindowLedger {
        makeLedger(isPurgePending: { BackupLocalDataPurge.isPurgePending(defaults: UserDefaults(suiteName: suite)!) })
    }

    func testAWindowThatEndsAfterASignOutPurgeDoesNotBringTheFileBack() throws {
        let purge = try makePurge()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: purge.suite))
        let ledger = makeLedger(purgeSuite: purge.suite)
        let started = ledger.begin(.photoBackup, at: minute(0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        XCTAssertTrue(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: purge.roots))
        ledger.end(started, with: .ran)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path))
    }

    func testAWindowThatEndsWhileASignOutPurgeIsPendingWritesNothing() throws {
        let purge = try makePurge()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: purge.suite))
        let ledger = makeLedger(purgeSuite: purge.suite)
        let started = ledger.begin(.photoBackup, at: minute(0))

        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        ledger.end(started, with: .ran)

        XCTAssertEqual(ledger.records(), [started.record], "the start stays unfinished until the purge removes it")
        XCTAssertTrue(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: purge.roots))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    #if DEBUG
        func testAWindowThatStartsRightAfterTheSignOutFlagWritesNothingAfterThePurge() throws {
            let purge = try makePurge()
            let defaults = try XCTUnwrap(UserDefaults(suiteName: purge.suite))
            let ledger = makeLedger(purgeSuite: purge.suite)
            let started = LockedValue<BackgroundWindowStart>()
            let startedAt = minute(0)
            BackupLocalDataPurge.afterPendingMarkForTesting = { started.set(ledger.begin(.photoBackup, at: startedAt)) }
            defer { BackupLocalDataPurge.afterPendingMarkForTesting = nil }

            BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
            XCTAssertTrue(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: purge.roots))
            ledger.end(try XCTUnwrap(started.value), with: .ran)

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fileURL.path),
                "a window that starts between the flag and the generation must not bring the file back")
        }
    #endif

    func testAWindowThatStartsWhileASignOutPurgeIsPendingWritesNothingAtItsEnd() throws {
        let purge = try makePurge()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: purge.suite))
        let ledger = makeLedger(purgeSuite: purge.suite)
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let started = ledger.begin(.photoBackup, at: minute(0))

        BackupLocalDataPurge.markPurgeCompleted(defaults: defaults)
        ledger.end(started, with: .ran)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testTheFileLivesInTheLocalDataThatSignOutRemoves() throws {
        let file = try XCTUnwrap(BackgroundWindowLedger.defaultFileURL)
        let roots = BackupLocalDataPurge.localDataRoots()
        XCTAssertTrue(
            roots.contains { file.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") },
            "\(file.lastPathComponent) must be inside a sign-out root")
    }

    // MARK: - Outcomes

    func testTheOSHearsSuccessOnlyWhenTheWindowRanOrHadNothingToDo() {
        let successful = BackgroundWindowOutcome.allCases.filter(\.reportsSuccess)
        XCTAssertEqual(Set(successful), [.ran, .notNeeded])
        XCTAssertEqual(BackgroundWindowOutcome.allCases.count, 8)
    }

    func testTheEndOfTheWorkMapsExpiryFirstThenCompletion() {
        XCTAssertEqual(BackgroundWindowOutcome.afterWork(didExpire: false, didComplete: true), .ran)
        XCTAssertEqual(BackgroundWindowOutcome.afterWork(didExpire: false, didComplete: false), .failed)
        XCTAssertEqual(BackgroundWindowOutcome.afterWork(didExpire: true, didComplete: false), .expired)
        XCTAssertEqual(
            BackgroundWindowOutcome.afterWork(didExpire: true, didComplete: true), .expired,
            "a window that expired never counts as a run, even when its work returned")
    }

    // MARK: - The end of a window

    func testAWindowEndsOnceItRecordsOneOutcomeAndTellsTheOSOnce() {
        let ledger = makeLedger()
        let reports = LockedValue<[Bool]>()
        reports.set([])
        let completion = BackgroundWindowCompletion(kind: .photoBackup, ledger: ledger, startedAt: minute(0)) {
            success in reports.set((reports.value ?? []) + [success])
        }

        XCTAssertEqual(ledger.records().map(\.outcome), [.unfinished], "the window is recorded when it starts")
        completion.finish(.notNeeded)
        completion.finish(.expired)

        XCTAssertEqual(reports.value, [true])
        XCTAssertEqual(
            ledger.records(), [BackgroundWindowRecord(kind: .photoBackup, outcome: .notNeeded, startedAt: minute(0))])
    }

    func testAnExpiredWindowTellsTheOSItFailed() {
        let ledger = makeLedger()
        let reports = LockedValue<[Bool]>()
        reports.set([])
        let completion = BackgroundWindowCompletion(kind: .smartSearch, ledger: ledger, startedAt: minute(0)) {
            success in reports.set((reports.value ?? []) + [success])
        }

        XCTAssertFalse(completion.didExpire)
        completion.markExpired()
        XCTAssertTrue(completion.didExpire)
        completion.finish(.expired)

        XCTAssertEqual(reports.value, [false])
        XCTAssertEqual(ledger.records().map(\.outcome), [.expired])
    }

    func testAWindowEndsOnlyAfterItsWaitReturned() async {
        let ledger = makeLedger()
        let reports = LockedValue<[Bool]>()
        reports.set([])
        let completion = BackgroundWindowCompletion(kind: .photoBackup, ledger: ledger, startedAt: minute(0)) {
            success in reports.set((reports.value ?? []) + [success])
        }
        let waiting = AsyncTestSignal()
        let release = AsyncTestSignal()

        let finishing = Task {
            await completion.finish(
                .ran,
                after: {
                    waiting.fire()
                    await release.wait()
                })
        }
        await awaitWindowEvent(waiting, "the wait")
        XCTAssertEqual(reports.value, [], "the OS hears nothing while the wait runs")
        XCTAssertEqual(ledger.records().map(\.outcome), [.unfinished])
        release.fire()
        await finishing.value

        XCTAssertEqual(reports.value, [true])
        XCTAssertEqual(ledger.records().map(\.outcome), [.ran])
    }

    func testAnExpiryDuringTheEndWaitIsRecordedWhileTheEarlierSuccessStays() async {
        let ledger = makeLedger()
        let reports = LockedValue<[Bool]>()
        reports.set([])
        let completion = BackgroundWindowCompletion(kind: .smartSearch, ledger: ledger, startedAt: minute(0)) {
            success in reports.set((reports.value ?? []) + [success])
        }

        // The work finished uncancelled, so its success is true; the window expires while the end waits.
        await completion.finish(
            after: { completion.markExpired() },
            deciding: { (BackgroundWindowOutcome.ran.afterTheEndWait(didExpire: completion.didExpire), true) })

        XCTAssertEqual(ledger.records().map(\.outcome), [.expired], "the ledger records the expiry")
        XCTAssertEqual(reports.value, [true], "the OS hears the success of the finished work")
    }

    func testAnExpiryAfterTheWorkOnlyTurnsARunIntoAnExpiry() {
        XCTAssertEqual(BackgroundWindowOutcome.ran.afterTheEndWait(didExpire: true), .expired)
        XCTAssertEqual(BackgroundWindowOutcome.notNeeded.afterTheEndWait(didExpire: true), .expired)
        XCTAssertEqual(BackgroundWindowOutcome.failed.afterTheEndWait(didExpire: true), .failed)
        XCTAssertEqual(BackgroundWindowOutcome.ran.afterTheEndWait(didExpire: false), .ran)
        XCTAssertEqual(BackgroundWindowOutcome.notNeeded.afterTheEndWait(didExpire: false), .notNeeded)
    }

    func testAHandlerCanKeepItsEarlierSuccessForAnOutcome() {
        let ledger = makeLedger()
        let reports = LockedValue<[Bool]>()
        reports.set([])
        let completion = BackgroundWindowCompletion(kind: .smartSearch, ledger: ledger, startedAt: minute(0)) {
            success in reports.set((reports.value ?? []) + [success])
        }

        completion.finish(.expired, reportsSuccess: true)

        XCTAssertEqual(reports.value, [true])
        XCTAssertEqual(ledger.records().map(\.outcome), [.expired])
    }

    // MARK: - The support report

    func testTheSupportSnapshotCountsEachKindAndOutcomeAndListsTheRecords() {
        let ledger = makeLedger()
        record(ledger, .ran, kind: .photoBackup, at: minute(0))
        record(ledger, .expired, kind: .photoBackup, at: minute(1))
        record(ledger, .ran, kind: .smartSearch, at: minute(2))
        record(ledger, .ran, kind: .photoBackup, at: minute(3))

        let snapshot = ledger.supportSnapshot()

        XCTAssertEqual(
            snapshot.counts,
            [
                .init(kind: .photoBackup, outcome: .expired, count: 1),
                .init(kind: .photoBackup, outcome: .ran, count: 2),
                .init(kind: .smartSearch, outcome: .ran, count: 1),
            ])
        XCTAssertEqual(snapshot.records, ledger.records())
    }

    func testTheSupportReportHasTheBackgroundWindowSection() async throws {
        let ledger = makeLedger()
        record(ledger, .ran, kind: .photoBackup, at: minute(0).addingTimeInterval(42))
        record(ledger, .expired, kind: .smartSearch, at: minute(1))
        let runtime = LibraryRuntimeState(initial: LibraryRuntimeSnapshot())

        let data = try await SupportDiagnosticsExporter.makeJSONData(
            runtimeState: runtime,
            resourceCoordinator: LibraryResourceCoordinator(runtimeState: runtime),
            diagnostics: PhotoDiagnostics(debugConsoleLogsEnabled: false),
            bundle: Bundle(for: Self.self),
            backgroundWindows: ledger
        )

        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["schemaVersion"] as? Int, 4)
        let section = try XCTUnwrap(report["backgroundWindows"] as? [String: Any])
        XCTAssertEqual(Set(section.keys), ["counts", "records"])
        let records = try XCTUnwrap(section["records"] as? [[String: Any]])
        XCTAssertEqual(records.map { $0["kind"] as? String }, ["photoBackup", "smartSearch"])
        XCTAssertEqual(records.map { $0["outcome"] as? String }, ["ran", "expired"])
        XCTAssertEqual(
            records.map { Set($0.keys) }, [["kind", "outcome", "startedAt"], ["kind", "outcome", "startedAt"]])
        XCTAssertEqual(records.first?["startedAt"] as? String, "2027-01-15T08:00:00Z")
        let counts = try XCTUnwrap(section["counts"] as? [[String: Any]])
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(counts.map { Set($0.keys) }, [["kind", "outcome", "count"], ["kind", "outcome", "count"]])
    }
}
