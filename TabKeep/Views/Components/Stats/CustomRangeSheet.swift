import SwiftUI

/// Date-range picker presented when the user taps the calendar button on
/// the Statistics range picker. Returns a `DateInterval` whose `.start` is
/// the start of the picked start day and `.end` is the start of the day
/// AFTER the picked end day, so `DateInterval.contains(expense.date)`
/// includes the entire end day.
struct CustomRangeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialInterval: DateInterval?
    let onApply: (DateInterval) -> Void

    @State private var start: Date
    @State private var end: Date

    private let calendar: Calendar = .current

    init(initialInterval: DateInterval?, onApply: @escaping (DateInterval) -> Void) {
        self.initialInterval = initialInterval
        self.onApply = onApply

        let cal = Calendar.current
        let today = Date()
        let defaultEnd = initialInterval.map { cal.startOfDay(for: $0.end - 1) } ?? cal.startOfDay(for: today)
        let defaultStart: Date = {
            if let interval = initialInterval {
                return cal.startOfDay(for: interval.start)
            }
            return cal.date(byAdding: .day, value: -29, to: defaultEnd) ?? defaultEnd
        }()
        _start = State(initialValue: defaultStart)
        _end = State(initialValue: defaultEnd)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    summaryCard
                    pickerCard("Start", date: $start, range: Date.distantPast...end)
                    pickerCard("End", date: $end, range: start...Date())
                    quickRanges
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .fontWeight(.semibold)
                        .disabled(!isValid)
                }
            }
        }
    }

    // MARK: - Pieces

    private var summaryCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.12))
                Image(systemName: "calendar")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text("RANGE")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(rangeSummary)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(daysSummary)
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

    private func pickerCard(_ label: String, date: Binding<Date>, range: ClosedRange<Date>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            DatePicker(
                "",
                selection: date,
                in: range,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(AppTheme.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(
            color: AppTheme.cardShadowColor,
            radius: AppTheme.cardShadowRadius,
            y: AppTheme.cardShadowYOffset
        )
    }

    private var quickRanges: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUICK RANGES")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            FlowLayoutWrap(spacing: 8) {
                ForEach(quickRangeOptions, id: \.label) { option in
                    Button {
                        applyQuickRange(option)
                    } label: {
                        Text(option.label)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(AppTheme.accent.opacity(0.10))
                            )
                            .foregroundStyle(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Logic

    private var isValid: Bool {
        end >= start
    }

    private func apply() {
        let s = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDay) else { return }
        guard endExclusive > s else { return }
        Haptics.success()
        onApply(DateInterval(start: s, end: endExclusive))
        dismiss()
    }

    private func applyQuickRange(_ option: QuickRange) {
        let today = calendar.startOfDay(for: Date())
        guard let computedStart = calendar.date(byAdding: .day, value: -(option.days - 1), to: today) else { return }
        start = computedStart
        end = today
    }

    // MARK: - Display helpers

    private var rangeSummary: String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .current
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        let nowYear = calendar.component(.year, from: Date())
        let needsYear = !sameYear || calendar.component(.year, from: end) != nowYear
        f.setLocalizedDateFormatFromTemplate(needsYear ? "MMM d y" : "MMM d")
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    private var daysSummary: String {
        let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0) + 1
        return days == 1 ? "1 day" : "\(days) days"
    }

    private struct QuickRange {
        let label: String
        let days: Int
    }

    private var quickRangeOptions: [QuickRange] {
        [
            .init(label: "Last 7 days",  days: 7),
            .init(label: "Last 14 days", days: 14),
            .init(label: "Last 30 days", days: 30),
            .init(label: "Last 90 days", days: 90),
        ]
    }
}

/// Tiny wrap layout — shows children left-to-right, wrapping to a new line
/// when out of room. Used for the quick-range chip row.
private struct FlowLayoutWrap: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    CustomRangeSheet(initialInterval: nil, onApply: { _ in })
}
