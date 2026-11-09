/// One deletion decision is about a photo, while every other problem keeps its existing per-revision action.
public struct BackupProblemPhotoSelection: Sendable {
    public let items: [BackupFailedItem]
    public let revisionsBySource: [UploadSourceIdentity: Set<UploadBackupRevision>]

    public init(_ input: [BackupFailedItem], decisionIssue: BackupIssueKind = .deletedElsewhere) {
        var photos: [BackupFailedItem] = []
        var positions: [UploadSourceIdentity: Int] = [:]
        var revisions: [UploadSourceIdentity: Set<UploadBackupRevision>] = [:]
        for item in input {
            guard item.issue == decisionIssue, let source = item.source else {
                photos.append(item)
                continue
            }
            if let revision = item.revision { revisions[source, default: []].insert(revision) }
            if let index = positions[source] {
                if let revision = item.revision, photos[index].revision.map({ revision > $0 }) ?? true {
                    photos[index] = item
                }
            } else {
                positions[source] = photos.count
                photos.append(item)
            }
        }
        items = photos
        revisionsBySource = revisions
    }
}
