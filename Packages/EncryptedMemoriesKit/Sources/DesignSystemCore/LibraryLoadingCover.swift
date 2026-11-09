import SwiftUI

/// Shared presentation for the full-window library loading cover. Core owns every visual and accessibility
/// decision; platform adapters provide only the native material that samples content behind this view.
public struct LibraryLoadingCover<Backdrop: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let isPresented: Bool
    private let accessibilityLabel: String
    private let activityMessage: String?
    private let activityState: LibraryActivityBannerState
    private let showsLoadingContent: Bool
    private let contentBounds: CGRect?
    private let backdrop: (Bool) -> Backdrop

    public init(
        isPresented: Bool,
        accessibilityLabel: String,
        activityMessage: String? = nil,
        activityState: LibraryActivityBannerState = .working,
        // A host may retain the exact same backdrop while presenting its own interactive center content.
        showsLoadingContent: Bool = true,
        contentBounds: CGRect? = nil,
        @ViewBuilder backdrop: @escaping (_ isActive: Bool) -> Backdrop
    ) {
        self.isPresented = isPresented
        self.accessibilityLabel = accessibilityLabel
        self.activityMessage = activityMessage
        self.activityState = activityState
        self.showsLoadingContent = showsLoadingContent
        self.contentBounds = contentBounds
        self.backdrop = backdrop
    }

    private var loadingMark: some View {
        LoadingMark()
            .frame(width: LibraryLoadingCoverMetrics.markSize, height: LibraryLoadingCoverMetrics.markSize)
            .shadow(color: .black.opacity(0.22), radius: 16)
            .transition(reduceMotion ? .identity : .scale(scale: 0.96).combined(with: .opacity))
    }

    private func activityBanner(_ message: String) -> some View {
        LibraryActivityBanner(message: message, state: activityState)
            .libraryLoadingActivityTransitionSource()
            .transition(.opacity)
    }

    public var body: some View {
        ZStack {
            if reduceTransparency {
                if isPresented {
                    ProtonColor.backgroundNorm
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            } else {
                // The adapter stays mounted. UIKit must animate its effect at alpha 1; AppKit may animate
                // its native surface. Parent opacity would render UIKit material incorrectly.
                backdrop(isPresented)
                    .ignoresSafeArea()
            }

            if isPresented && showsLoadingContent {
                if let contentBounds {
                    LibraryLoadingBlockLayout {
                        loadingMark
                        if let activityMessage { activityBanner(activityMessage) }
                    }
                    .frame(width: contentBounds.width, height: contentBounds.height)
                    .position(x: contentBounds.midX, y: contentBounds.midY)
                } else {
                    loadingMark
                    if let activityMessage {
                        activityBanner(activityMessage)
                            .offset(y: LibraryLoadingCoverMetrics.activityBannerOffset)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Keep the cover centered while native toolbar and safe-area insets settle.
        .ignoresSafeArea()
        .animation(
            reduceMotion ? nil : .easeInOut(duration: LibraryLoadingCoverMetrics.fadeDuration),
            value: isPresented
        )
        .allowsHitTesting(isPresented && showsLoadingContent)
        .accessibilityHidden(!isPresented || !showsLoadingContent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// One set of loading-cover geometry and motion values for every Apple platform.
public enum LibraryLoadingCoverMetrics {
    public static let fadeDuration = 0.32
    public static let markSize: CGFloat = 72
    public static let activityBannerOffset: CGFloat = 92
}

/// Keeps the established mark-to-message offset while centering their complete visible block.
private struct LibraryLoadingBlockLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        guard let mark = sizes.first else { return .zero }
        guard sizes.count > 1 else { return mark }
        return CGSize(
            width: max(mark.width, sizes[1].width),
            height: mark.height / 2 + LibraryLoadingCoverMetrics.activityBannerOffset + sizes[1].height / 2)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let mark = subviews.first else { return }
        let proposal = ProposedViewSize(width: bounds.width, height: nil)
        let markHeight = mark.sizeThatFits(proposal).height
        let center = CGPoint(x: bounds.midX, y: bounds.minY + markHeight / 2)
        mark.place(at: center, anchor: .center, proposal: proposal)
        if subviews.count > 1 {
            subviews[1].place(
                at: CGPoint(x: center.x, y: center.y + LibraryLoadingCoverMetrics.activityBannerOffset),
                anchor: .center, proposal: proposal)
        }
    }
}
