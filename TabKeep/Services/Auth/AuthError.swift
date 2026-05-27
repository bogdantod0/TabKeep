import Foundation

enum AuthError: Error, Equatable {
    /// User dismissed the sign-in sheet. UI should treat as no-op.
    case cancelled
    /// Provider sign-in failed for any other reason. UI should show alert.
    case failed(reason: String)
}
