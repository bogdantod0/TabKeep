// SplitBill/Views/Components/PaymentRow.swift
import SwiftUI

struct PaymentRow: View {
    let group: ExpenseGroup
    let payment: Payment
    @Environment(AppStore.self) private var store

    private var fromMember: Member? {
        group.members.first { $0.id == payment.fromMemberID }
    }
    private var toMember: Member? {
        group.members.first { $0.id == payment.toMemberID }
    }
    private var hasDraft: Bool {
        store.drafts[.payment(payment.id, in: group.id)] != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: -8) {
                if let fromMember {
                    AvatarView(emoji: fromMember.emoji, size: 30)
                        .overlay(Circle().strokeBorder(AppTheme.cardBackground, lineWidth: 2))
                }
                if let toMember {
                    AvatarView(emoji: toMember.emoji, size: 30)
                        .overlay(Circle().strokeBorder(AppTheme.cardBackground, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(fromMember?.name ?? "?")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                    Text(toMember?.name ?? "?")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if hasDraft {
                        Image(systemName: "doc.badge.ellipsis")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let note = payment.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(payment.amount.formatted(.currency(code: group.currencyCode)))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Text(relativeDate)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var relativeDate: String {
        let cal = Calendar.current
        if cal.isDateInToday(payment.date) { return "Today" }
        if cal.isDateInYesterday(payment.date) { return "Yesterday" }
        return payment.date.formatted(.dateTime.month(.abbreviated).day())
    }
}
