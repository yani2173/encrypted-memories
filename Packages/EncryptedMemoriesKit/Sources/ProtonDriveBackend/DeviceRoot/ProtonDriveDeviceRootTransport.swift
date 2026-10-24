import DeviceRootCore
import Foundation
import ProtonDriveSDK

/// SDK 0.31.1 operations for the app-owned Computer or My files fallback.
/// Construct this only after the account Labs gate opens.
struct ProtonDriveDeviceRootTransport: DeviceRootSDKTransport {
    private let client: ProtonDriveClient
    private let ownerAddresses: Set<String>

    init(client: ProtonDriveClient, ownerAddresses: Set<String>) {
        self.client = client
        self.ownerAddresses = Set(ownerAddresses.map { $0.lowercased() })
    }

    func devices() async throws -> [DeviceRootSDKListedDevice] {
        let collected = SDKEnumerationCollector<Device>()
        let devices: [Device]
        do {
            devices = try await SDKCancellableOperation.run { token in
                try await client.enumerateDevices(cancellationToken: token) { result in
                    collected.receive(result)
                }
                return try collected.collected()
            } cancel: { token in
                try? await client.cancelEnumerateDevices(cancellationToken: token)
            }
        } catch {
            let partial = collected.snapshot()
            if partial.elements.isEmpty, partial.failure == nil,
                let sdkError = error as? ProtonDriveSDKError,
                let httpCode = sdkError.asAPINetworkError?.httpCode,
                [404, 410, 501].contains(httpCode)
            {
                throw DeviceRootOperationError.unsupported
            }
            throw error
        }
        return devices.map { device in
            DeviceRootSDKListedDevice(
                deviceUID: device.uid.sdkCompatibleIdentifier,
                rootFolderUID: device.rootFolderUid.sdkCompatibleIdentifier,
                name: try? device.name.get())
        }
    }

    func createDevice(name: String) async throws -> DeviceRootSDKListedDevice {
        let device = try await SDKCancellableOperation.run { token in
            try await client.createDevice(
                name: name, type: .macOS, cancellationToken: token)
        } cancel: { token in
            try? await client.cancelCreateDevice(cancellationToken: token)
        }
        return DeviceRootSDKListedDevice(
            deviceUID: device.uid.sdkCompatibleIdentifier,
            rootFolderUID: device.rootFolderUid.sdkCompatibleIdentifier,
            name: try? device.name.get())
    }

    func myFilesFolders() async throws -> [DeviceRootSDKListedDevice] {
        let root = try await verifiedMyFilesRoot()
        var folders: [DeviceRootSDKListedDevice] = []
        for uid in try await folderChildren(root.uid) {
            guard let node = try await node(uid)
            else { throw DeviceRootOperationError.unknownOutcome }
            guard case .folder(let folder) = node else { continue }
            guard folder.parentUid?.sdkCompatibleIdentifier == root.uid.sdkCompatibleIdentifier
            else { throw DeviceRootOperationError.verificationFailed }
            folders.append(
                DeviceRootSDKListedDevice(
                    deviceUID: root.uid.sdkCompatibleIdentifier,
                    rootFolderUID: folder.uid.sdkCompatibleIdentifier,
                    name: try? folder.name.get(), location: .myFiles))
        }
        return folders
    }

    func createMyFilesFolder(name: String) async throws -> DeviceRootSDKListedDevice {
        let (root, folder) = try await DeviceRootCheckedMutation.afterLookup(
            lookup: { try await verifiedMyFilesRoot() },
            mutate: { root in
                let folder = try await SDKCancellableOperation.run { token in
                    try await client.createFolder(
                        parentFolderUid: root.uid, folderName: name,
                        lastModificationTime: Date(), cancellationToken: token)
                } cancel: { token in
                    try? await client.cancelCreateFolder(cancellationToken: token)
                }
                return (root, folder)
            })
        guard folder.parentUid?.sdkCompatibleIdentifier == root.uid.sdkCompatibleIdentifier,
            (try? folder.name.get()) == name,
            folder.trashTime == nil, folder.errors.isEmpty,
            DeviceRootClaimAuthorPolicy.accepts(folder.nameAuthor, ownerAddresses: ownerAddresses),
            DeviceRootClaimAuthorPolicy.accepts(folder.keyAuthor, ownerAddresses: ownerAddresses)
        else { throw DeviceRootOperationError.verificationFailed }
        return DeviceRootSDKListedDevice(
            deviceUID: root.uid.sdkCompatibleIdentifier,
            rootFolderUID: folder.uid.sdkCompatibleIdentifier,
            name: name, location: .myFiles)
    }

