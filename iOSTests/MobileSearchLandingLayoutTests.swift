import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

final class MobileSearchLandingLayoutTests: XCTestCase {
    @MainActor func testSearchClearanceFollowsSizeClassWithoutGrowingWithDynamicType() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let model = MobileLibraryModel()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let content = MobileSearchLandingContent(
            recents: (0..<5).map {
                MobileSearchRecentEntry(query: "Recent search \($0)", representativeUID: nil, suggestion: nil)
            })
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        // Only regular width and height place the field at the top. Reuse one host to test resizing too.
        let placements: [(width: UserInterfaceSizeClass, height: UserInterfaceSizeClass)] = [
            (.compact, .regular), (.regular, .regular), (.regular, .compact),
            (.compact, .compact), (.compact, .regular),
        ]
        for size in [DynamicTypeSize.large, .accessibility5, .xSmall] {
            for placement in placements {
                host.rootView = AnyView(
                    MobileSearchLandingScreen(content: content)
                        .environment(model)
                        .environment(\.horizontalSizeClass, placement.width)
                        .environment(\.verticalSizeClass, placement.height)
                        .environment(\.dynamicTypeSize, size)
                        .ignoresSafeArea())
                try await Task.sleep(for: .milliseconds(100))
                host.view.layoutIfNeeded()
                let scroll = try XCTUnwrap(scrollView(in: host.view))
                XCTAssertEqual(
                    scroll.contentInset.bottom,
                    placement.width == .regular && placement.height == .regular ? 0 : 56, accuracy: 1,
                    "Only a bottom search field needs clearance, at every text size")
            }
        }
    }

    @MainActor private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}
