import DesignSystemCore
import PhotosCore
import SwiftUI
import TimelineCore
import UIKit

/// iOS hosts the shared loading cover and supplies only UIKit's native material surface.
struct MobileLibraryLoadingView: View {
    let isPresented: Bool
    let accessibilityLabel: String
    let activityMessage: String
    let activityState: LibraryActivityBannerState

    init(
        isPresented: Bool,
        accessibilityLabel: String = String(localized: "loading.library_title"),
        activityMessage: String,
        activityState: LibraryActivityBannerState
    ) {
        self.isPresented = isPresented
        self.accessibilityLabel = accessibilityLabel
        self.activityMessage = activityMessage
        self.activityState = activityState
    }

    var body: some View {
        LibraryLoadingCover(
            isPresented: isPresented,
            accessibilityLabel: accessibilityLabel,
            activityMessage: activityMessage,
            activityState: activityState
        ) { isActive in
            MobileFrostedBackdrop(isActive: isActive)
        }
    }
}

/// Replaces the sign-out spinner after a real purge failure. The account remains unavailable until retry or
/// the next cold start completes the durable purge request.
struct MobileSignOutFailureView: View {
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            LibraryLoadingCover(
                isPresented: true,
                accessibilityLabel: L10n.string("sign_out.cleanup_failed_title"),
                showsLoadingContent: false
            ) { isActive in
                MobileFrostedBackdrop(isActive: isActive)
            }

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()

            SignOutCleanupFailedView(retry: onRetry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .allowsHitTesting(true)
    }
}

/// UIKit-only platform adapter. The effect itself animates between material and nil at alpha 1, avoiding
/// the offscreen-composition and visual artifacts caused by fading a `UIVisualEffectView` or its parent.
struct MobileFrostedBackdrop: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> MobileFrostedBackdropView {
        MobileFrostedBackdropView(isActive: isActive)
    }

    func updateUIView(_ view: MobileFrostedBackdropView, context: Context) {
        view.setActive(isActive, animated: !context.environment.accessibilityReduceMotion)
    }
}

final class MobileFrostedBackdropView: UIVisualEffectView {
    private var active: Bool

    init(isActive: Bool) {
        active = isActive
        super.init(effect: isActive ? UIBlurEffect(style: .systemUltraThinMaterial) : nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setActive(_ isActive: Bool, animated: Bool) {
        guard active != isActive else { return }
        active = isActive
        let changes: () -> Void = { [weak self] in
            guard let self else { return }
            self.effect = isActive ? UIBlurEffect(style: .systemUltraThinMaterial) : nil
        }
        guard animated else {
            changes()
            return
        }
        UIView.animate(
            withDuration: LibraryLoadingCoverMetrics.fadeDuration,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut],
            animations: changes
        )
    }
}

/// Shown when the first load fails; offers a retry when the failure is retryable.
struct MobileLibraryErrorView: View {
    let message: String
    let retryable: Bool
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("error.load_library_title"), systemImage: "exclamationmark.icloud")
        } description: {
            Text(message)
        } actions: {
            if retryable {
                RetryButton(.prominent, action: onRetry)
            }
        }
    }
}
