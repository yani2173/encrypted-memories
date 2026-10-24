import PhotosCore
import SwiftUI

/// The one Retry action of macOS, iOS and iPadOS, titled "Try again". `.prominent` is the main action of an empty or
/// error state; `.compact` is a small text button inside a row, a note or a banner; `.system` leaves the drawing to a
/// toolbar or a sheet header. Every style uses the same title. An alert builds its actions from `Button` values, so an
/// alert uses a plain `Button(RetryButton.title)` instead of this view.
public struct RetryButton: View {
    public enum Style: Sendable {
        /// The primary action below an empty or error state.
        case prominent
        /// A small text button inside a row, a note or a banner.
        case compact
        /// A button that a toolbar or a sheet header draws in its own style.
        case system
    }

    /// The single title of every Retry action.
    public nonisolated static var title: String { L10n.string("action.retry") }

    private let style: Style
    private let action: () -> Void

    public init(_ style: Style, action: @escaping () -> Void) {
        self.style = style
        self.action = action
    }

    public var body: some View {
        let button = Button(Self.title, action: action)
        switch style {
        case .prominent:
            button
                .buttonStyle(.glassProminent)
                .tint(ProtonColor.primary)
        case .compact:
            // iPhone and iPad keep the automatic style: inside a list it leaves the whole row tappable, elsewhere it
            // draws as tinted text. The Mac's automatic style is a push button, so the Mac draws borderless text.
            #if os(macOS)
                button
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.footnote)
                    .tint(ProtonColor.primary)
            #else
                // At least 44 pt high, so the small text stays easy to tap. Inside a list a tap anywhere in the row
                // still retries; a row that also holds a message grows by the extra height of the button.
                Button(action: action) {
                    Text(Self.title)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .controlSize(.small)
                .font(.footnote)
                .tint(ProtonColor.primary)
            #endif
        case .system:
            button
        }
    }
}
