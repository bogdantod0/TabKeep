import SwiftUI

struct InviteConfirmSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let confirm: PendingInviteConfirm

    @State private var isJoining = false

    var body: some View {
        ZStack {
            AppTheme.pageBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 24)

                hero

                VStack(spacing: 8) {
                    Text("You've been invited to join")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(confirm.groupName)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Text(memberCountLabel)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                buttons
            }
            .padding(.bottom, 20)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Pieces

    private var hero: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [AppTheme.accent.opacity(0.32), AppTheme.accent.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 88, height: 88)
                .overlay(Circle().strokeBorder(AppTheme.accent.opacity(0.18), lineWidth: 1))
                .shadow(color: AppTheme.accent.opacity(0.18), radius: 12, x: 0, y: 6)

            Text(confirm.groupEmoji?.isEmpty == false ? (confirm.groupEmoji ?? "") : "👥")
                .font(.system(size: 40))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 10) {
            Button(action: join) {
                HStack(spacing: 8) {
                    if isJoining {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "checkmark").font(.body.weight(.semibold))
                    }
                    Text(isJoining ? "Joining…" : "Join group")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(isJoining ? AppTheme.accent.opacity(0.7) : AppTheme.accent)
                )
                .shadow(color: AppTheme.accent.opacity(0.25), radius: 10, x: 0, y: 4)
            }
            .disabled(isJoining)
            .accessibilityIdentifier("inviteConfirmJoinButton")

            Button {
                store.pendingInviteConfirm = nil
                store.pendingInviteToken = nil
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .accessibilityIdentifier("inviteConfirmCancelButton")
        }
        .padding(.horizontal, 24)
    }

    private var memberCountLabel: String {
        confirm.memberCount == 1 ? "1 member" : "\(confirm.memberCount) members"
    }

    private func join() {
        isJoining = true
        Task {
            await store.finishAcceptingInvite(
                token: confirm.rawToken,
                preview: InvitePreviewResponse(
                    group: .init(
                        id: confirm.groupID,
                        name: confirm.groupName,
                        emoji: confirm.groupEmoji,
                        memberCount: confirm.memberCount
                    )
                )
            )
            isJoining = false
            dismiss()
        }
    }
}
