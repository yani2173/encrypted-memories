import SwiftUI

public extension View {
    /// Spins an SF Symbol steadily clockwise while `active` is true, at the one speed that every spinning activity
    /// symbol shares. The system owns the indefinite animation lifecycle, so foregrounding a scene cannot stack or
    /// accelerate repeating animations. Honors Reduce Motion by holding still.
    func spinsWhileActive(_ active: Bool) -> some View {
        modifier(ActivitySpin(active: active))
    }
}

struct ActivitySpin: ViewModifier {
    /// The one speed multiplier of every spinning activity symbol: the factor the Backup symbols used before. The
    /// system sets the base duration of the rotate effect, so this is a relative speed, not a number of seconds.
    nonisolated static let speed: Double = 1 / 1.7

    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .symbolEffect(
                .rotate.clockwise.wholeSymbol,
                options: .repeat(.continuous).speed(Self.speed),
                isActive: active && !reduceMotion
            )
    }
}
