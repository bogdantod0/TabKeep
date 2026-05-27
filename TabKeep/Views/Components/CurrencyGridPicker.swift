import SwiftUI

/// A 2-column grid of common-currency tiles plus a trailing "More…" tile
/// that opens the full searchable list. Used by the onboarding setup
/// screen and the Create / Edit Group sheets so every currency picker in
/// the app looks and behaves the same.
struct CurrencyGridPicker: View {
    @Binding var code: String
    var accessibilityPrefix: String = "currencyGrid"

    @State private var showingAll = false

    private var gridCurrencies: [String] {
        var list = SupportedCurrencies.displayList
        if !code.isEmpty && !list.contains(code) {
            list.insert(code, at: 0)
        }
        return list
    }

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
                spacing: 10
            ) {
                ForEach(gridCurrencies, id: \.self) { c in
                    CurrencyTile(
                        code: c,
                        symbol: SupportedCurrencies.symbol(for: c),
                        name: SupportedCurrencies.displayName(for: c),
                        isSelected: c == code,
                        accessibilityPrefix: accessibilityPrefix
                    ) {
                        code = c
                    }
                }
            }
            MoreCurrenciesTile(accessibilityPrefix: accessibilityPrefix) {
                showingAll = true
            }
        }
        .sheet(isPresented: $showingAll) {
            AllCurrenciesSheet(selected: code) { picked in
                code = picked
            }
        }
    }
}

private struct CurrencyTile: View {
    let code: String
    let symbol: String
    let name: String
    let isSelected: Bool
    let accessibilityPrefix: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.22) : AppTheme.accent.opacity(0.14))
                    Text(symbol)
                        .font(.body.weight(.semibold))
                        .monospaced()
                        .foregroundStyle(isSelected ? Color.white : AppTheme.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(code)
                        .font(.subheadline.weight(.semibold))
                        .monospaced()
                    Text(name)
                        .font(.caption2)
                        .lineLimit(1)
                        .opacity(isSelected ? 0.9 : 0.7)
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AppTheme.accent : Color(.tertiarySystemGroupedBackground))
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: isSelected)
        .accessibilityIdentifier("\(accessibilityPrefix)_\(code)")
        .accessibilityLabel("\(code), \(name)")
    }
}

private struct MoreCurrenciesTile: View {
    let accessibilityPrefix: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle().fill(AppTheme.accent.opacity(0.14))
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("More…").font(.subheadline.weight(.semibold))
                    Text("Other currencies")
                        .font(.caption2)
                        .opacity(0.7)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
            )
            .foregroundStyle(Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(accessibilityPrefix)_more")
        .accessibilityLabel("More currencies")
    }
}
