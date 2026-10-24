import CryptoKit
import Foundation
import Testing

@testable import MLSearchCore

/// Installs verified model artifacts atomically and keeps unverified files hidden.
@Suite struct MLModelInstallerTests {
    private final class ScriptedTransport: MLModelArtifactTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [URL: Data]
        private var failures: [URL: Int]
        private(set) var downloadCounts: [URL: Int] = [:]
        var progressSteps = 1

        init(payloads: [URL: Data], failFirst failures: [URL: Int] = [:]) {
            self.payloads = payloads
            self.failures = failures
        }

        func download(
            from url: URL,
            to destination: URL,
            expectedByteCount: Int64,
            progress: @escaping @Sendable (Int64, Int64?) async -> Void
        ) async throws {
            let payload: Data = try lock.withLock {
                downloadCounts[url, default: 0] += 1
                if let remaining = failures[url], remaining > 0 {
                    failures[url] = remaining - 1
                    throw URLError(.networkConnectionLost)
                }
                guard let data = payloads[url] else { throw URLError(.fileDoesNotExist) }
                return data
            }
            let steps = max(1, progressSteps)
            for step in 1...steps {
                await progress(Int64(payload.count * step / steps), Int64(payload.count))
            }
            try payload.write(to: destination)
        }

        func downloadCount(_ url: URL) -> Int {
            lock.withLock { downloadCounts[url, default: 0] }
        }
    }

    private actor DownloadGate {
        private var started = 0
        private var active = 0
        private var firstRelease: CheckedContinuation<Void, Never>?
        private var firstStart: CheckedContinuation<Void, Never>?
        private(set) var maxActive = 0

        func begin() async {
            started += 1
            active += 1
            maxActive = max(maxActive, active)
            if started == 1 {
                firstStart?.resume()
                firstStart = nil
                await withCheckedContinuation { firstRelease = $0 }
            }
        }

        func waitForFirstStart() async {
            if started > 0 { return }
            await withCheckedContinuation { firstStart = $0 }
        }

        func releaseFirst() {
            firstRelease?.resume()
            firstRelease = nil
        }

        func finish() {
            active -= 1
        }
    }

    private final class GatedTransport: MLModelArtifactTransport, @unchecked Sendable {
        let gate = DownloadGate()
        private let payloads: [URL: Data]
        private let lock = NSLock()
        private var downloadCounts: [URL: Int] = [:]

        init(payloads: [URL: Data]) { self.payloads = payloads }

        func download(
            from url: URL,
            to destination: URL,
            expectedByteCount: Int64,
            progress: @escaping @Sendable (Int64, Int64?) async -> Void
        ) async throws {
            await gate.begin()
            lock.withLock { downloadCounts[url, default: 0] += 1 }
            do {
                try Task.checkCancellation()
                guard let payload = payloads[url] else { throw URLError(.fileDoesNotExist) }
                try payload.write(to: destination)
                await progress(Int64(payload.count), expectedByteCount)
            } catch {
                await gate.finish()
                throw error
            }
            await gate.finish()
        }

        func downloadCount(_ url: URL) -> Int {
            lock.withLock { downloadCounts[url, default: 0] }
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func entry(
        id: String,
        plan: MLModelDownloadPlan?,
        track: MLModelReleaseTrack = .production,
        license: MLModelLicense = .mit,
        qualification: MLModelReleaseQualification? = nil
    ) -> MLModelCatalogEntry {
        MLModelCatalogEntry(
            id: MLModelID(id),
            displayName: id,
            family: "Test",
            descriptor: MLModelDescriptor(identifier: id, version: 1, embeddingDimension: 4),
            tokenizerID: "test-tokenizer",
            preprocessingID: "test-preprocessing",
            license: license,
            releaseTrack: track,
            estimatedInstalledBytes: 100,
            downloadPlan: plan,
            releaseQualification: qualification
        )
    }

    private func plan(revision: String = "rev1", files: [(String, Data, URL)]) -> MLModelDownloadPlan {
        MLModelDownloadPlan(
            revision: revision,
            items: files.map { name, data, url in
                let path =
                    name.hasPrefix("../") || name.hasPrefix("/")
                        || name.contains(".mlmodelc/") || name.contains(".mlpackage/")
                    ? name
                    : "Model.mlmodelc/\(name)"
                return MLModelDownloadPlan.Item(
                    url: url,
                    artifact: MLModelArtifactSpec(
                        relativePath: path,
                        sha256: sha256(data),
                        byteCount: Int64(data.count)
                    )
                )
            })
    }

    @Test func verifiedDownloadInstallsAtomicallyAndIsIdempotent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("model-bytes".utf8)
        let url = URL(string: "https://example.test/model.mlmodelc/weights.bin")!
        let testEntry = entry(id: "model-a", plan: plan(files: [("weights.bin", payload, url)]))
        let transport = ScriptedTransport(payloads: [url: payload])
        let installer = MLModelInstaller(layout: layout, transport: transport)

        let record = try await installer.install(testEntry) { _ in }
        #expect(record.revision == "rev1")
        #expect(record.installedByteCount == Int64(payload.count))

        let installedFile = layout.installDirectory(for: testEntry.id, revision: "rev1")
            .appendingPathComponent("Model.mlmodelc/weights.bin")
        #expect(try Data(contentsOf: installedFile) == payload)
        #expect(installer.installedRecord(for: testEntry, revision: "rev1") != nil)
        // Second install: already installed, no new download.
        _ = try await installer.install(testEntry) { _ in }
        #expect(transport.downloadCount(url) == 1)
    }

    @Test func interruptedRecordWritePromotesVerifiedStagingWithoutDownloading() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("verified-staging".utf8)
        let url = URL(string: "https://example.test/staging.bin")!
        let testEntry = entry(id: "model-staging", plan: plan(files: [("weights.bin", payload, url)]))
        let original = try MLInterruptedInstallFixture.write(
            entry: testEntry, layout: layout, payloads: [url: payload])
        let staging = layout.stagingDirectory(for: testEntry.id, revision: "rev1")
        let recordData = try Data(contentsOf: staging.appendingPathComponent("install.json"))
        let transport = ScriptedTransport(payloads: [:])
        let installer = MLModelInstaller(layout: layout, transport: transport, availableCapacity: { _ in 0 })
        #expect(installer.installedRecord(for: testEntry, revision: "rev1") == nil)

        let recovered = try await installer.install(testEntry) { _ in }

        #expect(recovered == original)
        #expect(installer.installedRecord(for: testEntry, revision: "rev1") == original)
        #expect(try Data(contentsOf: layout.installRecordURL(for: testEntry.id, revision: "rev1")) == recordData)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(transport.downloadCount(url) == 0)
    }

    @Test func currentInstallRecordRecoversAfterDirectoryPromotionWasInterrupted() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("current-staging".utf8)
        let url = URL(string: "https://example.test/current-staging.bin")!
        let testEntry = entry(id: "model-current", plan: plan(files: [("weights.bin", payload, url)]))
        let first = MLModelInstaller(layout: layout, transport: ScriptedTransport(payloads: [url: payload]))
        let original = try await first.install(testEntry) { _ in }
        let staging = layout.stagingDirectory(for: testEntry.id, revision: "rev1")
        try FileManager.default.moveItem(
            at: layout.installDirectory(for: testEntry.id, revision: "rev1"), to: staging)
        let transport = ScriptedTransport(payloads: [:])
        let restarted = MLModelInstaller(layout: layout, transport: transport)
        #expect(restarted.installedRecord(for: testEntry, revision: "rev1") == nil)

        let recovered = try await restarted.install(testEntry) { _ in }

        #expect(recovered == original)
        #expect(restarted.installedRecord(for: testEntry, revision: "rev1") == original)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(transport.downloadCount(url) == 0)
    }

    @Test(arguments: [
        "missing", "checksum", "record", "record-directory", "record-symlink", "revision", "compatibility", "extra",
        "symlink",
    ])
    func interruptedUnverifiableRecordDiscardsStagingAndDownloadsEveryArtifact(damage: String) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("good-weights".utf8)
        let metadata = Data("metadata".utf8)
        let url = URL(string: "https://example.test/recover-weights.bin")!
        let metadataURL = URL(string: "https://example.test/recover-metadata.bin")!
        let testEntry = entry(
            id: "model-damaged",
            plan: plan(files: [("weights.bin", payload, url), ("metadata.bin", metadata, metadataURL)]))
        let payloads = [url: payload, metadataURL: metadata]
        _ = try MLInterruptedInstallFixture.write(entry: testEntry, layout: layout, payloads: payloads)
        let staging = layout.stagingDirectory(for: testEntry.id, revision: "rev1")
        let weights = staging.appendingPathComponent("Model.mlmodelc/weights.bin")
        let recordURL = staging.appendingPathComponent("install.json")
        switch damage {
        case "missing":
            try FileManager.default.removeItem(at: weights)
        case "checksum":
            try Data(repeating: 0, count: payload.count).write(to: weights)
        case "record":
            try Data("{interrupted".utf8).write(to: recordURL)
        case "record-directory":
            try FileManager.default.removeItem(at: recordURL)
            try FileManager.default.createDirectory(at: recordURL, withIntermediateDirectories: false)
        case "record-symlink":
            try FileManager.default.removeItem(at: recordURL)
            try FileManager.default.createSymbolicLink(
                at: recordURL, withDestinationURL: root.appendingPathComponent("absent-record.json"))
        case "revision", "compatibility":
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
            if damage == "revision" {
                json["revision"] = "another-revision"
            } else {
                var compatibility = try #require(json["compatibility"] as? [String: Any])
                compatibility["tokenizerID"] = "another-tokenizer"
                json["compatibility"] = compatibility
            }
            try JSONSerialization.data(withJSONObject: json).write(to: recordURL, options: .atomic)
        case "extra":
            try Data("unlisted".utf8).write(to: staging.appendingPathComponent("extra.bin"))
        case "symlink":
            let outside = root.appendingPathComponent("outside.bin")
            try payload.write(to: outside)
            try FileManager.default.removeItem(at: weights)
            try FileManager.default.createSymbolicLink(at: weights, withDestinationURL: outside)
        default:
            Issue.record("unknown damage")
        }
        let transport = ScriptedTransport(payloads: payloads)
        let installer = MLModelInstaller(layout: layout, transport: transport)
        #expect(installer.installedRecord(for: testEntry, revision: "rev1") == nil)

        let recovered = try await installer.install(testEntry) { _ in }

        #expect(installer.installedRecord(for: testEntry, revision: "rev1") == recovered)
        #expect(transport.downloadCount(url) == 1)
        #expect(transport.downloadCount(metadataURL) == 1, "discard the complete invalid tree, including valid files")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        if damage == "symlink" {
            #expect(try Data(contentsOf: root.appendingPathComponent("outside.bin")) == payload)
        }
    }

    @Test func releaseReadinessUsesTrustedDistributionNotOptionalEvidence() {
        let payload = Data("model".utf8)
        let url = URL(string: "https://example.test/model.bin")!
        let hostedPlan = plan(revision: "rev2", files: [("model.bin", payload, url)])
        let stale = MLModelReleaseQualification(
            artifactRevision: "rev1",
            hardwareModel: "oldest-supported-device",
            osVersion: "test",
            peakResidentBytes: 1,
            imageP95Milliseconds: 1,
            textP95Milliseconds: 1,
            reachedSeriousThermalState: false,
            neuralEngineExecutionVerified: true,
            passed: true
        )
        let matching = MLModelReleaseQualification(
            artifactRevision: "rev2",
            hardwareModel: "oldest-supported-device",
            osVersion: "test",
            peakResidentBytes: 1,
            imageP95Milliseconds: 1,
            textP95Milliseconds: 1,
            reachedSeriousThermalState: false,
            neuralEngineExecutionVerified: true,
            passed: true
        )

        #expect(entry(id: "missing", plan: hostedPlan).isReleaseReady)
        #expect(entry(id: "stale", plan: hostedPlan, qualification: stale).isReleaseReady)
        #expect(entry(id: "ready", plan: hostedPlan, qualification: matching).isReleaseReady)
    }

    @Test func checksumMismatchNeverBecomesInstalled() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let goodPayload = Data("expected-bytes".utf8)
        let corruptPayload = Data("corrupted-bytes".utf8)
        let url = URL(string: "https://example.test/corrupt.bin")!
        // Plan pins the hash of goodPayload, transport serves corruptPayload (same length
        // would also fail; use different length to exercise the size check first).
        let testEntry = entry(id: "model-corrupt", plan: plan(files: [("weights.bin", goodPayload, url)]))
        let transport = ScriptedTransport(payloads: [url: corruptPayload])
        let installer = MLModelInstaller(layout: layout, transport: transport)

        await #expect(throws: MLModelInstallError.self) {
            _ = try await installer.install(testEntry) { _ in }
        }
        #expect(installer.installedRecord(for: testEntry, revision: "rev1") == nil)
        #expect(
            !FileManager.default.fileExists(atPath: layout.installDirectory(for: testEntry.id, revision: "rev1").path))
    }

    @Test func equalLengthCorruptionFailsChecksum() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let goodPayload = Data("aaaaaaaa".utf8)
        let corruptPayload = Data("bbbbbbbb".utf8)
        let url = URL(string: "https://example.test/samesize.bin")!
        let testEntry = entry(id: "model-samesize", plan: plan(files: [("weights.bin", goodPayload, url)]))
        let installer = MLModelInstaller(layout: layout, transport: ScriptedTransport(payloads: [url: corruptPayload]))

        do {
            _ = try await installer.install(testEntry) { _ in }
            Issue.record("install must fail")
        } catch let error as MLModelInstallError {
            #expect(error == .checksumMismatch(artifact: "Model.mlmodelc/weights.bin"))
        }
    }

    @Test func pathTraversalInManifestIsRejected() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("x".utf8)
        let url = URL(string: "https://example.test/evil.bin")!
        let testEntry = entry(id: "model-evil", plan: plan(files: [("../../evil.bin", payload, url)]))
        let installer = MLModelInstaller(layout: layout, transport: ScriptedTransport(payloads: [url: payload]))

        do {
            _ = try await installer.install(testEntry) { _ in }
            Issue.record("install must fail")
        } catch let error as MLModelInstallError {
            #expect(error == .unsafeArtifactPath("../../evil.bin"))
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: root.deletingLastPathComponent().appendingPathComponent("evil.bin").path))
    }

    @Test func modelPackageRootMustContainAFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("not-a-model-package".utf8)
        let url = URL(string: "https://example.test/Model.mlmodelc")!
        let installPlan = MLModelDownloadPlan(
            revision: "rev1",
            items: [
                .init(
                    url: url,
                    artifact: .init(
                        relativePath: "Model.mlmodelc",
                        sha256: sha256(payload),
                        byteCount: Int64(payload.count)
                    )
                )
            ]
        )
        let testEntry = entry(id: "model-file-root", plan: installPlan)
        let installer = MLModelInstaller(
            layout: MLModelInstallLayout(rootDirectory: root),
            transport: ScriptedTransport(payloads: [url: payload])
        )

        await #expect(throws: MLModelInstallError.ambiguousModelArtifact) {
            _ = try await installer.install(testEntry) { _ in }
        }
    }

    @Test func unsafeRelativePathRules() {
        #expect(MLModelInstallLayout.isSafeRelativePath("weights.bin"))
        #expect(MLModelInstallLayout.isSafeRelativePath("nested/dir/weights.bin"))
        #expect(!MLModelInstallLayout.isSafeRelativePath("/absolute"))
        #expect(!MLModelInstallLayout.isSafeRelativePath("../up"))
        #expect(!MLModelInstallLayout.isSafeRelativePath("a/../b"))
        #expect(!MLModelInstallLayout.isSafeRelativePath("a//b"))
        #expect(!MLModelInstallLayout.isSafeRelativePath("."))
        #expect(!MLModelInstallLayout.isSafeRelativePath(""))
    }

    @Test func failedDownloadRetriesCleanly() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("retry-bytes".utf8)
        let url = URL(string: "https://example.test/retry.bin")!
        let testEntry = entry(id: "model-retry", plan: plan(files: [("weights.bin", payload, url)]))
        let transport = ScriptedTransport(payloads: [url: payload], failFirst: [url: 1])
        let installer = MLModelInstaller(layout: layout, transport: transport)

        await #expect(throws: Error.self) {
            _ = try await installer.install(testEntry) { _ in }
        }
        #expect(installer.installedRecord(for: testEntry, revision: "rev1") == nil)

        let record = try await installer.install(testEntry) { _ in }
        #expect(record.revision == "rev1")
        #expect(transport.downloadCount(url) == 2)
    }

    @Test func interruptedDownloadResumesFromStagingWithoutASecondModelCopy() async throws {
        final class ResumingTransport: MLModelArtifactTransport, @unchecked Sendable {
            let payload: Data
            private(set) var starts: [Int] = []

            init(payload: Data) { self.payload = payload }

            func download(
                from url: URL,
                to destination: URL,
                expectedByteCount: Int64,
                progress: @escaping @Sendable (Int64, Int64?) async -> Void
            ) async throws {
                let existing = (try? Data(contentsOf: destination)) ?? Data()
                starts.append(existing.count)
                let split = payload.count / 2
                if existing.isEmpty {
                    try payload.prefix(split).write(to: destination)
                    await progress(Int64(split), expectedByteCount)
                    throw URLError(.networkConnectionLost)
                }
                var resumed = existing
                resumed.append(payload.dropFirst(existing.count))
                try resumed.write(to: destination)
                await progress(Int64(resumed.count), expectedByteCount)
            }
        }

        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data(repeating: 0xA5, count: 4 << 20)
        let url = URL(string: "https://example.test/resume.bin")!
        let testEntry = entry(id: "model-resume", plan: plan(files: [("Model.mlmodelc/weights.bin", payload, url)]))
        let transport = ResumingTransport(payload: payload)
        let installer = MLModelInstaller(layout: layout, transport: transport)

        await #expect(throws: Error.self) {
            _ = try await installer.install(testEntry) { _ in }
        }
        let partial = layout.stagingDirectory(for: testEntry.id, revision: "rev1")
            .appendingPathComponent("Model.mlmodelc/weights.bin.partial")
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect((try Data(contentsOf: partial)).count == payload.count / 2)

        let record = try await installer.install(testEntry) { _ in }
        #expect(record.installedByteCount == Int64(payload.count))
        #expect(transport.starts == [0, payload.count / 2])
    }

    private final class ScriptedCapacity: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64]

        /// Returns the values in order and then repeats the last one.
        init(_ values: [Int64]) { self.values = values }

        func next(_ url: URL) -> Int64? {
            lock.withLock { values.count > 1 ? values.removeFirst() : values.first }
        }
    }

    @Test func downloadThatDoesNotFitFailsBeforeAnyTransfer() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data(repeating: 1, count: 1_000)
        let url = URL(string: "https://example.test/space.bin")!
        let testEntry = entry(id: "model-space", plan: plan(files: [("weights.bin", payload, url)]))
        let transport = ScriptedTransport(payloads: [url: payload])
        let required = Int64(payload.count) + MLModelInstaller.storageReserveBytes
        let installer = MLModelInstaller(
            layout: layout, transport: transport, availableCapacity: { _ in required - 1 })

        await #expect(
            throws: MLModelInstallError.insufficientStorage(requiredBytes: required, availableBytes: required - 1)
        ) {
            _ = try await installer.install(testEntry) { _ in }
        }
        #expect(transport.downloadCount(url) == 0)

        // The same download runs once the space is there.
        let roomy = MLModelInstaller(layout: layout, transport: transport, availableCapacity: { _ in required })
        _ = try await roomy.install(testEntry) { _ in }
        #expect(transport.downloadCount(url) == 1)
    }

    @Test func fullDiskDuringTransferReportsInsufficientStorage() async throws {
        final class FullDiskTransport: MLModelArtifactTransport, @unchecked Sendable {
            func download(
                from url: URL,
                to destination: URL,
                expectedByteCount: Int64,
                progress: @escaping @Sendable (Int64, Int64?) async -> Void
            ) async throws {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data(repeating: 1, count: 1_000)
        let url = URL(string: "https://example.test/full.bin")!
        let testEntry = entry(id: "model-full", plan: plan(files: [("weights.bin", payload, url)]))
        let required = Int64(payload.count) + MLModelInstaller.storageReserveBytes
        // Enough space when the download starts; another app fills the disk during the transfer.
        let capacity = ScriptedCapacity([required, 10])
        let installer = MLModelInstaller(
            layout: layout, transport: FullDiskTransport(), availableCapacity: { capacity.next($0) })

        await #expect(throws: MLModelInstallError.insufficientStorage(requiredBytes: required, availableBytes: 10)) {
            _ = try await installer.install(testEntry) { _ in }
        }
    }

    @Test func transferFailureWithFreeSpaceKeepsItsOwnError() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("bytes".utf8)
        let url = URL(string: "https://example.test/network.bin")!
        let testEntry = entry(id: "model-network", plan: plan(files: [("weights.bin", payload, url)]))
        let transport = ScriptedTransport(payloads: [url: payload], failFirst: [url: 1])
        let installer = MLModelInstaller(layout: layout, transport: transport, availableCapacity: { _ in .max })

        await #expect(throws: URLError.self) {
            _ = try await installer.install(testEntry) { _ in }
        }
    }

    @Test func resumedBytesNeedNoNewSpace() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data(repeating: 7, count: 1_000)
        let url = URL(string: "https://example.test/resumed.bin")!
        let testEntry = entry(id: "model-resumed", plan: plan(files: [("weights.bin", payload, url)]))
        let partial = layout.stagingDirectory(for: testEntry.id, revision: "rev1")
            .appendingPathComponent("Model.mlmodelc/weights.bin.partial")
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.prefix(600).write(to: partial)
        let required = Int64(400) + MLModelInstaller.storageReserveBytes
        let installer = MLModelInstaller(
            layout: layout, transport: ScriptedTransport(payloads: [url: payload]),
            availableCapacity: { _ in required })

        let record = try await installer.install(testEntry) { _ in }
        #expect(record.installedByteCount == Int64(payload.count))
    }

    @Test func concurrentInstallsShareOneDownload() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("shared-bytes".utf8)
        let url = URL(string: "https://example.test/shared.bin")!
        let testEntry = entry(id: "model-shared", plan: plan(files: [("weights.bin", payload, url)]))
        let transport = ScriptedTransport(payloads: [url: payload])
        let installer = MLModelInstaller(layout: layout, transport: transport)

        async let first = installer.install(testEntry) { _ in }
        async let second = installer.install(testEntry) { _ in }
        _ = try await (first, second)
        #expect(transport.downloadCount(url) == 1)
    }

    #if DEBUG
        @Test func threeDifferentRequestsForOneDestinationNeverOverlap() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let layout = MLModelInstallLayout(rootDirectory: root)
            let payload = Data("shared-destination".utf8)
            let urls = ["a", "b", "c"].map { URL(string: "https://example.test/\($0).bin")! }
            let transport = GatedTransport(payloads: Dictionary(uniqueKeysWithValues: urls.map { ($0, payload) }))
            let installer = MLModelInstaller(layout: layout, transport: transport)
            let entries = urls.enumerated().map { index, url in
                entry(
                    id: "model-three-way",
                    plan: plan(revision: "shared-revision", files: [("weights-\(index).bin", payload, url)])
                )
            }

            let first = Task { try await installer.install(entries[0]) { _ in } }
            await transport.gate.waitForFirstStart()
            let second = Task { try await installer.install(entries[1]) { _ in } }
            let third = Task { try await installer.install(entries[2]) { _ in } }
            await installer.waitForInstallWaiters(2)
            await transport.gate.releaseFirst()

            let firstRecord = try await first.value
            let secondRecord = try await second.value
            let thirdRecord = try await third.value
            #expect(await transport.gate.maxActive == 1)
            #expect(transport.downloadCount(urls[0]) == 1)
            #expect(transport.downloadCount(urls[1]) == 1)
            #expect(transport.downloadCount(urls[2]) == 1)
            #expect(firstRecord.artifacts.map(\.relativePath) == ["Model.mlmodelc/weights-0.bin"])
            #expect(secondRecord.artifacts.map(\.relativePath) == ["Model.mlmodelc/weights-1.bin"])
            #expect(thirdRecord.artifacts.map(\.relativePath) == ["Model.mlmodelc/weights-2.bin"])
        }

        @Test func overlappingCancelInstallAndUninstallKeepModelFencedUntilBothRelease() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let layout = MLModelInstallLayout(rootDirectory: root)
            let payload = Data("overlap-model-fence".utf8)
            let url = URL(string: "https://example.test/overlap-model.bin")!
            let testEntry = entry(id: "model-overlap", plan: plan(files: [("weights.bin", payload, url)]))
            let transport = GatedTransport(payloads: [url: payload])
            let installer = MLModelInstaller(layout: layout, transport: transport)

            let first = Task { try await installer.install(testEntry) { _ in } }
            await transport.gate.waitForFirstStart()
            let cancellation = Task { await installer.cancelInstall(of: testEntry.id) }
            let removal = Task { await installer.uninstall(testEntry) }
            await installer.waitForFenceOwners(modelID: testEntry.id, minimum: 2)

            await #expect(throws: MLModelInstallError.cancelled) {
                _ = try await installer.install(testEntry) { _ in }
            }
            await transport.gate.releaseFirst()
            await cancellation.value
            await removal.value

            await #expect(throws: MLModelInstallError.cancelled) { _ = try await first.value }
            #expect(transport.downloadCount(url) == 1)
            #expect(!FileManager.default.fileExists(atPath: layout.modelDirectory(for: testEntry.id).path))
            #expect(
                !FileManager.default.fileExists(atPath: layout.runtimeCacheModelDirectory(for: testEntry.id).path))
            #expect(layout.stagingDirectories(for: testEntry.id).isEmpty)
        }

        @Test func concurrentCancelAllOwnersKeepEveryModelFencedUntilBothRelease() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let layout = MLModelInstallLayout(rootDirectory: root)
            let payload = Data("overlap-all-fence".utf8)
            let url = URL(string: "https://example.test/overlap-all.bin")!
            let testEntry = entry(id: "model-overlap-all", plan: plan(files: [("weights.bin", payload, url)]))
            let transport = GatedTransport(payloads: [url: payload])
            let installer = MLModelInstaller(layout: layout, transport: transport)

            let first = Task { try await installer.install(testEntry) { _ in } }
            await transport.gate.waitForFirstStart()
            let firstCancellation = Task { await installer.cancelAllInstalls() }
            let secondCancellation = Task { await installer.cancelAllInstalls() }
            await installer.waitForFenceOwners(minimum: 2)

            await #expect(throws: MLModelInstallError.cancelled) {
                _ = try await installer.install(testEntry) { _ in }
            }
            await transport.gate.releaseFirst()
            await firstCancellation.value
            await secondCancellation.value

            await #expect(throws: MLModelInstallError.cancelled) { _ = try await first.value }
            #expect(transport.downloadCount(url) == 1)
            #expect(!FileManager.default.fileExists(atPath: layout.modelDirectory(for: testEntry.id).path))
            // Cancellation preserves resumable partials; only uninstall removes staging.
            #expect(layout.stagingDirectories(for: testEntry.id).count == 1)
        }

        @Test func cancelAllFencesWaitingSuccessor() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let layout = MLModelInstallLayout(rootDirectory: root)
            let payload = Data("cancelled".utf8)
            let urls = [
                URL(string: "https://example.test/cancel-a.bin")!,
                URL(string: "https://example.test/cancel-b.bin")!,
            ]
            let transport = GatedTransport(payloads: Dictionary(uniqueKeysWithValues: urls.map { ($0, payload) }))
            let installer = MLModelInstaller(layout: layout, transport: transport)
            let entries = urls.enumerated().map { index, url in
                entry(
                    id: "model-cancel",
                    plan: plan(revision: "cancel-revision", files: [("weights-\(index).bin", payload, url)]))
            }

            let first = Task { try await installer.install(entries[0]) { _ in } }
            await transport.gate.waitForFirstStart()
            let successor = Task { try await installer.install(entries[1]) { _ in } }
            await installer.waitForInstallWaiters(1)
            let cancellation = Task { await installer.cancelAllInstalls() }
            await installer.waitForFenceOwners(minimum: 1)
            await transport.gate.releaseFirst()
            await cancellation.value

            await #expect(throws: MLModelInstallError.cancelled) { _ = try await first.value }
            await #expect(throws: MLModelInstallError.cancelled) { _ = try await successor.value }
            #expect(transport.downloadCount(urls[0]) == 1)
            #expect(transport.downloadCount(urls[1]) == 0)
            #expect(installer.installedRecord(for: entries[0], revision: "cancel-revision") == nil)
        }

        @Test func uninstallFencesWaitingSuccessorAndRemovesStaging() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let layout = MLModelInstallLayout(rootDirectory: root)
            let payload = Data("uninstalled".utf8)
            let urls = [
                URL(string: "https://example.test/uninstall-a.bin")!,
                URL(string: "https://example.test/uninstall-b.bin")!,
            ]
            let transport = GatedTransport(payloads: Dictionary(uniqueKeysWithValues: urls.map { ($0, payload) }))
            let installer = MLModelInstaller(layout: layout, transport: transport)
            let entries = urls.enumerated().map { index, url in
                entry(
                    id: "model-uninstall",
                    plan: plan(revision: "uninstall-revision", files: [("weights-\(index).bin", payload, url)]))
            }

            let first = Task { try await installer.install(entries[0]) { _ in } }
            await transport.gate.waitForFirstStart()
            let successor = Task { try await installer.install(entries[1]) { _ in } }
            await installer.waitForInstallWaiters(1)
            let removal = Task { await installer.uninstall(entries[0]) }
            await installer.waitForFenceOwners(modelID: entries[0].id, minimum: 1)
            await transport.gate.releaseFirst()
            await removal.value

            await #expect(throws: MLModelInstallError.cancelled) { _ = try await first.value }
            await #expect(throws: MLModelInstallError.cancelled) { _ = try await successor.value }
            #expect(transport.downloadCount(urls[1]) == 0)
            #expect(installer.installedRecord(for: entries[0], revision: "uninstall-revision") == nil)
            #expect(!FileManager.default.fileExists(atPath: layout.modelDirectory(for: entries[0].id).path))
            #expect(
                !FileManager.default.fileExists(atPath: layout.runtimeCacheModelDirectory(for: entries[0].id).path))
            #expect(layout.stagingDirectories(for: entries[0].id).isEmpty)
        }
    #endif

    @Test func localDeveloperInstallHashesAndInstallsContent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let source = root.appendingPathComponent("dev-artifact", isDirectory: true)
        let model = source.appendingPathComponent("Test.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: model.appendingPathComponent("Weights"), withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: model.appendingPathComponent("Manifest.json"))
        try Data("weights".utf8).write(to: model.appendingPathComponent("Weights/weight.bin"))
        let testEntry = entry(id: "model-dev", plan: nil, track: .developerOnly)
        let installer = MLModelInstaller(layout: layout, transport: ScriptedTransport(payloads: [:]))

        let record = try await installer.installFromLocalArtifact(testEntry, artifactDirectory: source)
        #expect(record.revision.hasPrefix("local-"))
        #expect(record.artifacts.count == 2)
        #expect(installer.anyInstalledRecord(for: testEntry)?.revision == record.revision)

        // Re-install of identical content is a no-op with the same revision.
        let again = try await installer.installFromLocalArtifact(testEntry, artifactDirectory: source)
        #expect(again.revision == record.revision)

        // A record whose files were tampered with (size change) is no longer trusted.
        try Data("weights-tampered".utf8).write(
            to: layout.installDirectory(for: testEntry.id, revision: record.revision)
                .appendingPathComponent("Test.mlmodelc/Weights/weight.bin")
        )
        #expect(installer.anyInstalledRecord(for: testEntry) == nil)
    }

    @Test func localInstallRejectsMultipleModelRepresentations() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ambiguous", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("Model.mlmodelc"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("Model.mlpackage"), withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: source.appendingPathComponent("Model.mlmodelc/model.bin"))
        try Data("package".utf8).write(to: source.appendingPathComponent("Model.mlpackage/model.bin"))
        let installer = MLModelInstaller(
            layout: MLModelInstallLayout(rootDirectory: root.appendingPathComponent("install")),
            transport: ScriptedTransport(payloads: [:])
        )

        await #expect(throws: MLModelInstallError.ambiguousModelArtifact) {
            _ = try await installer.installFromLocalArtifact(
                entry(id: "ambiguous", plan: nil, track: .developerOnly),
                artifactDirectory: source
            )
        }
    }

    @Test func restrictedLicenseIsTechnicallyBlockedFromDownload() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("restricted-weights".utf8)
        let url = URL(string: "https://example.test/restricted.bin")!
        // The transfer boundary enforces the license independently of catalog filtering.
        let testEntry = entry(
            id: "model-restricted",
            plan: plan(files: [("weights.bin", payload, url)]),
            license: MLModelLicense(
                identifier: "Test-Restricted",
                allowsRedistribution: false,
                allowsProductUse: false
            )
        )
        #expect(!testEntry.isDownloadable)
        let transport = ScriptedTransport(payloads: [url: payload])
        let installer = MLModelInstaller(layout: layout, transport: transport)

        do {
            _ = try await installer.install(testEntry) { _ in }
            Issue.record("install must fail on a restricted license")
        } catch let error as MLModelInstallError {
            #expect(error == .licenseProhibitsDistribution)
        }
        #expect(transport.downloadCount(url) == 0, "restricted weights must not be fetched")
        #expect(installer.anyInstalledRecord(for: testEntry) == nil)
        #expect(!FileManager.default.fileExists(atPath: layout.modelDirectory(for: testEntry.id).path))
    }

    @Test func uninstallRemovesEveryRevision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("bytes".utf8)
        let url = URL(string: "https://example.test/u.bin")!
        let testEntry = entry(id: "model-u", plan: plan(files: [("weights.bin", payload, url)]))
        let installer = MLModelInstaller(layout: layout, transport: ScriptedTransport(payloads: [url: payload]))

        _ = try await installer.install(testEntry) { _ in }
        let partialRevision = layout.stagingDirectory(for: testEntry.id, revision: "interrupted")
        try FileManager.default.createDirectory(at: partialRevision, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partialRevision.appendingPathComponent("weights.bin.partial"))
        await installer.uninstall(testEntry)
        #expect(installer.anyInstalledRecord(for: testEntry) == nil)
        #expect(!FileManager.default.fileExists(atPath: layout.modelDirectory(for: testEntry.id).path))
        #expect(!FileManager.default.fileExists(atPath: partialRevision.path))
    }
}
