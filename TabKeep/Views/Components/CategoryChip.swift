import SwiftUI

extension ExpenseCategory {
    /// Display label. Built-ins use tuned text; custom categories
    /// capitalize the user-typed raw value.
    var displayName: String {
        switch self {
        case .food:          return "Food"
        case .groceries:     return "Groceries"
        case .drinks:        return "Drinks"
        case .transport:     return "Transport"
        case .accommodation: return "Accommodation"
        case .travel:        return "Travel"
        case .entertainment: return "Entertainment"
        case .shopping:      return "Shopping"
        case .gifts:         return "Gifts"
        case .utilities:     return "Utilities"
        case .health:        return "Health"
        case .other:         return "Other"
        default:             return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// Lucide icon name (resolved against the asset catalog). Built-ins
    /// have hand-picked icons; custom categories use a generic tag icon.
    var lucideIconName: String {
        switch self {
        case .food:          return "utensils"
        case .groceries:     return "shopping-cart"
        case .drinks:        return "wine"
        case .transport:     return "car"
        case .accommodation: return "bed"
        case .travel:        return "plane"
        case .entertainment: return "party-popper"
        case .shopping:      return "shopping-bag"
        case .gifts:         return "gift"
        case .utilities:     return "zap"
        case .health:        return "heart-pulse"
        case .other:         return "circle-ellipsis"
        default:             return "tag"
        }
    }

    /// Brand-aligned color used in the Statistics donut, per-category cards,
    /// and any future per-category accents. Picked for: 3:1 contrast against
    /// `AppTheme.cardBackground`, hue distance under deuteranopia, and
    /// `accommodation` re-using `AppTheme.accent` so brand teal anchors the
    /// chart. Custom categories share `other`'s slate so they read as
    /// neutral and never collide with built-in hues.
    var tintColor: Color {
        switch self {
        case .food:          return Color(red: 225.0 / 255.0, green:  29.0 / 255.0, blue:  72.0 / 255.0) // #E11D48 rose
        case .groceries:     return Color(red:  16.0 / 255.0, green: 185.0 / 255.0, blue: 129.0 / 255.0) // #10B981 emerald
        case .drinks:        return Color(red: 236.0 / 255.0, green:  72.0 / 255.0, blue: 153.0 / 255.0) // #EC4899 pink
        case .transport:     return Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue:   6.0 / 255.0) // #D97706 amber
        case .accommodation: return AppTheme.accent
        case .travel:        return Color(red:  14.0 / 255.0, green: 165.0 / 255.0, blue: 233.0 / 255.0) // #0EA5E9 sky
        case .entertainment: return Color(red:  79.0 / 255.0, green:  70.0 / 255.0, blue: 229.0 / 255.0) // #4F46E5 indigo
        case .shopping:      return Color(red: 139.0 / 255.0, green:  92.0 / 255.0, blue: 246.0 / 255.0) // #8B5CF6 violet
        case .gifts:         return Color(red: 217.0 / 255.0, green:  70.0 / 255.0, blue: 239.0 / 255.0) // #D946EF fuchsia
        case .utilities:     return Color(red: 234.0 / 255.0, green: 179.0 / 255.0, blue:   8.0 / 255.0) // #EAB308 yellow
        case .health:        return Color(red: 220.0 / 255.0, green:  38.0 / 255.0, blue:  38.0 / 255.0) // #DC2626 red
        case .other:         return Color(red: 100.0 / 255.0, green: 116.0 / 255.0, blue: 139.0 / 255.0) // #64748B slate
        default:             return Color(red: 100.0 / 255.0, green: 116.0 / 255.0, blue: 139.0 / 255.0) // custom → same slate as `.other`
        }
    }
}

struct CategoryChip: View {
    let category: ExpenseCategory
    let isSelected: Bool
    var tint: Color = .accentColor
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(category.lucideIconName)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
            Text(label)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            Capsule().fill(isSelected ? tint : AppTheme.cardBackground)
        )
        .overlay(
            Capsule().strokeBorder(isSelected ? tint : Color(.separator), lineWidth: 0.5)
        )
    }

    private var label: String {
        if let count {
            return "\(category.displayName) · \(count)"
        }
        return category.displayName
    }
}
