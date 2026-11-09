import Foundation
import PhotosCore

/// The part of `EditedOriginalRevert` that the service calls; the actor conforms.
public protocol EditedOriginalReverting: Sendable {
    @discardableResult
    func revert(
        editedMain: PhotoUID, original: PhotoUID, restoredName: String, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> PhotoUID
}

extension EditedOriginalRevert: EditedOriginalReverting {}

/// The file names that decide the name of the restored photo.
public struct EditedPhotoRevertNames: Sendable, Equatable {
    public let main: String
    public let original: String

    public init(main: String, original: String) {
        self.main = main
        self.original = original
    }
}

/// Starts a revert for the viewer. It reverts only a pair that the backend proves again: `originals` must name the
/// same hidden original for the edited photo. A viewer that holds a stale or foreign pair therefore starts nothing.
public struct EditedPhotoRevertService: EditedPhotoReverting {
    public enum ServiceError: Error, Equatable {
        /// The backend does not prove `original` as the hidden original of the edited photo.
        case originalNotProven
        /// The names of the two files are unknown, so the restored photo has no name.
        case restoredNameUnavailable
    }

    public typealias Names = @Sendable (_ main: PhotoUID, _ original: PhotoUID) async throws -> EditedPhotoRevertNames?

    private let revert: any EditedOriginalReverting
    private let originals: any EditedPhotoOriginalProviding
    private let names: Names

    public init(
        revert: any EditedOriginalReverting,
        originals: any EditedPhotoOriginalProviding,
        names: @escaping Names
    ) {
        self.revert = revert
        self.originals = originals
        self.names = names
    }

    public func revertToOriginal(of main: PhotoItem, original: PhotoItem) async throws {
        guard main.mayHaveEditedOriginal, let proven = try await originals.editedOriginal(of: main),
            proven.uid == original.uid
        else { throw ServiceError.originalNotProven }
        guard let fileNames = try await names(main.uid, original.uid),
            let restoredName = EditedOriginalRestoredName.make(
                mainName: fileNames.main, originalName: fileNames.original)
        else { throw ServiceError.restoredNameUnavailable }
        try await revert.revert(
            editedMain: main.uid, original: original.uid, restoredName: restoredName, onProgress: { _ in })
    }
}
