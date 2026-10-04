import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

@MainActor
final class ExactDuplicatesModelTests: XCTestCase {
    private let a1 = PhotoUID(volumeID: "v", nodeID: "a1")
    private let a2 = PhotoUID(volumeID: "v", nodeID: "a2")
    private let a3 = PhotoUID(volumeID: "v", nodeID: "a3")
    private let b1 = PhotoUID(volumeID: "v", nodeID: "b1")
    private let b2 = PhotoUID(volumeID: "v", nodeID: "b2")

    private var groupA: ExactDuplicateGroup {
        ExactDuplicateGroup(contentHash: "A", hashKeyEpoch: "e", members: [a1, a2, a3])
    }
    private var groupB: ExactDuplicateGroup {
        ExactDuplicateGroup(contentHash: "B", hashKeyEpoch: "e", members: [b1, b2])
    }

    private func makeModel(_ finder: FakeDuplicateFinder) -> (ExactDuplicatesModel, TrashLog) {
        let log = TrashLog()
        let model = ExactDuplicatesModel(finder: finder) { log.calls.append($0) }
        return (model, log)
    }

    // MARK: - States

    func testLoadingUntilTheFirstScanFinishes() async {
        let (model, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)]))
        XCTAssertEqual(model.content, .loading)
        XCTAssertNil(model.knownDuplicateCount)
        await model.load()
        XCTAssertEqual(model.content, .groups)
        XCTAssertEqual(model.groups.map(\.id), ["A"])
        XCTAssertEqual(model.knownDuplicateCount, 2)
    }

    func testAnEmptyCompleteScanHasNoDuplicates() async {
        let (model, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [], coverage: .complete)]))
        await model.load()
        XCTAssertEqual(model.content, .noDuplicates)
        XCTAssertNil(model.stillCheckingNote)
        XCTAssertFalse(model.canMerge)
    }

    func testAnEmptyScanOfAnIndexThatIsNotCompleteSaysItIsStillChecking() async {
        for coverage in [ExactDuplicateCoverage.indexing, .incomplete(unresolvedCount: 3)] {
            let (model, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [], coverage: coverage)]))
            await model.load()
            XCTAssertEqual(model.content, .stillChecking, "\(coverage)")
            XCTAssertEqual(model.emptyStateCopy.title, L10n.string("duplicates.checking_title"), "\(coverage)")
            XCTAssertFalse(model.canMerge)
        }
        let (complete, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [], coverage: .complete)]))
        await complete.load()
        XCTAssertEqual(complete.emptyStateCopy, PhotoFilter.duplicates.emptyStateCopy)
    }

    func testAFailedScanShowsAShortReasonAndKeepsShownGroups() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        let (model, _) = makeModel(finder)
        finder.scanError = URLError(.notConnectedToInternet)
        await model.load()
        guard case .failed(let reason) = model.content else {
            return XCTFail("expected a failure, got \(model.content)")
        }
        XCTAssertFalse(reason.isEmpty)

        finder.scanError = nil
        await model.load()
        finder.scanError = URLError(.notConnectedToInternet)
        await model.load()
        XCTAssertEqual(model.content, .groups, "a failed refresh must not hide the groups already shown")
    }

    func testAFailedRankingFailsTheLoad() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.rankError = URLError(.timedOut)
        let (model, _) = makeModel(finder)
        await model.load()
        guard case .failed = model.content else { return XCTFail("expected a failure, got \(model.content)") }
        XCTAssertTrue(model.groups.isEmpty)
    }

    func testAnIncompleteOrIndexingScanShowsTheStillCheckingNoteWithItsGroups() async {
        for coverage in [ExactDuplicateCoverage.indexing, .incomplete(unresolvedCount: 3)] {
            let (model, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: coverage)]))
            await model.load()
            XCTAssertEqual(model.content, .groups, "\(coverage)")
            XCTAssertNotNil(model.stillCheckingNote, "\(coverage)")
        }
        let (complete, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)]))
        await complete.load()
        XCTAssertNil(complete.stillCheckingNote)
    }

    func testTheEntryCountScansWithoutRanking() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.loadCountIfNeeded()
        XCTAssertEqual(model.knownDuplicateCount, 3)
        XCTAssertEqual(finder.rankCalls, 0)
        await model.loadCountIfNeeded()
        XCTAssertEqual(finder.scanCalls, 1, "the entry counts once")
    }

    // MARK: - The photo to keep

    func testTheRankedFirstMemberIsKeptByDefault() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.ranked = ["A": [a3, a1, a2]]
        let (model, _) = makeModel(finder)
        await model.load()
        XCTAssertEqual(model.groups.first?.members, [a3, a1, a2])
        XCTAssertEqual(model.groups.first?.kept, a3)
    }

    func testTappingAnotherMemberKeepsItAndTheMergeUsesIt() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        model.keep(a2, inGroup: "A")
        model.keep(b1, inGroup: "A")
        XCTAssertEqual(model.groups.first?.kept, a2, "a photo of another group is never kept")
        await model.merge(groupID: "A")
        XCTAssertEqual(finder.merges.map(\.kept), [a2])
    }

    func testAChoiceSurvivesAReloadWhileItsPhotoIsStillAMember() async {
        let shrunk = ExactDuplicateGroup(contentHash: "A", hashKeyEpoch: "e", members: [a1, a3])
        let finder = FakeDuplicateFinder(scans: [
            .init(groups: [groupA], coverage: .complete), .init(groups: [groupA], coverage: .complete),
            .init(groups: [shrunk], coverage: .complete),
        ])
        let (model, _) = makeModel(finder)
        await model.load()
        model.keep(a2, inGroup: "A")
        await model.load()
        XCTAssertEqual(model.groups.first?.kept, a2)
        await model.load()
        XCTAssertEqual(model.groups.first?.kept, a1, "a choice that left the group falls back to the ranking")
    }

    // MARK: - Merge

    func testMergingOneGroupRemovesOnlyThatGroupAndHidesTheTrashedPhotos() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        let (model, log) = makeModel(finder)
        await model.load()
        await model.merge(groupID: "B")
        XCTAssertEqual(finder.merges.map(\.group), ["B"])
        XCTAssertEqual(model.groups.map(\.id), ["A"])
        XCTAssertEqual(log.calls, [[b2]])
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.knownDuplicateCount, 2)
        XCTAssertFalse(model.isMerging)
    }

    func testMergeAllMergesEveryGroupAndReportsTheTrashOnce() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        let (model, log) = makeModel(finder)
        await model.load()
        XCTAssertEqual(model.duplicateCount, 3, "Merge All asks for the photos that move to Recently Deleted")
        await model.mergeAll()
        XCTAssertEqual(Set(finder.merges.map(\.group)), ["A", "B"])
        XCTAssertEqual(model.content, .noDuplicates)
        XCTAssertEqual(log.calls.count, 1)
        XCTAssertEqual(Set(log.calls.first ?? []), [a2, a3, b2])
    }

    func testMergeAllHandsEveryGroupToTheFinderInOneBatch() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        await model.mergeAll()
        XCTAssertEqual(finder.batches, [["A", "B"]], "the finder reads the facts that the groups share once")
    }

    func testAKeptDuplicateGivesOneShortReasonAndTheGroupStaysWithIt() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.outcomes["A"] = .merged(
            kept: a1, trashed: [], keptDuplicates: [a2: .unreadable, a3: .neededByLocalSource])
        finder.outcomes["B"] = .merged(kept: b1, trashed: [], keptDuplicates: [b2: .relatedFileWithoutTwin])
        let (model, log) = makeModel(finder)
        await model.load()
        await model.merge(groupID: "A")
        XCTAssertEqual(model.notice, .keptDuplicates(count: 2, reason: .neededByLocalSource))
        XCTAssertEqual(model.groups.map(\.id), ["A", "B"])
        XCTAssertEqual(model.groups.first?.keptReason, .neededByLocalSource)
        XCTAssertEqual(model.groups.first?.keptReasonMessage, model.notice?.message)
        XCTAssertTrue(log.calls.isEmpty, "nothing moved to Recently Deleted")
        model.dismissNotice()
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.groups.first?.keptReason, .neededByLocalSource, "the reason stays with its group")

        await model.mergeAll()
        XCTAssertEqual(model.notice, .keptDuplicates(count: 3, reason: .relatedFileWithoutTwin))
        XCTAssertEqual(model.groups.last?.keptReason, .relatedFileWithoutTwin)
    }

    func testAMergeRemovesOnlyTheTrashedMembersAndThePersonCanKeepAnotherPhoto() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.outcomes["A"] = .merged(kept: a1, trashed: [a2], keptDuplicates: [a3: .pendingEditReplacement])
        let (model, log) = makeModel(finder)
        await model.load()
        await model.merge(groupID: "A")
        XCTAssertEqual(log.calls, [[a2]])
        XCTAssertEqual(model.groups.first?.members, [a1, a3])
        XCTAssertEqual(model.groups.first?.scanGroup.members, [a1, a3])
        XCTAssertEqual(model.groups.first?.kept, a1)
        XCTAssertEqual(model.groups.first?.keptReason, .pendingEditReplacement)
        XCTAssertEqual(model.knownDuplicateCount, 1)

        finder.outcomes["A"] = nil
        model.keep(a3, inGroup: "A")
        await model.merge(groupID: "A")
        XCTAssertEqual(finder.merges.last, .init(group: "A", kept: a3))
        XCTAssertEqual(log.calls, [[a2], [a1]])
        XCTAssertEqual(model.content, .noDuplicates)
    }

    func testEveryKeptReasonHasItsOwnMessage() {
        let reasons: [ExactDuplicateKeepReason] = [
            .relatedFileWithoutTwin, .pendingEditReplacement, .neededByLocalSource, .unreadable,
        ]
        let messages = Set(reasons.map { ExactDuplicateMergeNotice.keptDuplicates(count: 1, reason: $0).message })
        XCTAssertEqual(messages.count, reasons.count)
    }

    func testAFailedMergeKeepsTheGroupAndSaysSo() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.mergeErrors["A"] = URLError(.notConnectedToInternet)
        let (model, log) = makeModel(finder)
        await model.load()
        await model.mergeAll()
        XCTAssertEqual(model.groups.map(\.id), ["A"])
        XCTAssertEqual(model.notice, .failed)
        XCTAssertEqual(log.calls, [[b2]], "the merged group still leaves the library")
    }

    func testAnUnreadablePhotoToKeepLeavesTheGroupForAnotherChoice() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.outcomes["A"] = .skipped(.keptUnreadable)
        let (model, _) = makeModel(finder)
        await model.load()
        await model.merge(groupID: "A")
        XCTAssertEqual(model.groups.map(\.id), ["A"])
        XCTAssertEqual(model.notice, .keptPhotoUnreadable)
        XCTAssertEqual(finder.scanCalls, 1)
    }

    func testAGroupThatChangedSinceTheScanIsScannedAgain() async {
        let finder = FakeDuplicateFinder(scans: [
            .init(groups: [groupA], coverage: .complete), .init(groups: [], coverage: .complete),
        ])
        finder.outcomes["A"] = .skipped(.noDuplicateLeft)
        let (model, _) = makeModel(finder)
        await model.load()
        await model.merge(groupID: "A")
        XCTAssertEqual(finder.scanCalls, 2)
        XCTAssertEqual(model.content, .noDuplicates)
        XCTAssertNil(model.notice)
    }
}

