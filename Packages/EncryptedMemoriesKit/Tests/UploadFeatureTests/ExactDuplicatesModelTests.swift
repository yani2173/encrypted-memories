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

    func testAFinishedCheckNeverWaitsAndNamesThePhotosItCouldNotRead() async {
        let (incomplete, _) = makeModel(
            FakeDuplicateFinder(scans: [.init(groups: [], coverage: .incomplete(unresolvedCount: 3))]))
        await incomplete.load()
        XCTAssertEqual(incomplete.content, .noDuplicates, "a finished check shows its result")
        XCTAssertEqual(incomplete.emptyStateCopy.title, L10n.string("duplicates.none_title"))
        XCTAssertEqual(incomplete.emptyStateCopy.description, L10n.string("duplicates.unchecked \(3)"))
        XCTAssertNil(incomplete.checkFailedNote, "a retry cannot read those photos")

        let (unbuilt, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [], coverage: .indexing)]))
        await unbuilt.load()
        guard case .failed = unbuilt.content else {
            return XCTFail("a build that left no index offers a retry, got \(unbuilt.content)")
        }

        let (complete, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [], coverage: .complete)]))
        await complete.load()
        XCTAssertEqual(complete.emptyStateCopy, PhotoFilter.duplicates.emptyStateCopy)
        XCTAssertNil(complete.uncheckedNote)
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

    func testAFailedRankingKeepsTheFallbackOrderAndShowsTheGroups() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.rankError = URLError(.timedOut)
        finder.fallback = ["A": [a2, a1, a3]]
        let (model, _) = makeModel(finder)
        await model.load()
        XCTAssertEqual(model.content, .groups)
        XCTAssertEqual(model.groups.first?.members, [a2, a1, a3])
        XCTAssertEqual(model.groups.first?.kept, a2)
        XCTAssertEqual(model.groups.first?.isRanked, false)
    }

    func testTheGroupsShowBeforeTheRankingAndTheRankingShowsItsProgress() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.fallback = ["A": [a2, a1, a3]]
        finder.ranked = ["A": [a3, a1, a2]]
        finder.rankGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.rankGate.hasWaiters }, "the load ranks the groups")

        XCTAssertEqual(model.content, .groups, "the list never waits for the ranking")
        XCTAssertEqual(model.groups.first?.kept, a2, "the fallback order chooses the photo to keep until then")
        XCTAssertEqual(model.groupCountText, L10n.string("duplicates.group_count \(2)"))
        XCTAssertEqual(model.rankingLine?.title, L10n.string("duplicates.ranking_title"))
        XCTAssertEqual(
            model.rankingLine?.detail, L10n.string("duplicates.ranking_progress \(0.formatted()) \(2.formatted())"))
        XCTAssertEqual(model.rankingLine?.fraction, 0)
        XCTAssertTrue(model.canMerge)

        finder.rankGate.open()
        await load.value
        XCTAssertEqual(model.groups.first?.members, [a3, a1, a2])
        XCTAssertEqual(model.groups.first?.kept, a3)
        XCTAssertNil(model.rankingLine)
    }

    func testAGroupWhoseFactsCannotBeReadKeepsItsFallbackOrderAndTheOthersAreRanked() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.fallback = ["A": [a2, a1, a3], "B": [b2, b1]]
        finder.ranked = ["A": [a3, a1, a2], "B": [b1, b2]]
        finder.unreadableGroups = ["A"]
        let (model, _) = makeModel(finder)
        await model.load()
        XCTAssertEqual(model.content, .groups)
        XCTAssertEqual(model.groups.map(\.kept), [a2, b1])
        XCTAssertEqual(model.groups.map(\.isRanked), [false, true])
    }

    func testMergeAllReadsTheFactsOfAnUnrankedGroupButKeepsThePhotoShownAsKept() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.fallback = ["A": [a2, a1, a3], "B": [b2, b1]]
        finder.ranked = ["A": [a3, a1, a2], "B": [b1, b2]]
        finder.unreadableGroups = ["A", "B"]
        let (model, _) = makeModel(finder)
        await model.load()
        finder.unreadableGroups = []
        model.keep(b1, inGroup: "B")

        await model.mergeAll()

        XCTAssertEqual(finder.rankedGroups.last, ["A"], "Merge All reads the facts of an unranked group first")
        XCTAssertEqual(
            finder.merges, [.init(group: "A", kept: a2), .init(group: "B", kept: b1)],
            "the merge keeps the photo that the screen showed as kept")
    }

    func testMergeAllKeepsASharedMemberInsteadOfTheShownPhotoAndShowsIt() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.fallback = ["A": [a2, a1, a3]]
        finder.ranked = ["A": [a3, a1, a2]]
        finder.unreadableGroups = ["A"]
        let (model, _) = makeModel(finder)
        await model.load()
        finder.unreadableGroups = []
        finder.shared = ["A": [a3]]
        finder.rankGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.rankGate.hasWaiters }, "Merge All ranks")
        finder.rankGate.open()
        await waitUntil({ !finder.merges.isEmpty }, "the merge runs")
        XCTAssertEqual(finder.merges, [.init(group: "A", kept: a3)], "a trash would end the sharing of a3")
        await merge.value
    }

    func testMergingOneGroupKeepsExactlyThePhotoShownAsKept() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.fallback = ["A": [a2, a1, a3]]
        finder.ranked = ["A": [a3, a1, a2]]
        finder.unreadableGroups = ["A"]
        let (model, _) = makeModel(finder)
        await model.load()
        finder.unreadableGroups = []
        let ranksBefore = finder.rankCalls
        XCTAssertEqual(model.groups.first?.kept, a2)

        await model.merge(groupID: "A")

        XCTAssertEqual(finder.merges, [.init(group: "A", kept: a2)], "the checkmark is the photo that stays")
        XCTAssertEqual(finder.rankCalls, ranksBefore, "no ranking can move the checkmark before the merge")
    }

    func testTheScanShowsATitledCountedProgress() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.scanProgress = [.init(completed: 150, total: 3_180)]
        finder.scanGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.scanGate.hasWaiters }, "the load scans")

        XCTAssertEqual(model.content, .loading)
        XCTAssertEqual(model.loadingLine.title, L10n.string("duplicates.loading"))
        XCTAssertEqual(
            model.loadingLine.detail,
            L10n.string("duplicates.checking_progress \(150.formatted()) \(3_180.formatted())"))
        XCTAssertEqual(model.loadingLine.fraction ?? 0, 150.0 / 3_180.0, accuracy: 0.0001)
        finder.scanGate.open()
        await load.value
        XCTAssertNil(model.scanProgress)
    }

    func testARebuildOfACompleteIndexShowsItsProgressAboveTheGroups() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.buildProgress = [.init(phase: .indexing, completed: 10_000, total: 51_220)]
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")

        XCTAssertEqual(model.content, .groups)
        XCTAssertEqual(model.checkLine?.title, L10n.string("duplicates.checking_title"))
        XCTAssertEqual(model.checkLine?.detail, model.checkProgressText)
        XCTAssertNil(model.stillCheckingNote, "a complete index finds every group already")
        finder.buildGate.open()
        await load.value
        XCTAssertNil(model.checkLine)
    }

    func testAnIncompleteOrIndexingScanShowsTheStillCheckingNoteWithItsGroupsWhileTheCheckRuns() async {
        for coverage in [ExactDuplicateCoverage.indexing, .incomplete(unresolvedCount: 3)] {
            let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: coverage)])
            finder.buildGate.close()
            let (model, _) = makeModel(finder)
            let load = Task { await model.load() }
            await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")
            XCTAssertEqual(model.content, .groups, "\(coverage)")
            XCTAssertNotNil(model.stillCheckingNote, "\(coverage)")
            finder.buildGate.open()
            await load.value
            XCTAssertNil(model.stillCheckingNote, "no waiting text after the check: \(coverage)")
            if case .incomplete = coverage {
                XCTAssertEqual(model.uncheckedNote, L10n.string("duplicates.unchecked \(3)"))
                XCTAssertNil(model.checkFailedNote)
            } else {
                XCTAssertEqual(model.checkFailedNote, L10n.string("duplicates.check_failed"))
                XCTAssertNil(model.uncheckedNote)
            }
        }
        let (complete, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)]))
        await complete.load()
        XCTAssertNil(complete.stillCheckingNote)
    }

    // MARK: - The library check

    /// Waits until `condition` holds, for at most two seconds.
    private func waitUntil(_ condition: () -> Bool, _ message: String) async {
        for _ in 0..<2_000 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), message)
    }

    func testAnEmptyIndexThatIsStillBuildingSaysThatDuplicatesAppearWhenTheCheckIsDone() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [], coverage: .indexing)])
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")

        XCTAssertEqual(model.content, .stillChecking)
        XCTAssertEqual(model.emptyStateCopy.title, L10n.string("duplicates.checking_title"))
        XCTAssertEqual(model.emptyStateCopy.description, L10n.string("duplicates.checking_wait"))
        XCTAssertNotEqual(
            model.emptyStateCopy.description, L10n.string("duplicates.still_checking"),
            "more duplicates can only appear when some are shown")
        XCTAssertEqual(model.checkProgress, .indeterminate)
        finder.buildGate.open()
        await load.value
    }

    func testTheCheckShowsTheProgressOfTheBuild() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [], coverage: .indexing)])
        finder.buildProgress = [.init(phase: .loading), .init(phase: .indexing, completed: 1_234, total: 15_000)]
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")

        XCTAssertEqual(model.checkProgress, .counted(completed: 1_234, total: 15_000))
        XCTAssertEqual(
            model.checkProgressText,
            L10n.string("duplicates.checking_progress \(1_234.formatted()) \(15_000.formatted())"))
        finder.buildGate.open()
        await load.value
        XCTAssertNil(model.checkProgress, "no progress once the build finished")
        XCTAssertNil(model.checkProgressText)
    }

    func testAFinishedBuildLoadsTheGroupsWithoutARefresh() async {
        let finder = FakeDuplicateFinder(scans: [
            .init(groups: [], coverage: .indexing), .init(groups: [groupA], coverage: .complete),
        ])
        finder.buildChanged = true
        let (model, _) = makeModel(finder)
        await model.load()
        XCTAssertEqual(finder.buildCalls, 1)
        XCTAssertEqual(model.content, .groups)
        XCTAssertEqual(model.groups.map(\.id), ["A"])
        XCTAssertNil(model.stillCheckingNote)
    }

    func testABuildThatChangedNothingScansOnceAndACompleteEmptyIndexHasNoDuplicates() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [], coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        XCTAssertEqual(finder.buildCalls, 1, "a complete index is brought up to date")
        XCTAssertEqual(finder.scanCalls, 1)
        XCTAssertEqual(model.content, .noDuplicates)
        XCTAssertEqual(model.emptyStateCopy.title, L10n.string("duplicates.none_title"))
    }

    func testALoadWhileTheIndexBuildsWaitsForThatBuildInsteadOfStartingASecondOne() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [], coverage: .indexing)])
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let first = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")
        let second = Task { await model.load() }
        await waitUntil({ finder.scanCalls == 2 }, "the second load scans")
        finder.buildGate.open()
        await first.value
        await second.value
        XCTAssertEqual(finder.buildCalls, 1)
    }

    func testAFailedBuildWithoutGroupsOffersARetryAndKeepsACompleteIndex() async {
        let building = FakeDuplicateFinder(scans: [.init(groups: [], coverage: .indexing)])
        building.buildError = URLError(.notConnectedToInternet)
        let (model, _) = makeModel(building)
        await model.load()
        guard case .failed = model.content else { return XCTFail("expected a failure, got \(model.content)") }

        let complete = FakeDuplicateFinder(scans: [.init(groups: [], coverage: .complete)])
        complete.buildError = URLError(.notConnectedToInternet)
        let (completeModel, _) = makeModel(complete)
        await completeModel.load()
        XCTAssertEqual(completeModel.content, .noDuplicates, "the complete index still answers")
    }

    // MARK: - Freed space

    func testEachGroupAndTheTotalShowTheFreedSpaceInTheSystemByteFormat() async {
        let finder = FakeDuplicateFinder(
            scans: [.init(groups: [groupA, groupB], coverage: .complete, byteSizes: ["A": 1_000_000])])
        let (model, _) = makeModel(finder)
        await model.load()
        let a = model.groups.first { $0.id == "A" }
        XCTAssertEqual(a?.freedBytes, 2_000_000, "one size for each of the two duplicates")
        XCTAssertEqual(
            a?.freedText,
            L10n.string("duplicates.group_frees \(Int64(2_000_000).formatted(.byteCount(style: .file)))"))
        XCTAssertNil(model.groups.first { $0.id == "B" }?.freedText, "an unknown size shows nothing")
        XCTAssertEqual(model.totalFreedBytes, 2_000_000)
        XCTAssertEqual(
            model.totalFreedText,
            L10n.string("duplicates.total_frees \(Int64(2_000_000).formatted(.byteCount(style: .file)))"))
        XCTAssertEqual(
            model.totalFreedNote, L10n.string("duplicates.freed_when_emptied"),
            "the space is free only after Recently Deleted is emptied")
    }

    func testTheTotalGrowsWhileTheCheckFindsGroupsAndSizes() async {
        let finder = FakeDuplicateFinder(scans: [
            .init(groups: [groupA], coverage: .indexing, byteSizes: ["A": 100]),
            .init(groups: [groupA, groupB], coverage: .complete, byteSizes: ["A": 100]),
        ])
        finder.buildChanged = true
        finder.rankSizes = ["B": 50]
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")
        XCTAssertEqual(model.totalFreedBytes, 200)
        finder.buildGate.open()
        await load.value
        XCTAssertEqual(model.totalFreedBytes, 250, "the new group and the size from the ranking add up")
        XCTAssertEqual(model.groups.first { $0.id == "B" }?.freedBytes, 50)
    }

    func testNoGroupHasASizeWhenNothingKnowsIt() async {
        let (model, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)]))
        await model.load()
        XCTAssertNil(model.groups.first?.byteSize)
        XCTAssertEqual(model.totalFreedBytes, 0)
        XCTAssertNil(model.totalFreedText)
        XCTAssertNil(model.totalFreedNote, "no note without a total")
    }

    // MARK: - Ranking only what the screen shows

    private func manyGroups(_ count: Int) -> [ExactDuplicateGroup] {
        (0..<count).map { index in
            ExactDuplicateGroup(
                contentHash: String(format: "G%04d", index), hashKeyEpoch: "e",
                members: [
                    PhotoUID(volumeID: "v", nodeID: "g\(index)-1"), PhotoUID(volumeID: "v", nodeID: "g\(index)-2"),
                ])
        }
    }

    func testOpeningRanksTwoPagesAndScrollingRanksTheShownPageAndTheNext() async {
        let groups = manyGroups(1_500)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let size = ExactDuplicatesModel.rankingPageSize
        XCTAssertEqual(Set(finder.rankedGroups.joined()), Set(groups.prefix(2 * size).map(\.id)))
        XCTAssertEqual(model.groups.filter(\.isRanked).count, 2 * size)

        model.groupAppeared(groups[5 * size + 3].id)
        await waitUntil({ model.groups.filter(\.isRanked).count == 4 * size }, "the shown pages rank")
        let expected = groups.prefix(2 * size).map(\.id) + groups[(5 * size)..<(7 * size)].map(\.id)
        XCTAssertEqual(Set(finder.rankedGroups.joined()), Set(expected))
        XCTAssertEqual(finder.rankedGroups.joined().count, 4 * size, "no group is read twice")
    }

    func testScrollingStillRanksAfterAMergeRanAlongsideTheScrollRanking() async {
        let groups = manyGroups(100)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        finder.rankGate.close()
        model.groupAppeared(groups[50].id)
        await waitUntil({ finder.rankGate.hasWaiters }, "scrolling ranks")
        let merge = Task { await model.merge(groupID: groups[90].id) }
        for _ in 0..<2_000 where finder.rankedGroups.count < 3 { try? await Task.sleep(for: .milliseconds(1)) }
        finder.rankGate.open()
        await merge.value
        await waitUntil({ model.rankingLine == nil }, "the scroll ranking finishes")

        model.groupAppeared(groups[98].id)
        await waitUntil(
            { model.groups.first { $0.id == groups[98].id }?.isRanked == true }, "scrolling ranks after the merge")
    }

    func testScrollingDuringMergeAllKeepsTheProgressOfTheMerge() async {
        let groups = manyGroups(100)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let unranked = 100 - 2 * ExactDuplicatesModel.rankingPageSize
        finder.rankGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.rankGate.hasWaiters }, "Merge All ranks")
        model.groupAppeared(groups[60].id)
        await waitUntil({ finder.rankedGroups.count >= 3 }, "scrolling ranks beside the merge")
        XCTAssertEqual(
            model.rankingLine?.detail,
            L10n.string("duplicates.ranking_progress \(0.formatted()) \(unranked.formatted())"),
            "the merge keeps its progress row")
        finder.rankGate.open()
        await merge.value
    }

    func testABuildThatFinishesDuringAMergeReadsTheGroupsAfterTheMerge() async {
        let finder = FakeDuplicateFinder(scans: [
            .init(groups: [groupA], coverage: .indexing), .init(groups: [groupA, groupB], coverage: .complete),
        ])
        finder.buildChanged = true
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")
        finder.mergeGate.close()
        let merge = Task { await model.merge(groupID: "A") }
        await waitUntil({ finder.mergeGate.hasWaiters }, "the merge runs")
        finder.buildGate.open()
        await load.value
        XCTAssertEqual(finder.scanCalls, 1, "a merge holds the list")

        finder.mergeGate.open()
        await merge.value
        XCTAssertEqual(model.groups.map(\.id).contains("B"), true, "the groups of the new index show after the merge")
    }

    func testAServiceStopOfTheCheckDuringAMergeRestartsTheCheckAfterTheMerge() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .indexing)])
        finder.buildError = CancellationError()
        finder.buildProgress = [.init(phase: .indexing, completed: 10, total: 100)]
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")
        finder.mergeGate.close()
        let merge = Task { await model.merge(groupID: "A") }
        await waitUntil({ finder.mergeGate.hasWaiters }, "the merge runs")
        finder.buildGate.open()
        await load.value
        XCTAssertNil(model.checkLine)
        XCTAssertNil(model.checkFailedNote, "a stopped check did not fail")

        finder.buildError = nil
        finder.buildGate.close()
        finder.mergeGate.open()
        await merge.value
        await waitUntil({ finder.buildCalls == 2 }, "the check starts again after the merge")
        await waitUntil({ model.checkLine != nil }, "the screen shows the check again")
        XCTAssertEqual(model.checkLine?.title, L10n.string("duplicates.checking_title"))
        finder.buildGate.open()
    }

    func testAScreenThatOpensAgainReadsNothingForUnchangedGroups() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: manyGroups(60), coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let reads = finder.rankCalls
        await model.load()
        XCTAssertEqual(finder.rankCalls, reads, "the ranked facts stay for the session")
    }

    func testMergeAllReadsTheGroupsThatNobodyScrolledToWithProgress() async {
        let groups = manyGroups(60)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let size = ExactDuplicatesModel.rankingPageSize
        finder.rankGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.rankGate.hasWaiters }, "Merge All reads the remaining groups")
        XCTAssertEqual(finder.rankedGroups.last?.count, 60 - 2 * size)
        XCTAssertEqual(
            model.rankingLine?.detail,
            L10n.string("duplicates.ranking_progress \(0.formatted()) \((60 - 2 * size).formatted())"))
        finder.rankGate.open()
        await merge.value
        XCTAssertEqual(finder.batches.last?.count, 60)
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
    private var _buildCalls = 0
    private var _rankedGroups: [[String]] = []
    var scanProgress: [ExactDuplicateScanProgress] = []
    var fallback: [String: [PhotoUID]] = [:]
    /// Groups whose facts cannot be read.
    var unreadableGroups: Set<String> = []
    /// Shared members that the ranking reports.
    var shared: [String: Set<PhotoUID>] = [:]
    /// Sizes that the node reads of the ranking report.
    var rankSizes: [String: Int64] = [:]
    /// Holds the scan while it is closed.
    let scanGate = BuildGate()
    /// Holds the ranking while it is closed.
    let rankGate = BuildGate()
    var buildProgress: [UploadRemoteIndexPreparationProgress] = []
    var buildChanged = false
    var buildError: Error?
    /// Holds the build while it is closed.
    let buildGate = BuildGate()
    /// Holds the merge while it is closed.
    let mergeGate = BuildGate()
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
    var buildCalls: Int { lock.withLock { _buildCalls } }
    var rankedGroups: [[String]] { lock.withLock { _rankedGroups } }

    func duplicateGroups(
        progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
    ) async throws -> ExactDuplicateScan {
        let steps = lock.withLock { scanProgress }
        for step in steps { await progress(step) }
        await scanGate.pass()
        return try lock.withLock {
            _scanCalls += 1
            if let scanError { throw scanError }
            return scans.count > 1 ? scans.removeFirst() : scans[0]
        }
    }

    func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: groups.map { ($0.id, fallback[$0.id] ?? $0.members) })
        }
    }

    func prepareIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws -> Bool {
        let (steps, error, changed) = lock.withLock {
            _buildCalls += 1
            return (buildProgress, buildError, buildChanged)
        }
        for step in steps { await progress(step) }
        await buildGate.pass()
        if let error { throw error }
        return changed
    }

    func rankMembers(
        of groups: [ExactDuplicateGroup], ranked report: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
    ) async {
        lock.withLock {
            _rankCalls += 1
            _rankedGroups.append(groups.map(\.id))
        }
        await rankGate.pass()
        let page = lock.withLock { () -> ExactDuplicateRankingPage in
            guard rankError == nil else { return ExactDuplicateRankingPage(members: [:], groupCount: groups.count) }
            var members: [String: [PhotoUID]] = [:]
            for group in groups where !unreadableGroups.contains(group.id) {
                members[group.id] = ranked[group.id] ?? group.members
            }
            let sizes = rankSizes.filter { size in groups.contains { $0.id == size.key } }
            let sharedMembers = shared.filter { entry in groups.contains { $0.id == entry.key } }
            return ExactDuplicateRankingPage(
                members: members, groupCount: groups.count, byteSizes: sizes, shared: sharedMembers)
        }
        await report(page)
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
        await mergeGate.pass()
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

/// Lets callers pass while open and holds them while closed.
private final class BuildGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasWaiters: Bool { lock.withLock { !waiters.isEmpty } }

    func close() { lock.withLock { isOpen = false } }

    func open() {
        let held = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        held.forEach { $0.resume() }
    }

    func pass() async {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock {
                if !isOpen { waiters.append(continuation) }
                return isOpen
            }
            if passes { continuation.resume() }
        }
    }
}
