import Foundation

/// Pure value-in / value-out cross-group aggregation for the Statistics
/// surface. Must not import SwiftUI. Must not reference AppStore.
enum StatisticsAggregator {

    /// (groupAmount, groupCurrencyCode, on date) → (default-currency value, ratePending).
    typealias Convert = (Decimal, String, Date) async -> (value: Decimal, pending: Bool)

    /// One participating expense already converted to default currency.
    struct ConvertedExpense {
        let groupID: UUID
        let groupName: String
        let groupEmoji: String?
        let date: Date
        let category: ExpenseCategory
        let valueInDefault: Decimal
    }

    // MARK: - Single FX pass over all participating expenses

    /// Walks `groups` once. For every expense whose date falls inside
    /// `interval` (or every expense when `interval == nil`), converts
    /// `amount × exchangeRate` to default currency. Pending expenses are
    /// dropped from the returned array but trip `hasPending = true`.
    static func convertParticipating(
        groups: [ExpenseGroup],
        in interval: DateInterval?,
        convert: Convert
    ) async -> (converted: [ConvertedExpense], hasPending: Bool) {
        var out: [ConvertedExpense] = []
        var hasPending = false

        for group in groups {
            for expense in group.expenses {
                if let interval, !interval.contains(expense.date) {
                    continue
                }
                let inGroupCurrency = expense.amount * expense.exchangeRate
                let result = await convert(inGroupCurrency, group.currencyCode, expense.date)
                if result.pending {
                    hasPending = true
                    continue
                }
                out.append(ConvertedExpense(
                    groupID: group.id,
                    groupName: group.name,
                    groupEmoji: group.emoji,
                    date: expense.date,
                    category: expense.category,
                    valueInDefault: result.value
                ))
            }
        }
        return (out, hasPending)
    }

    // MARK: - Hero totals

    static func totalSpend(_ converted: [ConvertedExpense]) -> Decimal {
        converted.reduce(Decimal(0)) { $0 + $1.valueInDefault }
    }

    static func deltaPercent(current: Decimal, previous: Decimal?) -> Int? {
        guard let previous, previous != 0 else { return nil }
        let raw = (current - previous) / previous * 100
        var rounded = Decimal()
        var source = raw
        NSDecimalRound(&rounded, &source, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    // MARK: - Category breakdown

    static func categoryStats(
        _ converted: [ConvertedExpense],
        total: Decimal,
        previous: [ConvertedExpense]? = nil
    ) -> [StatisticsSummary.CategoryStat] {
        guard total > 0 else { return [] }
        var byCategory: [ExpenseCategory: (amount: Decimal, count: Int)] = [:]
        for c in converted {
            var existing = byCategory[c.category] ?? (0, 0)
            existing.amount += c.valueInDefault
            existing.count += 1
            byCategory[c.category] = existing
        }

        // Previous-period sums per category — only used to compute deltas.
        var previousByCategory: [ExpenseCategory: Decimal] = [:]
        if let previous {
            for c in previous {
                previousByCategory[c.category, default: 0] += c.valueInDefault
            }
        }

        return byCategory
            .map { (category, agg) in
                let prevAmount = previousByCategory[category]
                let delta = previous == nil ? nil : deltaPercent(current: agg.amount, previous: prevAmount)
                return StatisticsSummary.CategoryStat(
                    category: category,
                    amount: agg.amount,
                    percent: NSDecimalNumber(decimal: agg.amount / total).doubleValue,
                    count: agg.count,
                    deltaPercent: delta
                )
            }
            .sorted { $0.amount > $1.amount }
    }

    // MARK: - Group breakdown

    static func groupStats(
        _ converted: [ConvertedExpense]
    ) -> [StatisticsSummary.GroupStat] {
        var byGroup: [UUID: (name: String, emoji: String?, amount: Decimal)] = [:]
        for c in converted {
            var existing = byGroup[c.groupID] ?? (c.groupName, c.groupEmoji, 0)
            existing.amount += c.valueInDefault
            byGroup[c.groupID] = existing
        }
        return byGroup
            .map { (id, agg) in
                StatisticsSummary.GroupStat(
                    id: id,
                    name: agg.name,
                    emoji: agg.emoji,
                    amount: agg.amount
                )
            }
            .sorted { $0.amount > $1.amount }
    }

    // MARK: - Trend bucketing

    /// Buckets every converted expense into a chronological series.
    ///
    /// - `.day` granularity: one bucket per day in `interval`. Empty days
    ///   included so the X axis stays honest.
    /// - `.month` granularity: one bucket per month spanning either
    ///   `interval` (when non-nil) or `[earliestExpenseMonth, currentMonth]`
    ///   (when nil). When the resulting span exceeds 36 buckets the series
    ///   is downsampled to 3-month groups.
    /// - Other granularities fall back to monthly behaviour.
    static func trendBuckets(
        _ converted: [ConvertedExpense],
        in interval: DateInterval?,
        granularity: Calendar.Component,
        calendar: Calendar,
        now: Date
    ) -> [StatisticsSummary.TrendBucket] {
        // Resolve the bucket span.
        let monthly = (granularity != .day)
        let startBucket: Date
        let endBucket: Date

        if let interval {
            startBucket = monthly
                ? calendar.dateInterval(of: .month, for: interval.start)?.start ?? interval.start
                : calendar.startOfDay(for: interval.start)
            endBucket = monthly
                ? calendar.dateInterval(of: .month, for: interval.end - 1)?.start ?? interval.end
                : calendar.startOfDay(for: interval.end - 1)
        } else {
            // .allTime / monthly — earliest expense month → current month.
            let earliest = converted.map(\.date).min()
            startBucket = calendar.dateInterval(
                of: .month, for: earliest ?? now
            )?.start ?? now
            endBucket = calendar.dateInterval(of: .month, for: now)?.start ?? now
        }

        // Step through buckets accumulating amounts.
        let unit: Calendar.Component = monthly ? .month : .day
        var buckets: [Date: Decimal] = [:]
        var slots: [Date] = []
        var cursor = startBucket
        while cursor <= endBucket {
            slots.append(cursor)
            buckets[cursor] = 0
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor) else { break }
            cursor = next
        }

        for c in converted {
            let key = monthly
                ? (calendar.dateInterval(of: .month, for: c.date)?.start ?? c.date)
                : calendar.startOfDay(for: c.date)
            if buckets[key] != nil {
                buckets[key]! += c.valueInDefault
            }
        }

        var result = slots.map { StatisticsSummary.TrendBucket(date: $0, amount: buckets[$0] ?? 0) }

        // Downsample monthly series longer than 36 buckets to quarterly.
        if monthly && result.count > 36 {
            var quarterly: [Date: Decimal] = [:]
            var qSlots: [Date] = []
            for bucket in result {
                let comps = calendar.dateComponents([.year, .month], from: bucket.date)
                guard let month = comps.month, let year = comps.year else { continue }
                let qStartMonth = ((month - 1) / 3) * 3 + 1
                var qComps = DateComponents()
                qComps.year = year
                qComps.month = qStartMonth
                qComps.day = 1
                guard let qDate = calendar.date(from: qComps) else { continue }
                if quarterly[qDate] == nil {
                    quarterly[qDate] = 0
                    qSlots.append(qDate)
                }
                quarterly[qDate]! += bucket.amount
            }
            qSlots.sort()
            result = qSlots.map { StatisticsSummary.TrendBucket(date: $0, amount: quarterly[$0] ?? 0) }
        }

        return result
    }
}
