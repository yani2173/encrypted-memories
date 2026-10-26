import PhotosCore
import SwiftUI

/// The state of the viewer's Info panel when the photo details could not be loaded: the native unavailable view with
/// the shared prominent Try again button. The Mac panel and the iOS sheet show the same content and place it
/// themselves.
public struct ViewerInfoLoadFailedView: View {
    private let onRetry: () -> Void

    public init(onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
    }

    public var body: some View {
        ContentUnavailableView {
            Label(Self.title, systemImage: Self.systemImage)
        } description: {
            Text(Self.message)
        } actions: {
            RetryButton(.prominent, action: onRetry)
        }
    }

    nonisolated static var title: String { L10n.string("infopanel.load_failed_title") }
    nonisolated static var message: String { L10n.string("infopanel.load_failed_message") }
    nonisolated static let systemImage = "exclamationmark.triangle"
}
