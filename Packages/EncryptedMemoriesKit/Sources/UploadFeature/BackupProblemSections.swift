import DesignSystemCore
import SwiftUI
import UploadCore

/// Shared sections inside each platform's native List. The host supplies native row actions.
public struct BackupProblemSections<Row: View>: View {
    private let items: [BackupFailedItem]
    private let row: (BackupFailedItem) -> Row

    public init(items: [BackupFailedItem], @ViewBuilder row: @escaping (BackupFailedItem) -> Row) {
        self.items = items
        self.row = row
    }

    public var body: some View {
        ForEach(BackupProblemSection.group(items)) { section in
            Section {
                ForEach(section.items) { item in row(item) }
            } header: {
                Text(section.title)
                    .accessibilityIdentifier("backup.issueSection.\(section.id.rawValue)")
            }
        }
    }
}

/// The same file, reason, and retry caption with the existing native typography on each platform.
public struct BackupProblemRow<Actions: View>: View {
    private let item: BackupFailedItem
    private let actions: Actions

    public init(item: BackupFailedItem, @ViewBuilder actions: () -> Actions) {
        self.item = item
        self.actions = actions()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: rowSpacing) {
            Image(systemName: item.category.symbolName)
                .foregroundStyle(item.isPermanent ? detailColor : .orange)
                #if os(iOS)
                    .font(.body)
                #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    #if os(iOS)
                        .font(.subheadline)
                    #endif
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let retryDescription = item.retryDescription {
                    Text(retryDescription)
                        .font(.caption2)
                        .foregroundStyle(detailColor)
                }
            }
            #if os(macOS)
                Spacer(minLength: 8)
            #endif
            actions
        }
        .padding(.vertical, 2)
    }

    private var rowSpacing: CGFloat {
        #if os(macOS)
            10
        #else
            12
        #endif
    }

    private var detailColor: Color {
        #if os(macOS)
            .secondary
        #else
            ProtonColor.textWeak
        #endif
    }
}

extension BackupProblemRow where Actions == EmptyView {
    public init(item: BackupFailedItem) {
        self.init(item: item) { EmptyView() }
    }
}
