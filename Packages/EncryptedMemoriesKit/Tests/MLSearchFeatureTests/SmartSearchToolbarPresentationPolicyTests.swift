import Testing

@testable import MLSearchFeature

@Suite
struct SmartSearchToolbarPresentationPolicyTests {
    @Test func clearingSearchDismissesScopesWithoutInventingAQuery() {
        #expect(
            SmartSearchToolbarPresentationPolicy.queryChangeAction(
                oldQuery: "April 2026",
                newQuery: " \n "
            ) == .dismiss(clearText: false)
        )
    }

    @Test func openingAnEmptySearchFieldRetainsNativePresentation() {
        #expect(
            SmartSearchToolbarPresentationPolicy.queryChangeAction(
                oldQuery: "",
                newQuery: ""
            ) == .retain
        )
    }

    @Test func enabledNonEmptySearchRetainsNativePresentation() {
        #expect(
            SmartSearchToolbarPresentationPolicy.queryChangeAction(
                oldQuery: "",
                newQuery: "Rechnung"
            ) == .retain
        )
    }

    @Test func aScopeThatLeftTheAvailableListFallsBackToAll() {
        #expect(
            SmartSearchToolbarPresentationPolicy.scopeFallback(.text, availableScopes: [.all]) == .all)
    }

    @Test func aSelectedScopeThatIsStillAvailableIsKept() {
        #expect(
            SmartSearchToolbarPresentationPolicy.scopeFallback(.text, availableScopes: [.all, .text]) == .text)
        #expect(
            SmartSearchToolbarPresentationPolicy.scopeFallback(.all, availableScopes: [.all, .text]) == .all)
    }
}
