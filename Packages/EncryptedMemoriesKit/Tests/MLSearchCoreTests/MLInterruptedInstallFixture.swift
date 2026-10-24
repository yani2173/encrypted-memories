import Foundation
import Testing

@testable import MLSearchCore

/// Recreates the disk boundary between the atomic record write and directory promotion.
enum MLInterruptedInstallFixture {
    static func write(
        entry: MLModelCatalogEntry,
        layout: MLModelInstallLayout,
        payloads: [URL: Data]
    ) throws -> MLModelInstallRecord {
        let plan = try #require(entry.downloadPlan)
        let staging = layout.stagingDirectory(for: entry.id, revision: plan.revision)
        for item in plan.items {
            let destination = staging.appendingPathComponent(item.artifact.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #require(payloads[item.url]).write(to: destination)
        }
        let record = MLModelInstallRecord(
            modelID: entry.id,
            revision: plan.revision,
            compatibility: MLModelInstallCompatibility(entry: entry),
            modelRootPath: "Model.mlmodelc",
            artifacts: plan.items.map(\.artifact).sorted { $0.relativePath < $1.relativePath },
            installedByteCount: plan.totalByteCount,
            installedAt: Date(timeIntervalSince1970: 123)
        )
        try JSONEncoder().encode(record).write(
            to: staging.appendingPathComponent(MLModelInstallLayout.installRecordFileName), options: .atomic)
        return record
    }
}
