import SwiftUI

struct NumberPadView: View {
    @Binding var text: String
    var tint: Color = .accentColor

    private let rows: [[Key]] = [
        [.digit("1"), .digit("2"), .digit("3")],
        [.digit("4"), .digit("5"), .digit("6")],
        [.digit("7"), .digit("8"), .digit("9")],
        [.dot, .digit("0"), .backspace],
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
    }

    private func keyButton(_ key: Key) -> some View {
        Button {
            press(key)
        } label: {
            label(for: key)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("keypad_\(key.identifier)")
    }

    @ViewBuilder
    private func label(for key: Key) -> some View {
        switch key {
        case .digit(let d): Text(d).font(.title2.weight(.semibold))
        case .dot: Text(".").font(.title2.weight(.semibold))
        case .backspace: Image(systemName: "delete.left").font(.title3)
        }
    }

    private func press(_ key: Key) {
        switch key {
        case .digit(let d):
            if text == "0" { text = d } else { text += d }
            clampToTwoDecimalPlaces()
        case .dot:
            if !text.contains(".") { text += "." }
        case .backspace:
            if !text.isEmpty { text.removeLast() }
            if text.isEmpty { text = "0" }
        }
    }

    private func clampToTwoDecimalPlaces() {
        if let dot = text.firstIndex(of: ".") {
            let fractional = text.distance(from: dot, to: text.endIndex) - 1
            if fractional > 2 {
                text = String(text.prefix(text.count - (fractional - 2)))
            }
        }
    }

    enum Key: Hashable {
        case digit(String)
        case dot
        case backspace

        var identifier: String {
            switch self {
            case .digit(let d): return d
            case .dot: return "dot"
            case .backspace: return "backspace"
            }
        }
    }
}

#Preview {
    struct Wrap: View {
        @State var t = "0"
        var body: some View {
            VStack {
                Text(t).font(.largeTitle)
                NumberPadView(text: $t)
                    .padding()
            }
        }
    }
    return Wrap()
}
