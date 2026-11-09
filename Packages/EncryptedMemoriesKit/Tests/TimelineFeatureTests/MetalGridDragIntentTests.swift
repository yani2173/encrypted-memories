import AppKit
import GridCore
import MetalKit
import PhotosCore
import Testing
import TimelineCore

@testable import TimelineFeature

@MainActor private final class DragIntentDataSource: MetalGridDataSource {
    let sectionCounts = [3]
    let flatUIDs = (0..<3).map { PhotoUID(volumeID: "drag-intent", nodeID: "\($0)") }
    var onImagesAvailable: (() -> Void)?
    func image(for uid: PhotoUID) -> CGImage? { nil }
    func warm(_ requests: [ThumbnailRequest]) {}
    func hasImage(for uid: PhotoUID) -> Bool { false }
}

@Suite @MainActor struct MetalGridDragIntentTests {
    @Test func edgePressStillClicksButCannotClaimDragOut() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let coordinator = try #require(
            MetalGridCoordinator(
                device: device, dataSource: DragIntentDataSource(),
                gridProfile: TimelineGridProfileConfiguration.production.defaultProfile))
        let view = MetalGridView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), device: device)
        let clip = NSClipView(frame: view.frame)
        coordinator.metalView = view
        coordinator.clipView = clip
        coordinator.level = 3
        defer { withExtendedLifetime((view, clip)) {} }
        let rect = try #require(coordinator.cellRect(flatIndex: 0))
        let edge = CGPoint(x: rect.minX + 1, y: rect.midY)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        #expect(coordinator.hitTestCell(contentPoint: edge) != nil)
        #expect(coordinator.hitTestDragOut(contentPoint: edge) == nil)
        #expect(coordinator.hitTestDragOut(contentPoint: center)?.flatIndex == 0)
    }
}
