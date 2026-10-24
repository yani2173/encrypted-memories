import XCTest

@testable import PhotosCore

final class SupportDiagnosticsExporterTests: XCTestCase {
    func testSuggestionCacheDiagnosticsExposeOutcomesWithoutContent() {
        let diagnostics = PhotoDiagnostics(debugConsoleLogsEnabled: false)
        diagnostics.emitSupport(
            "SearchSuggestions",
            [
                "action": "restore", "result": "restored", "durationMs": "25",
                "uid": "private-photo", "fingerprint": "private-hash", "query": "private-query",
            ])
        diagnostics.increment("ml.suggestions.snapshotRestored")
        diagnostics.increment("ml.suggestions.private-photo")
        let snapshot = diagnostics.supportSnapshot()
        XCTAssertEqual(snapshot.events.first?.fields, ["action": "restore", "result": "restored", "durationMs": "25"])
        XCTAssertEqual(snapshot.counters, ["ml.suggestions.snapshotRestored": 1])
    }

    func testDisabledDebugLoggingDoesNotBuildFields() {
        let diagnostics = PhotoDiagnostics(debugConsoleLogsEnabled: false)
        var evaluations = 0
        diagnostics.emitDebug(
            "AuditProbe",
            fields: {
                evaluations += 1
                return ["count": "1"]
            }, throttleSeconds: 60, throttleKey: "frame")
        XCTAssertEqual(evaluations, 0)
    }

    func testExplicitDebugThrottleBuildsFieldsOnlyForAdmittedEvents() {
        let diagnostics = PhotoDiagnostics(debugConsoleLogsEnabled: true)
        var evaluations = 0
        for _ in 0..<100 {
            diagnostics.emitDebug(
                "AuditProbe",
                fields: {
                    evaluations += 1
                    return ["count": "1"]
                }, throttleSeconds: 60, throttleKey: "frame")
        }
        XCTAssertEqual(evaluations, 1)
        XCTAssertTrue(diagnostics.supportSnapshot().events.isEmpty)
        diagnostics.emitDebug(
            "AuditProbe",
            fields: {
                evaluations += 1
                return ["count": "2"]
            }, throttleSeconds: 60, throttleKey: "another-frame")
        XCTAssertEqual(evaluations, 2)
    }

    func testDiagnosticsThrottleRetainsOnlyItsFixedKeyBudget() {
        var throttle = BoundedDiagnosticsThrottle(capacity: 3)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(throttle.shouldEmit(key: "a", now: start, interval: 60))
        XCTAssertTrue(throttle.shouldEmit(key: "b", now: start.addingTimeInterval(1), interval: 60))
        XCTAssertTrue(throttle.shouldEmit(key: "c", now: start.addingTimeInterval(2), interval: 60))
        XCTAssertFalse(throttle.shouldEmit(key: "c", now: start.addingTimeInterval(3), interval: 60))

        XCTAssertTrue(throttle.shouldEmit(key: "d", now: start.addingTimeInterval(4), interval: 60))
        XCTAssertEqual(throttle.count, 3)
        XCTAssertTrue(
            throttle.shouldEmit(key: "a", now: start.addingTimeInterval(5), interval: 60),
            "The oldest key must be evicted when the fixed budget is full"
        )
        XCTAssertEqual(throttle.count, 3)
    }

    func testSupportSnapshotAllowsOnlyPrivacySafeResourceFields() {
        let diagnostics = PhotoDiagnostics.shared
        diagnostics.resetForTests()
        defer { diagnostics.resetForTests() }

        diagnostics.emit(
            "ResourcePermit",
            [
                "action": "acquire",
                "workload": "mlInference",
                "uid": "secret-asset",
                "filename": "secret.jpg",
                "query": "private search",
                "hash": "secret-hash",
            ])
        diagnostics.emit("ThumbHealth", ["uid": "secret-asset", "state": "geometryHole"])
        diagnostics.increment("timeline.refresh.applied")
        diagnostics.increment("timeline.refresh.asset-secret")

        let snapshot = diagnostics.supportSnapshot()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(
            snapshot.events.first?.fields,
            [
                "action": "acquire",
                "workload": "mlInference",
            ])
        XCTAssertEqual(snapshot.counters, ["timeline.refresh.applied": 1])
    }

    func testExportContainsRuntimeAndNeverRejectedFields() async throws {
        let diagnostics = PhotoDiagnostics.shared
        diagnostics.resetForTests()
        defer { diagnostics.resetForTests() }
        diagnostics.emit(
            "ResourceState",
            [
                "thermal": "serious",
                "path": "/private/photo",
                "error": "user content",
            ])
        let runtime = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(
                thermalLevel: .serious,
                memoryHeadroom: .constrained,
                isLowPowerMode: true,
                network: LibraryNetworkState(
                    isReachable: false, isConstrained: true, isExpensive: true,
                    usedInterfaces: [.other], availableInterfaces: [.other, .cellular])
            ))
        let coordinator = LibraryResourceCoordinator(runtimeState: runtime)

