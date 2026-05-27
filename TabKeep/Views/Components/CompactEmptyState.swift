import SwiftUI

/// Compact empty-state placeholder, smaller and more muted than
/// `ContentUnavailableView`. Icon is rendered in `.secondary` so all
/// empty states across tabs share the same neutral tone; the optional
/// action slot is the only branded element.
struct CompactEmptyState<Action: View>: View {
    let icon: String
    let title: String
    let description: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            action()
                .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}

extension CompactEmptyState where Action == EmptyView {
    init(icon: String, title: String, description: String) {
        self.init(icon: icon, title: title, description: description) { EmptyView() }
    }
}
