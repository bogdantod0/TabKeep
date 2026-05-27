import SwiftUI

struct InviteToast: View {
    let groupName: String
    let groupEmoji: String?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(AppTheme.success.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AppTheme.success)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Joined")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    if let emoji = groupEmoji, !emoji.isEmpty {
                        Text(emoji)
                    }
                    Text(groupName)
                        .font(.subheadline.weight(.semibold))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: AppTheme.cardShadowColor, radius: AppTheme.cardShadowRadius, y: AppTheme.cardShadowYOffset)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .onTapGesture { onDismiss() }
        .task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            onDismiss()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
