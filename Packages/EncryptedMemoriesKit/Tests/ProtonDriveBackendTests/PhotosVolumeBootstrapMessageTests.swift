import PhotosCore
import Testing

@testable import ProtonDriveBackend

/// The library-load error screen shows one generic text for a failed library creation. The text names no cause.
@Suite struct PhotosVolumeBootstrapMessageTests {
    @Test func missingSignerShowsTheGenericLibraryCreationText() {
        let message = PhotosVolumeBootstrapError.missingSigner.localizedDescription

        #expect(message == L10n.string("error.library_creation_failed"))
        #expect(!message.localizedCaseInsensitiveContains("Proton"))
        #expect(!message.localizedCaseInsensitiveContains("account"))
    }
}
