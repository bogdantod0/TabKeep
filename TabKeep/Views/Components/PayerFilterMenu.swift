import SwiftUI

struct PayerFilterMenu: View {
    let members: [Member]
    @Binding var selection: UUID?
    var tint: Color = .accentColor

    var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                HStack {
                    Text("Anyone")
                    if selection == nil { Image(systemName: "checkmark") }
                }
            }
            Divider()
            ForEach(members) { member in
                Button {
                    selection = member.id
                } label: {
                    HStack {
                        Text(member.name)
                        if selection == member.id { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.caption.weight(.bold))
                Text(buttonLabel)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(selection == nil ? Color.primary : Color.white)
            .background(
                Capsule().fill(selection == nil ? AppTheme.cardBackground : tint)
            )
            .overlay(
                Capsule().strokeBorder(selection == nil ? Color(.separator) : tint, lineWidth: 0.5)
            )
        }
        .accessibilityIdentifier("payerFilterMenu")
    }

    private var buttonLabel: String {
        if let id = selection, let member = members.first(where: { $0.id == id }) {
            return "Paid by \(member.name)"
        }
        return "Anyone paid"
    }
}
