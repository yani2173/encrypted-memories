import AlbumCore
import DesignSystemCore
import PhotosCore
import SwiftUI

#if os(iOS)
    /// Presentation facts are captured before opening a sheet or popover.
    public enum AlbumPresentationTraits {
        /// Whether an album presentation gets the bounded size. Only a compact width with a regular height, an
        /// iPhone in portrait or a narrow iPad window, shows a sheet across the whole width. Anywhere else the fitted presentation, a popover
        /// or a sheet in landscape, has no useful width of its own: without the bound it shrinks to its narrowest
        /// content.
        public static func usesRegularSizing(
            horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?
        ) -> Bool {
            horizontal == .regular || vertical == .compact
        }
    }
#endif

/// Shared adaptive name form. The system presentation supplied by each platform remains native;
/// validation, progress and partial-success behavior stay identical.
public struct AlbumCreationSheet: View {
    private let coordinator: AlbumActionCoordinator
    private let photoUIDs: [PhotoUID]
    private let regularPresentation: Bool
    private let onAlbumsChanged: () -> Void
    private let onCompleted: (AlbumID) -> Void

    public init(
        coordinator: AlbumActionCoordinator,
        photoUIDs: [PhotoUID] = [],
        regularPresentation: Bool = false,
        onAlbumsChanged: @escaping () -> Void = {},
        onCompleted: @escaping (AlbumID) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.photoUIDs = photoUIDs
        self.regularPresentation = regularPresentation
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
            .modifier(
                AlbumRegularPresentationSize(
                    width: 360, height: photoUIDs.isEmpty ? 210 : 250, regular: regularPresentation)
            )
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
    private let regularPresentation: Bool?
    private let onAlbumsChanged: () -> Void
    private let onCompleted: (AlbumID) -> Void

    @Environment(\.dismiss) private var dismiss

    public init(
        coordinator: AlbumActionCoordinator,
        photoUIDs: [PhotoUID],
        regularPresentation: Bool? = nil,
        onAlbumsChanged: @escaping () -> Void = {},
        onCompleted: @escaping (AlbumID) -> Void
    ) {
        self.coordinator = coordinator
        self.photoUIDs = photoUIDs
        self.regularPresentation = regularPresentation
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
                    Button {
                        dismiss()
                    } label: {
                        Label(L10n.string("action.cancel"), systemImage: "xmark").textBarItem()
                    }
                }
            }
        }
        .presentationSizing(.fitted)
        #if os(macOS)
            .frame(width: 330, height: pickerHeight)
        #else
            .modifier(
                AlbumRegularPresentationSize(width: 330, height: 390, regular: regularPresentation ?? false)
            )
            .presentationDetents(regularPresentation == true ? [.height(390)] : [.medium, .large])
            .presentationDragIndicator(.visible)
        #endif
        .task(id: photoUIDs) {
            async let catalog: Void = coordinator.refresh()
            async let memberships: Void = coordinator.loadMemberships(for: photoUIDs)
            _ = await (catalog, memberships)
        }
        .albumActionFailureAlert(coordinator)
        #if os(iOS)
            // A compact width turns the popover into the native sheet; a regular width, an iPad or a large iPhone in
            // landscape, keeps the source-anchored popover. Both get the bounded size except a full-width sheet.
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
                if coordinator.loadFailure?.canRetry == true {
                    RetryButton(.compact) { Task { await coordinator.refresh() } }
                }
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

#if os(iOS)
    /// Give fitted presentations a bounded ideal size. Only a full-width sheet, a compact width with a regular
    /// height, keeps its native detents.
    private struct AlbumRegularPresentationSize: ViewModifier {
        let width: CGFloat
        let height: CGFloat
        let regular: Bool

        func body(content: Content) -> some View {
            if regular {
                content.frame(idealWidth: width, maxWidth: width, idealHeight: height)
            } else {
                content
            }
        }
    }
#endif

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
                        Button {
                            dismiss()
                        } label: {
                            Label(L10n.string("action.cancel"), systemImage: "xmark").textBarItem()
                        }
                    }
                }
                ProminentToolbarItem(placement: .confirmationAction) {
                    Button {
                        create()
                    } label: {
                        Label(
                            photoUIDs.isEmpty
                                ? L10n.string("albums.create_action")
                                : L10n.string("albums.create_and_add_action"),
                            systemImage: "plus"
                        )
                        .textBarItem()
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
