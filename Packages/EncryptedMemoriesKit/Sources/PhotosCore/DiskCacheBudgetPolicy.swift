/// Current disk budgets. Volume facts do not change these defaults.
public struct DiskCacheBudgetPolicy: Sendable, Equatable {
    public enum Platform: Sendable, Equatable { case mobile, macOS }
    public enum Budget: Sendable, Equatable {
        case unlimited
        case bytes(Int64)
    }
    public enum OriginalsOverride: Sendable, Equatable {
        case unlimited
        case bounded(Int64)
    }

    public let thumbnailBudget: Budget = .unlimited
    public let previewBudget: Budget = .bytes(2 << 30)
    public let originalsBudget: Budget
    public let videoBudget: Budget = .bytes(512 << 20)
    public let locationBudget: Budget = .unlimited
    public let backupMaximumBytes: Int64 = 2 << 30
    public let backupMinimumFreeBytes: Int64 = 1 << 30
    public let lowStorageThresholdBytes: Int64 = 2 << 30
    public let criticalStorageThresholdBytes: Int64 = 512 << 20
    public let storageRecoveryMarginBytes: Int64 = 256 << 20

    public init(
        platform: Platform,
        originalsOverride: OriginalsOverride? = nil,
        totalBytes: Int64? = nil,
        availableBytes: Int64? = nil
    ) {
        switch (platform, originalsOverride) {
        case (.mobile, _):
            originalsBudget = .bytes(512 << 20)
        case (.macOS, nil):
            originalsBudget = .bytes(5 << 30)
        case (.macOS, .unlimited):
            originalsBudget = .unlimited
        case (.macOS, .bounded(let bytes)):
            originalsBudget = .bytes(max(0, bytes))
        }
    }
}
