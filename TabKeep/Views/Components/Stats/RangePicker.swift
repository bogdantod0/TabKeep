import SwiftUI

struct StatisticsRangePicker: View {
    @Binding var selection: StatisticsRange

    @State private var showCustomSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PillSegmented(
                    items: visibleItems,
                    selection: pillSelectionBinding,
                    tint: AppTheme.accent,
                    compact: true
                )

                customButton
            }

            if case .custom = selection {
                Text(selection.displayTitle(now: Date()))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
        .accessibilityIdentifier("statisticsRangePicker")
        .animation(.easeInOut(duration: 0.18), value: selection)
        .sheet(isPresented: $showCustomSheet) {
            CustomRangeSheet(initialInterval: currentCustomInterval) { interval in
                selection = .custom(interval)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Pieces

    private var customButton: some View {
        Button {
            showCustomSheet = true
        } label: {
            Image(systemName: "calendar")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selection.isCustom ? .white : AppTheme.accent)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(selection.isCustom ? AppTheme.accent : AppTheme.cardBackground)
                )
                .overlay {
                    Circle().strokeBorder(
                        selection.isCustom ? Color.clear : AppTheme.borderHairline,
                        lineWidth: 1
                    )
                }
                .shadow(
                    color: AppTheme.cardShadowColor,
                    radius: AppTheme.cardShadowRadius,
                    y: AppTheme.cardShadowYOffset
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pick a custom date range")
    }

    // MARK: - Selection plumbing

    /// The pill row only knows about the three preset cases. When the user
    /// has a custom range active, no pill is highlighted; tapping a preset
    /// pill replaces the custom range with that preset.
    private var pillSelectionBinding: Binding<StatisticsRange?> {
        Binding(
            get: {
                switch selection {
                case .month, .year, .allTime: return selection
                case .custom: return nil
                }
            },
            set: { new in
                if let new { selection = new }
            }
        )
    }

    private var visibleItems: [PillSegmented<StatisticsRange?>.Item] {
        StatisticsRange.presets.map { preset in
            .init(label: preset.title, tag: Optional(preset))
        }
    }

    private var currentCustomInterval: DateInterval? {
        if case .custom(let interval) = selection { return interval }
        return nil
    }
}

#Preview {
    StatePreviewWrapper()
}

private struct StatePreviewWrapper: View {
    @State private var range: StatisticsRange = .month
    var body: some View {
        VStack(spacing: 16) {
            StatisticsRangePicker(selection: $range)
            Text("Selected: \(range.displayTitle(now: Date()))")
                .font(.caption)
        }
        .padding()
        .background(AppTheme.pageBackground)
    }
}
