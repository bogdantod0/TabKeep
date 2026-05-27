import Foundation

/// Which mutation kind the drainer was attempting when a permission error
/// came back from the server. Drives the banner copy ("can't delete" vs
/// "can't edit/create").
enum PermissionDeniedAction: Hashable, Sendable {
    case upsert
    case delete
}

/// Emitted by SyncDrainer to communicate sync outcomes to AppStore.
/// Carrying `Any` for entity payloads avoids generic plumbing through the
/// actor's interface; the receiver switches on `key.kind` to cast.
enum ServerEvent: @unchecked Sendable {
    case upserted(EntityKey, payload: Any)
    case deleted(EntityKey)
    case conflict(EntityKey, server: Any?, rejectedLocal: Any?)
    case groupGoneOnServer(UUID)
    /// Server returned 403 forbidden. AppStore surfaces an explanatory
    /// banner and triggers an immediate refresh so the local state matches
    /// the server's (the local mutation has already been rolled back by the
    /// drainer clearing its dirty / tombstone entry).
    case permissionDenied(EntityKey, action: PermissionDeniedAction)
    /// Hard validation failure during receipt upload (e.g., byte_size_too_large,
    /// invalid_content_type). AppStore surfaces a banner and leaves the local
    /// receipt row visible so the user can still view the photo.
    case receiptRejected(EntityKey, reason: String?)
    /// Local JPEG file vanished from disk before the drainer could PUT it.
    /// AppStore should remove the now-dangling ReceiptAttachment from the model.
    case receiptFileMissing(EntityKey)
}
