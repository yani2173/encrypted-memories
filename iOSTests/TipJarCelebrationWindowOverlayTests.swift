import Testing
import UIKit

@testable import DesignSystemUIKitAdapter

@Suite("Tip jar celebration UIKit window overlay")
@MainActor
struct TipJarCelebrationWindowOverlayTests {
    @Test("Uses a foreground, click-through native window policy")
    func usesForegroundClickThroughPolicy() {
        #expect(TipJarCelebrationWindowPolicy.windowLevel.rawValue > UIWindow.Level.alert.rawValue)
        #expect(!TipJarCelebrationWindowPolicy.allowsUserInteraction)
    }

    @Test("The native foreground window never becomes key and forwards every touch")
    func windowRemainsNonKeyAndPassesThroughTouches() throws {
        let scene = try #require(
            UIApplication.shared.foregroundWindowScene
        )
        let window = TipJarCelebrationPassthroughWindow(windowScene: scene)

        #expect(!window.canBecomeKey)
        #expect(window.hitTest(.zero, with: nil) == nil)
    }

    @Test("Presents only while a celebration has an attached window scene")
    func resolvesPresentationLifecycle() {
        #expect(
            TipJarCelebrationWindowPresentation.resolve(hasScene: false, isCelebrating: false) == .detached
        )
        #expect(
            TipJarCelebrationWindowPresentation.resolve(hasScene: false, isCelebrating: true) == .detached
        )
        #expect(
            TipJarCelebrationWindowPresentation.resolve(hasScene: true, isCelebrating: false) == .hidden
        )
        #expect(
            TipJarCelebrationWindowPresentation.resolve(hasScene: true, isCelebrating: true) == .visible
        )
    }
}
