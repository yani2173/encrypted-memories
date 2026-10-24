import PhotosCore
import SwiftUI

/// The one small inline spinner of macOS, iOS and iPadOS: the native indeterminate indicator, small and in the
/// primary color, for rows, sections, toolbar buttons and the activity banner. VoiceOver reads "Loading" unless the
/// caller names what loads. Spinners over photos and full-screen loading use the loading marks instead.
public struct ProgressSpinner: View {
    private let accessibilityLabel: String?

    public init(accessibilityLabel: String? = nil) {
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(ProtonColor.primary)
            .accessibilityLabel(Self.label(accessibilityLabel))
    }

    nonisolated static func label(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return L10n.string("loading.content") }
        return name
    }
}
