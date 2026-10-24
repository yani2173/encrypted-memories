import DesignSystemCore
import MLSearchFeature
import MediaCacheUIKitAdapter
import PhotosCore
import SwiftUI
import TimelineCore
import UIKit

/// One entry of the in-memory search history with the preview shown next to it.
struct MobileSearchRecentEntry: Identifiable, Equatable {
    let query: String
    let representativeUID: PhotoUID?
    /// Set when the entry came from a structured suggestion, so selecting it again restores the same result.
    let suggestion: TimelineSearchSuggestion?
    /// False while a structured entry waits for current suggestions: it is shown but cannot be selected.
    var isAvailable = true

    var id: String { query }
}

/// Everything the search landing shows while the search field is empty. The native search field itself stays
/// owned by the Search tab; the landing only scrolls above it.
struct MobileSearchLandingContent {
    var recents: [MobileSearchRecentEntry] = []
    var discovery: SmartSearchDiscoveryModel?
    var isUpdatingSuggestions = false
    var onSelectRecent: (MobileSearchRecentEntry) -> Void = { _ in }
    var onSelectSuggestion: (TimelineSearchSuggestion) -> Void = { _ in }
    var onClearHistory: () -> Void = {}
}

struct MobileSearchLandingScreen: View {
    @Environment(MobileLibraryModel.self) private var libraryModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let content: MobileSearchLandingContent
    /// With compact width or height, the search field floats above the keyboard outside its safe area. Keep
    /// 48 pt for the field plus its 8 pt gap, without scaling that space with text. Only regular width and height
    /// place the field at the top, so narrow iPad windows and landscape phones keep the clearance.
    private var searchFieldClearance: CGFloat {
        horizontalSizeClass == .regular && verticalSizeClass == .regular ? 0 : 56
    }

    private var discovery: SmartSearchDiscoveryModel? { content.discovery }

    /// Suggestions are re-checked against the current library revision and search availability at render time,
    /// so a row that can no longer work is never offered.
    private var displayedForYou: [TimelineSearchSuggestion] {
        discovery?.forYou(content: discoveryContent, snapshot: libraryModel.smartSearch?.snapshot) ?? []
    }

    private var displayedChips: [TimelineSearchSuggestion] {
        discovery?.chips(content: discoveryContent, snapshot: libraryModel.smartSearch?.snapshot) ?? []
    }

