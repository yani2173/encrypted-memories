import PhotosCore
import Testing
import UploadCore
import UploadFeature

@Suite
struct BackupProblemSectionTests {
    @Test func sectionsKeepTheirOrderAndTheOriginalRows() {
        let permanent = item("permanent", issue: .unsupported)
        let waiting = item("waiting", issue: .network)
        let decision = item("decision", issue: .deletedElsewhere)
        let action = item("action", issue: .accountStorage)
        let items = [permanent, waiting, decision, action]

        let sections = BackupProblemSection.grouped(items, section: { $0.category.section })

        #expect(sections.map(\.id) == [.actionNeeded, .continuesByItself, .notPossible])
        #expect(sections.map(\.items) == [[decision, action], [waiting], [permanent]])
        #expect(sections.map(\.title) == BackupIssueSection.allCases.map(\.localizedTitle))
        #expect(items.offersUserRetry)
    }

    @Test func noRowsGiveNoSections() {
        let items: [BackupFailedItem] = []
        #expect(BackupProblemSection.grouped(items, section: { $0.category.section }).isEmpty)
        #expect(!items.offersUserRetry)
    }

    private func item(_ id: String, issue: BackupIssueKind) -> BackupFailedItem {
        BackupFailedItem(
            id: id, filename: "\(id).heic", reason: "Localized reason", isPermanent: false,
            issue: issue, nextAttemptAt: .distantFuture)
    }
}
