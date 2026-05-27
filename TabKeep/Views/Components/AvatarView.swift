import SwiftUI

/// Renders a member's emoji on a tinted accent circle. Mirrors the visual
/// language of the user-identity tile used in onboarding.
struct AvatarView: View {
    let emoji: String
    var size: CGFloat = 40
    var isSelected: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [AppTheme.accent.opacity(0.28), AppTheme.accent.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(Circle().strokeBorder(AppTheme.accent.opacity(0.18), lineWidth: 1))
            EmojiText(emoji: emoji.isEmpty ? Member.defaultEmoji : emoji, size: size * 0.55)
        }
        .frame(width: size, height: size)
        .overlay {
            if isSelected {
                Circle().strokeBorder(AppTheme.accent, lineWidth: 3)
            }
        }
    }
}

#Preview {
    HStack(spacing: 12) {
        AvatarView(emoji: "🦊", size: 48)
        AvatarView(emoji: "🐻", size: 48)
        AvatarView(emoji: "🦉", size: 48)
        AvatarView(emoji: "🙂", size: 48, isSelected: true)
    }
    .padding()
}
