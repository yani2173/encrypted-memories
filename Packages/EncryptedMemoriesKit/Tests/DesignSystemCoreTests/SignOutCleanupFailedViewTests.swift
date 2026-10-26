import PhotosCore
import SwiftUI
import Testing

@testable import DesignSystemCore

@Suite struct SignOutCleanupFailedViewTests {
    @Test func theStateUsesTheSignOutFailureCopyAndSymbol() {
        #expect(SignOutCleanupFailedView.title == L10n.string("sign_out.cleanup_failed_title"))
        #expect(SignOutCleanupFailedView.message == L10n.string("sign_out.cleanup_failed_message"))
        #expect(SignOutCleanupFailedView.systemImage == "exclamationmark.shield")
        // A key that the catalog lacks would show up as itself.
        #expect(SignOutCleanupFailedView.title != "sign_out.cleanup_failed_title")
        #expect(SignOutCleanupFailedView.message != "sign_out.cleanup_failed_message")
    }

    @MainActor @Test func theViewDrawsTheMessageBeyondTheTitle() throws {
        let titleOnly = try RenderedInk.pixels(
            ContentUnavailableView {
                Label(SignOutCleanupFailedView.title, systemImage: SignOutCleanupFailedView.systemImage)
            }
            .padding())
        let full = try RenderedInk.pixels(SignOutCleanupFailedView(retry: {}))
        // The message is several lines of text: it adds well over a hundred dark pixels to the title and symbol.
        #expect(full - titleOnly > 100)
    }
}
