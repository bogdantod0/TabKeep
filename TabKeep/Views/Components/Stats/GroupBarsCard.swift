import SwiftUI

struct GroupBarsCard: View {
    let stats: [StatisticsSummary.GroupStat]
    let currencyCode: String
    var onTapGroup: ((UUID) -> Void)? = nil

    @State private var showAll = false

    private let visibleLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            bars

            if stats.count > visibleLimit {
                Button {
                    showAll = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Show all (\(stats.count))")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AppTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if stats.isEmpty {
                Text("No spend in this period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(
            color: AppTheme.cardShadowColor,
            radius: AppTheme.cardShadowRadius,
            y: AppTheme.cardShadowYOffset
        )
        .sheet(isPresented: $showAll) {
            GroupBarsSheet(
                stats: stats,
                currencyCode: currencyCode,
                onTapGroup: onTapGroup.map { handler in
                    { id in
                        showAll = false
                        handler(id)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var bars: some View {
        let visible = Array(stats.prefix(visibleLimit))
        let topAmount = visible.first?.amount ?? 0
        if !visible.isEmpty {
            VStack(spacing: 4) {
                ForEach(visible) { stat in
                    if let onTapGroup {
                        Button {
                            onTapGroup(stat.id)
                        } label: {
                            barRow(stat: stat, topAmount: topAmount, isTappable: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        barRow(stat: stat, topAmount: topAmount, isTappable: false)
                    }
                }
            }
        }
    }

    private func barRow(stat: StatisticsSummary.GroupStat, topAmount: Decimal, isTappable: Bool) -> some View {
        let ratio = ratioFor(amount: stat.amount, top: topAmount)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                groupEmojiChip(stat.emoji)

                Text(stat.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(stat.amount.aggregateCurrency(code: currencyCode))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)

                if isTappable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(AppTheme.accent.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(AppTheme.accent.opacity(barOpacity(ratio: ratio)))
                        .frame(width: max(8, geo.size.width * ratio))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stat.name), \(stat.amount.formatted(.currency(code: currencyCode)))")
        .accessibilityAddTraits(isTappable ? .isButton : [])
    }

    @ViewBuilder
    private func groupEmojiChip(_ emoji: String?) -> some View {
        if let emoji {
            EmojiText(emoji: emoji, size: 18)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)
        }
    }

    private func ratioFor(amount: Decimal, top: Decimal) -> Double {
        guard top > 0 else { return 0 }
        return min(1.0, NSDecimalNumber(decimal: amount / top).doubleValue)
    }

    private func barOpacity(ratio: Double) -> Double {
        max(0.4, min(1.0, ratio))
    }
}

private struct GroupBarsSheet: View {
    let stats: [StatisticsSummary.GroupStat]
    let currencyCode: String
    var onTapGroup: ((UUID) -> Void)? = nil

    var body: some View {
        NavigationStack {
            List(stats) { stat in
                if let onTapGroup {
                    Button {
                        onTapGroup(stat.id)
                    } label: {
                        row(for: stat)
                    }
                    .buttonStyle(.plain)
                } else {
                    row(for: stat)
                }
            }
            .navigationTitle("By group")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(for stat: StatisticsSummary.GroupStat) -> some View {
        HStack(spacing: 12) {
            emojiChip(stat.emoji)

            Text(stat.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(stat.amount.aggregateCurrency(code: currencyCode))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)

            if onTapGroup != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func emojiChip(_ emoji: String?) -> some View {
        if let emoji {
            EmojiText(emoji: emoji, size: 18)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)
        }
    }
}

#Preview {
    GroupBarsCard(
        stats: [
            .init(id: UUID(), name: "Lisbon trip",                     emoji: "🌅", amount: 842),
            .init(id: UUID(), name: "Roommates",                       emoji: "🏠", amount: 580),
            .init(id: UUID(), name: "Climbing crew",                   emoji: "🧗", amount: 420),
            .init(id: UUID(), name: "Family",                          emoji: "👨‍👩‍👧", amount: 269),
            .init(id: UUID(), name: "Backpacking around Europe 2026",  emoji: "🎒", amount: 12849),
        ],
        currencyCode: "USD"
    )
    .padding()
    .background(AppTheme.pageBackground)
}
