import SwiftUI

struct ActivityRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case groupCreated
        case memberJoined(name: String)
        case expenseAdded(description: String, amount: Decimal, currencyCode: String, payerName: String)
        case expenseEdited(description: String, changes: [String])
        case expenseDeleted(description: String, amount: Decimal, currencyCode: String, payerName: String)
        case paymentRecorded(fromMemberName: String, toMemberName: String, amount: Decimal, currencyCode: String)
        case paymentEdited(fromMemberName: String, toMemberName: String, changes: [String])
        case paymentDeleted(fromMemberName: String, toMemberName: String, amount: Decimal, currencyCode: String)
        case draftRecorded(entityName: String?, entityKindLabel: String)
    }
    let id: UUID
    let date: Date
    let groupID: UUID
    let groupName: String
    let kind: Kind
    /// Display name of the user who triggered this row, when known.
    /// Currently set on edit rows (`expenseEdited` / `paymentEdited`)
    /// to surface "by Alice" attribution in the title.
    var editorName: String? = nil
}

struct ActivityRowView: View {
    let row: ActivityRow
    var showsGroupBadge: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconColor.opacity(0.14))
                Image(systemName: icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    amountChip
                }
                if let detail = detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if showsGroupBadge {
                        Text(row.groupName)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                    }
                    Text(row.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
        )
        .shadow(
            color: AppTheme.cardShadowColor,
            radius: AppTheme.cardShadowRadius,
            x: 0,
            y: AppTheme.cardShadowYOffset
        )
    }

    /// The right-aligned amount label for rows that carry a value. Returns
    /// `nil` for non-financial rows so the column collapses out of layout.
    @ViewBuilder
    private var amountChip: some View {
        if let amount = amountText {
            Text(amount.text)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(amount.color)
                .lineLimit(1)
        }
    }

    private struct AmountText {
        let text: String
        let color: Color
    }

    private var amountText: AmountText? {
        switch row.kind {
        case .expenseAdded(_, let amount, let code, _):
            return AmountText(
                text: "+" + amount.formatted(.currency(code: code)),
                color: AppTheme.success
            )
        case .expenseDeleted(_, let amount, let code, _):
            return AmountText(
                text: "\u{2212}" + amount.formatted(.currency(code: code)),
                color: AppTheme.danger
            )
        case .paymentRecorded(_, _, let amount, let code):
            return AmountText(
                text: amount.formatted(.currency(code: code)),
                color: .primary
            )
        case .paymentDeleted(_, _, let amount, let code):
            return AmountText(
                text: amount.formatted(.currency(code: code)),
                color: AppTheme.danger
            )
        case .groupCreated, .memberJoined, .expenseEdited, .paymentEdited, .draftRecorded:
            return nil
        }
    }

    private var icon: String {
        switch row.kind {
        case .groupCreated:        return "sparkles"
        case .memberJoined:        return "person.fill.badge.plus"
        case .expenseAdded:        return "plus"
        case .expenseEdited:       return "pencil"
        case .expenseDeleted:      return "trash"
        case .paymentRecorded:     return "arrow.left.arrow.right"
        case .paymentEdited:       return "pencil"
        case .paymentDeleted:      return "arrow.uturn.backward"
        case .draftRecorded:       return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch row.kind {
        case .groupCreated:        return AppTheme.accent
        case .memberJoined:        return AppTheme.accent
        case .expenseAdded:        return AppTheme.success
        case .expenseEdited:       return AppTheme.warning
        case .expenseDeleted:      return AppTheme.danger
        case .paymentRecorded:     return AppTheme.accent
        case .paymentEdited:       return AppTheme.warning
        case .paymentDeleted:      return AppTheme.danger
        case .draftRecorded:       return AppTheme.warning
        }
    }

    private var title: String {
        switch row.kind {
        case .groupCreated:
            return "Group created"
        case .memberJoined(let name):
            return "\(name) joined"
        case .expenseAdded(let desc, _, _, let payer):
            let d = desc.isEmpty ? "Expense" : desc
            return "\(payer) added \u{201C}\(d)\u{201D}"
        case .expenseEdited(let desc, _):
            let d = desc.isEmpty ? "an expense" : "\u{201C}\(desc)\u{201D}"
            return "Edited \(d)\(editorSuffix)"
        case .expenseDeleted(let desc, _, _, let payer):
            let d = desc.isEmpty ? "an expense" : "\u{201C}\(desc)\u{201D}"
            return "Deleted \(d) (\(payer))"
        case .paymentRecorded(let from, let to, _, _):
            return "\(from) paid \(to)"
        case .paymentEdited(let from, let to, _):
            return "Edited \(from) → \(to) payment\(editorSuffix)"
        case .paymentDeleted(let from, let to, _, _):
            return "Removed \(from) → \(to) payment"
        case .draftRecorded(let name, let label):
            if let name, !name.isEmpty {
                return "Conflict on \u{201C}\(name)\u{201D} — saved as draft"
            }
            return "Conflict on this \(label) — saved as draft"
        }
    }

    /// Inlines "by <editor>" into edit titles when the editor's name is
    /// known, leaving non-edit titles untouched.
    private var editorSuffix: String {
        guard let name = row.editorName, !name.isEmpty else { return "" }
        return " by \(name)"
    }

    private var detail: String? {
        switch row.kind {
        case .expenseEdited(_, let changes) where !changes.isEmpty:
            return changes.joined(separator: " · ")
        case .paymentEdited(_, _, let changes) where !changes.isEmpty:
            return changes.joined(separator: " · ")
        default:
            return nil
        }
    }
}
