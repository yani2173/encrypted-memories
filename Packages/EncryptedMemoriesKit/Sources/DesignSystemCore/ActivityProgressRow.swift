import SwiftUI

/// One titled progress row for lists and empty states on macOS, iOS, and iPadOS: a short title, a count line, and the
/// native determinate bar while the total is known. Without a total, `showsIndeterminateProgress` shows the native
/// indeterminate indicator next to the title instead. The row stays a standard list row; it draws no glass.
public struct ActivityProgressRow: View {
    private let title: String?
    private let detail: String?
    private let fraction: Double?
    private let showsIndeterminateProgress: Bool

    public init(
        title: String?, detail: String? = nil, fraction: Double? = nil, showsIndeterminateProgress: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.fraction = fraction.map { min(max($0, 0), 1) }
        self.showsIndeterminateProgress = showsIndeterminateProgress
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || (fraction == nil && showsIndeterminateProgress) {
                HStack(spacing: 8) {
                    if fraction == nil, showsIndeterminateProgress {
                        ProgressView().controlSize(.small)
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
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }
        }
    }
}
