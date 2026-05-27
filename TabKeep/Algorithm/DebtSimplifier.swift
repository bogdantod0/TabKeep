import Foundation

protocol DebtSimplifier {
    func settlements(from balances: [MemberBalance]) -> [Settlement]
}
