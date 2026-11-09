import Foundation
import Observation

/// A visible list owns one read admission across native task restarts and manual refreshes.
@MainActor
@Observable
public final class BackupProblemListSession {
    public private(set) var rows: [BackupProblemSnapshot.Row] = []
    public private(set) var isUnavailable = false
    public private(set) var isReading = false
    public private(set) var total = 0
    public private(set) var decisionCount = 0
    public private(set) var hasRead = false
    public var isRetired: Bool { retired }
    public var fixedActionMessage: String? { retired ? nil : message() }
    #if DEBUG || ENCRYPTED_MEMORIES_PROBLEM_LIST_BENCHMARK
        enum PublicationEvent: String { case willApply, didApply, willAppend, didAppend }
        @ObservationIgnored var onPublicationEvent: ((PublicationEvent) -> Void)?
    #endif
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let read: @MainActor () async -> BackupProblemSnapshot?
    @ObservationIgnored private let message: @MainActor () -> String?
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var snapshot: BackupProblemSnapshot?
    @ObservationIgnored private var next: BackupProblemSnapshot.Cursor?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var retired = false
    @ObservationIgnored private var lastReadStarted: TimeInterval?
    @ObservationIgnored private var publication = UUID()
    @ObservationIgnored private var pageRequest: UUID?
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var pageDemand: BackupProblemSnapshot.Row.ID?

    public init(
        pageSize: Int = 200, fixedActionMessage: @escaping @MainActor () -> String? = { nil },
        read: @escaping @MainActor () async -> BackupProblemSnapshot?
    ) {
        self.pageSize = max(1, pageSize)
        self.read = read
        message = fixedActionMessage
        now = { ProcessInfo.processInfo.systemUptime }
        sleep = { try await Task.sleep(for: .seconds($0)) }
    }

    init(
        now: @escaping @MainActor () -> TimeInterval,
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void,
        read: @escaping @MainActor () async -> BackupProblemSnapshot?
    ) {
        pageSize = 200
        self.now = now
        self.sleep = sleep
        self.read = read
        message = { nil }
    }

    public func requestRefresh() {
        guard !retired else { return }
        if rows.isEmpty, isUnavailable {
            isUnavailable = false
            hasRead = false
        }
        dirty = true
        guard task == nil else { return }
        task = Task {
            while dirty, !retired, !Task.isCancelled {
                if let lastReadStarted {
                    let delay = max(0, lastReadStarted + 1 - now())
                    if delay > 0 {
                        do { try await sleep(delay) } catch { break }
                    }
                }
                guard !retired, !Task.isCancelled else { break }
                // Requests during the coalescing wait belong to this read. Requests during the read get one follow-up.
                dirty = false
                lastReadStarted = now()
                isReading = true
                let captured = await read()
                guard !retired, !Task.isCancelled else { break }
                #if DEBUG || ENCRYPTED_MEMORIES_PROBLEM_LIST_BENCHMARK
                    onPublicationEvent?(.willApply)
                #endif
                hasRead = true
                if let captured, let loaded = captured.page(size: max(pageSize, rows.count)) {
                    publication = UUID()
                    pageTask?.cancel()
                    pageTask = nil
                    pageRequest = nil
                    snapshot = captured
                    rows = loaded.rows
                    next = loaded.next
                    total = captured.rows.count
                    decisionCount = captured.decisionCount
                    isUnavailable = false
                    continueNearEndRequest()
                } else {
                    isUnavailable = true
                }
                #if DEBUG || ENCRYPTED_MEMORIES_PROBLEM_LIST_BENCHMARK
                    onPublicationEvent?(.didApply)
                #endif
            }
            isReading = false
            task = nil
        }
    }

    /// Native rows request metadata only when they approach the end of the loaded prefix.
    @discardableResult
    public func requestNextPage(near item: BackupFailedItem) -> Bool {
        guard let row = rows.suffix(40).first(where: { $0.item.id == item.id }) else { return false }
        pageDemand = row.id
        return requestNextPage()
    }

    private func continueNearEndRequest() {
        guard let pageDemand, rows.suffix(40).contains(where: { $0.id == pageDemand }) else {
            self.pageDemand = nil
            return
        }
        requestNextPage()
    }

    public func dismissItem(id: String) {
        let before = rows.count
        let removedDecisions = rows.filter { $0.item.id == id && $0.item.issue == snapshot?.decisionIssue }.count
        rows.removeAll { $0.item.id == id }
        decisionCount -= removedDecisions
        total -= before - rows.count
    }

    @discardableResult
    public func resolveDecision(_ item: BackupFailedItem, using resolve: () -> Bool) -> Bool {
        guard !retired else { return false }
        let committed = resolve()
        if committed { dismissItem(id: item.id) }
        requestRefresh()
        return committed
    }

    @discardableResult
    public func requestNextPage() -> Bool {
        guard !retired, pageTask == nil, let snapshot, let next else { return false }
        let pageSize = pageSize
        let request = UUID()
        let publication = publication
        pageRequest = request
        pageTask = Task {
            let page = await Task.detached(priority: .userInitiated) { snapshot.page(after: next, size: pageSize) }
                .value
            guard !retired, !Task.isCancelled, self.publication == publication, pageRequest == request else { return }
            if let page {
                #if DEBUG || ENCRYPTED_MEMORIES_PROBLEM_LIST_BENCHMARK
                    onPublicationEvent?(.willAppend)
                #endif
                rows += page.rows
                self.next = page.next
                #if DEBUG || ENCRYPTED_MEMORIES_PROBLEM_LIST_BENCHMARK
                    onPublicationEvent?(.didAppend)
                #endif
            }
            pageRequest = nil
            pageTask = nil
        }
        return true
    }

    public func waitUntilIdle() async {
        await task?.value
        await pageTask?.value
    }

    public func shutdown() async {
        retired = true
        dirty = false
        publication = UUID()
        let readTask = task
        let pendingPage = pageTask
        readTask?.cancel()
        pendingPage?.cancel()
        await readTask?.value
        await pendingPage?.value
        task = nil
        pageTask = nil
        pageRequest = nil
        pageDemand = nil
        snapshot = nil
        next = nil
        rows = []
        total = 0
        decisionCount = 0
        hasRead = false
        isUnavailable = false
    }
}
