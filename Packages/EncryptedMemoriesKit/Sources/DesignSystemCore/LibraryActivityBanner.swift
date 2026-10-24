import SwiftUI

private struct LibraryActivityTransitionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private struct LibraryLoadingCoverPresentedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var libraryActivityTransitionNamespace: Namespace.ID? {
        get { self[LibraryActivityTransitionNamespaceKey.self] }
        set { self[LibraryActivityTransitionNamespaceKey.self] = newValue }
    }

    var libraryLoadingCoverPresented: Bool {
        get { self[LibraryLoadingCoverPresentedKey.self] }
        set { self[LibraryLoadingCoverPresentedKey.self] = newValue }
    }
}

public extension View {
    /// Connects the launch-cover and grid instances of the activity banner.
    func libraryActivityTransition(
        namespace: Namespace.ID,
        loadingCoverPresented: Bool
    ) -> some View {
        modifier(
            LibraryActivityTransitionModifier(
                namespace: namespace,
                loadingCoverPresented: loadingCoverPresented
            ))
    }
}

private struct LibraryActivityTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let namespace: Namespace.ID
    let loadingCoverPresented: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.libraryActivityTransitionNamespace, namespace)
            .environment(\.libraryLoadingCoverPresented, loadingCoverPresented)
            .animation(reduceMotion ? nil : .spring, value: loadingCoverPresented)
    }
}

public enum LibraryActivityBannerState: Equatable, Sendable {
    case working
    case success
    case failure
    case offline
}

/// Resolves connectivity messages shown by the shared grid banner.
public enum LibraryConnectivityBannerState: Equatable, Sendable {
    case hidden
    case offline
    case connectionRestored

    public static func resolve(
        isOnline: Bool,
        didRecentlyRestoreConnection: Bool
    ) -> Self {
        if !isOnline { return .offline }
        if didRecentlyRestoreConnection { return .connectionRestored }
        return .hidden
    }
}

/// One shared, non-interactive activity surface for the library grid on macOS, iOS and iPadOS.
public struct LibraryActivityBanner: View {
    private let message: String
    private let state: LibraryActivityBannerState

    public init(message: String, state: LibraryActivityBannerState = .working) {
        self.message = message
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .working:
                ProgressSpinner()
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            case .offline:
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.secondary)
            }

            Text(message)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .animation(.easeInOut(duration: 0.18), value: message)
        .animation(.easeInOut(duration: 0.18), value: state)
    }
}

/// Shared placement and transition policy for the grid activity pill. Hosts provide only state; motion,
/// bottom spacing, hit testing and the stable full-frame alignment stay identical on every Apple platform.
public struct LibraryActivityBannerOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.libraryActivityTransitionNamespace) private var transitionNamespace
    @Environment(\.libraryLoadingCoverPresented) private var loadingCoverPresented

    private let isPresented: Bool
    private let message: String
    private let state: LibraryActivityBannerState
    private let bottomPadding: CGFloat
    private let leadingObstructionInset: CGFloat
    private let isActiveSurface: Bool

    public init(
        isPresented: Bool,
        message: String,
        state: LibraryActivityBannerState = .working,
        bottomPadding: CGFloat = 20,
        leadingObstructionInset: CGFloat = 0,
        isActiveSurface: Bool = true
    ) {
        self.isPresented = isPresented
        self.message = message
        self.state = state
        self.bottomPadding = bottomPadding
        self.leadingObstructionInset = max(0, leadingObstructionInset)
        self.isActiveSurface = isActiveSurface
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            transitionBanner
                .padding(.bottom, bottomPadding)
                .opacity(isPresented && !loadingCoverPresented ? 1 : 0)
                .accessibilityHidden(!isPresented || loadingCoverPresented)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.leading, leadingObstructionInset)
        .animation(
            reduceMotion ? .easeInOut(duration: 0.12) : .easeInOut(duration: 0.22),
            value: isPresented
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder private var transitionBanner: some View {
        let banner = LibraryActivityBanner(message: message, state: state)
        if !reduceMotion, isActiveSurface, let transitionNamespace {
            banner.matchedGeometryEffect(
                id: LibraryActivityTransitionID.banner,
                in: transitionNamespace,
                properties: .frame,
                anchor: .center,
                isSource: !loadingCoverPresented
            )
        } else {
            banner
        }
    }
}

enum LibraryActivityTransitionID {
    static let banner = "library-activity-banner"
}

extension View {
    func libraryLoadingActivityTransitionSource() -> some View {
        modifier(LibraryLoadingActivityTransitionSource())
    }
}

private struct LibraryLoadingActivityTransitionSource: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.libraryActivityTransitionNamespace) private var transitionNamespace

    @ViewBuilder func body(content: Content) -> some View {
        if !reduceMotion, let transitionNamespace {
            content.matchedGeometryEffect(
                id: LibraryActivityTransitionID.banner,
                in: transitionNamespace,
                properties: .frame,
                anchor: .center,
                isSource: true
            )
        } else {
            content
        }
    }
}
