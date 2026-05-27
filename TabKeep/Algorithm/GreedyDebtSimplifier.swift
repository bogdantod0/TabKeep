import Foundation

struct GreedyDebtSimplifier: DebtSimplifier {
    func settlements(from balances: [MemberBalance]) -> [Settlement] {
        let nonZero = balances.filter { $0.netAmount != 0 }

        assert(nonZero.reduce(Decimal(0)) { $0 + $1.netAmount } == 0,
               "Debt simplifier input balances do not sum to zero")

        var creditors = nonZero
            .filter { $0.netAmount > 0 }
            .sorted { lhs, rhs in
                if lhs.netAmount != rhs.netAmount { return lhs.netAmount > rhs.netAmount }
                return lhs.memberID.uuidString < rhs.memberID.uuidString
            }
        var debtors = nonZero
            .filter { $0.netAmount < 0 }
            .sorted { lhs, rhs in
                if lhs.netAmount != rhs.netAmount { return lhs.netAmount < rhs.netAmount }
                return lhs.memberID.uuidString < rhs.memberID.uuidString
            }

        var settlements: [Settlement] = []

        while let creditor = creditors.first, let debtor = debtors.first {
            let transferAmount = min(creditor.netAmount, -debtor.netAmount)
            settlements.append(Settlement(
                fromMemberID: debtor.memberID,
                toMemberID: creditor.memberID,
                amount: transferAmount
            ))

            let newCreditorAmount = creditor.netAmount - transferAmount
            let newDebtorAmount = debtor.netAmount + transferAmount

            creditors.removeFirst()
            debtors.removeFirst()

            if newCreditorAmount > 0 {
                creditors = insertSorted(
                    MemberBalance(memberID: creditor.memberID, netAmount: newCreditorAmount),
                    into: creditors,
                    descending: true
                )
            }
            if newDebtorAmount < 0 {
                debtors = insertSorted(
                    MemberBalance(memberID: debtor.memberID, netAmount: newDebtorAmount),
                    into: debtors,
                    descending: false
                )
            }
        }

        return settlements
    }

    private func insertSorted(
        _ balance: MemberBalance,
        into list: [MemberBalance],
        descending: Bool
    ) -> [MemberBalance] {
        var copy = list
        copy.append(balance)
        copy.sort { lhs, rhs in
            if lhs.netAmount != rhs.netAmount {
                return descending ? lhs.netAmount > rhs.netAmount : lhs.netAmount < rhs.netAmount
            }
            return lhs.memberID.uuidString < rhs.memberID.uuidString
        }
        return copy
    }
}
