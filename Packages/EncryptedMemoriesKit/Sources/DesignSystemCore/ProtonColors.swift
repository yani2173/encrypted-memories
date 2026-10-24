import SwiftUI

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

/// Proton design tokens.
///
/// Neutrals (backgrounds / text / borders) map to **semantic system colors**, so the whole app adapts to
/// light/dark appearance, increased-contrast, and material vibrancy automatically - and inherits Apple's
/// refined Liquid Glass on macOS 27 with no per-token work. Only the brand accent + signal hues stay fixed
/// (they are brand identity and read correctly in both appearances). Call sites keep using these token names.
public enum ProtonColor {
    // Brand accent - legitimately custom (the only fixed brand hue; readable on light + dark).
    public static let primary = Color(hex: 0x6D4AFF)

    // Friendly Encrypted Memories mark. Keep interaction accents on `primary`.
    public static let brandMark = Color(hex: 0x4F9FA7)

    // Backgrounds use semantic, appearance-adaptive colors. Prefer native materials and window backgrounds;
    // these are for the few chrome surfaces that need an explicit fill.
    #if os(macOS)
        public static let backgroundNorm = Color(nsColor: .windowBackgroundColor)
    #elseif os(iOS)
        public static let backgroundNorm = Color(uiColor: .systemBackground)
        /// The background of an inset grouped list, and of the rounded cards on it.
        public static let groupedBackground = Color(uiColor: .systemGroupedBackground)
        public static let groupedCard = Color(uiColor: .secondarySystemGroupedBackground)
    #endif

    // Text uses semantic label roles that support Dynamic Type and vibrancy.
    public static let textNorm = Color.primary
    public static let textWeak = Color.secondary
    #if os(macOS)
        public static let textHint = Color(nsColor: .tertiaryLabelColor)
    #elseif os(iOS)
        public static let textHint = Color(uiColor: .tertiaryLabel)
    #endif

    // Signal - brand-tuned, readable in both appearances.
    public static let danger = Color(hex: 0xDC3251)
    public static let warning = Color(hex: 0xFF9900)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
