import Foundation

/// Builds a scrubbed support report without account, asset, query, path, or error content.
public enum SupportDiagnosticsExporter {
    private struct Report: Codable {
        struct Runtime: Codable {
            let thermal: String
            let memoryPressure: String
            let memoryBudget: String
            let memoryHeadroom: String
            let lowPowerMode: Bool
            let networkReachable: Bool
            let networkConstrained: Bool
            let networkExpensive: Bool
            /// Interface types only, for example ["cellular", "other"]; never names or addresses.
            let networkUsedInterfaces: [String]
            let networkAvailableInterfaces: [String]
            let executionOpportunity: String
            let visibleMediaDemand: Bool
            let activeUserInteraction: Bool
            let activeUserTransfers: Int
            let generation: UInt64
        }

        struct Resources: Codable {
            let permitsAcquired: Int
            let permitsReleased: Int
            let cancelledWaiters: Int
            let policyPauses: Int
            let recoveries: Int
            let maximumConcurrentPermits: Int
            let maximumWaitMilliseconds: UInt64
        }

        struct Backup: Codable {
            let queues: [BackupQueueSupportSnapshot]
            let editReplacements: [EditReplacementSupportSnapshot]
            let pendingGrid: PendingGridSupportSnapshot
        }

        struct RecentEvents: Codable {
            let events: [SupportEventTrail.ExportedEvent]
            /// Older events that the bounded trail no longer holds.
            let dropped: Int
        }

        let placeCandidates: [PlaceCandidateSupportSnapshot]
        let librarySync: LibrarySyncSupportSnapshot
        let backup: Backup
        let recentEvents: RecentEvents
        let schemaVersion: Int
        let generatedAt: Date
        let appVersion: String
        let appBuild: String
        let appCommit: String
        let operatingSystem: String
        let runtime: Runtime
        let resources: Resources
        let diagnostics: PhotoDiagnosticsSupportSnapshot
        /// Nil without a signed-in session.
        let requests: RemoteRequestSupportSnapshot?
    }

    public static func makeJSONData(
        runtimeState: LibraryRuntimeState = .shared,
        resourceCoordinator: LibraryResourceCoordinator = .shared,
        diagnostics: PhotoDiagnostics = .shared,
        bundle: Bundle = .main,
        sources: SupportDiagnosticsSources = .shared,
        trail: SupportEventTrail = .shared
    ) async throws -> Data {
        let snapshot = runtimeState.snapshot()
        let metrics = await resourceCoordinator.metrics()
        let buildInfo = AppBuildInfo(bundle: bundle)
        let now = Date()
        let librarySync = await sources.librarySnapshot(now: now)
        // One salt per report: hashes link the events of one report, never two reports.
        let trailExport = trail.export(hashingWith: SupportReportIdentifierHasher())
        let report = Report(
            placeCandidates: await sources.placeSnapshot(),
            librarySync: librarySync,
            backup: Report.Backup(
                queues: sources.queueSnapshots(),
                editReplacements: sources.editReplacementSnapshots(),
                pendingGrid: sources.pendingGridSnapshot()
            ),
            recentEvents: Report.RecentEvents(events: trailExport.events, dropped: trailExport.dropped),
            schemaVersion: 2,
            generatedAt: now,
            appVersion: buildInfo.version ?? "unknown",
            appBuild: buildInfo.build ?? "unknown",
            appCommit: buildInfo.commit ?? "unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            runtime: Report.Runtime(
                thermal: String(describing: snapshot.thermalLevel),
                memoryPressure: String(describing: snapshot.memoryPressure),
                memoryBudget: String(describing: snapshot.memoryBudgetTier),
                memoryHeadroom: String(describing: snapshot.memoryHeadroom),
                lowPowerMode: snapshot.isLowPowerMode,
                networkReachable: snapshot.network.isReachable,
                networkConstrained: snapshot.network.isConstrained,
                networkExpensive: snapshot.network.isExpensive,
                networkUsedInterfaces: snapshot.network.usedInterfaces.map(\.rawValue).sorted(),
                networkAvailableInterfaces: snapshot.network.availableInterfaces.map(\.rawValue).sorted(),
                executionOpportunity: String(describing: snapshot.executionOpportunity),
                visibleMediaDemand: snapshot.hasVisibleMediaDemand,
                activeUserInteraction: snapshot.hasActiveUserInteraction,
                activeUserTransfers: snapshot.activeUserTransferCount,
                generation: snapshot.generation
            ),
            resources: Report.Resources(
                permitsAcquired: metrics.permitsAcquired,
                permitsReleased: metrics.permitsReleased,
                cancelledWaiters: metrics.cancelledWaiters,
                policyPauses: metrics.policyPauses,
                recoveries: metrics.recoveries,
                maximumConcurrentPermits: metrics.maximumConcurrentPermits,
                maximumWaitMilliseconds: metrics.maximumWaitMilliseconds
            ),
            diagnostics: diagnostics.supportSnapshot(),
            requests: await sources.requestSnapshot()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}
