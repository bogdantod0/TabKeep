import Foundation

enum ActivityBuilder {
    static func events(from groups: [ExpenseGroup]) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        for group in groups {
            events.append(ActivityEvent(
                id: group.id,
                kind: .groupCreated,
                groupID: group.id,
                groupName: group.name,
                date: group.createdAt
            ))

            for member in group.members {
                events.append(ActivityEvent(
                    id: member.id,
                    kind: .memberJoined(memberName: member.name),
                    groupID: group.id,
                    groupName: group.name,
                    date: member.joinedAt
                ))
            }

            for expense in group.expenses {
                let payerName = group.members.first { $0.id == expense.payerID }?.name ?? "Unknown"
                events.append(ActivityEvent(
                    id: expense.id,
                    kind: .expenseAdded(
                        description: expense.description,
                        amount: expense.amount,
                        currencyCode: group.currencyCode,
                        payerName: payerName
                    ),
                    groupID: group.id,
                    groupName: group.name,
                    date: expense.date
                ))
            }

            for payment in (group.payments ?? []) {
                let fromName = group.members.first { $0.id == payment.fromMemberID }?.name ?? "Unknown"
                let toName = group.members.first { $0.id == payment.toMemberID }?.name ?? "Unknown"
                events.append(ActivityEvent(
                    id: payment.id,
                    kind: .paymentRecorded(
                        fromMemberName: fromName,
                        toMemberName: toName,
                        amount: payment.amount,
                        currencyCode: group.currencyCode
                    ),
                    groupID: group.id,
                    groupName: group.name,
                    date: payment.date
                ))
            }
        }
        return events.sorted { $0.date > $1.date }
    }
}
