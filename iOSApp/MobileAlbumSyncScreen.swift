import AlbumSyncCore
import DesignSystemCore
import PhotoLibraryBackupAdapter
import PhotosCore
import SwiftUI

/// Renders selected local-album mappings from the shared sync controller.
/// Removing a row stops syncing that album without deleting its Proton mapping.
struct MobileAlbumSyncScreen: View {
    @State var controller: AlbumSyncController
    @State private var showPicker = false
    @State private var problemListAlbumID: String?

    var body: some View {
        List {
            if !controller.isAvailable {
                Text(String(localized: "settings.albumsync_unavailable"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                selectedSection
                if controller.isSyncing {
                    progressSection
                }
                if let message = controller.lastMessage {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(controller.lastMessageStyle == .information ? Color.secondary : Color.red)
                    }
                }
            }
        }
        .mobileNavigationTitle(String(localized: "settings.albumsync_title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPicker = true
                } label: {
                    Label(L10n.string("settings.albumsync_add_albums"), systemImage: "plus")
                }
                .disabled(!controller.isAvailable)
            }
            .mobileVisibilityPriority(.high)
        }
        .sheet(isPresented: $showPicker) {
            MobileAlbumPickerSheet(controller: controller)
        }
        .sheet(
            isPresented: Binding(
                get: { problemListAlbumID != nil }, set: { if !$0 { problemListAlbumID = nil } })
        ) {
            if let problemListAlbumID {
                MobileFailedBackupSheet(albumSync: controller, albumID: problemListAlbumID)
            }
        }
        .alert(
            L10n.string("settings.albumsync_conflict_title"),
            isPresented: conflictPresented
        ) {
            if let conflict = controller.pendingConflict, conflict.existing.count == 1,
                let existing = conflict.existing.first
            {
                Button(L10n.string("settings.albumsync_use_existing")) {
                    controller.resolveConflict(useExisting: existing.id)
                }
            }
            Button(L10n.string("action.cancel"), role: .cancel) {
                controller.resolveConflict(useExisting: nil)
            }
        } message: {
            if let conflict = controller.pendingConflict {
                if conflict.existing.count > 1 {
                    Text(L10n.string("settings.albumsync_conflict_multiple"))
                } else {
                    Text(L10n.string("settings.albumsync_conflict_message \(conflict.album.title)"))
                }
            }
        }
    }

    // MARK: - Selected albums

    @ViewBuilder private var selectedSection: some View {
        Section {
            if controller.selectedAlbums.isEmpty {
                Button {
                    showPicker = true
                } label: {
                    Label(L10n.string("settings.albumsync_add_albums"), systemImage: "plus")
                }
            }
            ForEach(controller.selectedAlbums) { album in
                selectedRow(album)
            }
            if !controller.selectedAlbums.isEmpty {
                if controller.isSyncing {
                    Button(String(localized: "settings.albumsync_stop"), role: .destructive) {
                        controller.stopSync()
                    }
                } else {
                    Button(L10n.string("settings.albumsync_sync_all")) {
                        controller.syncSelected()
                    }
                }
            }
        } footer: {
            Text(L10n.string("settings.albumsync_explainer"))
        }
    }

    @ViewBuilder
    private func selectedRow(_ album: AlbumSyncController.SelectedAlbum) -> some View {
        let isActive = controller.isSyncing && controller.progress.localAlbumID == album.id
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let count = album.assetCount {
                        Text(L10n.string("settings.albumsync_photo_count \(count)"))
                    }
                    if !isActive, album.showsProblemList {
                        // Opens the shared problem list with this album's photos; Sync now is the retry.
                        Button {
                            problemListAlbumID = album.id
                        } label: {
                            HStack(spacing: 4) {
                                Text(album.localizedRowStatusDescription)
                                Image(systemName: "chevron.right").font(.caption2)
                            }
                            .foregroundStyle(stateColor(album, isActive: isActive))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("albumsync.notInAlbum.\(album.id)")
                    } else {
                        Text(isActive ? controller.progress.localizedTitle : album.localizedRowStatusDescription)
                            .foregroundStyle(stateColor(album, isActive: isActive))
                    }
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                ProgressSpinner()
            } else if album.state == .needsDecision {
                Button(L10n.string("settings.albumsync_decide")) {
                    controller.presentConflict(albumID: album.id)
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    controller.removeFromSelection(album.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(L10n.string("settings.albumsync_remove")))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                controller.removeFromSelection(album.id)
            } label: {
                Label(L10n.string("settings.albumsync_remove"), systemImage: "xmark.circle")
            }
            .disabled(isActive)
        }
    }

    private func stateColor(_ album: AlbumSyncController.SelectedAlbum, isActive: Bool) -> Color {
        if isActive { return .secondary }
        if album.hasNeedsAttention { return .orange }
        switch album.state {
        case .missingLocally, .needsDecision: return .orange
        case .notSynced, .synced: return .secondary
        }
    }

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(controller.progress.albumTitle)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    Text(controller.progress.localizedTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let detail = controller.progress.localizedDetail {
                    Text(detail)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressSpinner()
            }
        }
    }

    private var conflictPresented: Binding<Bool> {
        Binding(
            get: { controller.pendingConflict != nil },
            set: { presented in
                if !presented, controller.pendingConflict != nil {
                    controller.resolveConflict(useExisting: nil)
                }
            }
        )
    }
}

/// The album picker. Confirmation replaces the full selection.
/// Opening the sheet is the explicit user action that may trigger the photo-access prompt.
private struct MobileAlbumPickerSheet: View {
    @State var controller: AlbumSyncController
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Set<String> = []
    @State private var searchText = ""
    @State private var didLoad = false

    private var filteredAlbums: [LocalAlbumSummary] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return controller.availableAlbums }
        return controller.availableAlbums.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if controller.isLoadingAlbums && !didLoad {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if controller.accessState == .denied || controller.accessState == .restricted {
                    ContentUnavailableView(
                        String(localized: "settings.photos_backup_denied_ios"),
                        systemImage: "lock.rectangle.stack"
                    )
                } else if filteredAlbums.isEmpty {
                    ContentUnavailableView(
                        L10n.string("settings.albumsync_picker_empty"),
                        systemImage: "rectangle.stack"
                    )
                } else {
                    List(filteredAlbums) { album in
                        let isSelected = draft.contains(album.id)
                        Button {
                            toggle(album.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    .imageScale(.large)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(L10n.string("settings.albumsync_photo_count \(album.assetCount)"))
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            // The whole row toggles; the plain style keeps the text out of the tint color.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .mobileNavigationTitle(L10n.string("settings.albumsync_picker_title"))
            .searchable(text: $searchText, prompt: L10n.string("settings.albumsync_picker_search"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("action.cancel")) { dismiss() }
                }
                .mobileVisibilityPriority(.high)
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("settings.albumsync_picker_apply")) {
                        controller.applySelection(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!didLoad || draft == controller.selectedAlbumIDs)
                }
                .mobileVisibilityPriority(.high)
                if !draft.isEmpty {
                    ToolbarItem(placement: .status) {
                        // The .status pill constrains width; keep the full text ("3 Alben"), not "3 Al…".
                        Text(L10n.string("settings.albumsync_picker_selected \(draft.count)"))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .task {
            await controller.loadAvailableAlbums()
            if !didLoad {
                draft = controller.selectedAlbumIDs
                didLoad = true
            }
        }
    }

    private func toggle(_ id: String) {
        if draft.contains(id) { draft.remove(id) } else { draft.insert(id) }
    }
}
