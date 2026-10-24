#if canImport(UIKit) && !os(watchOS)
    import Foundation
    import LibraryRuntimeAppleAdapter
    import MediaByteCache
    import os
    import PhotosCore
    import UIKit

    /// iOS/iPadOS cache-responder composition for the Core `MemoryPressureGovernor`.
    /// Dynamic Apple signals are owned once by `AppleLibraryRuntimeAdapter`; this type only registers
    /// identity-keyed cache owners and emits platform budget diagnostics.
    ///
    @MainActor
    public final class UIKitMemoryPressureCoordinator {
        public static let shared = UIKitMemoryPressureCoordinator(governor: .shared)

        private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "MemBudget")
        private var installed = false
        private let governor: MemoryPressureGovernor

        /// The coordinator mutates attachments only on the main actor. Its nonisolated deinitializer owns the
        /// final reference and may therefore transfer the Sendable registration token to main-actor cleanup.
        private final class Attachment: @unchecked Sendable {
            weak var owner: AnyObject?
            let token: MemoryPressureRegistration

            init(owner: AnyObject, token: MemoryPressureRegistration) {
                self.owner = owner
                self.token = token
            }
        }

        /// One token per live owner, keyed by object identity. Separate grids each keep their own token.
        private var attachments: [ObjectIdentifier: Attachment] = [:]

        private init(governor: MemoryPressureGovernor) {
            self.governor = governor
        }

        deinit {
            let registrations = attachments.values.map(\.token)
            Task { @MainActor in
                for registration in registrations {
                    registration.end()
                }
            }
        }

        /// Test-only injection keeps ownership tests isolated from the process-wide singleton.
        init(testGovernor: MemoryPressureGovernor) {
            self.governor = testGovernor
        }

        var activeAttachmentCount: Int {
            pruneDeallocatedAttachments()
            return attachments.count
        }

        /// Install the process signal adapter and the tier-change diagnostic. Cache registration stays in
        /// this module; OS signal ownership lives solely in `LibraryRuntimeAppleAdapter`.
        public func install() {
            AppleLibraryRuntimeAdapter.shared.install()
            guard !installed else { return }
            installed = true

            // Production-visible `[MemBudget]` line on every tier change (the governor fans out only on change):
            // tier + live headroom + the scaled RAM ceilings, so a device log answers "did the valve fire, and
            // to what budgets?" without a debug build.
            governor.register { tier in
                Self.logMemBudget(tier)
            }
        }

        /// Register the live thumbnail feed's RAM tiers (UIImage wrappers + decoded core).
        @discardableResult
        public func attachFeed(_ feed: UIKitThumbnailFeed) -> MemoryPressureRegistration {
            attach(feed) { [weak feed] tier in
                feed?.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
            }
        }

        /// Register the live encrypted thumbnail byte cache's in-process plaintext RAM tier.
        @discardableResult
        public func attachByteCache(_ cache: ThumbnailCache) -> MemoryPressureRegistration {
            attach(cache) { [weak cache] tier in
                cache?.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
            }
        }

        /// Generic owner attachment for owners this module must not depend on (the viewer display store, the grid
        /// host's texture cache). Re-attaching the same object is a no-op; every distinct object gets its own
        /// registration. The responder is invoked immediately with the current tier (governor semantics), so an
        /// owner attached under existing pressure starts scaled.
        @discardableResult
        public func attach(
            _ owner: AnyObject,
            respond: @escaping @MainActor (MemoryBudgetTier) -> Void
        ) -> MemoryPressureRegistration {
            pruneDeallocatedAttachments()
            let id = ObjectIdentifier(owner)
            if let existing = attachments[id] {
                return existing.token
            }
            let token = governor.register(respond)
            attachments[id] = Attachment(owner: owner, token: token)
            return token
        }

        /// End the owner token during feed/host teardown. Tab inactivity must not call this method.
        public func detach(_ owner: AnyObject) {
            let id = ObjectIdentifier(owner)
            attachments.removeValue(forKey: id)?.token.end()
        }

        private func pruneDeallocatedAttachments() {
            let deallocatedIDs = attachments.compactMap { id, attachment in
                attachment.owner == nil ? id : nil
            }
            for id in deallocatedIDs {
                attachments.removeValue(forKey: id)?.token.end()
            }
        }

        private static func logMemBudget(_ tier: MemoryBudgetTier) {
            let conditions = MemoryPressureGovernor.shared.conditions
            let mib = 1_048_576
            let headroomMB = UIKitMediaCachePolicy.liveAvailableMemoryBytes().map { Int($0) / mib } ?? -1
            let scale = tier.budgetScale
            let byteMB = Int(Double(UIKitMediaCachePolicy.dataMemoryBudgetBytes()) * scale) / mib
            let decodedMB = Int(Double(UIKitMediaCachePolicy.decodedRAMBudgetBytes()) * scale) / mib
            let wrapperMB = Int(Double(UIKitMediaCachePolicy.wrapperRAMBudgetBytes()) * scale) / mib
            logger.notice(
                """
                [MemBudget] tier=\(String(describing: tier), privacy: .public) \
                pressure=\(String(describing: conditions.pressure), privacy: .public) \
                thermal=\(String(describing: conditions.thermal), privacy: .public) \
                purge=\(tier.requiresImmediatePurge) headroomMB=\(headroomMB) \
                byteMB=\(byteMB) decodedMB=\(decodedMB) wrapperMB=\(wrapperMB)
                """)
        }
    }
#endif