    private func verifiedMyFilesRoot() async throws -> FolderNode {
        let root = try await SDKCancellableOperation.run { token in
            try await client.getMyFilesRootFolder(cancellationToken: token)
        } cancel: { token in
            try? await client.cancelGetMyFilesRootFolder(cancellationToken: token)
        }
        guard root.trashTime == nil, root.errors.isEmpty else {
            throw DeviceRootOperationError.verificationFailed
        }
        return root
    }

    private func node(_ uid: SDKNodeUid) async throws -> DriveNode? {
        try await SDKCancellableOperation.run { token in
            try await client.getNode(nodeUid: uid, cancellationToken: token)
        } cancel: { token in
            try? await client.cancelGetNode(cancellationToken: token)
        }
    }

    private func folderChildren(_ folderUID: SDKNodeUid) async throws -> [SDKNodeUid] {
        let collected = SDKEnumerationCollector<SDKNodeUid>()
        return try await SDKCancellableOperation.run { token in
            try await client.enumerateFolderChildrenNodeUids(
                folderUid: folderUID, cancellationToken: token
            ) { result in
                collected.receive(result)
            }
            return try collected.collected()
        } cancel: { token in
            try? await client.cancelEnumerateFolderChildren(cancellationToken: token)
        }
    }

    func marker(for device: DeviceRootSDKListedDevice) async throws -> DeviceRootSDKMarkerStatus {
        try await DeviceRootMarkerVerifier.verify(
            device: device, ownerAddresses: ownerAddresses,
            node: { try await node($0) },
            folderChildren: { try await folderChildren($0) })
    }

    func createMarker(for device: DeviceRootSDKListedDevice, name: String) async throws {
        guard let folderUID = SDKNodeUid(sdkCompatibleIdentifier: device.rootFolderUID),
            name.hasPrefix(DeviceRootMarker.prefix),
            case .folder(let root) = try await node(folderUID),
            root.trashTime == nil, root.errors.isEmpty,
            device.location == .computer
                || root.parentUid?.sdkCompatibleIdentifier == device.deviceUID,
            DeviceRootClaimAuthorPolicy.accepts(root.nameAuthor, ownerAddresses: ownerAddresses),
            DeviceRootClaimAuthorPolicy.accepts(root.keyAuthor, ownerAddresses: ownerAddresses)
        else { throw DeviceRootOperationError.verificationFailed }
        try Task.checkCancellation()
        let marker = try await SDKCancellableOperation.run { token in
            try await client.createFolder(
                parentFolderUid: folderUID, folderName: name,
                lastModificationTime: Date(), cancellationToken: token)
        } cancel: { token in
            try? await client.cancelCreateFolder(cancellationToken: token)
        }
        guard marker.parentUid?.sdkCompatibleIdentifier == device.rootFolderUID,
            (try? marker.name.get()) == name,
            marker.trashTime == nil, marker.errors.isEmpty,
            DeviceRootClaimAuthorPolicy.accepts(marker.nameAuthor, ownerAddresses: ownerAddresses),
            DeviceRootClaimAuthorPolicy.accepts(marker.keyAuthor, ownerAddresses: ownerAddresses)
        else { throw DeviceRootOperationError.verificationFailed }
    }
}

