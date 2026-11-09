import Foundation

enum UploadUITrigger: String {
    case toolbar
    case menu
}

/// What `MainView` does when an upload command arrives. The raw values are the words of the debug log line.
enum UploadUIAction: String {
    case uploadPhotos
    case uploadFolder
    case showQueue
}

/// Notifications posted by the File-menu / toolbar upload commands (which live in the App scene) and
/// observed by `MainView` (which owns the upload coordinator + can present panels).
extension Notification.Name {
    static let encryptedMemoriesUploadPhotos = Notification.Name("EncryptedMemories.uploadPhotos")
    static let encryptedMemoriesUploadFolder = Notification.Name("EncryptedMemories.uploadFolder")
    static let encryptedMemoriesShowUploadQueue = Notification.Name("EncryptedMemories.showUploadQueue")
    static let encryptedMemoriesRefreshLibrary = Notification.Name("EncryptedMemories.refreshLibrary")
    static let encryptedMemoriesNewAlbum = Notification.Name("EncryptedMemories.newAlbum")
}

func uploadCommandUserInfo(trigger: UploadUITrigger) -> [AnyHashable: Any] {
    ["trigger": trigger.rawValue]
}

func uploadTrigger(from notification: Notification) -> UploadUITrigger {
    guard let raw = notification.userInfo?["trigger"] as? String,
        let trigger = UploadUITrigger(rawValue: raw)
    else {
        return .menu
    }
    return trigger
}
