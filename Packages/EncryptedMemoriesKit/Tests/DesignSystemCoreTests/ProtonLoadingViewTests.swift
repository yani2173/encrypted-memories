import Testing

@testable import DesignSystemCore

@Suite struct ProtonLoadingViewTests {
    private static let caption = "Building your library…"

    @MainActor @Test func aCaptionIsDrawnBelowTheSpinner() throws {
        let plain = try Self.inkPixels(ProtonLoadingView())
        let captioned = try Self.inkPixels(ProtonLoadingView(caption: Self.caption))
        // The caption is a line of text: it adds well over a hundred dark pixels and nothing else changes.
        #expect(captioned - plain > 100)
    }

    @MainActor @Test func aLongerCaptionDrawsMoreOfIt() throws {
        let short = try Self.inkPixels(ProtonLoadingView(caption: "Signing out…"))
        let long = try Self.inkPixels(ProtonLoadingView(caption: "Signing out of every window…"))
        #expect(long > short)
    }

    @MainActor private static func inkPixels(_ view: ProtonLoadingView) throws -> Int {
        try RenderedInk.pixels(view, width: 320, height: 200)
    }
}
