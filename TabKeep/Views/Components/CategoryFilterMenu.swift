import SwiftUI

struct CategoryFilterMenu: View {
    @Binding var selection: ExpenseCategory?
    let counts: [ExpenseCategory: Int]
    var tint: Color = .accentColor

    var body: some View {
        // Built-ins always show; custom categories appear only when they
        // have a non-zero count from this group's expenses.
        let categories: [ExpenseCategory] = ExpenseCategory.builtIn +
            counts.keys
                .filter { !$0.isBuiltIn && (counts[$0] ?? 0) > 0 }
                .sorted { $0.raw < $1.raw }
        return Menu {
            Button {
                selection = nil
            } label: {
                HStack {
                    Text("All categories")
                    if selection == nil { Image(systemName: "checkmark") }
                }
            }
            Divider()
            ForEach(categories, id: \.self) { category in
                Button {
                    selection = category
                } label: {
                    HStack {
                        Text(label(for: category))
                        if selection == category { Image(systemName: "checkmark") }
                    }
                }
                .accessibilityIdentifier("categoryFilterMenuItem_\(category.raw)")
            }
        } label: {
            HStack(spacing: 6) {
                if let selected = selection {
                    Image(selected.lucideIconName)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.caption.weight(.bold))
                }
                Text(buttonLabel)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(selection == nil ? Color.primary : Color.white)
            .background(
                Capsule().fill(selection == nil ? AppTheme.cardBackground : tint)
            )
            .overlay(
                Capsule().strokeBorder(selection == nil ? Color(.separator) : tint, lineWidth: 0.5)
            )
        }
        .accessibilityIdentifier("categoryFilterMenu")
    }

    private var buttonLabel: String {
        selection?.displayName ?? "All categories"
    }

    private func label(for category: ExpenseCategory) -> String {
        if let count = counts[category], count > 0 {
            return "\(category.displayName) · \(count)"
        }
        return category.displayName
    }
}
