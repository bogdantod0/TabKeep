import SwiftUI

/// Unified searchable currency picker sheet.
///
/// Single modal that combines a "Suggested" section (the common currencies
/// from `SupportedCurrencies.displayList`) with an "All currencies" section,
/// plus a top-of-screen `searchable` field. Tapping any row calls
/// `onPick(code)` and auto-dismisses — no separate Done button.
///
/// Used by Settings, CreateGroupSheet, and CurrencyGridPicker's "More…" tile.
struct AllCurrenciesSheet: View {
    let selected: String
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    private var commonCodes: [String] { SupportedCurrencies.displayList }

    private var common: [SupportedCurrency] {
        commonCodes.compactMap { code in
            SupportedCurrencies.all.first { $0.code == code }
        }
    }

    private var rest: [SupportedCurrency] {
        let common = Set(commonCodes)
        return SupportedCurrencies.all
            .filter { !common.contains($0.code) }
            .sorted { $0.code < $1.code }
    }

    private var filtered: [SupportedCurrency] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return SupportedCurrencies.all
            .filter { c in
                c.code.lowercased().contains(q) || c.name.lowercased().contains(q)
            }
            .sorted { lhs, rhs in
                let lp = lhs.code.lowercased().hasPrefix(q)
                let rp = rhs.code.lowercased().hasPrefix(q)
                if lp != rp { return lp }
                return lhs.code < rhs.code
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if query.isEmpty {
                        sectionCard(title: "Suggested", currencies: common)
                        sectionCard(title: "All currencies", currencies: rest)
                    } else if filtered.isEmpty {
                        emptyState
                    } else {
                        sectionCard(title: nil, currencies: filtered)
                    }
                }
                .padding(16)
                .padding(.bottom, 16)
            }
            .background(AppTheme.sheetBackground.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $query, prompt: "Search currency")
            .navigationTitle("Currency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func sectionCard(title: String?, currencies: [SupportedCurrency]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                ForEach(Array(currencies.enumerated()), id: \.element.code) { index, currency in
                    row(for: currency)
                    if index < currencies.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppTheme.borderHairlineStrong, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func row(for currency: SupportedCurrency) -> some View {
        let isSelected = currency.code == selected
        Button {
            onPick(currency.code)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Text(currency.code)
                    .font(.subheadline.weight(.semibold))
                    .monospaced()
                    .foregroundStyle(isSelected ? AppTheme.accent : Color.primary)
                    .frame(width: 44, alignment: .leading)
                Text(SupportedCurrencies.displayName(for: currency.code))
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? AppTheme.accent.opacity(0.8) : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppTheme.accent.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("currenciesSheet_\(currency.code)")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No currencies match \"\(query)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.borderHairlineStrong, lineWidth: 1)
        )
    }
}
