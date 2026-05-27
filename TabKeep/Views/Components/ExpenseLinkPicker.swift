import SwiftUI

/// Collapsible multi-select section used by RecordPaymentSheet and
/// EditPaymentSheet to let the user mark which existing expenses a
/// payment settles. Selection is owned by the parent via a binding;
/// the picker does no filtering or sorting of its own — the caller
/// passes the already-prepared expense list (non-deleted, sorted
/// desc by date).
struct ExpenseLinkPicker: View {
    let expenses: [Expense]
    let currencyCode: String
    @Binding var selectedIDs: Set<UUID>
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                helperText
                if expenses.isEmpty {
                    emptyState
                } else {
                    expenseList
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SETTLES EXPENSES (OPTIONAL)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                    if !selectedIDs.isEmpty {
                        Text("\(selectedIDs.count) selected")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AppTheme.accent)
                    }
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("expenseLinkPickerHeader")
    }

    private var helperText: some View {
        Text("Marking expenses prevents new members joining later from being added to them.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        Text("No expenses to link.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)
    }

    private var expenseList: some View {
        VStack(spacing: 0) {
            ForEach(expenses) { e in
                row(for: e)
                if e.id != expenses.last?.id {
                    Divider().opacity(0.3)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.pageBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
        )
    }

    private func row(for expense: Expense) -> some View {
        let isSelected = selectedIDs.contains(expense.id)
        return Button {
            if isSelected {
                selectedIDs.remove(expense.id)
            } else {
                selectedIDs.insert(expense.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AppTheme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(expense.description.isEmpty ? "Untitled" : expense.description)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle(for: expense))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("expenseLinkRow_\(expense.id.uuidString)")
    }

    private func subtitle(for expense: Expense) -> String {
        let amount = Self.amountFormatter.string(from: NSDecimalNumber(decimal: expense.amount))
            ?? NSDecimalNumber(decimal: expense.amount).stringValue
        let symbol = SupportedCurrencies.symbol(for: expense.currencyCode)
        let dateStr = expense.date.formatted(.dateTime.month(.abbreviated).day())
        return "\(amount) \(symbol) • \(dateStr)"
    }

    private static let amountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f
    }()
}
