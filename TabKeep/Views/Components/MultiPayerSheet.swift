import SwiftUI

/// Choose-your-payers sheet for an expense. Lets the user mark which
/// members paid and enter each member's contribution.
///
/// **Auto-calculate.** Mirrors `ExpenseFormContent.redistributeAmountSplit`:
/// rows the user hasn't manually typed into share the remaining amount
/// (total minus the sum of manually-edited rows) evenly, with the last
/// unedited row absorbing the rounding residual. Toggling a row on/off
/// re-runs the pass. Once a user types into a field, that row is "locked"
/// at the typed value until cleared.
///
/// Sum must equal the expense total (within $0.01) to save. Picking
/// exactly one payer at the full amount collapses back to single-payer
/// mode (`payments = nil`) so we don't store a degenerate one-row array.
struct MultiPayerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let members: [Member]
    let total: Decimal
    let currencyCode: String
    let isYou: (Member) -> Bool
    let initialPayments: [ExpensePayment]?
    let initialPrimaryPayerID: UUID?
    let onSave: (_ payments: [ExpensePayment]?, _ primaryPayerID: UUID) -> Void

    @State private var entries: [Entry] = []
    /// Rows the user has typed into directly. Auto-distribute leaves these
    /// alone; clearing the field removes the row from this set.
    @State private var manuallyEditedIDs: Set<UUID> = []
    @State private var didSeed = false

    private struct Entry: Identifiable, Equatable {
        let id: UUID
        let memberID: UUID
        let name: String
        let emoji: String
        let isYou: Bool
        var checked: Bool
        var amountText: String
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.pageBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        explainerCard
                        memberList
                        summaryCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Paid by")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commit() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: seedEntries)
    }

    // MARK: - Pieces

    private var explainerCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AppTheme.accent)
            Text("Check each member who paid. Amounts auto-split the total — type to set a custom value, and the rest re-balance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
    }

    private var memberList: some View {
        VStack(spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                memberRow(idx: idx, entry: entry)
            }
        }
    }

    private func memberRow(idx: Int, entry: Entry) -> some View {
        HStack(spacing: 10) {
            Button {
                toggleChecked(at: idx)
            } label: {
                Image(systemName: entry.checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(entry.checked ? AppTheme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.checked ? "Uncheck \(entry.name)" : "Check \(entry.name)")

            AvatarView(emoji: entry.emoji, size: 30)
            Text(entry.isYou ? "\(entry.name) (You)" : entry.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            if entry.checked {
                TextField("0.00", text: amountBinding(for: entry.memberID))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.pageBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                manuallyEditedIDs.contains(entry.memberID)
                                    ? AppTheme.accent.opacity(0.4)
                                    : Color.black.opacity(0.06),
                                lineWidth: 1
                            )
                    )
            } else {
                Text("—")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(width: 110, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
    }

    private var summaryCard: some View {
        let sum = currentSum
        let diff = sum - total
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Entered")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                Text(sum.formatted(.currency(code: currencyCode)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            HStack {
                Text("Expense total")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                Text(total.formatted(.currency(code: currencyCode)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if abs(diff) > Decimal(0.01) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.warning)
                    Text(diff > 0
                         ? "Over by \(diff.formatted(.currency(code: currencyCode)))"
                         : "Short by \((-diff).formatted(.currency(code: currencyCode)))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } else if !checkedEntries.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AppTheme.success)
                    Text("Matches the expense total")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            if !manuallyEditedIDs.isEmpty {
                Button {
                    resetAutoCalc()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                        Text("Reset to auto-split")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
    }

    // MARK: - Logic

    private var checkedEntries: [Entry] {
        entries.filter { $0.checked }
    }

    private var currentSum: Decimal {
        checkedEntries.reduce(Decimal(0)) { acc, e in
            acc + (Decimal(string: e.amountText) ?? 0)
        }
    }

    private var canSave: Bool {
        guard !checkedEntries.isEmpty else { return false }
        return abs(currentSum - total) <= Decimal(0.01)
    }

    private func seedEntries() {
        guard !didSeed else { return }
        didSeed = true
        let isMultiPayerSeed = (initialPayments?.isEmpty == false)
        let prefilled: [UUID: Decimal] = Dictionary(
            uniqueKeysWithValues: (initialPayments ?? []).map { ($0.memberID, $0.amount) }
        )
        entries = members.map { m in
            let checked: Bool
            if isMultiPayerSeed {
                checked = prefilled[m.id] != nil
            } else {
                checked = (m.id == initialPrimaryPayerID)
            }
            return Entry(
                id: m.id,
                memberID: m.id,
                name: m.name,
                emoji: m.emoji,
                isYou: isYou(m),
                checked: checked,
                amountText: ""
            )
        }
        // Pre-existing multi-payer amounts are treated as user-intent: mark
        // each as manually-edited so the auto-redistribute pass leaves them
        // alone. Then seed their text values from the prefill map.
        if isMultiPayerSeed {
            for (memberID, amount) in prefilled {
                manuallyEditedIDs.insert(memberID)
                if let idx = entries.firstIndex(where: { $0.memberID == memberID }) {
                    entries[idx].amountText = Self.plainAmountString(amount)
                }
            }
        }
        // Fill any unedited checked rows with the auto-split share.
        redistributeUnedited()
    }

    private func toggleChecked(at idx: Int) {
        guard entries.indices.contains(idx) else { return }
        let memberID = entries[idx].memberID
        entries[idx].checked.toggle()
        if !entries[idx].checked {
            entries[idx].amountText = ""
            manuallyEditedIDs.remove(memberID)
        }
        redistributeUnedited()
    }

    private func amountBinding(for memberID: UUID) -> Binding<String> {
        Binding(
            get: {
                entries.first(where: { $0.memberID == memberID })?.amountText ?? ""
            },
            set: { newValue in
                guard let idx = entries.firstIndex(where: { $0.memberID == memberID }) else { return }
                entries[idx].amountText = newValue
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    manuallyEditedIDs.remove(memberID)
                } else {
                    manuallyEditedIDs.insert(memberID)
                }
                redistributeUnedited()
            }
        )
    }

    /// Splits `total - sum(manually edited)` evenly across checked rows that
    /// the user hasn't manually typed into. Last unedited row absorbs the
    /// rounding residual so checked rows always sum to `total` exactly
    /// (within Decimal's 2-place precision).
    private func redistributeUnedited() {
        let checked = entries.filter { $0.checked }
        let unedited = checked.filter { !manuallyEditedIDs.contains($0.memberID) }
        guard !unedited.isEmpty else { return }

        let editedSum = checked
            .filter { manuallyEditedIDs.contains($0.memberID) }
            .reduce(Decimal(0)) { $0 + (Decimal(string: $1.amountText) ?? 0) }
        let remaining = max(Decimal(0), total - editedSum)
        let perPerson = Self.roundedTo2(remaining / Decimal(unedited.count))

        var residual = remaining
        for (i, row) in unedited.enumerated() {
            guard let idx = entries.firstIndex(where: { $0.memberID == row.memberID }) else { continue }
            if i == unedited.count - 1 {
                entries[idx].amountText = Self.plainAmountString(Self.roundedTo2(residual))
            } else {
                entries[idx].amountText = Self.plainAmountString(perPerson)
                residual -= perPerson
            }
        }
    }

    private func resetAutoCalc() {
        manuallyEditedIDs.removeAll()
        redistributeUnedited()
    }

    private func commit() {
        guard canSave else { return }
        let checked = checkedEntries
        let parsed: [(UUID, Decimal)] = checked.map { e in
            (e.memberID, Decimal(string: e.amountText) ?? 0)
        }
        // Single payer at full amount → collapse back to single-payer mode.
        if parsed.count == 1, abs(parsed[0].1 - total) <= Decimal(0.01) {
            onSave(nil, parsed[0].0)
        } else {
            let payments = parsed.map { ExpensePayment(memberID: $0.0, amount: $0.1) }
            // Primary payer: the one who paid the most. Stable tiebreak by
            // memberID UUID order.
            let primary = payments
                .sorted { ($0.amount, $1.memberID.uuidString) > ($1.amount, $0.memberID.uuidString) }
                .first!
                .memberID
            onSave(payments, primary)
        }
        dismiss()
    }

    // MARK: - Decimal helpers (mirrors ExpenseFormContent's fileprivate ones)

    private static func roundedTo2(_ value: Decimal) -> Decimal {
        var v = value
        var result = Decimal()
        NSDecimalRound(&result, &v, 2, .bankers)
        return result
    }

    private static func plainAmountString(_ value: Decimal) -> String {
        var v = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &v, 2, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}
