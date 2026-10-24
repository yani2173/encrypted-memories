import SwiftUI

/// One titled progress row for lists and empty states on macOS, iOS, and iPadOS: a short title, a count line, and the
/// native determinate bar while the total is known. Without a total, `showsIndeterminateProgress` shows the native
/// indeterminate indicator next to the title instead. The row stays a standard list row; it draws no glass.
public struct ActivityProgressRow: View {
    private let title: String?
    private let detail: String?
    private let fraction: Double?
    private let showsIndeterminateProgress: Bool
    private let alignment: HorizontalAlignment
    private let accessibilityName: String?

    /// `accessibilityName` names the bar for VoiceOver when the row shows no title, for example because the
    /// surrounding view shows it; the visible count line then stays a separate text.
    public init(
        title: String?, detail: String? = nil, fraction: Double? = nil, showsIndeterminateProgress: Bool = false,
        alignment: HorizontalAlignment = .leading, accessibilityName: String? = nil
    ) {
        self.accessibilityName = accessibilityName
        self.title = title
        self.detail = detail
        self.fraction = fraction.map(ActivityProgressBar.clamped)
        self.showsIndeterminateProgress = showsIndeterminateProgress
        self.alignment = alignment
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            if title != nil || (fraction == nil && showsIndeterminateProgress) {
                HStack(spacing: 8) {
                    if fraction == nil, showsIndeterminateProgress {
                        ProgressSpinner(accessibilityLabel: Self.spinnerName(title, accessibilityName))
                    }
                    if let title {
                        Text(title)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let fraction {
                ActivityProgressBar(fraction: fraction, accessibilityLabel: Self.barName(title, accessibilityName))
            }
        }
    }

    /// VoiceOver names the bar after the row's title, else after the name the caller gives for an untitled row.
    nonisolated static func barName(_ title: String?, _ accessibilityName: String?) -> String? {
        title ?? accessibilityName
    }

    /// The spinner of an untitled row is named after the caller's name; next to a visible title it keeps "Loading".
    nonisolated static func spinnerName(_ title: String?, _ accessibilityName: String?) -> String? {
        title == nil ? accessibilityName : nil
    }
}

/// The one determinate progress bar of macOS, iOS and iPadOS: the native linear bar in the app's primary color. It
/// takes the width its container offers; the detail text (count and percent) belongs above it, as in
/// `ActivityProgressRow`.
public struct ActivityProgressBar: View {
    private let fraction: Double
    private let accessibilityLabel: String?

    public init(fraction: Double, accessibilityLabel: String? = nil) {
        self.fraction = Self.clamped(fraction)
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        let bar = ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .tint(ProtonColor.primary)
        if let accessibilityLabel {
            bar.accessibilityLabel(accessibilityLabel)
        } else {
            bar
        }
    }

    nonisolated static func clamped(_ fraction: Double) -> Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }
}

/// Sizes a progress line inside an empty, waiting or overlay state: 70 % of the state's width, counted up to the
/// shared readable progress width, and at least 120 pt unless the state itself is narrower. Rows do not use this
/// layout; their bar takes the full row width. The line stays centered and is never measured and fed back into layout.
/// With `hugsLine`, the layout is as wide as its line, so a card around it hugs the bar; otherwise it fills the state.
public struct ActivityProgressStateLayout: Layout {
    /// The one readable width of a progress line in a state.
    nonisolated static let readableWidth: CGFloat = 320
    nonisolated static let minimumWidth: CGFloat = 120
    nonisolated static let widthRatio: CGFloat = 0.7

    private let hugsLine: Bool

    public init(hugsLine: Bool = false) {
        self.hugsLine = hugsLine
    }

    nonisolated static func availableWidth(for proposal: CGFloat?) -> CGFloat {
        min(readableWidth, max(0, proposal ?? readableWidth))
    }

    nonisolated static func lineWidth(in available: CGFloat) -> CGFloat {
        min(available, max(minimumWidth, available * widthRatio))
    }

    /// The width the layout reports for a proposed width: the state's width, or the line's width when it hugs it.
    nonisolated static func reportedWidth(for proposal: CGFloat?, hugsLine: Bool) -> CGFloat {
        let available = availableWidth(for: proposal)
        return hugsLine ? lineWidth(in: available) : available
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let line = subviews.first?.sizeThatFits(
            ProposedViewSize(width: Self.lineWidth(in: Self.availableWidth(for: proposal.width)), height: nil))
        return CGSize(width: Self.reportedWidth(for: proposal.width, hugsLine: hugsLine), height: line?.height ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // A hugging layout is already as wide as its line; a state layout narrows the line inside its width.
        let width = hugsLine ? bounds.width : Self.lineWidth(in: bounds.width)
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
            proposal: ProposedViewSize(width: width, height: nil))
    }
}
