import Testing

@testable import ProtonDriveBackend

/// The SDK's HTTP client cannot tell which upload a request serves, so it asks the count of running uploads.
@Suite("Expensive network access of upload requests")
struct ExpensiveUploadAccessTests {
    @Test func backupUploadsWithMobileDataOffRefuseExpensiveNetworks() {
        let access = ExpensiveUploadAccess()
        #expect(access.allowsExpensiveNetworkAccess, "no upload runs")

        access.begin(allowsExpensiveNetwork: false)
        access.begin(allowsExpensiveNetwork: false)
        #expect(!access.allowsExpensiveNetworkAccess)

        access.end(allowsExpensiveNetwork: false)
        #expect(!access.allowsExpensiveNetworkAccess, "one restricted upload still runs")
        access.end(allowsExpensiveNetwork: false)
        #expect(access.allowsExpensiveNetworkAccess)
    }

    @Test func anUploadThatThePersonStartedKeepsEveryNetwork() {
        let access = ExpensiveUploadAccess()
        access.begin(allowsExpensiveNetwork: false)
        access.begin(allowsExpensiveNetwork: true)
        #expect(access.allowsExpensiveNetworkAccess)

        access.end(allowsExpensiveNetwork: true)
        #expect(!access.allowsExpensiveNetworkAccess)
    }
}
