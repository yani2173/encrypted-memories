import AlbumCore
import DesignSystemCore
import PhotosCore
import SwiftUI

/// Shared adaptive name form. The system presentation supplied by each platform remains native;
/// validation, progress and partial-success behavior stay identical.
public struct AlbumCreationSheet: View {
    private let coordinator: AlbumActionCoordinator
    private let photoUIDs: [PhotoUID]
    private let onAlbumsChanged: () -> Void
    private let onCompleted: (AlbumID) -> Void

    public init(
        coordinator: AlbumActionCoordinator,
        photoUIDs: [PhotoUID] = [],
        onAlbumsChanged: @escaping () -> Void = {},
        onCompleted: @escaping (AlbumID) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.photoUIDs = photoUIDs
        self.onAlbumsChanged = onAlbumsChanged
        self.onCompleted = onCompleted
    }

    public var body: some View {
        NavigationStack {
            AlbumNameForm(
                coordinator: coordinator,
                photoUIDs: photoUIDs,
                showsCancel: true,
                onAlbumsChanged: onAlbumsChanged,
                onCompleted: onCompleted
            )
        }
        .presentationSizing(.fitted)
        #if os(macOS)
            .frame(width: 360, height: photoUIDs.isEmpty ? 170 : 195)
        #else
            .presentationDetents([.height(photoUIDs.isEmpty ? 210 : 250)])
            .presentationDragIndicator(.visible)
        #endif
        .albumActionFailureAlert(coordinator)
    }
}

/// Compact destination chooser designed for a toolbar popover. On iOS 26 a toolbar popover morphs
/// directly from its Liquid Glass source control; macOS uses the same native presentation behavior.
public struct AlbumDestinationPicker: View {
    private let coordinator: AlbumActionCoordinator
    private let photoUIDs: [PhotoUID]
    private let onAlbumsChanged: () -> Void
    private let onCompleted: (AlbumID) -> Void

    @Environment(\.dismiss) private var dismiss

    public init(
        coordinator: AlbumActionCoordinator,
        photoUIDs: [PhotoUID],
        onAlbumsChanged: @escaping () -> Void = {},
        onCompleted: @escaping (AlbumID) -> Void
    ) {
        self.coordinator = coordinator
        self.photoUIDs = photoUIDs
        self.onAlbumsChanged = onAlbumsChanged
        self.onCompleted = onCompleted
    }

    public var body: some View {
        NavigationStack {
            Group {
                #if os(macOS)
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink {
                            AlbumNameForm(
                                coordinator: coordinator,
                                photoUIDs: photoUIDs,
                                showsCancel: false,
                                onAlbumsChanged: onAlbumsChanged,
                                onCompleted: onCompleted
                            )
                        } label: {
                            Label(L10n.string("albums.create_new_action"), systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(!coordinator.canCreate || !coordinator.canAddPhotos || coordinator.isWorking)

                        Divider()

                        Text(L10n.string("albums.existing_section"))
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        ScrollView {
                            LazyVStack(spacing: 6) {
                                destinationRows
                            }
                        }
                    }
                    .padding(16)
                #else
                    List {
                        Section {
                            NavigationLink {
                                AlbumNameForm(
                                    coordinator: coordinator,
                                    photoUIDs: photoUIDs,
                                    showsCancel: false,
                                    onAlbumsChanged: onAlbumsChanged,
                                    onCompleted: onCompleted
                                )
                            } label: {
                                Label(L10n.string("albums.create_new_action"), systemImage: "plus")
                            }
                            .disabled(!coordinator.canCreate || !coordinator.canAddPhotos || coordinator.isWorking)
                        }

                        Section(L10n.string("albums.existing_section")) {
                            destinationRows
                        }
                    }
                #endif
            }
            .navigationTitle(L10n.string("albums.add_selection_title"))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("action.cancel")) { dismiss() }
                }
            }
        }
        .presentationSizing(.fitted)
        #if os(macOS)
            .frame(width: 330, height: pickerHeight)
        #else
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #endif
        .task(id: photoUIDs) {
            async let catalog: Void = coordinator.refresh()
            async let memberships: Void = coordinator.loadMemberships(for: photoUIDs)
            _ = await (catalog, memberships)
        }
        .albumActionFailureAlert(coordinator)
        #if os(iOS)
            // The destination list has no useful fitted popover width on a compact iPhone. Let the native
            // presentation become a sheet there; regular-width iPad keeps the source-anchored popover.
            .presentationCompactAdaptation(.sheet)
        #endif
    }

    #if os(macOS)
        private var pickerHeight: CGFloat {
            coordinator.albums.isEmpty ? 210 : min(390, 145 + CGFloat(coordinator.albums.count) * 42)
        }
    #endif

    @ViewBuilder private var destinationRows: some View {
        if coordinator.isLoading, coordinator.albums.isEmpty {
            HStack(spacing: 10) {
                ProgressSpinner()
                Text(L10n.string("albums.loading"))
            }
        } else if let message = coordinator.loadErrorMessage, coordinator.albums.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                RetryButton(.compact) { Task { await coordinator.refresh() } }
            }
        } else if coordinator.albums.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(L10n.string("albums.none_available"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            ForEach(coordinator.albums) { album in
                let membershipState = coordinator.membershipState(for: album.id)
                Button {
                    Task {
                        guard await coordinator.add(photoUIDs, to: album.id) else { return }
                        onAlbumsChanged()
                        onCompleted(album.id)
                    }
                } label: {
                    HStack {
                        Label(album.title, systemImage: "rectangle.stack")
                        Spacer()
                        if membershipState == .all {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel(L10n.string("albums.membership_all"))
                        } else if membershipState == .some {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(L10n.string("albums.membership_some"))
                        }
                        Text(album.photoCount, format: .number)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    #if os(macOS)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    #endif
                }
                #if os(macOS)
                    .buttonStyle(.plain)
                #endif
                .disabled(coordinator.isWorking || membershipState == .all)
            }
        }
    }
}

