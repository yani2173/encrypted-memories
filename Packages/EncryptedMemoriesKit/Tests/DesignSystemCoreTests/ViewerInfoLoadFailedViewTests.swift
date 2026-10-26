import PhotosCore
import SwiftUI
import Testing

@testable import DesignSystemCore

@Suite struct ViewerInfoLoadFailedViewTests {
    @Test func theStateUsesTheInfoPanelFailureCopyAndSymbol() {
        #expect(ViewerInfoLoadFailedView.title == L10n.string("infopanel.load_failed_title"))
        #expect(ViewerInfoLoadFailedView.message == L10n.string("infopanel.load_failed_message"))
        #expect(ViewerInfoLoadFailedView.systemImage == "exclamationmark.triangle")
        // A key that the catalog lacks would show up as itself.
        #expect(ViewerInfoLoadFailedView.title != "infopanel.load_failed_title")
        #expect(ViewerInfoLoadFailedView.message != "infopanel.load_failed_message")
    }

    @MainActor @Test func theViewDrawsTheMessageBeyondTheTitle() throws {
        let titleOnly = try RenderedInk.pixels(
            ContentUnavailableView {
                Label(ViewerInfoLoadFailedView.title, systemImage: ViewerInfoLoadFailedView.systemImage)
            })
        let full = try RenderedInk.pixels(ViewerInfoLoadFailedView(onRetry: {}))
        // The message is a line or more of text: it adds well over a hundred dark pixels to the title and symbol.
        #expect(full - titleOnly > 100)
    }
}
