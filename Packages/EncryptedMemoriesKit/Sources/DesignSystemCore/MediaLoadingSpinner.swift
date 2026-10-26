import PhotosCore
import SwiftUI

/// The loading indicator over a photo or a video in the Mac viewer: the large native spinner on a glass circle, or, while
/// bytes arrive with a known size, the native circular progress with its percentage. VoiceOver reads "Loading".
public struct MediaLoadingSpinner: View {
    private let fraction: Double?

    /// `fraction` is the share of the media that arrived; nil shows the indeterminate spinner.
    public init(fraction: Double? = nil) {
        self.fraction = fraction
    }

    @ViewBuilder public var body: some View {
        if let fraction {
            ProgressView(value: fraction) {
                EmptyView()
            } currentValueLabel: {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .progressViewStyle(.circular)
            .controlSize(.large)
            .padding(20)
            .glassEffect(in: Circle())
            .accessibilityLabel(Self.accessibilityName)
        } else {
            ProgressView()
                .controlSize(.large)
                .padding(20)
                .glassEffect(in: Circle())
                .accessibilityLabel(Self.accessibilityName)
        }
    }

    /// The fraction to show while media downloads: only after the first and before the last percent, so a download
    /// that has not started or has nearly finished shows the calm spinner instead of a ring that jumps.
    public nonisolated static func visibleFraction(_ progress: Double, isDownloading: Bool) -> Double? {
        isDownloading && progress > 0.001 && progress < 0.995 ? progress : nil
    }

    nonisolated static var accessibilityName: String { L10n.string("loading.content") }
}
