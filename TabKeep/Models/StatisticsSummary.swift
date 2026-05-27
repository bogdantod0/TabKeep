import Foundation

/// Cross-group statistics aggregate fed to the Statistics tab. Pure value
/// type — derived from `AppStore` snapshot, never persisted.
struct StatisticsSummary: Equatable {
    let range: StatisticsRange
    let defaultCurrencyCode: String
    let rangeTitle: String          // "May 2026" / "2026" / "All time"
    let hasPendingRates: Bool

    // MARK: Hero
    let total: Decimal
    let previousTotal: Decimal?
    let deltaPercent: Int?

    // MARK: Category breakdown — descending by amount
    struct CategoryStat: Hashable {
        let category: ExpenseCategory
        let amount: Decimal
        let percent: Double         // 0.0 – 1.0
        let count: Int
        /// Delta vs same category in the previous period. `nil` for
        /// `.allTime` or when the previous period had zero spend in this
        /// category (anything > 0 vs 0 has no defined percentage).
        let deltaPercent: Int?
    }
    let byCategory: [CategoryStat]

    // MARK: Group breakdown — descending by amount
    struct GroupStat: Hashable, Identifiable {
        let id: UUID
        let name: String
        let emoji: String?
        let amount: Decimal         // default currency
    }
    let byGroup: [GroupStat]

    // MARK: Trend buckets — chronological
    struct TrendBucket: Hashable {
        let date: Date              // start of bucket
        let amount: Decimal
    }
    let trend: [TrendBucket]

    static let empty = StatisticsSummary(
        range: .month,
        defaultCurrencyCode: "USD",
        rangeTitle: "",
        hasPendingRates: false,
        total: 0,
        previousTotal: nil,
        deltaPercent: nil,
        byCategory: [],
        byGroup: [],
        trend: []
    )
}

extension StatisticsSummary {

    /// Build a fresh summary from the live `AppStore`. Async because FX
    /// conversion happens off the main actor. One conversion per
    /// participating expense; the FX cache makes repeats cheap.
    static func build(
        from store: AppStore,
        range: StatisticsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> StatisticsSummary {
        let interval = range.interval(now: now, calendar: calendar)
        let groups = store.activeGroups
        let convert: StatisticsAggregator.Convert = { amount, code, date in
            await store.convertToDefault(groupAmount: amount, groupCurrency: code, on: date)
        }

        // Single FX pass for the period.
        let (converted, hasPending) = await StatisticsAggregator.convertParticipating(
            groups: groups,
            in: interval,
            convert: convert
        )

        // Hero
        let total = StatisticsAggregator.totalSpend(converted)

        // Previous-period converted set (single FX pass). Reused for hero
        // delta and per-category deltas.
        let previousConverted: [StatisticsAggregator.ConvertedExpense]?
        if let prior = range.previousInterval(now: now, calendar: calendar) {
            let (prev, _) = await StatisticsAggregator.convertParticipating(
                groups: groups,
                in: prior,
                convert: convert
            )
            previousConverted = prev
        } else {
            previousConverted = nil
        }
        let previousTotal = previousConverted.map(StatisticsAggregator.totalSpend)
        let delta = StatisticsAggregator.deltaPercent(current: total, previous: previousTotal)

        // Category + group + trend
        let categoryStats = StatisticsAggregator.categoryStats(
            converted,
            total: total,
            previous: previousConverted
        )
        let groupStats = StatisticsAggregator.groupStats(converted)
        let trend = StatisticsAggregator.trendBuckets(
            converted,
            in: interval,
            granularity: range.bucketGranularity,
            calendar: calendar,
            now: now
        )

        return StatisticsSummary(
            range: range,
            defaultCurrencyCode: store.defaultCurrencyCode,
            rangeTitle: range.displayTitle(now: now, calendar: calendar),
            hasPendingRates: hasPending,
            total: total,
            previousTotal: previousTotal,
            deltaPercent: delta,
            byCategory: categoryStats,
            byGroup: groupStats,
            trend: trend
        )
    }
}
