import SwiftUI

struct ConflictBannerStack: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.conflictBanners.suffix(3)) { banner in
                ConflictBannerRow(banner: banner)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: banner.id) {
                        // Only auto-dismiss banners that don't carry a draft.
                        if !hasDraft(banner) {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            if !Task.isCancelled {
                                await MainActor.run {
                                    withAnimation { store.dismissConflictBanner(banner.id) }
                                }
                            }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.conflictBanners.count)
    }

    // Inferred from `banner.kind`, not from `store.drafts[key]`, to avoid a
    // race: applyConflict appends the banner synchronously but mirrors the
    // draft into store.drafts via an actor-hop on SyncState. The .task below
    // runs once on appear; if the mirror hasn't landed yet, a draft-bearing
    // banner would otherwise see hasDraft==false and auto-dismiss. Every
    // entity-bound banner represents a draftable conflict; only
    // .groupDeleted is informational (and entityKey returns nil for it).
    private func hasDraft(_ banner: ConflictBanner) -> Bool {
        AppStore.entityKey(for: banner.kind) != nil
    }
}

private struct ConflictBannerRow: View {
    let banner: ConflictBanner
    @Environment(AppStore.self) private var store

    private var draft: RejectedDraft? {
        guard let key = AppStore.entityKey(for: banner.kind) else { return nil }
        return store.drafts[key]
    }

    private var isTombstoneDraft: Bool {
        if case .tombstone = draft?.kind { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.message)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                if draft != nil {
                    Text(isTombstoneDraft ? "Your delete is on hold." : "Your edit was saved as a draft.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            actionButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let key = AppStore.entityKey(for: banner.kind), store.drafts[key] != nil {
            if isTombstoneDraft {
                Button("Keep") { store.discardDraft(key) }
                    .font(.caption.bold())
                Button("Delete anyway") { store.confirmDeleteFromDraft(key) }
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            } else {
                Button("Discard") { store.discardDraft(key) }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Button("Review") { store.openDraftReview(key) }
                    .font(.caption.bold())
            }
        } else {
            Button("Dismiss") {
                store.dismissConflictBanner(banner.id)
            }
            .font(.caption.bold())
        }
    }
}
