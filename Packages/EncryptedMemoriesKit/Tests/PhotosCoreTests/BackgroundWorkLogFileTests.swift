import Foundation
import XCTest

@testable import PhotosCore

/// The background log on the device, which the support file carries (#976).
final class BackgroundWorkLogFileTests: XCTestCase {
    private final class Service: Sendable {}

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundWorkLogFileTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("EncryptedMemories/background-log-v1.txt") }

    private func makeFile(
        limit: Int = BackgroundWorkLogFile.limit, trimTarget: Int = BackgroundWorkLogFile.trimTarget,
        isPurgePending: @escaping @Sendable () -> Bool = { false }
    ) -> BackgroundWorkLogFile {
        BackgroundWorkLogFile(fileURL: fileURL, limit: limit, trimTarget: trimTarget, isPurgePending: isPurgePending)
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testLinesKeepTheirOrderAndTheirTime() {
        let file = makeFile()
        file.append("PhotoBackupBackground window.began kind=photoBackup", at: start)
        file.append(
            "PhotoBackupBackground window.ended kind=photoBackup outcome=ran", at: start.addingTimeInterval(1.5))

        XCTAssertEqual(
            file.export(),
            .init(
                lines: [
                    "2027-01-15T08:00:00.000Z PhotoBackupBackground window.began kind=photoBackup",
                    "2027-01-15T08:00:01.500Z PhotoBackupBackground window.ended kind=photoBackup outcome=ran",
                ], droppedLines: 0))
    }

    func testTheFileKeepsItsBoundAndDropsTheOldestLines() throws {
        let file = makeFile(limit: 600, trimTarget: 400)
        for index in 0..<40 {
            file.append("PhotoBackupBackground pass.progress completed=\(index)", at: start)
        }
        let export = file.export()
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)

        XCTAssertLessThanOrEqual(size, 600, "the file never stays above its bound")
        XCTAssertGreaterThan(export.droppedLines, 0)
        XCTAssertEqual(export.lines.count + export.droppedLines, 40, "every line is kept or counted")
        XCTAssertEqual(export.lines.last?.hasSuffix("completed=39"), true, "the newest lines stay")
        let kept = export.lines.compactMap { Int($0.split(separator: "=").last ?? "") }
        XCTAssertEqual(kept, Array((40 - kept.count)..<40), "the kept lines are the newest, in order")
    }

    func testLinesFromSeveralThreadsAreAllKept() {
        let file = makeFile()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            file.append("SmartSearchBackground window.began kind=smartSearch n=\(index)", at: start)
        }
        let numbers = Set(file.export().lines.compactMap { Int($0.split(separator: "=").last ?? "") })
        XCTAssertEqual(numbers, Set(0..<200))
    }

    func testAPendingSignOutPurgeWritesNothing() {
        let file = makeFile(isPurgePending: { true })
        file.append("PhotoBackupBackground window.began kind=photoBackup", at: start)
        XCTAssertEqual(file.export(), .init(lines: [], droppedLines: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "the purge cannot find the file again")
    }

    func testTheFileHasNoDataProtectionAndLivesWhereTheSignOutPurgeDeletes() throws {
        XCTAssertTrue(
            BackgroundWorkLogFile.fileWriteOptions.contains(.noFileProtection),
            "a window before the first unlock after a restart must write its lines")
        let url = try XCTUnwrap(BackgroundWorkLogFile.defaultFileURL)
        XCTAssertTrue(
            BackupLocalDataPurge.localDataRoots().contains { url.path.hasPrefix($0.path + "/") },
            "the sign-out purge deletes the file")
    }

    func testAProcessThatIsNoAppKeepsNoFile() {
        XCTAssertNil(
            BackgroundWorkLogFile.shared.fileURL, "the package test runner must not write into the home folder")
    }

    func testAFileThatDoesNotOpenKeepsItsLines() throws {
        let file = makeFile()
        file.append("PhotoBackupBackground window.began kind=photoBackup", at: start)
        _ = file.export()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }
        file.append("PhotoBackupBackground window.ended kind=photoBackup outcome=ran", at: start)

        XCTAssertEqual(
            file.export().lines, ["2027-01-15T08:00:00.000Z PhotoBackupBackground window.began kind=photoBackup"],
            "a write that cannot open the file never replaces it")
    }

    func testEveryStoredLineHoldsOnlyTheFixedGrammar() {
        let file = makeFile()
        let log = BackgroundWorkLog.persisting(to: file)
        log.notice(.photoBackup, "window.began", [(.init("kind"), .name(BackgroundWindowKind.photoBackup))])
        log.accountWait(.libraryRefresh, BackgroundAccountWait<Service>.notReady, waited: .milliseconds(12))
        log.requestSubmitted(.smartSearch, earliestBegin: nil, errorCode: 3)
        let grammar =
            #/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z [A-Za-z]+ [a-z]+\.[A-Za-z]+( [A-Za-z]+(\.[A-Za-z]+)?=[A-Za-z0-9-]+)*$/#
        let lines = file.export().lines
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            XCTAssertNotNil(line.wholeMatch(of: grammar), line)
        }
    }
}
