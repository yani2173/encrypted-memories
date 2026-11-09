// GridTransitionTuning.swift
//
// Production defaults for normal-grid transitions. Keeping them together separates tuning from the
// renderer, geometry, and gesture code.

package struct GridTransitionTuning: Equatable, Sendable {
    // Click (toolbar +/-).
    package var clickDurationMs: Double = 420
    package var clickRampFraction: Double = 0.20
    package var c1EdgeFraction: Double = 0.20

    // Structural sampling targets.
    package var minFocusInteriorSamples60: Int = 4
    package var minCornerInteriorSamples60: Int = 2

    // Live pinch.
    package var pinchWidthQ: Double = 0.0706

    // Continuous multi-level live-pinch scrub.
    package var pinchReleaseCommitQ: Double = 0.50
    package var pinchAutoCompleteMinQPerSecond: Double = 1.8
    package var pinchAutoCompleteMaxQPerSecond: Double = 8.0
    package var pinchVelocityEmaAlpha: Double = 0.25
    package var pinchDirectionResolveQ: Double = 0.02
    package var pinchDetentHysteresisQ: Double = 0.02
    package var pinchDisplayLowPassAlpha: Double = 1.0

    // Click-window placement.
    package var leadInFrames60: Int = 1
    package var edgeZoneLo: Double = 0.01
    package var edgeZoneHi: Double = 0.99
    package var minVisibleWindowWidthQ: Double = 0.035

    /// Reference refresh used to allocate the immutable plan (the harder rate; finer is smoother).
    package var planRefreshHz: Double = 60

    package static let `default` = GridTransitionTuning()

    package var localAlphaCurve: LocalAlphaCurve { LocalAlphaCurve(edgeFraction: c1EdgeFraction) }
    package var clickDurationSeconds: Double { clickDurationMs / 1000.0 }
}
