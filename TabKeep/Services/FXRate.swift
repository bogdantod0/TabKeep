import Foundation

struct FXRate: Codable, Hashable {
    let from: String
    let to: String
    let date: Date
    let rate: Decimal
    let fetchedAt: Date
}