@MainActor
private final class TrashLog {
    var calls: [[PhotoUID]] = []
}

/// Answers from memory. Without a configured outcome, a merge trashes every member except the kept one.
private final class FakeDuplicateFinder: ExactDuplicateMerging, @unchecked Sendable {
    struct Merge: Equatable {
        let group: String
        let kept: PhotoUID
    }

    private let lock = NSLock()
    private var scans: [ExactDuplicateScan]
    private var _scanCalls = 0
    private var _rankCalls = 0
    private var _merges: [Merge] = []
    private var _batches: [[String]] = []
    var ranked: [String: [PhotoUID]] = [:]
    var outcomes: [String: ExactDuplicateMergeOutcome] = [:]
    var mergeErrors: [String: Error] = [:]
    var scanError: Error?
    var rankError: Error?

    init(scans: [ExactDuplicateScan]) { self.scans = scans }

    var scanCalls: Int { lock.withLock { _scanCalls } }
    var rankCalls: Int { lock.withLock { _rankCalls } }
    var merges: [Merge] { lock.withLock { _merges } }
    var batches: [[String]] { lock.withLock { _batches } }

    func duplicateGroups() async throws -> ExactDuplicateScan {
        try lock.withLock {
            _scanCalls += 1
            if let scanError { throw scanError }
            return scans.count > 1 ? scans.removeFirst() : scans[0]
        }
    }

    func rankedMembers(of groups: [ExactDuplicateGroup]) async throws -> [String: [PhotoUID]] {
        try lock.withLock {
            _rankCalls += 1
            if let rankError { throw rankError }
            return ranked
        }
    }

    func merge(_ group: ExactDuplicateGroup, keeping kept: PhotoUID) async throws -> ExactDuplicateMergeOutcome {
        try lock.withLock {
            _merges.append(Merge(group: group.id, kept: kept))
            if let error = mergeErrors[group.id] { throw error }
            return outcomes[group.id]
                ?? .merged(kept: kept, trashed: group.members.filter { $0 != kept }, keptDuplicates: [:])
        }
    }

    func merge(
        _ requests: [(group: ExactDuplicateGroup, kept: PhotoUID)]
    ) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
        lock.withLock { _batches.append(requests.map(\.group.id)) }
        var results: [Result<ExactDuplicateMergeOutcome, any Error>] = []
        for request in requests {
            do {
                results.append(.success(try await merge(request.group, keeping: request.kept)))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }
}
