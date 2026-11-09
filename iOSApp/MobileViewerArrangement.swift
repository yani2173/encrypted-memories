import PhotoViewerCore
import SwiftUI

/// The viewer's media and its lower part (the filmstrip, and the details in the folded layout) in one arrangement.
///
/// On iOS 27.1 an overlay `ArrangementView` holds them. While the display is whole it lays the lower part over the
/// media, and the media ends above the lower part the way the filmstrip has always shortened it. When the system
/// selects the folded layout of a partly open device, it puts the media on one part of the display and the lower part
/// on the other: below the media in tabletop, beside it in book pose. The media keeps its one pager and player; only
/// its frame changes. Earlier systems and SDKs keep the lower part as bottom safe-area content, which lays the media
/// out the same way.
struct MobileViewerArrangement<Media: View, LowerPart: View, Notice: View>: View {
    /// The chrome toggle hides the lower part; the media then fills its whole part in the same animation.
    let showsLowerPart: Bool
    /// The height of the lower part while it lies over the media. It comes from the layout profile, so the media
    /// refits in the same pass when the chrome returns, the window turns or the viewer opens.
    let stackedLowerPartHeight: CGFloat
    /// Whether the system put the two parts side by side, read from the z-index it gives each part.
    @Binding var isSideBySide: Bool
    @ViewBuilder let media: Media
    @ViewBuilder let lowerPart: LowerPart
    /// A transient notice, such as Undo. It belongs to the lower part's region, so in the folded layout it never
    /// sits on the fold; while the display is whole that region is the whole area, as before.
    @ViewBuilder let notice: Notice

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The z-index of each part in the overlay arrangement. They start as the whole display lays them out.
    @State private var lowerPartZIndex = 1
    @State private var mediaZIndex = 0

    var body: some View {
        #if canImport(SwiftUI, _version: 8.0.85)
            if #available(iOS 27.1, *) {
                arranged
            } else {
                stacked
            }
        #else
            stacked
        #endif
    }

    private var stacked: some View {
        media.safeAreaInset(edge: .bottom, spacing: 0) {
            if showsLowerPart { lowerPart }
        }
        .overlay { notice }
    }

    #if canImport(SwiftUI, _version: 8.0.85)
        @available(iOS 27.1, *)
        private var arranged: some View {
            // Apple's media example: the controls are the primary view, laid over the media in the whole display and
            // moved to the trailing or bottom part when the device is partly open.
            ArrangementView {
                // The region the system gives the lower part. The lower part lies over it and fills it in the folded
                // layout, where its details scroll.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if showsLowerPart { lowerPart }
                    }
                    .overlay { notice }
                    .background {
                        ArrangementZIndexReader { value, isChange in
                            lowerPartZIndex = value
                            updateSideBySide(animated: isChange)
                        }
                    }
            } secondary: {
                media
                    .safeAreaPadding(.bottom, showsLowerPart && !isSideBySide ? stackedLowerPartHeight : 0)
                    .background {
                        ArrangementZIndexReader { value, isChange in
                            mediaZIndex = value
                            updateSideBySide(animated: isChange)
                        }
                    }
            }
            .arrangementViewStyle(.overlay)
        }
    #endif

    /// `animated` is false for the first value: a viewer that opens folded starts in the folded layout at once.
    private func updateSideBySide(animated: Bool) {
        let sideBySide = ViewerArrangement.isSideBySide(lowerPartZIndex: lowerPartZIndex, mediaZIndex: mediaZIndex)
        guard sideBySide != isSideBySide else { return }
        guard animated else {
            isSideBySide = sideBySide
            return
        }
        // The strip, the details and the title change together with the system's own fold animation.
        withAnimation(MobileViewerMotionPolicy.animation(.smooth(duration: 0.24), reduceMotion: reduceMotion)) {
            isSideBySide = sideBySide
        }
    }
}

#if canImport(SwiftUI, _version: 8.0.85)
    /// Reports the z-index the overlay arrangement gives the view it backs, at once and on every change.
    @available(iOS 27.1, *)
    private struct ArrangementZIndexReader: View {
        /// The value, and whether it changed (false for the first value).
        let report: (Int, Bool) -> Void
        @Environment(\.overlayArrangementZIndex) private var zIndex

        var body: some View {
            Color.clear.onChange(of: zIndex, initial: true) { old, value in report(value, old != value) }
        }
    }
#endif

extension View {
    /// Lays this view out as the viewer's media with `lowerPart` in one `MobileViewerArrangement`.
    func viewerArrangement<LowerPart: View, Notice: View>(
        showsLowerPart: Bool, stackedLowerPartHeight: CGFloat, isSideBySide: Binding<Bool>,
        @ViewBuilder lowerPart: () -> LowerPart, @ViewBuilder notice: () -> Notice
    ) -> some View {
        MobileViewerArrangement(
            showsLowerPart: showsLowerPart, stackedLowerPartHeight: stackedLowerPartHeight,
            isSideBySide: isSideBySide, media: { self }, lowerPart: lowerPart, notice: notice)
    }
}
