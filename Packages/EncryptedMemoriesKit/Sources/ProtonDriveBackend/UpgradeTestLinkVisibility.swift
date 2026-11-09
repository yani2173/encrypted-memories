#if ENCRYPTED_MEMORIES_UPGRADE_TEST
    import PhotosCore

    // This query became part of the backend contract after v1.0.5.
    extension UpgradeTestBackend {
        func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
            Self.linkVisibility(of: linkIDs, activeLinkIDs: Set(try await links().map(\.id)))
        }

        /// The synthetic server lists links without a state or role record. With the stricter root rule (#876), its
        /// answers must carry explicit photo state, so every released version counts them as backed up roots and
        /// avoids re-uploads that fail the duplicate-upload gate. The initializer omits `hasExplicitState` on
        /// purpose: its fail-closed default supplies false, so no series check counts these answers.
        static func linkVisibility(of linkIDs: [String], activeLinkIDs: Set<String>) -> [String: RemoteLinkVisibility] {
            Dictionary(
                uniqueKeysWithValues: linkIDs.map {
                    (
                        $0,
                        RemoteLinkVisibility(
                            isActive: activeLinkIDs.contains($0), mainPhotoLinkID: nil, hasExplicitPhotoState: true)
                    )
                })
        }
    }
#endif