private struct AlbumNameForm: View {
    let coordinator: AlbumActionCoordinator
    let photoUIDs: [PhotoUID]
    let showsCancel: Bool
    let onAlbumsChanged: () -> Void
    let onCompleted: (AlbumID) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        nameContent
            .navigationTitle(L10n.string("albums.create_title"))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if showsCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("action.cancel")) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        photoUIDs.isEmpty
                            ? L10n.string("albums.create_action")
                            : L10n.string("albums.create_and_add_action")
                    ) {
                        create()
                    }
                    .disabled(trimmedName.isEmpty || coordinator.isWorking)
                }
            }
            .overlay {
                if coordinator.isWorking {
                    ProgressView().controlSize(.large)
                }
            }
            .onAppear { nameFocused = true }
    }

    @ViewBuilder private var nameContent: some View {
        #if os(macOS)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("albums.name_label"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                nameField
                if !photoUIDs.isEmpty {
                    Text(
                        photoUIDs.count == 1
                            ? L10n.string("albums.create_add_footer_one")
                            : L10n.string("albums.create_add_footer \(photoUIDs.count)")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        #else
            Form {
                Section {
                    nameField
                } header: {
                    Text(L10n.string("albums.name_label"))
                } footer: {
                    if !photoUIDs.isEmpty {
                        Text(
                            photoUIDs.count == 1
                                ? L10n.string("albums.create_add_footer_one")
                                : L10n.string("albums.create_add_footer \(photoUIDs.count)"))
                    }
                }
            }
        #endif
    }

    private var nameField: some View {
        TextField(L10n.string("albums.name_placeholder"), text: $name)
            .textContentType(.name)
            .focused($nameFocused)
            .submitLabel(.done)
            .onSubmit(create)
    }

    private func create() {
        guard !trimmedName.isEmpty, !coordinator.isWorking else { return }
        Task {
            guard let outcome = await coordinator.createAlbum(name: trimmedName, adding: photoUIDs) else { return }
            onAlbumsChanged()
            switch outcome {
            case .completed(let albumID):
                onCompleted(albumID)
            case .albumCreatedNeedsMembershipRetry:
                // Stay in the picker. The shared failure explains that the album exists; returning
                // manually reveals it in the refreshed list for a membership-only retry.
                break
            }
        }
    }
}

extension View {
    /// Presents the coordinator's last album action failure once, with the shared title and message. Hosts whose
    /// album support is optional pass `nil` and show nothing.
    public func albumActionFailureAlert(_ coordinator: AlbumActionCoordinator?) -> some View {
        alert(
            coordinator?.actionFailure?.title ?? "",
            isPresented: Binding(
                get: { coordinator?.actionFailure != nil },
                set: { if !$0 { coordinator?.clearActionFailure() } }
            )
        ) {
            Button(L10n.string("albums.failure_done"), role: .cancel) {
                coordinator?.clearActionFailure()
            }
        } message: {
            Text(coordinator?.actionFailure?.message ?? "")
        }
    }
}
