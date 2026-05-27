import Foundation

enum APIError: Error, Equatable {
    case transport(URLError)
    case server(code: String, message: String, status: Int, reason: String?)
    case staleWrite(currentRaw: Data)
    case decoding(String)               // String not Error so Equatable works
    case unexpected(status: Int, bodyPreview: String)
    case upgradeRequired(minimum: String)

    var isRetryable: Bool {
        switch self {
        case .transport: return true
        case .server(let code, _, let status, _):
            return status >= 500 || code == "rate_limited"
        case .staleWrite, .decoding, .unexpected, .upgradeRequired:
            return false
        }
    }
}
