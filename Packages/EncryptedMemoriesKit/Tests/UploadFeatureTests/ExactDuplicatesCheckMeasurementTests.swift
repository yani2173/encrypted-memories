import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Measures the check and the first ranking of the Duplicates screen with 1,500 groups through the real finder and
/// the real model. Runs only with `DUPLICATES_MEASURE=1` and prints the median of five rounds. With
/// `DUPLICATES_MEASURE_MIXED=1`, the last copy of every fifth group has other metadata, so those groups split.
@MainActor
final class ExactDuplicatesCheckMeasurementTests: XCTestCase {
    static let groupCount = 1_500
    static let rounds = 5

    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DUPLICATES_MEASURE"] == "1", "set DUPLICATES_MEASURE=1")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicates-measure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testMeasureTheCheckAndTheFirstRankingOfALargeLibrary() async throws {
        let store = try XCTUnwrap(
            UploadIdentityManifestStore(
                url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        let server = EditScenarioServer()
        let mixed = ProcessInfo.processInfo.environment["DUPLICATES_MEASURE_MIXED"] == "1"
        let described = ExactDuplicateFingerprint(
            captureTime: Date(timeIntervalSince1970: 1_720_000_000), latitude: 10.5, longitude: -20.25,
            device: "Test Camera", pixelWidth: 4000, pixelHeight: 3000, mimeType: "image/heic")
        for index in 0..<Self.groupCount {
            var digest = Data(repeating: 0, count: 20)
            withUnsafeBytes(of: UInt32(index).bigEndian) { digest.replaceSubrange(0..<4, with: $0) }
            // Every third group has three copies, the others two.
            let copies = server.seedLinks(digests: Array(repeating: digest, count: index % 3 == 0 ? 3 : 2))
            guard mixed else { continue }
            for copy in copies { server.setFingerprint(described, of: copy) }
            if index % 5 == 0, let last = copies.last {
                server.setFingerprint(ExactDuplicateFingerprint(captureTime: described.captureTime), of: last)
            }
        }
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                server.links.map {
                    UploadRemoteContentIndexRecord(
                        contentHash: $0.contentHash, hashKeyEpoch: "scenario-epoch", remoteLinkID: $0.linkID)
                }, unresolvedIssues: [], hashKeyEpoch: "scenario-epoch",
                checkpoint: .init(eventID: "event-1", refreshedAt: Date())))
        let finder = ExactDuplicateFinder(
            checker: server, resolver: UploadDedupePipeline(store: store, checker: server, replacementJournal: journal),
            index: store, identities: store, journal: journal,
            mergeJournal: ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory), remote: server,
            albums: server)

        var scans: [Duration] = []
        var checks: [Duration] = []
        var rankings: [Duration] = []
        var shownGroups = 0
        var shownCopies = 0
        for _ in 0..<Self.rounds {
            let clock = ContinuousClock()
            var start = clock.now
            let scan = try await finder.duplicateGroups()
            scans.append(start.duration(to: .now))
            XCTAssertEqual(scan.groups.count, Self.groupCount)

            let model = ExactDuplicatesModel(finder: finder)
            start = clock.now
            let load = Task { await model.load() }
            while model.content != .groups { await Task.yield() }
            checks.append(start.duration(to: .now))
            let shown = model.groupChanges
            // The first ranking reads the first two pages and publishes one change for each.
            while model.groupChanges < shown + 2 { await Task.yield() }
            rankings.append(start.duration(to: .now))
            shownGroups = model.groups.count
            shownCopies = model.copyCount
            await load.value
        }
        let report = [
            "groups: \(Self.groupCount), shown after the first ranking: \(shownGroups) with \(shownCopies) copies",
            "finder scan median: \(Self.ms(scans)) ms",
            "check until groups shown median: \(Self.ms(checks)) ms",
            "check until first ranking (2 pages) median: \(Self.ms(rankings)) ms",
        ].joined(separator: "\n")
        print(report)
    }

    private static func ms(_ durations: [Duration]) -> String {
        let median = durations.sorted()[durations.count / 2]
        let milliseconds =
            Double(median.components.seconds) * 1_000
            + Double(median.components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.1f", milliseconds)
    }
}
