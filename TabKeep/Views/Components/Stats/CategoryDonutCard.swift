import SwiftUI
import Charts

struct CategoryDonutCard: View {
    let stats: [StatisticsSummary.CategoryStat]
    let total: Decimal
    let currencyCode: String
    var range: StatisticsRange? = nil

    @State private var selectedAngle: Double?

    var body: some View {
        VStack(spacing: 16) {
            donut
                .frame(maxWidth: .infinity)

            if !stats.isEmpty {
                Divider().opacity(0.5)
                rankedRows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(
            color: AppTheme.cardShadowColor,
            radius: AppTheme.cardShadowRadius,
            y: AppTheme.cardShadowYOffset
        )
        .animation(.easeInOut(duration: 0.18), value: selectedCategory)
        .onChange(of: selectedCategory) { _, _ in
            Haptics.selection()
        }
    }

    // MARK: - Donut

    private var donut: some View {
        ZStack {
            if stats.isEmpty {
                Circle().stroke(Color.primary.opacity(0.07), lineWidth: 14)
            } else {
                Chart(stats, id: \.category) { stat in
                    SectorMark(
                        angle: .value("amount", NSDecimalNumber(decimal: stat.amount).doubleValue),
                        innerRadius: .ratio(0.64),
                        angularInset: 1.4
                    )
                    .foregroundStyle(stat.category.tintColor)
                    .opacity(opacity(for: stat.category))
                    .accessibilityLabel("\(stat.category.displayName), \(stat.amount.formatted(.currency(code: currencyCode))), \(percentString(stat.percent)).")
                }
                .chartLegend(.hidden)
                .chartAngleSelection(value: $selectedAngle)
            }
            donutCenter
                .padding(.horizontal, 30)
        }
        .frame(width: 150, height: 150)
        .overlay(alignment: .center) {
            if stats.isEmpty {
                Text("No spend in this period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 64)
            }
        }
    }

    @ViewBuilder
    private var donutCenter: some View {
        if let selected = selectedCategory,
           let stat = stats.first(where: { $0.category == selected }) {
            VStack(spacing: 2) {
                Text(stat.category.displayName)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.4)
                    .foregroundStyle(stat.category.tintColor)
                    .lineLimit(1)
                Text(stat.amount.aggregateCurrency(code: currencyCode))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(percentString(stat.percent))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)
        } else {
            VStack(spacing: 2) {
                Text(total.aggregateCurrency(code: currencyCode))
                    .font(.headline.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("total")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)
        }
    }

    /// Resolves the cumulative angle Decimal returned by `chartAngleSelection`
    /// to the category whose sector contains it. Returns `nil` when the user
    /// taps the chart center / outside the ring.
    private var selectedCategory: ExpenseCategory? {
        guard let value = selectedAngle else { return nil }
        var accumulated: Double = 0
        for stat in stats {
            accumulated += NSDecimalNumber(decimal: stat.amount).doubleValue
            if value <= accumulated { return stat.category }
        }
        return nil
    }

    private func opacity(for category: ExpenseCategory) -> Double {
        guard let selectedCategory else { return 1.0 }
        return selectedCategory == category ? 1.0 : 0.35
    }

    // MARK: - Ranked rows

    private var rankedRows: some View {
        let topAmount = stats.first?.amount ?? 0
        return VStack(spacing: 4) {
            ForEach(stats, id: \.category) { stat in
                if let range {
                    NavigationLink(value: CategoryExpensesQuery(category: stat.category, range: range)) {
                        row(stat: stat, topAmount: topAmount, isTappable: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    row(stat: stat, topAmount: topAmount, isTappable: false)
                }
            }
        }
    }

    private func row(stat: StatisticsSummary.CategoryStat, topAmount: Decimal, isTappable: Bool) -> some View {
        let ratio = ratioFor(amount: stat.amount, top: topAmount)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                iconChip(for: stat.category)

                Text(stat.category.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    DeltaChip(delta: stat.deltaPercent)

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(stat.amount.aggregateCurrency(code: currencyCode))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(percentString(stat.percent))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    if isTappable {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .layoutPriority(1)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(stat.category.tintColor.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(stat.category.tintColor)
                        .frame(width: max(8, geo.size.width * ratio))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stat.category.displayName), \(stat.amount.formatted(.currency(code: currencyCode))), \(percentString(stat.percent)).")
        .accessibilityAddTraits(isTappable ? .isButton : [])
    }

    private func iconChip(for category: ExpenseCategory) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(category.tintColor)
            Image(category.lucideIconName)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .foregroundStyle(.white)
        }
        .frame(width: 26, height: 26)
    }

    private func ratioFor(amount: Decimal, top: Decimal) -> Double {
        guard top > 0 else { return 0 }
        return min(1.0, NSDecimalNumber(decimal: amount / top).doubleValue)
    }

    private func percentString(_ p: Double) -> String {
        let rounded = Int((p * 100).rounded())
        return "\(rounded)%"
    }
}

#Preview("Populated") {
    CategoryDonutCard(
        stats: [
            .init(category: .food,          amount: 744, percent: 0.30, count: 12, deltaPercent:  18),
            .init(category: .transport,     amount: 497, percent: 0.20, count:  8, deltaPercent:  -6),
            .init(category: .accommodation, amount: 447, percent: 0.18, count:  4, deltaPercent: nil),
            .init(category: .entertainment, amount: 348, percent: 0.14, count:  6, deltaPercent:  22),
            .init(category: .shopping,      amount: 248, percent: 0.10, count:  3, deltaPercent: -12),
            .init(category: .other,         amount: 197, percent: 0.08, count:  2, deltaPercent:   0)
        ],
        total: 2481,
        currencyCode: "USD"
    )
    .padding()
    .background(AppTheme.pageBackground)
}

#Preview("Empty") {
    CategoryDonutCard(stats: [], total: 0, currencyCode: "USD")
        .padding()
        .background(AppTheme.pageBackground)
}
