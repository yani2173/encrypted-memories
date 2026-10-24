import DesignSystemCore
import MediaCacheUIKitAdapter
import PhotoViewerCore
import PhotoViewerUIKitAdapter
import PhotosCore
import SwiftUI
import UIKit
import UploadCore

/// What opens the "Select Favorites" mode: one loaded series and the photo the viewer showed.
struct MobileSeriesSelectionRequest: Identifiable {
    let seriesMainUID: PhotoUID
    let items: [PhotoItem]
    let focusedUID: PhotoUID

    var id: PhotoUID { seriesMainUID }
}

/// Presentation state of the "Select Favorites" mode. The marks and the Confirm choice come from the shared
/// `SeriesFavoritesSelection`; the backend operation is injected, so the mode never knows the transport.
@MainActor @Observable
final class MobileSeriesFavoritesModel: Identifiable {
    typealias KeepOnlyFavorites =
        @MainActor (_ favoriteUIDs: [PhotoUID], _ onProgress: @escaping @Sendable (SeriesDissolutionProgress) -> Void)
        async throws -> Void

    enum Operation: Equatable {
        case idle
        case running(SeriesDissolutionProgress?)
        case failed(String)
    }

    private(set) var selection: SeriesFavoritesSelection
    private(set) var operation: Operation = .idle
    var showsKeepChoice = false
    private let keepOnlyFavorites: KeepOnlyFavorites
    private let abandonKeepOnlyFavorites: @MainActor () -> Void
    /// True after a failed attempt that no later attempt finished: its journal can still be pending.
    private var hasUnfinishedAttempt = false
    private let onFinished: @MainActor (_ seriesDissolved: Bool) -> Void

    init(
        request: MobileSeriesSelectionRequest,
        canKeepOnlyFavorites: Bool,
        keepOnlyFavorites: @escaping KeepOnlyFavorites,
        abandonKeepOnlyFavorites: @escaping @MainActor () -> Void,
        onFinished: @escaping @MainActor (_ seriesDissolved: Bool) -> Void
    ) {
        selection = SeriesFavoritesSelection(
            items: request.items,
            focusedUID: request.focusedUID,
            canKeepOnlyFavorites: canKeepOnlyFavorites
        )
        self.keepOnlyFavorites = keepOnlyFavorites
        self.abandonKeepOnlyFavorites = abandonKeepOnlyFavorites
        self.onFinished = onFinished
    }

