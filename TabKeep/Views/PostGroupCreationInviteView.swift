import SwiftUI
import UIKit

struct PostGroupCreationInviteView: View {
    @Environment(AppStore.self) private var store

    let groupID: UUID
    let onFinished: (UUID) -> Void

    @State private var isMinting = false
    @State private var shareURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        let group = store.group(id: groupID)

        ZStack {
            AppTheme.pageBackground.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                hero

                VStack(spacing: 10) {
                    Text("Invite people")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)

                    Text(groupHeadline(for: group))
                        .font(.title3.weight(.medium))
                        .foregroundStyle(AppTheme.accent)
                        .multilineTextAlignment(.center)

                    Text("Share a link so others can join from any device. No account needed.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("Link expires in 3 days · Latest link replaces older ones")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                Spacer()

                buttons

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AppTheme.danger)
                        .padding(.top, 4)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 24)
        }
        .animation(.snappy, value: errorMessage)
        .sheet(item: Binding(
            get: { shareURL.map(InviteShareItem.init) },
            set: { _ in shareURL = nil; onFinished(groupID) }
        )) { item in
            ShareLinkSheet(url: item.url)
        }
    }

    // MARK: - Pieces

    private var hero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.accent.opacity(0.38), AppTheme.accent.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 112, height: 112)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(AppTheme.accent.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: AppTheme.accent.opacity(0.18), radius: 14, x: 0, y: 8)

            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 14) {
            Button(action: invite) {
                HStack(spacing: 10) {
                    if isMinting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Image(systemName: "link")
                            .font(.body.weight(.semibold))
                    }
                    Text(isMinting ? "Creating link…" : "Share invite link")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(isMinting ? AppTheme.accent.opacity(0.7) : AppTheme.accent)
                )
                .shadow(color: AppTheme.accent.opacity(0.25), radius: 12, x: 0, y: 6)
            }
            .disabled(isMinting)
            .accessibilityIdentifier("postCreateInviteButton")

            Button {
                onFinished(groupID)
            } label: {
                Text("Maybe later")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .accessibilityIdentifier("postCreateSkipButton")
        }
        .padding(.horizontal, 24)
    }

    private func groupHeadline(for group: ExpenseGroup?) -> String {
        guard let group else { return "to your group" }
        let emoji = group.emoji ?? ""
        return emoji.isEmpty ? "to \(group.name)" : "to \(emoji)  \(group.name)"
    }

    private func invite() {
        isMinting = true
        errorMessage = nil
        Task {
            defer { isMinting = false }
            do {
                let url = try await store.createInvite(for: groupID)
                shareURL = url
            } catch {
                errorMessage = "Couldn't create invite link. Try again."
            }
        }
    }
}

private struct InviteShareItem: Identifiable {
    let url: URL
    var id: URL { url }
    init(_ url: URL) { self.url = url }
}

/// Wraps `UIActivityViewController` for SwiftUI presentation.
struct ShareLinkSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
