#if ENCRYPTED_MEMORIES_UPGRADE_TEST
    import PhotosCore

    // This query became part of the backend contract after v1.0.5.
    extension UpgradeTestBackend {
        func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
            Self.linkVisibility(of: linkIDs, activeLinkIDs: Set(try await links().map(\.id)))
        }

        /// The synthetic server lists links without a state or role record, so no answer is explicit.
        /// The strict draft checks of `UploadDedupePipeline` therefore treat these answers like an incomplete
        /// response of the real service.
        static func linkVisibility(of linkIDs: [String], activeLinkIDs: Set<String>) -> [String: RemoteLinkVisibility] {
            Dictionary(
                uniqueKeysWithValues: linkIDs.map {
                    (
                        $0,
                        RemoteLinkVisibility(
                            isActive: activeLinkIDs.contains($0), mainPhotoLinkID: nil, hasExplicitPhotoState: false)
                    )
                })
        }
    }
#endif
