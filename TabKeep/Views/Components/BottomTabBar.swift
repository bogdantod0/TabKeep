import SwiftUI

struct BottomTabBar: View {
    static let height: CGFloat = 60

    enum Tab: Hashable { case dashboard, groups, activity, settings }

    let selection: Tab
    let onSelect: (Tab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            TabBarItem(tab: .groups, asset: "users", label: "Groups", selection: selection, onSelect: onSelect)
            TabBarItem(tab: .dashboard, asset: "chart-bar", label: "Stats", selection: selection, onSelect: onSelect)
            TabBarItem(tab: .activity, asset: "activity", label: "Activity", selection: selection, onSelect: onSelect)
            TabBarItem(tab: .settings, asset: "hexagon", label: "Settings", selection: selection, onSelect: onSelect)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 6)
        )
    }
}

private struct TabBarItem: View {
    let tab: BottomTabBar.Tab
    let asset: String
    let label: String
    let selection: BottomTabBar.Tab
    let onSelect: (BottomTabBar.Tab) -> Void

    private var isSelected: Bool { selection == tab }

    var body: some View {
        Button {
            onSelect(tab)
        } label: {
            VStack(spacing: 3) {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                Text(label)
                    .font(.caption2.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? AppTheme.accent : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab_\(identifier(for: tab))")
        .animation(.snappy, value: isSelected)
    }

    private func identifier(for tab: BottomTabBar.Tab) -> String {
        switch tab {
        case .dashboard: return "dashboard"
        case .groups:    return "groups"
        case .activity:  return "activity"
        case .settings:  return "settings"
        }
    }
}

#Preview {
    struct Wrap: View {
        @State var sel: BottomTabBar.Tab = .dashboard
        var body: some View {
            VStack {
                Spacer()
                BottomTabBar(selection: sel, onSelect: { sel = $0 })
            }
        }
    }
    return Wrap()
}
