import PhotosCore
import SwiftUI
import Testing

@testable import UploadFeature

@Suite struct BackupProblemListStateViewTests {
    @Test func theStatesUseTheirCopySymbolsAndIdentifiers() {
        #expect(BackupProblemListStateView.loadingTitle == L10n.string("loading.content"))
        #expect(BackupProblemListStateView.unavailableTitle == L10n.string("backup.failed_sheet_unavailable"))
        #expect(BackupProblemListStateView.emptyTitle == L10n.string("backup.failed_sheet_empty"))
        #expect(BackupProblemListStateView.unavailableSystemImage == "exclamationmark.triangle")
        #expect(BackupProblemListStateView.emptySystemImage == "checkmark.shield")
        // The UI tests and the diagnostics find the loading state and the Try again button by these names.
        #expect(BackupProblemListStateView.loadingIdentifier == "backup.failedSheet.loading")
        #expect(BackupProblemListStateView.retryIdentifier == "backup.failedSheet.retry")
        // A key that the catalog lacks would show up as itself.
        #expect(BackupProblemListStateView.unavailableTitle != "backup.failed_sheet_unavailable")
        #expect(BackupProblemListStateView.emptyTitle != "backup.failed_sheet_empty")
    }

    @MainActor @Test func theUnavailableAndEmptyStatesDrawTheirTitle() throws {
        let unavailable = try RenderedInk.pixels(BackupProblemListStateView(.unavailable, retry: {}))
        let empty = try RenderedInk.pixels(BackupProblemListStateView(.empty, retry: {}))
        #expect(unavailable > 100)
        #expect(empty > 100)
        // Two different titles and symbols do not draw the same pixels.
        #expect(unavailable != empty)
    }

    @MainActor @Test func theEmptyStateLooksLikeTheTitleAndSymbolInitializerTheMacSheetUsedBefore() throws {
        let shared = try RenderedInk.pixels(BackupProblemListStateView(.empty, retry: {}))
        let mac = try RenderedInk.pixels(
            ContentUnavailableView(
                BackupProblemListStateView.emptyTitle, systemImage: BackupProblemListStateView.emptySystemImage))
        #expect(shared == mac)
    }

    @MainActor @Test func theListStateDrawsNothingBecauseTheHostShowsTheList() throws {
        #expect(try RenderedInk.pixels(BackupProblemListStateView(.list, retry: {})) == 0)
    }
}
