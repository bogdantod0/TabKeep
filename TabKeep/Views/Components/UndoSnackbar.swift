import SwiftUI

struct UndoSnackbar: View {
    let pending: PendingDeletion
    let onUndo: () -> Void
    let onCommit: () -> Void
    var duration: TimeInterval = 5

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.fill")
                .foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                onUndo()
            } label: {
                Text("Undo")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("undoDeleteButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.label))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        )
        .padding(.horizontal)
        .task(id: pending.id) {
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled {
                onCommit()
            }
        }
    }

    private var title: String {
        switch pending.kind {
        case .expense:    return "Expense deleted"
        case .payment:    return "Payment deleted"
        }
    }

    private var detail: String? {
        switch pending.kind {
        case .expense(let expense, _):
            return expense.description.isEmpty ? nil : expense.description
        case .payment(let payment, _, _):
            let trimmed = payment.note?.trimmingCharacters(in: .whitespaces)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
    }
}