    private var discoveryContent: SmartSearchContentIdentity {
        SmartSearchContentIdentity(
            timelineRevision: libraryModel.timelineRevision,
            favoriteUIDs: libraryModel.favoriteUIDs
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !content.recents.isEmpty {
                    recentSection
                }
                forYouSection
                if !displayedChips.isEmpty {
                    chipSection(displayedChips)
                }
                notes
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .contentMargins(.bottom, searchFieldClearance, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .background(ProtonColor.backgroundNorm)
    }

    // MARK: Sections

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(L10n.string("search.recent_searches"))
                Spacer()
                Button(L10n.string("search.clear"), action: content.onClearHistory)
                    .font(.subheadline)
            }
            VStack(spacing: 0) {
                ForEach(Array(content.recents.prefix(5).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider().padding(.leading, 60)
                    }
                    Button {
                        content.onSelectRecent(entry)
                    } label: {
                        HStack(spacing: 12) {
                            MobileSearchThumbnail(
                                uid: entry.representativeUID,
                                size: 44,
                                cornerRadius: 10,
                                placeholderSymbol: "clock.arrow.circlepath",
                                thumbnailFeed: libraryModel.thumbnailFeed
                            )
                            Text(entry.query)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.left")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isAvailable)
                }
            }
        }
    }

    @ViewBuilder private var forYouSection: some View {
        let suggestions = displayedForYou
        let isLoading = content.isUpdatingSuggestions && discovery?.hasComputed != true
        if isLoading || !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle(L10n.string("search.for_you"))
                if content.isUpdatingSuggestions, !isLoading {
                    Text(L10n.string("search.suggestions_loading"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    if isLoading {
                        // One sweep over the whole placeholder block, as a single continuous band.
                        VStack(spacing: 0) {
                            ForEach(0..<3, id: \.self) { index in
                                if index > 0 { Divider().padding(.leading, 132) }
                                MobileSearchSuggestionRow(
                                    suggestion: nil,
                                    thumbnailFeed: libraryModel.thumbnailFeed
                                )
                            }
                        }
                        .redacted(reason: .placeholder)
                        .placeholderShimmer()
                        // VoiceOver hears that suggestions are loading, also when Reduce Motion stops the sweep.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.string("search.suggestions_loading"))
                    } else {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            if index > 0 { Divider().padding(.leading, 132) }
                            Button {
                                content.onSelectSuggestion(suggestion)
                            } label: {
                                MobileSearchSuggestionRow(
                                    suggestion: suggestion,
                                    thumbnailFeed: libraryModel.thumbnailFeed
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } else if content.recents.isEmpty {
            ContentUnavailableView(
                L10n.string("search.suggestions_empty"),
                systemImage: "magnifyingglass",
                description: Text(L10n.string("search.suggestions_empty_description"))
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
        }
    }

    private func chipSection(_ chips: [TimelineSearchSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(L10n.string("search.discover"))
            FlowLayout(spacing: 10) {
                ForEach(chips) { chip in
                    Button {
                        content.onSelectSuggestion(chip)
                    } label: {
                        Label(chip.title, systemImage: chip.systemImage)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
        }
    }

    @ViewBuilder private var notes: some View {
        if discovery?.showsVisualSuggestionsPendingNote(libraryModel.smartSearch?.snapshot) == true {
            Label(L10n.string("search.suggestions_indexing"), systemImage: "sparkles")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if discovery?.showsSmartSearchHint == true, discovery?.hasComputed == true {
            Label(L10n.string("search.suggestions_ml_hint"), systemImage: "sparkle.magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
    }
}

/// A "For You" row: two previews from the matching photos, the title and the match count.
private struct MobileSearchSuggestionRow: View {
    let suggestion: TimelineSearchSuggestion?
    let thumbnailFeed: UIKitThumbnailFeed?

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { index in
                    MobileSearchThumbnail(
                        uid: suggestion.flatMap {
                            index < $0.representativeUIDs.count ? $0.representativeUIDs[index] : nil
                        },
                        size: 56,
                        cornerRadius: 12,
                        placeholderSymbol: suggestion?.systemImage ?? "photo",
                        thumbnailFeed: thumbnailFeed
                    )
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion?.title ?? "Placeholder suggestion")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle = suggestion?.subtitle ?? (suggestion == nil ? "000 photos" : nil) {
                    Label(subtitle, systemImage: suggestion?.systemImage ?? "photo")
                        .labelStyle(MobileSearchSubtitleLabelStyle())
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct MobileSearchSubtitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .imageScale(.small)
            configuration.title
                .lineLimit(1)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// A square preview from the authenticated thumbnail cache, with a symbol while it loads or when no item exists.
struct MobileSearchThumbnail: View {
    let uid: PhotoUID?
    let size: CGFloat
    let cornerRadius: CGFloat
    let placeholderSymbol: String
    let thumbnailFeed: UIKitThumbnailFeed?
    @State private var image: UIImage?

    private struct LoadIdentity: Equatable {
        let uid: PhotoUID?
        let feed: ObjectIdentifier?
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProtonColor.primary.opacity(0.18)
                Image(systemName: placeholderSymbol)
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(ProtonColor.primary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task(id: LoadIdentity(uid: uid, feed: thumbnailFeed.map { ObjectIdentifier($0) })) {
            guard let uid, let thumbnailFeed else {
                image = nil
                return
            }
            image = thumbnailFeed.memoryImage(for: uid)
            if image == nil {
                let loaded = await thumbnailFeed.image(for: uid)
                guard !Task.isCancelled else { return }
                image = loaded
            }
        }
    }
}

/// A compact wrapping layout keeps localized suggestions readable on every iPhone width.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? 320
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}
