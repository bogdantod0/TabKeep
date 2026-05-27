import Foundation

extension APIError {
    /// User-friendly message. Don't pattern-match on `code` strings in views;
    /// route through this.
    var userMessage: String {
        switch self {
        case .transport:
            return "Couldn't reach the server. Try again."
        case .server(let code, let message, _, _):
            return Self.message(forServerCode: code, fallback: message)
        case .staleWrite:
            return "Someone else changed this. We've refreshed it for you."
        case .decoding:
            return "Unexpected response from the server."
        case .unexpected:
            return "Something went wrong."
        case .upgradeRequired:
            return "Update SplitBill to continue."
        }
    }

    /// True if this error should be shown via an iOS alert; false if inline
    /// red text under the buttons is the right surface.
    var preferAlert: Bool {
        switch self {
        case .transport: return false
        case .server(_, _, let status, _):
            return status < 500 && !isRetryable
        case .staleWrite:
            // Repositories convert this into MutationOutcome.staleWrite and
            // surface it as a non-modal banner; never alert.
            return false
        case .decoding, .unexpected:
            return true
        case .upgradeRequired:
            // Surfaced as a full-screen hard-block cover, not an alert.
            return false
        }
    }

    private static func message(forServerCode code: String, fallback: String) -> String {
        switch code {
        case "auth_required":                    return "Please sign in again."
        case "auth_invalid":                     return "Couldn't verify your sign-in. Try again."
        case "forbidden":                        return "You don't have access to that."
        case "not_found":                        return "Not found."
        case "validation_failed":                return "That didn't look right. Try again."
        case "rate_limited":                     return "Slow down — try again in a bit."
        case "already_signed_in_as_other_user":  return "Sign out first to switch accounts."
        case "idempotency_replay":               return "Conflicting retry. Try again."
        default:                                 return fallback.isEmpty ? "Something went wrong." : fallback
        }
    }
}
