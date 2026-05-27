import SwiftUI

struct CategoryExpensesQuery: Hashable {
    let category: ExpenseCategory
    let range: StatisticsRange
}

struct CategoryExpensesView: View {
    @Environment(AppStore.self) private var store

    let category: ExpenseCategory
    let range: StatisticsRange

    @State private var rows: [Row] = []
    @State private var hasPending: Bool = false
    @State private var isLoaded: Bool = false
    @State private var now: Date = Date()

    struct Row: Identifiable, Hashable {
        let id: UUID            // expense.id
        let groupID: UUID
        let groupName: String
        let groupEmoji: String?
        let expenseDescription: String
        let date: Date
        let payerName: String
        let convertedAmount: Decimal
        let originalAmount: Decimal
        let originalCurrency: String
        let isCrossCurrency: Bool
        let pending: Bool
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if !rows.isEmpty {
                    listSection
                } else if isLoaded {
                    emptyState
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable {
            await store.foregroundRefresh(force: true)
            await store.retryPendingRates()
            await reloadRows()
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .navigationTitle(category.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: rowsTaskID) {
            now = Date()
            await reloadRows()
            withAnimation(.easeInOut(duration: 0.18)) {
                isLoaded = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(category.tintColor)
                Image(category.lucideIconName)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text("TOTAL SPEND")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(totalDisplay)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(
            color: AppTheme.cardShadowColor,
            radius: AppTheme.cardShadowRadius,
            y: AppTheme.cardShadowYOffset
        )
    }

    // MARK: - List

    private var listSection: some View {
        VStack(spacing: 8) {
            ForEach(rows) { row in
                NavigationLink(value: GroupsRoute.expense(groupID: row.groupID, expenseID: row.id)) {
                    rowCard(row)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func rowCard(_ row: Row) -> some View {
        HStack(spacing: 12) {
            groupChip(emoji: row.groupEmoji)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.expenseDescription.isEmpty ? row.groupName : row.expenseDescription)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(rowSubtitle(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(row.convertedAmount.formatted(.currency(code: store.defaultCurrencyCode)))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                if row.isCrossCurrency {
                    Text(row.originalAmount.formatted(.currency(code: row.originalCurrency)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(
            color: AppTheme.cardShadowColor,
            radius: AppTheme.cardShadowRadius,
            y: AppTheme.cardShadowYOffset
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: row))
    }

    @ViewBuilder
    private func groupChip(emoji: String?) -> some View {
        if let emoji {
            EmojiText(emoji: emoji, size: 18)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 32)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(category.tintColor.opacity(0.12))
                Image(systemName: "tray")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(category.tintColor)
            }
            .frame(width: 64, height: 64)

            Text("No \(category.displayName.lowercased()) expenses in this period")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Derived

    private var totalDisplay: String {
        let total = rows.reduce(Decimal(0)) { $0 + $1.convertedAmount }
        return total.aggregateCurrency(code: store.defaultCurrencyCode)
    }

    private var subtitle: String {
        let count = rows.count
        let title = range.displayTitle(now: now)
        let suffix = count == 1 ? "1 expense" : "\(count) expenses"
        if hasPending {
            return "\(suffix) · \(title) · rates updating"
        }
        return "\(suffix) · \(title)"
    }

    private func rowSubtitle(_ row: Row) -> String {
        let date = row.date.formatted(.dateTime.month(.abbreviated).day())
        return "\(row.groupName) · \(date) · paid by \(row.payerName)"
    }

    private func accessibilityLabel(for row: Row) -> String {
        let amount = row.convertedAmount.formatted(.currency(code: store.defaultCurrencyCode))
        let date = row.date.formatted(.dateTime.month().day().year())
        return "\(row.expenseDescription.isEmpty ? row.groupName : row.expenseDescription), \(amount), in \(row.groupName), on \(date), paid by \(row.payerName)."
    }

    // MARK: - Loading

    private var rowsTaskID: String {
        "\(category.raw)|\(range.taskKey)|\(store.defaultCurrencyCode)|\(store.activeGroups.count)|\(fingerprint)"
    }

    private var fingerprint: String {
        store.activeGroups.flatMap { group in
            group.expenses
                .filter { $0.category == category }
                .map { "\($0.id)-\($0.date.timeIntervalSince1970)-\($0.amount)-\($0.exchangeRate)-\($0.ratePending)" }
        }.joined(separator: ",")
    }

    private func reloadRows() async {
        let interval = range.interval(now: now)
        var built: [Row] = []
        var anyPending = false

        for group in store.activeGroups {
            for expense in group.expenses where expense.category == category {
                if let interval, !interval.contains(expense.date) { continue }

                let result = await store.convertToDefault(
                    groupAmount: expense.amount,
                    groupCurrency: expense.currencyCode,
                    on: expense.date
                )
                if result.pending { anyPending = true }

                let payerName = group.members.first(where: { $0.id == expense.payerID })?.name ?? "—"
                built.append(Row(
                    id: expense.id,
                    groupID: group.id,
                    groupName: group.name,
                    groupEmoji: group.emoji,
                    expenseDescription: expense.description,
                    date: expense.date,
                    payerName: payerName,
                    convertedAmount: result.value,
                    originalAmount: expense.amount,
                    originalCurrency: expense.currencyCode,
                    isCrossCurrency: expense.currencyCode != store.defaultCurrencyCode,
                    pending: result.pending
                ))
            }
        }

        built.sort { $0.date > $1.date }
        rows = built
        hasPending = anyPending
    }
}