        let data = try await SupportDiagnosticsExporter.makeJSONData(
            runtimeState: runtime,
            resourceCoordinator: coordinator,
            diagnostics: diagnostics,
            bundle: Bundle(for: Self.self)
        )
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("\"schemaVersion\" : 2"))
        XCTAssertTrue(text.contains("\"appBuild\""))
        XCTAssertTrue(text.contains("\"appCommit\""))
        XCTAssertTrue(text.contains("serious"))
        XCTAssertFalse(text.contains("/private/photo"))
        XCTAssertFalse(text.contains("user content"))
        let runtimeSection = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["runtime"] as? [String: Any])
        XCTAssertEqual(runtimeSection["networkUsedInterfaces"] as? [String], ["other"])
        XCTAssertEqual(runtimeSection["networkAvailableInterfaces"] as? [String], ["cellular", "other"])
    }

    func testExportContainsTheRegisteredRequestCountsOnly() async throws {
        let sources = SupportDiagnosticsSources(trail: SupportEventTrail())
        let runtime = LibraryRuntimeState()
        let coordinator = LibraryResourceCoordinator(runtimeState: runtime)
        func export() async throws -> [String: Any] {
            let data = try await SupportDiagnosticsExporter.makeJSONData(
                runtimeState: runtime, resourceCoordinator: coordinator,
                diagnostics: PhotoDiagnostics(debugConsoleLogsEnabled: false),
                bundle: Bundle(for: Self.self), sources: sources, trail: SupportEventTrail())
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let signedOut = try await export()
        XCTAssertNil(signedOut["requests"])

        let source = FixedRequestSource()
        sources.registerRequests(source)
        let signedIn = try await export()
        let requests = try XCTUnwrap(signedIn["requests"] as? [String: Any])
        let counts = try XCTUnwrap(requests["counts"] as? [[String: Any]])
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts.first?["endpoint"] as? String, "/core/v4/users")
        XCTAssertEqual(counts.first?["cause"] as? String, "account")
        XCTAssertEqual(counts.first?["count"] as? Int, 2)
        let scopes = try XCTUnwrap(requests["scopes"] as? [[String: Any]])
        XCTAssertEqual(scopes.first?["peakInFlight"] as? Int, 3)
    }

    /// The VPN rule needs the used and available interface types from the owner's device. Types only.
    func testResourceStateEventCarriesTheNetworkInterfaceTypes() async throws {
        let diagnostics = PhotoDiagnostics.shared
        diagnostics.resetForTests()
        defer { diagnostics.resetForTests() }
        let runtime = LibraryRuntimeState()
        let coordinator = LibraryResourceCoordinator(runtimeState: runtime)
        await coordinator.startObserving()

        runtime.update {
            $0.network = LibraryNetworkState(
                path: LibraryNetworkPath(
                    isSatisfied: true, usedInterfaces: [.other], availableInterfaces: [.other, .cellular]))
        }

        var event: SupportDiagnosticEvent?
        let deadline = Date().addingTimeInterval(2)
        while event == nil, Date() < deadline {
            event = diagnostics.supportSnapshot().events.last {
                $0.category == "ResourceState" && $0.fields["networkAvailableInterfaces"] == "cellular,other"
            }
            if event == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        let fields = try XCTUnwrap(event?.fields)
        XCTAssertEqual(fields["networkInterfaces"], "other")
        XCTAssertEqual(fields["networkExpensive"], "true")
    }

    func testMLIndexQuantumExportsOnlyTechnicalAllowlistedFields() {
        let diagnostics = PhotoDiagnostics.shared
        diagnostics.resetForTests()
        defer { diagnostics.resetForTests() }

        diagnostics.emitSupport(
            "MLIndexQuantum",
            [
                "pipeline": "native",
                "parallelism": "3",
                "assetLimit": "32",
                "processed": "17",
                "durationMs": "2001",
                "waitMs": "4",
                "policyReason": "nominal",
                "yieldReason": "timeSliceCompleted",
                "rampStep": "3",
                "thermalBefore": "nominal",
                "thermalAfter": "fair",
                "memoryBefore": "normal",
                "memoryAfter": "normal",
                "assetID": "secret-asset",
                "filename": "private.jpg",
                "ocrText": "private document",
                "query": "private search",
                "modelInput": "private pixels",
            ])

        let event = diagnostics.supportSnapshot().events.first
        XCTAssertEqual(event?.category, "MLIndexQuantum")
        XCTAssertEqual(event?.fields.count, 13)
        XCTAssertEqual(event?.fields["pipeline"], "native")
        XCTAssertEqual(event?.fields["yieldReason"], "timeSliceCompleted")
        XCTAssertNil(event?.fields["assetID"])
        XCTAssertNil(event?.fields["filename"])
        XCTAssertNil(event?.fields["ocrText"])
        XCTAssertNil(event?.fields["query"])
        XCTAssertNil(event?.fields["modelInput"])
    }
}

private final class FixedRequestSource: RemoteRequestSupportSource {
    func remoteRequestSupportSnapshot() async -> RemoteRequestSupportSnapshot {
        RemoteRequestSupportSnapshot(
            counts: [
                .init(
                    scope: "api", method: "GET", endpoint: "/core/v4/users", cause: "account", status: "2xx",
                    count: 2)
            ],
            overflowRequests: 0,
            scopes: [
                .init(
                    scope: "api", inFlight: 0, queued: 0, concurrencyLimit: 4, admissionIntervalMilliseconds: 0,
                    admittedLastMinute: 2, rateLimitedLastMinute: 0, peakInFlight: 3,
                    maximumRetryAfterSeconds: nil, totalCooldownSeconds: 0)
            ])
    }
}
