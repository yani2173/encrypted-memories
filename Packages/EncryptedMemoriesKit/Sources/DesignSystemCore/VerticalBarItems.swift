import SwiftUI

extension EnvironmentValues {
    /// The system's preferred vertical bar edge. Older SDKs and contexts without vertical bars return nil.
    public var verticalBarEdge: HorizontalEdge? {
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
            if #available(iOS 27.1, *) { return toolbarVerticalEdge }
        #endif
        return nil
    }
}

extension View {
    /// Keep existing text buttons where bars stay horizontal; let vertical bars use the label's symbol.
    public func textBarItem() -> some View {
        modifier(TextBarItemModifier())
    }
}

/// Prominent actions lead a vertical bar while keeping their existing placement in horizontal bars.
public struct ProminentToolbarItem<Content: View>: ToolbarContent {
    @Environment(\.verticalBarEdge) private var edge
    private let horizontalPlacement: ToolbarItemPlacement
    private let isProminent: Bool
    private let content: Content

    public init(
        placement: ToolbarItemPlacement, isProminent: Bool = true, @ViewBuilder content: () -> Content
    ) {
        horizontalPlacement = placement
        self.isProminent = isProminent
        self.content = content()
    }

    public var body: some ToolbarContent {
        ToolbarItem(placement: placement) { content }
    }

    private var placement: ToolbarItemPlacement {
        #if os(iOS)
            if #available(iOS 27.0, *), isProminent, edge != nil { return .topBarPinnedTrailing }
        #endif
        return horizontalPlacement
    }
}

private struct TextBarItemModifier: ViewModifier {
    @Environment(\.verticalBarEdge) private var edge

    @ViewBuilder func body(content: Content) -> some View {
        if edge == nil {
            content.labelStyle(.titleOnly)
        } else {
            content
        }
    }
}
