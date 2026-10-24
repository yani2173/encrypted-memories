import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct TimelineCacheValidationPolicyTests {
    @Test func matchingStableTokenValidatesCachedInventory() async {
        let repository = CacheValidationRepository(cachedToken: "event-4", currentToken: "event-4")

        #expect(
            await TimelineCacheValidationPolicy.validate(
                snapshot: snapshot(token: "event-4"), repository: repository
            ) == .validated(token: "event-4"))
        #expect(await repository.probeCount == 1)
    }

    @Test func changedTokenRequiresRefreshAndPreservesOldBaseline() async {
        let repository = CacheValidationRepository(cachedToken: "event-4", currentToken: "event-5")

        #expect(
            await TimelineCacheValidationPolicy.validate(
                snapshot: snapshot(token: "event-4"), repository: repository
            ) == .refreshRequired(monitorBaseline: "event-5"))
    }

    @Test func missingPersistedTokenFailsClosedButStillCapturesMonitorBaseline() async {
        let repository = CacheValidationRepository(cachedToken: nil, currentToken: "event-5")

        #expect(
            await TimelineCacheValidationPolicy.validate(
                snapshot: snapshot(token: nil), repository: repository
            ) == .refreshRequired(monitorBaseline: "event-5"))
        #expect(await repository.probeCount == 1)
    }

    @Test func failedProbeFailsClosed() async {
        let repository = CacheValidationRepository(cachedToken: "event-4", currentToken: nil)

        #expect(
            await TimelineCacheValidationPolicy.validate(
                snapshot: snapshot(token: "event-4"), repository: repository
            ) == .refreshRequired(monitorBaseline: "event-4"))
    }

    @Test func terminalProbePreservesRecoveryMeaning() async {
        #expect(
            await TimelineCacheValidationPolicy.validate(
                snapshot: snapshot(token: "event-4"),
                repository: TerminalCacheValidationRepository()
            ) == .terminalFailure
        )
    }

    @Test(arguments: ["missing", "changed", "unpaired"])
    func publicationValidationRejectsAnUnprovenReread(state: String) async {
        let repository = RereadValidationRepository(state: state)
        let result = await TimelineCacheValidationPolicy.validateForPublication(
            snapshot: snapshot(token: "photos-inventory-v2:a"), repository: repository)
        #expect(result.validation == .refreshRequired(monitorBaseline: ""))
        #expect(result.snapshot == nil, "An unproven reread cannot become an authoritative publication")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringRereadCannotValidateAPublication() async {
        let repository = RereadValidationRepository(state: "held")
        let validation = Task {
            await TimelineCacheValidationPolicy.validateForPublication(
                snapshot: snapshot(token: "photos-inventory-v2:a"), repository: repository)
        }
        await repository.waitUntilHeld()
        validation.cancel()
        await repository.release()
        let result = await validation.value
        #expect(result.validation == .refreshRequired(monitorBaseline: ""))
        #expect(result.snapshot == nil)
    }

    @Test
    func failedCheapValidationCannotAuthorizeACacheReread() async {
        let repository = FailedRereadValidationRepository()
        let result = await TimelineCacheValidationPolicy.validateForPublication(
            snapshot: snapshot(token: "photos-inventory-v2:a"), repository: repository)
        #expect(result.validation == .refreshRequired(monitorBaseline: "photos-inventory-v2:b"))
        #expect(result.snapshot == nil, "A failed cheap check must not authorize cached content for publication")
        #expect(await repository.cachedReads == 0, "A failed cheap check proceeds directly to authoritative recovery")
    }

    private func snapshot(token: String?) -> CachedTimelineSnapshot {
        CachedTimelineSnapshot(sections: [], validationToken: token)
    }
}

private actor CacheValidationRepository: PhotosRepository, LibraryChangeTokenProvider {
    let cachedToken: String?
    let currentToken: String?
    private(set) var probeCount = 0

    init(cachedToken: String?, currentToken: String?) {
        self.cachedToken = cachedToken
        self.currentToken = currentToken
    }

    func loadTimeline() async throws -> [TimelineSection] { [] }
    func cachedTimelineValidationToken() async -> String? { cachedToken }

    func libraryChangeToken() async throws -> String {
        probeCount += 1
        guard let currentToken else { throw ProbeFailure() }
        return currentToken
    }
}

private struct ProbeFailure: Error {}

private struct TerminalCacheValidationRepository: PhotosRepository, LibraryChangeTokenProvider {
    func loadTimeline() async throws -> [TimelineSection] { [] }

    func libraryChangeToken() async throws -> String {
        throw TerminalCacheValidationError()
    }
}

private struct TerminalCacheValidationError: LibraryChangeTerminalError {}

private actor RereadValidationRepository: PhotosRepository, LibraryChangeTokenProvider {
    let state: String
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(state: String) { self.state = state }
    func loadTimeline() async throws -> [TimelineSection] { [] }
    func launchValidationToken(for snapshot: CachedTimelineSnapshot) async throws -> String { "photos-inventory-v2:a" }
    func libraryChangeToken() async throws -> String { "a#media=1#order=1" }
    func cachedTimelineSnapshot() async -> CachedTimelineSnapshot? {
        if state == "held" {
            held = true
            await withCheckedContinuation { continuation = $0 }
        }
        if state == "missing" { return nil }
        return CachedTimelineSnapshot(
            sections: [],
            validationToken: state == "changed"
                ? "photos-inventory-v2:b" : state == "unpaired" ? nil : "photos-inventory-v2:a")
    }
    func waitUntilHeld() async { while !held { await Task.yield() } }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FailedRereadValidationRepository: PhotosRepository, LibraryChangeTokenProvider {
    private(set) var cachedReads = 0
    func loadTimeline() async throws -> [TimelineSection] { [] }
    func launchValidationToken(for snapshot: CachedTimelineSnapshot) async throws -> String { "photos-inventory-v2:b" }
    func libraryChangeToken() async throws -> String { "b#media=1#order=1" }
    func cachedTimelineSnapshot() async -> CachedTimelineSnapshot? {
        cachedReads += 1
        return CachedTimelineSnapshot(sections: [], validationToken: "photos-inventory-v2:a")
    }
}
