import SwiftUI

struct BackfillSnackbar: View {
    let pending: PendingBackfill
    let onUndo: () -> Void
    let onDismiss: () -> Void
    var duration: TimeInterval = 6

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
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
            .accessibilityIdentifier("undoBackfillButton")
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
                onDismiss()
            }
        }
    }

    private var title: String {
        let n = pending.expenseIDs.count
        return n == 1 ? "Added to 1 expense" : "Added to \(n) expenses"
    }

    private var detail: String? {
        var fragments: [String] = []
        let settled = pending.skippedSettledCount
        if settled > 0 {
            fragments.append(settled == 1 ? "1 already settled" : "\(settled) already settled")
        }
        let custom = pending.skippedCustomShareCount
        if custom > 0 {
            fragments.append(custom == 1
                ? "1 with custom split unchanged"
                : "\(custom) with custom splits unchanged")
        }
        return fragments.isEmpty ? nil : fragments.joined(separator: " · ")
    }
}
