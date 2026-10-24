import PhotosCore
import SwiftUI

/// The native empty screen shared by the library and its successfully loaded filter routes.
public struct LibraryEmptyView: View {
    private let filter: PhotoFilter
    private let backupAction: LibraryEmptyBackupAction?

    public init(filter: PhotoFilter = .all, backupAction: LibraryEmptyBackupAction? = nil) {
        self.filter = filter
        self.backupAction = backupAction
    }

    public var body: some View {
        let copy = filter.emptyStateCopy
        ContentUnavailableView {
            Label {
                Text(copy.title)
                    .accessibilityIdentifier("library.empty.title")
            } icon: {
                MemoriesBrandMark(height: 40)
            }
        } description: {
            Text(copy.description)
        } actions: {
            if let backupAction, backupAction.isOffered(for: filter) {
                Button(L10n.string("empty.set_up_backup"), action: backupAction.perform)
                    .accessibilityIdentifier("library.empty.backup")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The app supplies availability and its native navigation action. Core decides whether to offer it.
public struct LibraryEmptyBackupAction {
    private let isAvailable: Bool
    private let isEnabled: Bool
    let perform: () -> Void

    public init(isAvailable: Bool, isEnabled: Bool, perform: @escaping () -> Void) {
        self.isAvailable = isAvailable
        self.isEnabled = isEnabled
        self.perform = perform
    }

    /// Filters keep their own copy and never suggest backup to remedy an empty filter result.
    public func isOffered(for filter: PhotoFilter) -> Bool {
        filter == .all && isAvailable && !isEnabled
    }
}
