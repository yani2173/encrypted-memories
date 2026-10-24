import PhotosCore
import SwiftUI
import UIKit
import UploadFeature
import XCTest

@testable import EncryptedMemoriesMobile
@testable import UploadCore

/// The shared waiting screen in real narrow iPad windows, including widths smaller than the app's normal column.
final class MobileDuplicatesWaitingLayoutTests: XCTestCase {
    @MainActor func testWaitingProgressFitsNarrowIPadWindows() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "this probe covers narrow iPad windows")
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKey() }
        let members = (0..<2).map { PhotoUID(volumeID: "fixture", nodeID: "waiting-\($0)") }
        for width in [CGFloat(240), 320, 480] {
            for scan in [true, false] {
                let finder = MobileFixtureDuplicates(
                    groups: [members], scanDelay: scan ? .seconds(30) : nil, rankDelay: .seconds(30))
                let model = ExactDuplicatesModel(finder: finder)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                let host = UIHostingController(
                    rootView: ExactDuplicatesView(
                        model: model, confirmsMergeAll: .constant(false), accent: .blue, cornerRadius: 8,
                        onOpen: { _, _ in }
                    ) { _ in Color.blue })
                window.rootViewController = host
                window.makeKeyAndVisible()
                for _ in 0..<200 where !model.isCheckingGroups || (!scan && model.rankingLine == nil) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(model.isCheckingGroups)
                XCTAssertFalse(model.canMerge)
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(host.view.bounds.width, width)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "duplicates-ipad-narrow-\(Int(width))-\(scan ? "scan" : "ranking")"
                attachment.lifetime = .keepAlways
                add(attachment)
                model.retire()
                window.isHidden = true
                window.rootViewController = nil
            }
        }
    }
}