    var isRunning: Bool {
        if case .running = operation { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = operation { return message }
        return nil
    }

    func focus(index: Int) {
        selection.focus(index: index)
    }

    func toggleFavorite(_ uid: PhotoUID) {
        guard !isRunning else { return }
        selection.toggleFavorite(uid)
    }

    func cancel() {
        guard !isRunning else { return }
        closeKeepingTheSeries()
    }

    func confirm() {
        guard !isRunning else { return }
        switch selection.confirmation {
        case .close: closeKeepingTheSeries()
        case .choose: showsKeepChoice = true
        }
    }

    /// "Keep Everything" changes nothing: no backend call, the series stays a series.
    func keepEverything() {
        closeKeepingTheSeries()
    }

    /// Every exit that keeps the series. After a failed attempt the user abandons the operation here, so its
    /// journal must not survive: nothing may finish "Keep Only Favorites" later without the user.
    private func closeKeepingTheSeries() {
        if hasUnfinishedAttempt {
            hasUnfinishedAttempt = false
            abandonKeepOnlyFavorites()
        }
        onFinished(false)
    }

    /// Runs or resumes "Keep Only N Favorites". The journaled operation makes a repeated call safe.
    func keepOnlyMarkedFavorites() async {
        guard !isRunning else { return }
        operation = .running(nil)
        do {
            try await keepOnlyFavorites(selection.orderedFavoriteUIDs) { [weak self] progress in
                Task { @MainActor in
                    // Each callback hops to the main actor on its own, so callbacks can arrive out of order.
                    // The bar only moves forward.
                    guard let self, case .running(let shown) = self.operation,
                        progress.fraction >= shown?.fraction ?? 0
                    else { return }
                    self.operation = .running(progress)
                }
            }
            hasUnfinishedAttempt = false
            operation = .idle
            onFinished(true)
        } catch {
            hasUnfinishedAttempt = true
            operation = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func dismissFailure() {
        guard failureMessage != nil else { return }
        operation = .idle
    }
}

/// The full-screen "Select Favorites" mode of a series, as in the Photos app: a paging carousel with neighbor
/// previews and a selection circle per photo, a filmstrip with a position marker, Cancel and Confirm in the bar.
/// A series outside the own library opens the same screen without marks and without Confirm.
struct MobileSeriesFavoritesScreen: View {
    @State private var model: MobileSeriesFavoritesModel
    @State private var scrolledUID: PhotoUID?
    @State private var imageStore: UIKitViewerImageStore
    private let feed: UIKitThumbnailFeed?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: MobileSeriesFavoritesModel, libraryModel: MobileLibraryModel) {
        _model = State(initialValue: model)
        _scrolledUID = State(initialValue: model.selection.focusedItem?.uid)
        let feed = libraryModel.thumbnailFeed
        self.feed = feed
        _imageStore = State(
            initialValue: UIKitViewerImageStore(
                thumbnailProvider: { feed?.memoryImage(for: $0) },
                media: libraryModel.backend
            ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                carousel
                filmstrip
            }
            .padding(.bottom, 8)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(
                String(
                    localized: model.selection.canKeepOnlyFavorites
                        ? "series.select_favorites_title" : "series.browse_title")
            )
            .toolbarTitleDisplayMode(.inline)
            .toolbar { bars }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .overlay { progressOverlay }
        }
        .tint(nil)
        .interactiveDismissDisabled(model.isRunning)
        .alert(
            String(localized: "series.failed_title"),
            isPresented: Binding(
                get: { model.failureMessage != nil },
                set: { if !$0 { model.dismissFailure() } }
            )
        ) {
            Button(RetryButton.title) { Task { await model.keepOnlyMarkedFavorites() } }
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(
                [model.failureMessage, String(localized: "series.failed_recovery")]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")
            )
        }
    }

    @ToolbarContentBuilder private var bars: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) {
                model.cancel()
            }
            .disabled(model.isRunning)
            .accessibilityIdentifier("series.cancel")
        }
        if model.selection.canKeepOnlyFavorites {
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .confirm) {
                    model.confirm()
                }
                .disabled(model.isRunning)
                .accessibilityIdentifier("series.confirm")
                // The choice is anchored to Confirm, so a regular-width window shows it as a popover there.
                .confirmationDialog(
                    String(localized: "series.keep_choice_message"),
                    isPresented: $model.showsKeepChoice,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "series.keep_everything")) { model.keepEverything() }
                    if case .choose(let favoriteCount) = model.selection.confirmation {
                        Button(String(localized: "series.keep_only_favorites \(favoriteCount)")) {
                            Task { await model.keepOnlyMarkedFavorites() }
                        }
                    }
                    Button(L10n.string("action.cancel"), role: .cancel) {}
                }
            }
        }
    }

    /// One photo per page. The horizontal content margins leave the edges of both neighbors visible.
    private var carousel: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(Array(model.selection.items.enumerated()), id: \.element.uid) { index, item in
                    MobileSeriesPage(
                        item: item,
                        position: index + 1,
                        total: model.selection.items.count,
                        // Only the focused photo and its neighbors decode a preview; the rest stay thumbnails.
                        loadsPreview: abs(index - model.selection.focusedIndex) <= 1,
                        isFavorite: model.selection.isFavorite(item.uid),
                        showsMark: model.selection.canKeepOnlyFavorites,
                        feed: feed,
                        imageStore: imageStore,
                        onToggle: { model.toggleFavorite(item.uid) }
                    )
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 28, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrolledUID, anchor: .center)
        .scrollIndicators(.hidden)
        .scrollDisabled(model.isRunning)
        .onChange(of: scrolledUID) { _, uid in
            guard let uid, let index = model.selection.items.firstIndex(where: { $0.uid == uid }) else { return }
            model.focus(index: index)
        }
    }

    /// The marker is fixed at the center, because the strip keeps the focused photo centered below it.
    private var filmstrip: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityHidden(true)
            MobileViewerFilmstrip(
                items: model.selection.items,
                selectedUID: model.selection.focusedItem?.uid,
                feed: feed,
                itemSide: 40,
                itemSpacing: 2,
                onSelect: { uid in
                    withAnimation(
                        MobileViewerMotionPolicy.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion)
                    ) {
                        scrolledUID = uid
                    }
                }
            )
            .frame(height: 44)
            .disabled(model.isRunning)
        }
    }

    @ViewBuilder private var progressOverlay: some View {
        if case .running(let progress) = model.operation {
            ActivityProgressStateLayout(hugsLine: true) {
                ActivityProgressRow(
                    title: nil, detail: progressText(progress), fraction: progress?.fraction ?? 0, alignment: .center)
            }
            .multilineTextAlignment(.center)
            .padding(20)
            .glassEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private func progressText(_ progress: SeriesDissolutionProgress?) -> String {
        switch progress?.step {
        case .movingSeriesToTrash:
            String(localized: "series.progress_trashing")
        case .copyingFavorite(let index, let count):
            String(localized: "series.progress_copying \(index + 1) \(count)")
        case nil:
            String(localized: "series.progress_copying \(1) \(model.selection.favoriteUIDs.count)")
        }
    }
}

/// One carousel page: the thumbnail at once, then a bounded preview, with the selection circle on the photo.
private struct MobileSeriesPage: View {
    let item: PhotoItem
    let position: Int
    let total: Int
    let loadsPreview: Bool
    let isFavorite: Bool
    let showsMark: Bool
    let feed: UIKitThumbnailFeed?
    let imageStore: UIKitViewerImageStore
    let onToggle: () -> Void

    @State private var thumbnail: UIImage?
    @State private var preview: UIImage?

    private static let previewPixelSize = 2048

    var body: some View {
        ZStack {
            Color.clear
            if let image = preview ?? thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay(alignment: .bottomTrailing) {
                        if showsMark { mark }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .task(id: item.uid) {
            thumbnail = feed?.memoryImage(for: item.uid)
            guard thumbnail == nil, let feed else { return }
            thumbnail = await MobileThumbnailArrival.image(for: item.uid, feed: feed)
        }
        .task(id: loadsPreview) {
            guard loadsPreview, preview == nil else { return }
            let loaded = await imageStore.displayImage(for: item.uid, maxPixelSize: Self.previewPixelSize)
            guard !Task.isCancelled else { return }
            preview = loaded?.image
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("a11y.photo"))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(showsMark ? String(localized: "series.favorite_toggle_hint") : "")
        .accessibilityAddTraits(showsMark ? (isFavorite ? [.isButton, .isSelected] : .isButton) : .isImage)
        .accessibilityIdentifier("series.page.\(position)")
    }

    private var mark: some View {
        Image(systemName: isFavorite ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.white, isFavorite ? Color.accentColor : Color.clear)
            .shadow(color: .black.opacity(0.45), radius: 2)
            .padding(10)
    }

    private var accessibilityValue: String {
        let positionText = L10n.string("a11y.grid.position \(position) \(total)")
        return isFavorite ? "\(positionText), \(String(localized: "series.favorite_selected"))" : positionText
    }
}
