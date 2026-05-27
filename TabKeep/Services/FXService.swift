import Foundation

enum FXServiceError: Error {
    case unsupportedCurrency(String)
    case invalidResponse
    case httpError(Int)
    case missingRate
}

protocol FXService {
    func rate(from: String, to: String, on date: Date) async throws -> Decimal
}
