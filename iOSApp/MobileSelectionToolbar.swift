import DesignSystemCore
import PhotosCore
import SwiftUI

/// One native selection bar for every grid surface: library, filtered collections, album grids and map clusters.
///
/// Every action is a separate native toolbar item with a symbol-and-title label. Horizontal bars show the
/// symbol; vertical bars and overflow menus (iPhone Duo) can use the title. All items stay mounted so the
/// system morphs the bar in one transition; `mobileSelectionBars` hides the bar outside selection, which is
/// the verified iOS 26/27 chrome contract (a transparent item alone still paints a full-width background).
/// `ToolbarSpacer(.flexible)` is the documented system space item ("Spacers can ... be flexible and push items
/// apart"); it separates the three Liquid Glass groups and adapts with the bar, unlike manual padding.
struct MobileSelectionToolbarItems<AlbumPicker: View>: ToolbarContent {
    let selection: MobileGridSelectionController
    /// Whether the surface can add the selection to an album (the shared album coordinator is available).
    let canAddToAlbum: Bool
    /// Surface-specific busy state (for example removing photos from an album) that also disables Trash.
    var isTrashBusy = false
    @Binding var showAlbumPicker: Bool
    let onShare: () -> Void
    let onTrash: () -> Void
    @ViewBuilder let albumPicker: () -> AlbumPicker

    private var isSelecting: Bool { selection.isSelecting }
    private var actionsDisabled: Bool { selection.selected.isEmpty || selection.isBusy }

    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button(action: onShare) {
                if selection.isExporting {
                    ProgressSpinner()
                } else {
                    Label(String(localized: "viewer.share_action"), systemImage: "square.and.arrow.up")
                }
            }
            .disabled(actionsDisabled)
            .accessibilityLabel(String(localized: "selection.share_a11y"))
            .mobileSelectionItemVisibility(isSelecting)
        }
        .sharedBackgroundVisibility(isSelecting ? .automatic : .hidden)
        .mobileVisibilityPriority(.high)
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            // The selected count is the bar title in selection mode (`barTitle(default:)`), so this slot is a
            // symbol item like its neighbours and a vertical bar can show it.
            Button {
                showAlbumPicker = true
            } label: {
                Label(L10n.string("albums.add_selection_title"), systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(actionsDisabled || !canAddToAlbum)
            .accessibilityLabel(L10n.string("albums.add_selection_title"))
            .popover(isPresented: $showAlbumPicker, arrowEdge: .bottom) { albumPicker() }
            .mobileSelectionItemVisibility(isSelecting)
        }
        .sharedBackgroundVisibility(isSelecting ? .automatic : .hidden)
        // Album filing is the least frequent selection action; it leaves a compressed bar before Share and Trash.
        .mobileVisibilityPriority(.low)
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button(role: .destructive, action: onTrash) {
                Label(String(localized: "viewer.move_to_trash_action"), systemImage: "trash")
            }
            .disabled(actionsDisabled || isTrashBusy)
            .accessibilityLabel(String(localized: "selection.trash_a11y"))
            .mobileSelectionItemVisibility(isSelecting)
        }
        .sharedBackgroundVisibility(isSelecting ? .automatic : .hidden)
        .mobileVisibilityPriority(.high)
    }
}

extension MobileGridSelectionController {
    /// The bar title of a grid route. In selection mode the selected count replaces the route title, the way
    /// the Photos app reports "Select Items" and "3 Items Selected"; the bottom bar then keeps symbol items only.
    func barTitle(default title: String) -> String {
        isSelecting ? L10n.selectionCenterText(selectedCount: selected.count) : title
    }
}

/// How strongly a toolbar item resists moving into the system overflow menu when a bar compresses.
enum MobileToolbarItemPriority {
    /// Stays in the bar as long as possible: the one action a person needs to leave a mode or finish a task.
    case high
    /// Moves into the overflow menu first: reachable elsewhere (menu bar, keyboard command) or rarely used.
    case low
}

extension ToolbarContent {
    /// Overflow order for compressed bars. Adaptive bars and narrow windows can move items into the system
    /// overflow menu; the priority keeps mode-critical
    /// actions in the bar. The system decides the bar axis, edge and overflow; this only ranks the items.
    /// Below iOS 27 the item keeps the default order.
    @ToolbarContentBuilder func mobileVisibilityPriority(_ priority: MobileToolbarItemPriority) -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            visibilityPriority(priority == .high ? .high : .low)
        } else {
            self
        }
    }
}

extension View {
    /// Keeps a selection item mounted for native bar transitions while removing it from touch and
    /// accessibility outside selection mode.
    func mobileSelectionItemVisibility(_ isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}
