import SwiftUI

/// Capsule chip for picking a currency code. Reused by CreateGroupSheet,
/// EditGroupSheet and the onboarding setup screen.
struct CurrencyChip: View {
    let code: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(code)
                .font(.subheadline.weight(.semibold))
                .monospaced()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Color(.tertiarySystemGroupedBackground))
                )
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: isSelected)
    }
}
