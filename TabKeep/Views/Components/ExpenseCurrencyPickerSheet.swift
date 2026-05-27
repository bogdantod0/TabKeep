import SwiftUI

struct ExpenseCurrencyPickerSheet: View {
    @Binding var selected: String
    var tint: Color = .accentColor
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered, id: \.code) { currency in
                    Button {
                        selected = currency.code
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(currency.code)
                                    .font(.body.weight(.semibold))
                                Text(currency.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if currency.code == selected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("currencyPickerRow_\(currency.code)")
                }
            }
            .navigationTitle("Currency")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search currency")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var filtered: [SupportedCurrency] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SupportedCurrencies.all }
        return SupportedCurrencies.all.filter {
            $0.code.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }
}