/// Verifies the exact SDK node shape that the transport reads from the server.
enum DeviceRootMarkerVerifier {
    static func verify(
        device: DeviceRootSDKListedDevice, ownerAddresses: Set<String>,
        node: @Sendable (SDKNodeUid) async throws -> DriveNode?,
        folderChildren: @Sendable (SDKNodeUid) async throws -> [SDKNodeUid]
    ) async throws -> DeviceRootSDKMarkerStatus {
        guard let folderUID = SDKNodeUid(sdkCompatibleIdentifier: device.rootFolderUID),
            case .folder(let folder) = try await node(folderUID),
            folder.trashTime == nil, folder.errors.isEmpty,
            device.location == .computer
                || folder.parentUid?.sdkCompatibleIdentifier == device.deviceUID
        else { return .unverified }

        var markerName: String?
        for uid in try await folderChildren(folderUID) {
            guard let child = try await node(uid) else { return .unverified }
            let name: String
            switch child {
            case .folder(let marker):
                guard let verifiedName = try? marker.name.get() else { return .unverified }
                name = verifiedName
                if name.hasPrefix(DeviceRootMarker.prefix) {
                    guard markerName == nil,
                        marker.parentUid?.sdkCompatibleIdentifier == device.rootFolderUID,
                        marker.trashTime == nil, marker.errors.isEmpty,
                        DeviceRootClaimAuthorPolicy.accepts(marker.nameAuthor, ownerAddresses: ownerAddresses),
                        DeviceRootClaimAuthorPolicy.accepts(marker.keyAuthor, ownerAddresses: ownerAddresses)
                    else { return .unverified }
                    markerName = name
                }
            case .file(let file):
                guard let verifiedName = try? file.name.get() else { return .unverified }
                name = verifiedName
                if name.hasPrefix(DeviceRootMarker.prefix) { return .unverified }
            case .album(let album):
                guard let verifiedName = try? album.name.get() else { return .unverified }
                name = verifiedName
                if name.hasPrefix(DeviceRootMarker.prefix) { return .unverified }
            case .photo(let photo):
                guard let verifiedName = try? photo.name.get() else { return .unverified }
                name = verifiedName
                if name.hasPrefix(DeviceRootMarker.prefix) { return .unverified }
            }
            if name.hasPrefix(DeviceRootMarker.prefix), markerName != name { return .unverified }
        }
        switch DeviceRootClaimFolderPolicy.disposition(
            hasClaim: markerName != nil, nameAuthor: folder.nameAuthor,
            keyAuthor: folder.keyAuthor, ownerAddresses: ownerAddresses)
        {
        case .missing: return .missing
        case .unverified: return .unverified
        case .eligible: break
        }
        guard let markerName else { return .unverified }
        guard DeviceRootMarker.incarnation(from: markerName, for: device) != nil
        else { return .unverified }
        return .verified(name: markerName)
    }
}

enum DeviceRootCheckedMutation {
    static func afterLookup<Root, Value>(
        lookup: () async throws -> Root,
        mutate: (Root) async throws -> Value
    ) async throws -> Value {
        let root: Root
        do {
            root = try await lookup()
            try Task.checkCancellation()
        } catch {
            // The remote mutation closure has not run, regardless of the lookup error.
            throw DeviceRootOperationError.notDispatched
        }
        return try await mutate(root)
    }
}

enum DeviceRootClaimAuthorPolicy {
    static func accepts(_ author: Author, ownerAddresses: Set<String>) -> Bool {
        guard author.signatureVerificationError == nil,
            let email = author.emailAddress
        else { return false }
        return ownerAddresses.contains(email.lowercased())
    }
}

enum DeviceRootClaimFolderPolicy {
    enum Disposition: Equatable {
        case missing
        case eligible
        case unverified
    }

    static func disposition(
        hasClaim: Bool, nameAuthor: Author, keyAuthor: Author,
        ownerAddresses: Set<String>
    ) -> Disposition {
        guard hasClaim else { return .missing }
        guard DeviceRootClaimAuthorPolicy.accepts(nameAuthor, ownerAddresses: ownerAddresses),
            DeviceRootClaimAuthorPolicy.accepts(keyAuthor, ownerAddresses: ownerAddresses)
        else { return .unverified }
        return .eligible
    }
}
