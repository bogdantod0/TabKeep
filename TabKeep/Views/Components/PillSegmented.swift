import SwiftUI

struct PillSegmented<Tag: Hashable>: View {
    struct Item: Identifiable {
        let label: String
        let tag: Tag
        var badge: String? = nil
        var badgeAlert: Bool = false
        var id: Tag { tag }
    }

    let items: [Item]
    @Binding var selection: Tag
    var tint: Color = .accentColor
    /// When true, drops the white card surface, hairline, and shadow so the
    /// control fits cleanly inside another card (e.g. the split-mode picker
    /// inside the "Split between" card on the expense form).
    var inline: Bool = false

    /// When true, shrinks the pill: smaller label font and tighter padding.
    /// Used by GroupDetailView's Expenses/Balances tab where vertical space
    /// is at a premium. Other call sites keep the default sizing.
    var compact: Bool = false

    @Namespace private var pillSpace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        selection = item.tag
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(item.label)
                            .font(compact ? .subheadline.weight(.semibold) : .callout.weight(.semibold))
                        if let badge = item.badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(badgeBackground(for: item))
                                .foregroundStyle(badgeForeground(for: item))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, compact ? 6 : 9)
                    .padding(.horizontal, compact ? 12 : 14)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selection == item.tag ? .white : .primary)
                    .background {
                        if selection == item.tag {
                            Capsule()
                                .fill(tint)
                                .matchedGeometryEffect(id: "pill", in: pillSpace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(compact ? 3 : 4)
        .background(
            Capsule().fill(
                inline ? AppTheme.pageBackground : AppTheme.cardBackground
            )
        )
        .overlay {
            Capsule().strokeBorder(
                AppTheme.borderHairline,
                lineWidth: 1
            )
        }
        .shadow(
            color: inline ? .clear : AppTheme.cardShadowColor,
            radius: inline ? 0 : AppTheme.cardShadowRadius,
            x: 0,
            y: inline ? 0 : AppTheme.cardShadowYOffset
        )
    }

    private func badgeBackground(for item: Item) -> Color {
        if selection == item.tag {
            return Color.white.opacity(0.22)
        }
        return item.badgeAlert ? AppTheme.warning.opacity(0.18) : Color.black.opacity(0.07)
    }

    private func badgeForeground(for item: Item) -> Color {
        if selection == item.tag {
            return .white
        }
        return item.badgeAlert ? AppTheme.warning : .secondary
    }
}

#Preview {
    struct Wrap: View {
        @State var sel = "A"
        var body: some View {
            VStack(spacing: 12) {
                PillSegmented(
                    items: [
                        .init(label: "Expenses", tag: "A", badge: "12"),
                        .init(label: "Balances", tag: "B", badge: "2", badgeAlert: true)
                    ],
                    selection: $sel
                )
                PillSegmented(
                    items: [
                        .init(label: "Expenses", tag: "A", badge: "12"),
                        .init(label: "Balances", tag: "B")
                    ],
                    selection: .constant("B")
                )
            }
            .padding()
        }
    }
    return Wrap()
}
