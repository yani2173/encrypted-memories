import AppKit
import CoreGraphics
import GridCore
import MetalKit
import Testing
import TimelineCore

@testable import TimelineFeature

/// Resizing the window across the compact profile width (640 pt) switches the grid profile. Every switch picked the
/// level whose tiles look closest in size, so the density crept on repeated resizes; the same width must show the
/// same density after any sequence of resizes.
@Suite struct MetalGridProfileDensityTests {
    @MainActor
    private func makeCoordinator() -> MetalGridCoordinator? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return MetalGridCoordinator(
            device: device,
            dataSource: PresentationTestDataSource(count: 2000),
            gridProfile: TimelineGridProfileConfiguration.production.defaultProfile)
    }

    @MainActor
    private func resize(
        _ coordinator: MetalGridCoordinator, to profile: GridLevelProfile, from oldWidth: CGFloat,
        to newWidth: CGFloat
    ) {
        _ = coordinator.applyGridProfile(
            profile, oldFrame: CGRect(x: 0, y: 0, width: oldWidth, height: 800),
            newFrame: CGRect(x: 0, y: 0, width: newWidth, height: 800), oldScrollY: 1800, wasBottomPinned: false)
    }

    @MainActor
    private func tileSide(_ coordinator: MetalGridCoordinator, width: CGFloat) -> CGFloat {
        coordinator.engine.resolvedMetrics(level: coordinator.level, width: width).slotSide
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil)) @MainActor
    func repeatedResizesAcrossTheCompactWidthKeepTheDensityAtTheSameWidth() throws {
        let configuration = TimelineGridProfileConfiguration.production
        let regular = try #require(configuration.profile(id: "regularTimeline"))
        let compact = try #require(configuration.profile(id: "compactTimeline"))
        var drifts: [String] = []
        for level in 0..<regular.levels.count {
            for (wide, narrow) in [(900, 600), (1280, 500), (700, 630), (1500, 400), (660, 320)] as [(CGFloat, CGFloat)]
            {
                let coordinator = try #require(makeCoordinator())
                coordinator.level = level
                let startSide = tileSide(coordinator, width: wide)
                var sides: [CGFloat] = []
                for _ in 0..<6 {
                    resize(coordinator, to: compact, from: wide, to: narrow)
                    resize(coordinator, to: regular, from: narrow, to: wide)
                    sides.append(tileSide(coordinator, width: wide))
                }
                if !sides.allSatisfy({ abs($0 - startSide) < 0.5 }) {
                    drifts.append("level \(level) \(wide)/\(narrow): \(startSide) -> \(sides)")
                }
            }
        }
        #expect(drifts.isEmpty, "\(drifts)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil)) @MainActor
    func aPinchInTheCompactProfileDecidesTheLevelWhenTheWindowWidensAgain() throws {
        let configuration = TimelineGridProfileConfiguration.production
        let regular = try #require(configuration.profile(id: "regularTimeline"))
        let compact = try #require(configuration.profile(id: "compactTimeline"))
        var casesWhereTheMemoryWouldDiffer = 0
        for startLevel in 0..<regular.levels.count {
            for step in [-1, 1] {
                let coordinator = try #require(makeCoordinator())
                coordinator.level = startLevel
                resize(coordinator, to: compact, from: 900, to: 600)
                let pinchedLevel = compact.clampLevel(coordinator.level + step)
                guard pinchedLevel != coordinator.level else { continue }  // no room to pinch that way
                coordinator.level = pinchedLevel  // the person pinches one step in the compact profile
                resize(coordinator, to: regular, from: 600, to: 900)

                // The size match alone decides after a pinch: a window that never saw the first visit gives the same level.
                let reference = try #require(makeCoordinator())
                _ = reference.applyGridProfile(
                    compact, oldFrame: CGRect(x: 0, y: 0, width: 900, height: 800),
                    newFrame: CGRect(x: 0, y: 0, width: 600, height: 800), oldScrollY: 1800,
                    wasBottomPinned: false, levelMapping: .explicit(pinchedLevel))
                resize(reference, to: regular, from: 600, to: 900)
                #expect(coordinator.level == reference.level, "start \(startLevel), pinch \(step)")
                if reference.level != startLevel { casesWhereTheMemoryWouldDiffer += 1 }
            }
        }
        #expect(casesWhereTheMemoryWouldDiffer > 0)
    }
}
