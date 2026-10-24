import PhotosCore
import Testing
import UploadCore
import UploadFeature

@Suite @MainActor
struct BackupProblemListModelTests {
    @Test func sectionsKeepTheirOrderAndTheOriginalRows() {
        let model = BackupProblemListModel()
        let permanent = item("permanent", issue: .unsupported)
        let waiting = item("waiting", issue: .network)
        let decision = item("decision", issue: .deletedElsewhere)
        let action = item("action", issue: .accountStorage)
        model.replaceItems([permanent, waiting, decision, action])

        #expect(model.sections.map(\.id) == [.actionNeeded, .continuesByItself, .notPossible])
        #expect(model.sections.map(\.items) == [[decision, action], [waiting], [permanent]])
        #expect(model.sections.map(\.title) == BackupIssueSection.allCases.map(\.localizedTitle))
        #expect(model.items.offersUserRetry)
    }

    @Test func theSheetNeverSaysThatNothingNeedsAttentionBeforeItReadAnything() {
        let model = BackupProblemListModel()
        #expect(model.presentation(expectsItems: false) == .loading)
        #expect(model.presentation(expectsItems: true) == .loading)
    }

    @Test func anEmptyListThatTheSummaryContradictsIsNoAnswer() {
        let model = BackupProblemListModel()
        model.replaceItems([])
        #expect(model.presentation(expectsItems: false) == .empty, "Nothing is counted, so nothing needs attention")
        #expect(model.presentation(expectsItems: true) == .loading, "The summary counts a photo that the list lacks")
        model.markUnavailable()
        #expect(model.presentation(expectsItems: true) == .unavailable)
        // The list can come back: the next read shows its rows again.
        model.replaceItems([item("late", issue: .unsupported)])
        #expect(model.presentation(expectsItems: true) == .list)
        #expect(model.phase == .loaded)
    }

    @Test func aNewReadAfterAnUnavailableListLoadsAgain() {
        let model = BackupProblemListModel()
        model.markUnavailable()
        model.beginReading()
        #expect(model.presentation(expectsItems: true) == .loading)
        // Rows that are shown stay shown while the next read runs.
        model.replaceItems([item("shown", issue: .network)])
        model.markUnavailable()
        model.beginReading()
        #expect(model.presentation(expectsItems: true) == .list)
    }

    @Test func emptySectionsDisappearAfterDismissal() {
        let model = BackupProblemListModel()
        model.replaceItems([item("permanent", issue: .unsupported)])
        model.dismissItem(id: "permanent")
        #expect(model.items.isEmpty)
        #expect(model.sections.isEmpty)
        #expect(!model.items.offersUserRetry)
    }

    private func item(_ id: String, issue: BackupIssueKind) -> BackupFailedItem {
        BackupFailedItem(
            id: id, filename: "\(id).heic", reason: "Localized reason", isPermanent: false,
            issue: issue, nextAttemptAt: .distantFuture)
    }
}
