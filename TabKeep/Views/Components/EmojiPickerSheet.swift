import SwiftUI

/// In-app emoji picker. Shows a single curated grid based on `category`.
/// Doesn't depend on the system emoji keyboard, so it works reliably on
/// simulators with broken emoji fonts and on devices where the user
/// hasn't installed the Emoji keyboard.
struct EmojiPickerSheet: View {
    enum Category {
        case animals
        case travelAndOutdoors
    }

    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    let category: Category

    /// Returns a random animal emoji. Used by `OnboardingView` to seed the
    /// initial profile emoji with something concrete instead of a generic
    /// face. Falls back to "🐶" only if the array is somehow empty.
    static func randomAnimal() -> String {
        animals.randomElement() ?? "🐶"
    }

    private static let animals: [String] = [
        "🐶", "🐱", "🐰", "🐻", "🐼", "🦊", "🐯", "🦁", "🐮", "🐷",
        "🐸", "🐵", "🦄", "🐔", "🐧", "🦋", "🦉", "🐢", "🐬", "🦈"
    ]

    private static let travelAndOutdoors: [String] = [
        "✈️", "🚗", "🚆", "🛳️", "🚲", "🚌", "🏖️", "🏔️", "🌋", "🗺️",
        "🌴", "🌍", "🎒", "⛺", "🏕️", "🚴", "🛶", "🏝️", "🚀", "🛤️"
    ]

    private var emojis: [String] {
        switch category {
        case .animals:           return Self.animals
        case .travelAndOutdoors: return Self.travelAndOutdoors
        }
    }

    private var navTitle: String {
        switch category {
        case .animals:           return "Pick an animal"
        case .travelAndOutdoors: return "Pick a travel emoji"
        }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(emojis, id: \.self) { emoji in
                        emojiButton(emoji)
                    }
                }
                .padding(16)
            }
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(32)
    }

    private func emojiButton(_ emoji: String) -> some View {
        Button {
            selection = emoji
            dismiss()
        } label: {
            Text(emoji)
                .font(.system(size: 32))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selection == emoji
                              ? AppTheme.accent.opacity(0.18)
                              : AppTheme.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            selection == emoji
                                ? AppTheme.accent.opacity(0.6)
                                : Color.clear,
                            lineWidth: 1.5
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(emoji)
    }
}
