import PhotosCore
import Testing

@testable import DesignSystemCore

@Suite struct LibraryEmptyViewTests {
    @Test func backupIsOfferedOnlyForAnAvailableDisabledWholeLibraryBackup() {
        let routes: [PhotoFilter] = [
            .all, .tag(.favorites), .tag(.videos), .album(id: "album", title: "Album"), .trash,
        ]
        for available in [false, true] {
            for enabled in [false, true] {
                let action = LibraryEmptyBackupAction(isAvailable: available, isEnabled: enabled, perform: {})
                for route in routes {
                    #expect(action.isOffered(for: route) == (route == .all && available && !enabled))
                }
            }
        }
    }
}
