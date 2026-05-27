import SwiftUI
import Charts

struct HeroTotalCard: View {
    let total: Decimal
    let rangeTitle: String
    let currencyCode: String
    let deltaPercent: Int?
    let hasPendingRates: Bool
    let previousRangeLabel: String?     // "April" / "2025" / nil
    let trend: [StatisticsSummary.TrendBucket]
    let granularity: Calendar.Component

    @State private var scrubDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrowText)
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .contentTransition(.opacity)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if isZeroState {
                    Text("No spend yet")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityIdentifier("statisticsHeroTotal")
                        .layoutPriority(1)
                } else {
                    Text(headlineAmount.aggregateCurrency(code: currencyCode))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("statisticsHeroTotal")
                        .layoutPriority(1)
                }

                Spacer(minLength: 8)

                if scrubBucket == nil, !isZeroState, let delta = deltaPercent, let previous = previousRangeLabel {
                    deltaChip(delta: delta, previous: previous)
                        .transition(.opacity)
                }
            }

            if isZeroState {
                Text("Add an expense to see your stats for \(rangeTitle).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            if hasSparkline {
                sparkline
                    .frame(height: 64)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }

            if hasPendingRates {
                Text("Updating rates…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Currency rates are still updating.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(
            color: AppTheme.cardShadowColor,
            radius: AppTheme.cardShadowRadius,
            y: AppTheme.cardShadowYOffset
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .animation(.easeInOut(duration: 0.15), value: scrubBucket?.date)
        .onChange(of: scrubBucket?.date) { _, _ in
            Haptics.selection()
        }
    }

    // MARK: - Sparkline

    private var hasSparkline: Bool {
        trend.count >= 2 && !trend.allSatisfy { $0.amount == 0 }
    }

    private var isZeroState: Bool {
        total == 0 && !hasSparkline && scrubBucket == nil
    }

    private var sparkline: some View {
        Chart {
            ForEach(trend, id: \.date) { bucket in
                AreaMark(
                    x: .value("date", bucket.date),
                    y: .value("amount", NSDecimalNumber(decimal: bucket.amount).doubleValue)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [AppTheme.accent.opacity(0.30), AppTheme.accent.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("date", bucket.date),
                    y: .value("amount", NSDecimalNumber(decimal: bucket.amount).doubleValue)
                )
                .foregroundStyle(AppTheme.accent)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
            }

            if let bucket = scrubBucket {
                RuleMark(x: .value("scrub", bucket.date))
                    .foregroundStyle(AppTheme.accent.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                PointMark(
                    x: .value("scrub", bucket.date),
                    y: .value("amount", NSDecimalNumber(decimal: bucket.amount).doubleValue)
                )
                .foregroundStyle(AppTheme.accent)
                .symbolSize(80)
            }
        }
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.padding(.horizontal, 0)
        }
        .chartXSelection(value: $scrubDate)
    }

    // MARK: - Delta chip

    private func deltaChip(delta: Int, previous: String) -> some View {
        let isUp = delta >= 0
        let color = isUp ? AppTheme.success : AppTheme.danger
        let symbol = isUp ? "arrow.up" : "arrow.down"
        return HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
            Text("\(abs(delta))%")
                .monospacedDigit()
            Text("vs \(previous)")
                .foregroundStyle(color.opacity(0.75))
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.12))
        )
        .fixedSize()
    }

    // MARK: - Scrub helpers

    /// Snap the scrub gesture's raw Date to the nearest bucket so the
    /// indicator + headline always align with real data.
    private var scrubBucket: StatisticsSummary.TrendBucket? {
        guard let scrubDate, hasSparkline else { return nil }
        return trend.min(by: {
            abs($0.date.timeIntervalSince(scrubDate)) < abs($1.date.timeIntervalSince(scrubDate))
        })
    }

    private var headlineAmount: Decimal {
        scrubBucket?.amount ?? total
    }

    private var eyebrowText: String {
        if let bucket = scrubBucket {
            return scrubLabel(for: bucket.date)
        }
        return "TOTAL SPEND · \(rangeTitle)"
    }

    private func scrubLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        switch granularity {
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        default:
            formatter.setLocalizedDateFormatFromTemplate("MMMM y")
        }
        return formatter.string(from: date).uppercased()
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        var parts: [String] = [
            "Total spend in \(rangeTitle), \(total.formatted(.currency(code: currencyCode)))."
        ]
        if let delta = deltaPercent, let previous = previousRangeLabel {
            let direction = delta >= 0 ? "up" : "down"
            parts.append("\(direction) \(abs(delta))% versus \(previous).")
        }
        if hasSparkline {
            let totalTrend = trend.reduce(Decimal(0)) { $0 + $1.amount }
            parts.append("Trend across \(trend.count) buckets, total \(totalTrend.formatted(.currency(code: currencyCode))).")
        }
        if hasPendingRates {
            parts.append("Currency rates still updating.")
        }
        return parts.joined(separator: " ")
    }
}

#Preview("With trend") {
    let cal = Calendar.current
    let now = Date()
    let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? now
    let buckets: [StatisticsSummary.TrendBucket] = (0..<28).map { offset in
        let d = cal.date(byAdding: .day, value: offset, to: monthStart) ?? monthStart
        let amount = Decimal(50 + (offset % 5) * 28 + (offset % 3) * 18)
        return .init(date: d, amount: amount)
    }
    return VStack(spacing: 16) {
        HeroTotalCard(
            total: 2481,
            rangeTitle: "May 2026",
            currencyCode: "USD",
            deltaPercent: 12,
            hasPendingRates: false,
            previousRangeLabel: "April",
            trend: buckets,
            granularity: .day
        )
        HeroTotalCard(
            total: 980,
            rangeTitle: "May 2026",
            currencyCode: "USD",
            deltaPercent: -4,
            hasPendingRates: true,
            previousRangeLabel: "April",
            trend: buckets,
            granularity: .day
        )
    }
    .padding()
    .background(AppTheme.pageBackground)
}

#Preview("Empty trend") {
    HeroTotalCard(
        total: 0,
        rangeTitle: "May 2026",
        currencyCode: "USD",
        deltaPercent: nil,
        hasPendingRates: false,
        previousRangeLabel: nil,
        trend: [],
        granularity: .day
    )
    .padding()
    .background(AppTheme.pageBackground)
}
