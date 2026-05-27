import SwiftUI

struct MemberChip: View {
    let member: Member
    var isSelected: Bool = false
    var isYou: Bool = false
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(emoji: member.emoji, size: 28)
            Text(isYou ? "\(member.name) (You)" : member.name)
                .font(.callout.weight(.medium))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            Capsule()
                .fill(isSelected ? tint.opacity(0.2) : Color(.tertiarySystemFill))
        )
        .overlay {
            if isSelected {
                Capsule().strokeBorder(tint, lineWidth: 2)
            }
        }
    }
}
