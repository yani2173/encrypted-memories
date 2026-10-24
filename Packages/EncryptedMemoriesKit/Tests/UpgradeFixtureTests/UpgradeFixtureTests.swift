import CryptoKit
import Foundation
import XCTest

#if os(macOS)
    final class UpgradeFixtureTests: XCTestCase {
        struct Manifest: Decodable {
            let format: Int
            let release: String
            let commit: String
            let sdk: String
            let scenarios: [String: [Snapshot]]
        }
        struct Snapshot: Decodable {
            struct Event: Decodable {
                let id: Int
                let kind: String
                let path: String
                let frames: Int
                let threshold: Int
                let result: Int
            }
            let event: Event
            let atomicTargets: [String: [String]]
            let atomicHelpers: [String: String]
            let retryIssueObserved: Bool
            struct FileMetadata: Decodable {
                let mtimeNanoseconds: Int64
                let mode: Int
                let byteCount: Int
            }
            let files: [String: String]
            let metadata: [String: FileMetadata]
            let directories: [String]
            let oracle: FixtureOracle
        }
        struct Release: Decodable, Sendable {
            let tag: String
            let commit: String
            let sdk: String
        }
        struct ReleaseList: Decodable {
            let format: Int
            let minimumPublicRelease: String
            let releases: [Release]
        }

        private func fixtureRoot() throws -> URL {
            try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        }

        private func releases(at root: URL) throws -> [Release] {
            let list = try JSONDecoder().decode(
                ReleaseList.self, from: Data(contentsOf: root.appendingPathComponent("releases.json")))
            try fixtureRequire(list.format == 1 && list.minimumPublicRelease == "v1.0.5", "Invalid public release list")
            let tags = Set(list.releases.map(\.tag))
            try fixtureRequire(
                tags.count == list.releases.count && tags.contains(list.minimumPublicRelease),
                "Release list must retain the first public release and contain no duplicates")
            for release in list.releases {
                let validTag =
                    release.tag.range(
                        of: #"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression)
                    != nil
                let version = release.tag.dropFirst().split(separator: ".").compactMap { Int($0) }
                try fixtureRequire(
                    validTag && version.count == 3 && !version.lexicographicallyPrecedes([1, 0, 5]),
                    "Only stable public releases from v1.0.5 are supported")
                try fixtureRequire(
                    release.commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
                        && release.sdk.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
                    "Invalid recorded commit or SDK")
                for name in ["manifest.json", "corpus.tar.gz", "wal-policy-proof.json"] {
                    try fixtureRequire(
                        FileManager.default.fileExists(
                            atPath: root.appendingPathComponent("\(release.tag)/\(name)").path),
                        "Missing committed upgrade states for \(release.tag): \(name)")
                }
            }
            let folders = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            )
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map(\.lastPathComponent)
            try fixtureRequire(Set(folders) == tags, "Release folders and release list differ")
            return list.releases
        }

        private func manifest(_ release: Release) throws -> Manifest {
            let url = try fixtureRoot().appendingPathComponent("\(release.tag)/manifest.json")
            let corpus = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            try fixtureRequire(
                corpus.format == 1 && corpus.release == release.tag && corpus.commit == release.commit
                    && corpus.sdk == release.sdk,
                "Recorded release metadata differs from the release list: \(release.tag)")
            return corpus
        }

        func testEveryDeclaredReleaseHasCommittedFixtures() throws {
            for release in try releases(at: fixtureRoot()) { _ = try manifest(release) }
        }

        func testReleaseCatalogAcceptsNewReleasesAndRejectsMissingOrUnlistedFolders() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "upgrade-catalog-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            func writeList(_ tags: [String]) throws {
                let records = tags.map { ["tag": $0, "commit": String(repeating: "7", count: 40), "sdk": "0.29.1"] }
                let data = try JSONSerialization.data(withJSONObject: [
                    "format": 1, "minimumPublicRelease": "v1.0.5", "releases": records,
                ])
                try data.write(to: root.appendingPathComponent("releases.json"))
            }
            for tag in ["v1.0.5", "v1.1.0"] {
                let folder = root.appendingPathComponent(tag)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for name in ["manifest.json", "corpus.tar.gz", "wal-policy-proof.json"] {
                    try Data().write(to: folder.appendingPathComponent(name))
                }
            }
            try writeList(["v1.0.5", "v1.1.0"])
            XCTAssertEqual(try releases(at: root).map(\.tag), ["v1.0.5", "v1.1.0"])
            try writeList(["v1.0.5"])
            XCTAssertThrowsError(try releases(at: root), "An unlisted release must never be skipped")
            try writeList(["v1.0.5", "v1.1.0"])
            try FileManager.default.removeItem(at: root.appendingPathComponent("v1.1.0/corpus.tar.gz"))
            XCTAssertThrowsError(try releases(at: root), "A listed release must have a corpus")
            for tag in ["v1.0.4", "v1.1.0-beta.1", "v1.0.5"] {
                let folder = root.appendingPathComponent(tag)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for name in ["manifest.json", "corpus.tar.gz", "wal-policy-proof.json"] {
                    try Data().write(to: folder.appendingPathComponent(name))
                }
                try writeList(["v1.0.5", tag])
                XCTAssertThrowsError(try releases(at: root))
            }
        }

        func testCommittedCorpusCoversEveryScenario() throws {
            guard ProcessInfo.processInfo.environment["UPGRADE_CHECK_SCENARIO"] == nil else { return }
            for release in try releases(at: fixtureRoot()) {
                try verifyCoverage(release)
            }
        }

        private func verifyCoverage(_ release: Release) throws {
            let corpus = try manifest(release)
            XCTAssertEqual(Set(corpus.scenarios.keys), Set(FixtureWorkloads.scenarios))
            for scenario in FixtureWorkloads.scenarios {
                let snapshots = try XCTUnwrap(corpus.scenarios[scenario])
                XCTAssertFalse(snapshots.isEmpty, scenario)
                XCTAssertEqual(
                    snapshots.map(\.event.id), Array(1..<(snapshots.count + 1)), "Every boundary must be retained")
                if scenario == "backup" || scenario == "index" {
                    XCTAssertTrue(snapshots.contains { $0.event.kind == "commit" }, "No SQLite commit observed")
                    XCTAssertTrue(snapshots.contains { $0.files.keys.contains { $0.hasSuffix("-wal") } }, "WAL missing")
                    XCTAssertTrue(snapshots.contains { $0.files.keys.contains { $0.hasSuffix("-shm") } }, "SHM missing")
                }
            }
            let backup = try XCTUnwrap(corpus.scenarios["backup"])
            XCTAssertTrue(backup.contains { !$0.oracle.complete.isEmpty }, "No historical backed-up revision in corpus")
            XCTAssertTrue(backup.contains { !$0.oracle.remote.isEmpty }, "No independent server commit in corpus")
            let states = Set(backup.flatMap { $0.oracle.queueStates ?? [] })
            XCTAssertTrue(
                states.isSuperset(of: [
                    "discovered", "checking", "uploading", "needsRemoteReconciliation", "completed", "alreadyBackedUp",
                ]),
                "Missing persisted upload boundaries")
            XCTAssertTrue(backup.contains { $0.retryIssueObserved }, "Network retry boundary missing")
            XCTAssertTrue(backup.contains { $0.oracle.generation == 2 }, "Edit boundaries missing")
            XCTAssertTrue(backup.contains { $0.oracle.generation == 3 }, "Undo boundaries missing")
            for scenario in ["model", "index"] {
                let snapshots = try XCTUnwrap(corpus.scenarios[scenario])
                XCTAssertTrue(
                    snapshots.contains { snapshot in
                        snapshot.metadata.contains { path, file in
                            path.contains("weights.bin") && file.byteCount > 0
                                && file.byteCount < FixtureWorkloads.payload.count
                        }
                    }, "Partial model download missing")
            }
            let caches = try XCTUnwrap(corpus.scenarios["cache"])
            for namespace in ["thumbnails.enc", "previews.enc"] {
                XCTAssertTrue(
                    caches.contains { snapshot in
                        snapshot.metadata.contains { path, file in
                            snapshot.atomicHelpers[path]?.contains(namespace) == true && file.byteCount > 2048
                                && file.byteCount < FixtureWorkloads.cacheBytes.count
                        }
                    }, "Partial atomic cache helper missing: \(namespace)")
            }
            let fixtureRoot = try fixtureRoot().appendingPathComponent(release.tag)
            let entries = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: fixtureRoot, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]))
            let size = try entries.compactMap { $0 as? URL }.reduce(0) { result, url in
                let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                return result + (metadata.isRegularFile == true ? metadata.fileSize ?? 0 : 0)
            }
            XCTAssertLessThanOrEqual(size, 15_000_000, release.tag)
        }

        func testEveryRecordedFirstLaunch() throws {
            guard ProcessInfo.processInfo.environment["UPGRADE_CHECK_SCENARIO"] == nil else { return }
            let releases = try releases(at: fixtureRoot())
            let started = ContinuousClock.now
            // The budget grows with the recorded releases: 60 s of setup plus 60 s for each (120 s for one release).
            let budget = 60 * (releases.count + 1)
            let deadline = DispatchTime.now() + .seconds(budget)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "upgrade-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for release in releases {
                _ = try manifest(release)
                let pool = root.appendingPathComponent(release.tag)
                try FileManager.default.createDirectory(at: pool, withIntermediateDirectories: true)
                let archive = try fixtureRoot().appendingPathComponent("\(release.tag)/corpus.tar.gz")
                let extraction = Process()
                extraction.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                extraction.arguments = ["-xzf", archive.path, "-C", pool.path]
                let done = DispatchSemaphore(value: 0)
                extraction.terminationHandler = { _ in done.signal() }
                try extraction.run()
                try Self.finish(extraction, done: done, deadline: deadline)
                try fixtureRequire(extraction.terminationStatus == 0, "Corpus extraction failed: \(release.tag)")
            }

            let limit = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 2))
            let slots = DispatchSemaphore(value: limit)
            let group = DispatchGroup()
            let results = Results()
            for release in releases {
                for scenario in FixtureWorkloads.scenarios {
                    group.enter()
                    DispatchQueue.global().async {
                        slots.wait()
                        defer {
                            slots.signal()
                            group.leave()
                        }
                        do {
                            try fixtureRequire(
                                DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds,
                                "Upgrade verification exceeded its total deadline")
                            let pool = root.appendingPathComponent(release.tag)
                            let label = "\(release.tag)/\(scenario)"
                            let log = pool.appendingPathComponent("\(scenario).log")
                            FileManager.default.createFile(atPath: log.path, contents: nil)
                            let output = try FileHandle(forWritingTo: log)
                            defer { try? output.close() }
                            let process = Process()
                            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                            process.arguments = [
                                "-p", "(version 1)(allow default)(deny network*)", "/usr/bin/xcrun", "xctest",
                                "-XCTest",
                                "UpgradeFixtureTests.UpgradeFixtureTests/testScenarioWorker",
                                Bundle(for: UpgradeFixtureTests.self).bundleURL.path,
                            ]
                            let inherited = ProcessInfo.processInfo.environment
                            let allowed = [
                                "HOME", "PATH", "DEVELOPER_DIR", "TMPDIR", "LANG", "LC_ALL",
                                "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
                            ]
                            var environment = Dictionary(
                                uniqueKeysWithValues: allowed.compactMap { key in
                                    inherited[key].map { (key, $0) }
                                })
                            environment["UPGRADE_CHECK_SCENARIO"] = scenario
                            environment["UPGRADE_CHECK_POOL"] = pool.path
                            environment["UPGRADE_CHECK_RELEASE"] = release.tag
                            let dataRoot = pool.appendingPathComponent("data-\(scenario)")
                            let temporary = dataRoot.appendingPathComponent("Temporary")
                            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                            environment["TMPDIR"] = temporary.path + "/"
                            process.environment = environment
                            process.standardOutput = output
                            process.standardError = output
                            let done = DispatchSemaphore(value: 0)
                            process.terminationHandler = { _ in done.signal() }
                            try process.run()
                            try Self.finish(process, done: done, deadline: deadline)
                            let text = try String(contentsOf: log, encoding: .utf8)
                            if process.terminationStatus != 0 {
                                let errors = text.split(separator: "\n").filter { $0.contains("error:") }
                                results.append(
                                    "\(label): worker exit \(process.terminationStatus)\n\(errors.joined(separator: "\n"))\n\(text.suffix(1500))"
                                )
                            } else {
                                let marker = "Verified upgrade scenario: \(label)"
                                if let range = text.range(of: marker) {
                                    print(text[range.lowerBound...].split(separator: "\n").first ?? Substring(marker))
                                } else {
                                    results.append("\(label): worker did not verify any recorded boundaries")
                                }
                            }
                        } catch { results.append("\(release.tag)/\(scenario): \(error)") }
                    }
                }
            }
            group.wait()
            for failure in results.failures { XCTFail(failure) }
            let elapsed = started.duration(to: .now)
            print("Upgrade corpus verification duration: \(elapsed)")
            XCTAssertLessThan(elapsed, .seconds(budget), "Upgrade verification exceeds the CI runtime budget")
        }

        private static func finish(_ process: Process, done: DispatchSemaphore, deadline: DispatchTime) throws {
            guard done.wait(timeout: deadline) == .timedOut else { return }
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw FixtureFailure(description: "Upgrade verification exceeded its total deadline")
        }

        func testScenarioWorker() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard let scenario = environment["UPGRADE_CHECK_SCENARIO"],
                let poolPath = environment["UPGRADE_CHECK_POOL"],
                let tag = environment["UPGRADE_CHECK_RELEASE"]
            else { return }
            let release = try XCTUnwrap(try releases(at: fixtureRoot()).first { $0.tag == tag })
            let snapshots = try XCTUnwrap(try manifest(release).scenarios[scenario])
            let pool = URL(fileURLWithPath: poolPath)
            var expectedFailures = 0
            for snapshot in snapshots {
                let root = pool.appendingPathComponent("data-\(scenario)")
                print(
                    "Checking \(tag)/\(scenario) boundary \(snapshot.event.id) \(snapshot.event.kind) \(snapshot.event.path)"
                )
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                var failure: (any Error)?
                do {
                    for directory in snapshot.directories {
                        try validateRelativePath(directory)
                        try FileManager.default.createDirectory(
                            at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
                    }
                    for (relative, digest) in snapshot.files {
                        try validateRelativePath(relative)
                        try fixtureRequire(
                            digest.count == 64 && digest.allSatisfy { $0.isHexDigit }, "Invalid fixture hash")
                        let data = try Data(contentsOf: pool.appendingPathComponent("blobs/\(digest)"))
                        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        try fixtureRequire(actual == digest, "Fixture blob hash mismatch")
                        let destination = root.appendingPathComponent(relative)
                        try data.write(to: destination)
                        let metadata = try XCTUnwrap(snapshot.metadata[relative])
                        try FileManager.default.setAttributes(
                            [
                                .modificationDate: Date(
                                    timeIntervalSince1970: Double(metadata.mtimeNanoseconds) / 1_000_000_000),
                                .posixPermissions: metadata.mode,
                            ], ofItemAtPath: destination.path)
                    }
                    for (target, allowed) in snapshot.atomicTargets {
                        if let digest = snapshot.files[target] {
                            try fixtureRequire(
                                allowed.contains(digest), "Atomic target was partially visible: \(target)")
                        }
                    }
                    try await FixtureWorkloads.run(scenario, root: root, recording: false, oracle: snapshot.oracle)
                    if snapshot.atomicHelpers.keys.contains(where: { !$0.hasPrefix("Temporary/") }) {
                        for helper in snapshot.atomicHelpers.keys where !helper.hasPrefix("Temporary/") {
                            try fixtureRequire(
                                !FileManager.default.fileExists(atPath: root.appendingPathComponent(helper).path),
                                "Interrupted atomic helper remains outside system-managed temporary storage: \(helper)")
                        }
                        let afterFirstLaunch = try auxiliaryUsage(root, snapshot: snapshot)
                        for _ in 0..<2 {
                            try await FixtureWorkloads.run(
                                scenario, root: root, recording: false, oracle: snapshot.oracle)
                            let repeated = try auxiliaryUsage(root, snapshot: snapshot)
                            try fixtureRequire(
                                repeated.files <= afterFirstLaunch.files && repeated.bytes <= afterFirstLaunch.bytes,
                                "Interrupted-write helpers grow over repeated launches")
                        }
                    }
                } catch { failure = error }
                let reportFailure = {
                    if let failure { XCTFail("\(scenario) boundary \(snapshot.event.id): \(failure)") }
                }
                if let known = tag == "v1.0.5" ? knownFailure(scenario, snapshot: snapshot) : nil {
                    let options = XCTExpectedFailure.Options()
                    options.issueMatcher = { issue in
                        issue.compactDescription.contains(
                            "\(scenario) boundary \(snapshot.event.id): \(known.signature)")
                    }
                    XCTExpectFailure(known.issue, options: options) { reportFailure() }
                    if let failure, String(describing: failure) == known.signature { expectedFailures += 1 }
                } else {
                    reportFailure()
                }
                try FileManager.default.removeItem(at: root)
            }
            print(
                "Verified upgrade scenario: \(tag)/\(scenario), boundaries: \(snapshots.count), expected failures: \(expectedFailures)"
            )
        }

        private func knownFailure(_ scenario: String, snapshot: Snapshot) -> (issue: String, signature: String)? {
            return nil
        }

        private func auxiliaryUsage(_ root: URL, snapshot: Snapshot) throws -> (files: Int, bytes: Int) {
            let parents = Set(
                snapshot.atomicHelpers.keys.map { path in
                    path.hasPrefix("Temporary/")
                        ? "Temporary" : path.split(separator: "/").dropLast().joined(separator: "/")
                })
            var count = 0
            var bytes = 0
            for parent in parents {
                let directory = root.appendingPathComponent(parent)
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                let entries = try XCTUnwrap(
                    FileManager.default.enumerator(
                        at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]))
                for case let file as URL in entries {
                    let path = String(file.path.dropFirst(root.path.count + 1))
                    guard snapshot.atomicTargets[path] == nil else { continue }
                    let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if values.isRegularFile == true {
                        count += 1
                        bytes += values.fileSize ?? 0
                    }
                }
            }
            return (count, bytes)
        }

        private func validateRelativePath(_ path: String) throws {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            try fixtureRequire(
                !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." },
                "Unsafe fixture path")
        }

        private final class Results: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func append(_ value: String) { lock.withLock { values.append(value) } }
            var failures: [String] { lock.withLock { values } }
        }
    }
#endif
