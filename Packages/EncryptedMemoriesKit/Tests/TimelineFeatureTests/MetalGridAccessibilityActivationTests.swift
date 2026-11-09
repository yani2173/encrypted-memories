import AppKit
import GridCore
import Metal
import PhotosCore
import Testing
import TimelineCore

@testable import TimelineFeature

@MainActor private final class ActivateDataSource: MetalGridDataSource {
    let sectionCounts = [4]
    let flatUIDs = (0..<4).map { PhotoUID(volumeID: "a11y-activate", nodeID: "\($0)") }
    var onImagesAvailable: (() -> Void)?
    func image(for uid: PhotoUID) -> CGImage? { nil }
    func warm(_ requests: [ThumbnailRequest]) {}
    func hasImage(for uid: PhotoUID) -> Bool { false }
}

/// U1: VoiceOver press on a grid cell must respect the CURRENT selection mode. In selection mode it
/// toggles exactly one item (no viewer); outside selection mode it opens the viewer. Stale UIDs
/// (removed photos) must fail, and a mode change must affect an already-created accessibility element.
@Suite @MainActor struct MetalGridAccessibilityActivationTests {
    @Test func existingAccessibilityElementReflectsConsecutiveSelectionPresses() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let coordinator = try #require(
            MetalGridCoordinator(
                device: device, dataSource: ActivateDataSource(),
                gridProfile: TimelineGridProfileConfiguration.production.defaultProfile))
        let host = NSView()
        let provider = MetalGridAccessibilityProvider(host: host, coordinator: coordinator)
        let selection = MetalGridSelectionController()
        let interaction = MetalGridInteractionController(coordinator: coordinator, selection: selection)
        interaction.selectionMode = true
        selection.onChange = { provider.selected = $0 }
        let element = MetalGridA11yElement()
        element.uid = coordinator.orderedUIDs[0]
        element.setAccessibilitySelected(false)
        element.onActivate = { interaction.activate(uid: $0) }
        host.setAccessibilityChildren([element])

        #expect(element.accessibilityPerformPress())
        #expect(element.isAccessibilitySelected())
        #expect(element.accessibilityPerformPress())
        #expect(!element.isAccessibilitySelected())
        #expect((host.accessibilityChildren()?.first as? MetalGridA11yElement) === element)
    }

    @Test func pressInSelectionModeTogglesSingleItemWithoutOpeningViewer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let coordinator = try #require(
            MetalGridCoordinator(
                device: device, dataSource: ActivateDataSource(),
                gridProfile: TimelineGridProfileConfiguration.production.defaultProfile))
        let selection = MetalGridSelectionController()
        var openedUIDs: [PhotoUID] = []
        let interaction = MetalGridInteractionController(coordinator: coordinator, selection: selection)
        interaction.onOpen = { openedUIDs.append($0) }
        interaction.selectionMode = true

        let uids = coordinator.orderedUIDs
        #expect(interaction.activate(uid: uids[1]) == true)
        #expect(selection.selected == [uids[1]])
        #expect(openedUIDs.isEmpty)

        // Second press on the same element deselects (toggle semantics in selection mode).
        #expect(interaction.activate(uid: uids[1]) == true)
        #expect(selection.selected.isEmpty)
        #expect(openedUIDs.isEmpty)
    }

    @Test func pressOutsideSelectionModeOpensViewer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let coordinator = try #require(
            MetalGridCoordinator(
                device: device, dataSource: ActivateDataSource(),
                gridProfile: TimelineGridProfileConfiguration.production.defaultProfile))
        let selection = MetalGridSelectionController()
        var openedUIDs: [PhotoUID] = []
        let interaction = MetalGridInteractionController(coordinator: coordinator, selection: selection)
        #expect(!interaction.activate(uid: coordinator.orderedUIDs[0]))
        interaction.onOpen = { openedUIDs.append($0) }
        interaction.selectionMode = false

        let uids = coordinator.orderedUIDs
        #expect(interaction.activate(uid: uids[2]) == true)
        #expect(openedUIDs == [uids[2]])
        #expect(selection.selected.isEmpty)
    }

    @Test func modeChangeAppliesToExistingAccessibilityElement() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let coordinator = try #require(
            MetalGridCoordinator(
                device: device, dataSource: ActivateDataSource(),
                gridProfile: TimelineGridProfileConfiguration.production.defaultProfile))
        let selection = MetalGridSelectionController()
        var openedUIDs: [PhotoUID] = []
        let interaction = MetalGridInteractionController(coordinator: coordinator, selection: selection)
        interaction.onOpen = { openedUIDs.append($0) }

        // Outside selection mode: press opens the viewer.
        let uids = coordinator.orderedUIDs
        interaction.selectionMode = false
        #expect(interaction.activate(uid: uids[0]) == true)
        #expect(openedUIDs == [uids[0]])

        // Selection mode turns on AFTER the element exists: the same element must now toggle instead.
        interaction.selectionMode = true
        #expect(interaction.activate(uid: uids[0]) == true)
        #expect(selection.selected == [uids[0]])
        #expect(openedUIDs.count == 1)
    }

    @Test func removedUIDFailsActivation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let coordinator = try #require(
            MetalGridCoordinator(
                device: device, dataSource: ActivateDataSource(),
                gridProfile: TimelineGridProfileConfiguration.production.defaultProfile))
        let selection = MetalGridSelectionController()
        var openedUIDs: [PhotoUID] = []
        let interaction = MetalGridInteractionController(coordinator: coordinator, selection: selection)
        interaction.onOpen = { openedUIDs.append($0) }

        // A UID that no longer exists in the grid must fail without side effects.
        let stale = PhotoUID(volumeID: "a11y-activate", nodeID: "removed")
        #expect(interaction.activate(uid: stale) == false)
        #expect(selection.selected.isEmpty)
        #expect(openedUIDs.isEmpty)
    }

    @Test func accessibilityElementPressRoutesThroughActivation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let coordinator = try #require(
            MetalGridCoordinator(
                device: device, dataSource: ActivateDataSource(),
                gridProfile: TimelineGridProfileConfiguration.production.defaultProfile))
        let selection = MetalGridSelectionController()
        let interaction = MetalGridInteractionController(coordinator: coordinator, selection: selection)
        interaction.selectionMode = true

        let element = MetalGridA11yElement()
        element.uid = coordinator.orderedUIDs[2]
        element.onActivate = { [weak interaction] uid in
            guard let interaction else { return false }
            return interaction.activate(uid: uid)
        }

        #expect(element.accessibilityPerformPress() == true)
        #expect(selection.selected == [coordinator.orderedUIDs[2]])

        // Element without a handler must fail the press.
        let orphan = MetalGridA11yElement()
        orphan.uid = coordinator.orderedUIDs[0]
        #expect(orphan.accessibilityPerformPress() == false)

        // Element without a UID must fail the press.
        let anonymous = MetalGridA11yElement()
        #expect(anonymous.accessibilityPerformPress() == false)
    }
}
