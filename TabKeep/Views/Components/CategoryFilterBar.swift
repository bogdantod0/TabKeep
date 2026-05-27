import SwiftUI

struct CategoryFilterBar: View {
    @Binding var selection: ExpenseCategory?
    let counts: [ExpenseCategory: Int]
    var tint: Color = .accentColor

    var body: some View {
        // Built-ins always show; custom categories show only when they
        // have a count > 0 (they were sourced from this group's expenses).
        let categories: [ExpenseCategory] = ExpenseCategory.builtIn +
            counts.keys
                .filter { !$0.isBuiltIn && (counts[$0] ?? 0) > 0 }
                .sorted { $0.raw < $1.raw }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                allChip
                ForEach(categories, id: \.self) { category in
                    Button {
                        selection = (selection == category) ? nil : category
                    } label: {
                        CategoryChip(
                            category: category,
                            isSelected: selection == category,
                            tint: tint,
                            count: counts[category]
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("categoryFilterChip_\(category.raw)")
                }
            }
            .padding(.horizontal)
        }
    }

    private var allChip: some View {
        Button {
            selection = nil
        } label: {
            Text("All")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(selection == nil ? Color.white : Color.primary)
                .background(
                    Capsule().fill(selection == nil ? tint : AppTheme.cardBackground)
                )
                .overlay(
                    Capsule().strokeBorder(selection == nil ? tint : Color(.separator), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("categoryFilterChip_all")
    }
}
