import PhotosCore
import SwiftUI

/// The content of the state after a sign-out whose local cleanup failed: the native unavailable view with the
/// shared prominent Try again button. macOS and iOS put it on their own surface (a window background, or the frosted
/// cover); the content, strings and symbol are the same.
public struct SignOutCleanupFailedView: View {
    private let retry: () -> Void

    public init(retry: @escaping () -> Void) {
        self.retry = retry
    }

    public var body: some View {
        ContentUnavailableView {
            Label {
                Text(Self.title)
            } icon: {
                Image(systemName: Self.systemImage)
            }
        } description: {
            Text(Self.message)
        } actions: {
            RetryButton(.prominent, action: retry)
        }
        .padding()
    }

    nonisolated static var title: String { L10n.string("sign_out.cleanup_failed_title") }
    nonisolated static var message: String { L10n.string("sign_out.cleanup_failed_message") }
    nonisolated static let systemImage = "exclamationmark.shield"
}
