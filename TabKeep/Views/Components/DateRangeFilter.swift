import SwiftUI

enum DateRangePreset: Hashable {
    case allTime
    case thisWeek
    case thisMonth
    case last30Days
    case custom(start: Date, end: Date)

    var displayName: String {
        switch self {
        case .allTime:    return "All time"
        case .thisWeek:   return "This week"
        case .thisMonth:  return "This month"
        case .last30Days: return "Last 30 days"
        case .custom:     return "Custom"
        }
    }

    func interval(now: Date = Date()) -> DateInterval? {
        let cal = Calendar.current
        switch self {
        case .allTime:
            return nil
        case .thisWeek:
            return cal.dateInterval(of: .weekOfYear, for: now)
        case .thisMonth:
            return cal.dateInterval(of: .month, for: now)
        case .last30Days:
            let start = cal.date(byAdding: .day, value: -30, to: now) ?? now
            return DateInterval(start: start, end: now)
        case .custom(let start, let end):
            let lo = min(start, end)
            let hi = max(start, end)
            let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: hi)) ?? hi
            return DateInterval(start: cal.startOfDay(for: lo), end: endOfDay)
        }
    }
}

struct DateRangeFilterMenu: View {
    @Binding var selection: DateRangePreset
    var tint: Color = .accentColor

    @State private var showingCustom = false
    @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()

    private static let presetChoices: [DateRangePreset] = [.allTime, .thisWeek, .thisMonth, .last30Days]

    var body: some View {
        Menu {
            ForEach(Self.presetChoices, id: \.self) { preset in
                Button {
                    selection = preset
                } label: {
                    HStack {
                        Text(preset.displayName)
                        if preset == selection { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Button {
                if case .custom(let start, let end) = selection {
                    customStart = start
                    customEnd = end
                }
                showingCustom = true
            } label: {
                HStack {
                    Text("Custom…")
                    if case .custom = selection { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption.weight(.bold))
                Text(buttonLabel)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background(
                Capsule().fill(isActive ? tint : AppTheme.cardBackground)
            )
            .overlay(
                Capsule().strokeBorder(isActive ? tint : Color(.separator), lineWidth: 0.5)
            )
        }
        .accessibilityIdentifier("dateRangeFilterMenu")
        .sheet(isPresented: $showingCustom) {
            CustomDateRangeSheet(
                start: $customStart,
                end: $customEnd,
                onApply: { selection = .custom(start: customStart, end: customEnd) }
            )
        }
    }

    private var isActive: Bool {
        if case .allTime = selection { return false }
        return true
    }

    private var buttonLabel: String {
        if case .custom(let start, let end) = selection {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
        }
        return selection.displayName
    }
}

private struct CustomDateRangeSheet: View {
    @Binding var start: Date
    @Binding var end: Date
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $start, displayedComponents: .date)
                DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
            }
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
