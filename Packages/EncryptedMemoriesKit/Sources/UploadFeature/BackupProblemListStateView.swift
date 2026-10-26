import DesignSystemCore
import PhotosCore
import SwiftUI

/// What the failed-items sheet shows when it has no list to draw: the loading state, the state after a list that
/// could not be read, with the shared Try again button, and the one state that says nothing needs attention. The
/// list itself stays with each platform's native `List`, so the `.list` presentation draws nothing here. macOS and
/// iOS place the view themselves and supply what Try again does.
public struct BackupProblemListStateView: View {
    private let presentation: BackupProblemListModel.Presentation
    private let retry: () -> Void

    public init(_ presentation: BackupProblemListModel.Presentation, retry: @escaping () -> Void) {
        self.presentation = presentation
        self.retry = retry
    }

    @ViewBuilder public var body: some View {
        switch presentation {
        case .loading:
            ProgressView(Self.loadingTitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(Self.loadingIdentifier)
        case .unavailable:
            ContentUnavailableView {
                Label(Self.unavailableTitle, systemImage: Self.unavailableSystemImage)
            } actions: {
                RetryButton(.prominent, action: retry)
                    .accessibilityIdentifier(Self.retryIdentifier)
            }
        case .empty:
            ContentUnavailableView {
                Label(Self.emptyTitle, systemImage: Self.emptySystemImage)
            }
        case .list:
            EmptyView()
        }
    }

    nonisolated static var loadingTitle: String { L10n.string("loading.content") }
    nonisolated static var unavailableTitle: String { L10n.string("backup.failed_sheet_unavailable") }
    nonisolated static var emptyTitle: String { L10n.string("backup.failed_sheet_empty") }
    nonisolated static let unavailableSystemImage = "exclamationmark.triangle"
    nonisolated static let emptySystemImage = "checkmark.shield"
    nonisolated static let loadingIdentifier = "backup.failedSheet.loading"
    nonisolated static let retryIdentifier = "backup.failedSheet.retry"
}
