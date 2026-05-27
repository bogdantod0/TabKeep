import Foundation

enum BalanceCalculator {
    static func balances(for group: ExpenseGroup) -> [MemberBalance] {
        var net: [UUID: Decimal] = Dictionary(uniqueKeysWithValues: group.members.map { ($0.id, Decimal(0)) })
        let memberIDs = Set(group.members.map(\.id))

        for expense in group.expenses {
            // Skip expenses that lack ANY debit destination — without
            // shares or participants, crediting the payer would break the
            // zero-sum invariant (assertion below). This can happen
            // transiently when a server response races with local state
            // (e.g., participant_membership_ids cache stale on the server's
            // expense partial render). Treat such expenses as in-flight and
            // exclude until refresh repairs them.
            let hasShares = !(expense.shares?.isEmpty ?? true)
            let hasParticipants = !expense.participantIDs.isEmpty
            guard hasShares || hasParticipants else { continue }

            // Same hazard as the payments skip below: a sync race or local
            // eviction can leave an expense whose payerID / participantIDs
            // / shares.*.memberID / payments.*.memberID points at a member
            // that isn't in this group's local roster. `net[id, default: 0]
            // += amount` would silently create a phantom entry, and the
            // per-member return below would drop it, leaving the real
            // members' balances non-zero and tripping the downstream
            // debt-simplifier's zero-sum assertion. Skip the expense
            // entirely until refresh repairs the roster.
            let creditIDs: [UUID] = (expense.payments?.isEmpty == false)
                ? expense.payments!.map(\.memberID)
                : [expense.payerID]
            let debitIDs: [UUID] = (expense.shares?.isEmpty == false)
                ? expense.shares!.map(\.memberID)
                : expense.participantIDs
            guard creditIDs.allSatisfy(memberIDs.contains),
                  debitIDs.allSatisfy(memberIDs.contains) else { continue }

            let payerCredit = (expense.amount * expense.exchangeRate)
                .rounded(scale: 2, roundingMode: .bankers)

            // Credit side: single-payer (legacy) credits the full amount
            // to `expense.payerID`. Multi-payer credits each payer their
            // converted share. Last payer (by ID-sort) absorbs the
            // rounding residual so sum(credits) == payerCredit exactly,
            // mirroring how shares handle the debit-side residual.
            if let expensePayments = expense.payments, !expensePayments.isEmpty {
                let sortedPayments = expensePayments.sorted { $0.memberID.uuidString < $1.memberID.uuidString }
                var runningSum: Decimal = 0
                for (i, p) in sortedPayments.enumerated() {
                    var credit = (p.amount * expense.exchangeRate)
                        .rounded(scale: 2, roundingMode: .bankers)
                    if i == sortedPayments.count - 1 {
                        credit = payerCredit - runningSum
                    } else {
                        runningSum += credit
                    }
                    net[p.memberID, default: 0] += credit
                }
            } else {
                net[expense.payerID, default: 0] += payerCredit
            }

            if let expenseShares = expense.shares, !expenseShares.isEmpty {
                // Custom split: honor stored per-member amounts (in the
                // expense's own currency), convert to group currency with
                // the snapshotted rate, and absorb rounding residual into
                // the last share so sum(debits) == payerCredit exactly.
                let sorted = expenseShares.sorted { $0.memberID.uuidString < $1.memberID.uuidString }
                var runningSum: Decimal = 0
                for (i, share) in sorted.enumerated() {
                    var debit = (share.amount * expense.exchangeRate)
                        .rounded(scale: 2, roundingMode: .bankers)
                    if i == sorted.count - 1 {
                        debit = payerCredit - runningSum
                    } else {
                        runningSum += debit
                    }
                    net[share.memberID, default: 0] -= debit
                }
            } else {
                guard !expense.participantIDs.isEmpty else { continue }
                let sortedParticipants = expense.participantIDs
                    .sorted { $0.uuidString < $1.uuidString }
                let perShare = splitAmount(payerCredit, across: sortedParticipants.count)
                for (participant, share) in zip(sortedParticipants, perShare) {
                    net[participant, default: 0] -= share
                }
            }
        }

        // Recorded payments: the payer (debtor) gives money — their net
        // moves toward 0 from below → +amount. The recipient (creditor)
        // was owed money — they're owed less now → -amount. Zero-sum
        // invariant is preserved within each iteration. Skip payments
        // whose endpoints aren't in the group for the same reason as
        // the expense skip above.
        for payment in (group.payments ?? []) {
            guard memberIDs.contains(payment.fromMemberID),
                  memberIDs.contains(payment.toMemberID) else { continue }
            let amount = payment.amount.rounded(scale: 2, roundingMode: .bankers)
            net[payment.fromMemberID, default: 0] += amount
            net[payment.toMemberID, default: 0] -= amount
        }

        // Assert on the per-member sum that we actually return, not on
        // net.values — phantom entries created by `default: 0` writes
        // would otherwise hide a roster mismatch here and surface it
        // downstream in the debt simplifier.
        let result = group.members.map { MemberBalance(memberID: $0.id, netAmount: net[$0.id] ?? 0) }
        assert(result.reduce(Decimal(0)) { $0 + $1.netAmount } == 0,
               "Balance invariant violated: members' net sum != 0")
        return result
    }

    static func splitAmount(_ amount: Decimal, across n: Int) -> [Decimal] {
        precondition(n > 0, "Cannot split across zero participants")
        let hundred = Decimal(100)
        let totalCents = (amount * hundred).rounded(scale: 0, roundingMode: .bankers)
        let totalCentsInt = NSDecimalNumber(decimal: totalCents).intValue
        let perShare = totalCentsInt / n
        let remainder = totalCentsInt - perShare * n
        var shares = Array(repeating: Decimal(perShare) / hundred, count: n)
        if remainder != 0 {
            shares[0] = Decimal(perShare + remainder) / hundred
        }
        return shares
    }
}

private extension Decimal {
    func rounded(scale: Int, roundingMode: NSDecimalNumber.RoundingMode) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, roundingMode)
        return result
    }
}
