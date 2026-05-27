import SwiftUI

struct MoneyLabel: View {
    let amount: Decimal
    let currencyCode: String
    var font: Font = .body
    var weight: Font.Weight = .semibold

    var body: some View {
        Text(formatted)
            .font(font.weight(weight))
            .monospacedDigit()
    }

    private var formatted: String {
        amount.formatted(.currency(code: currencyCode).presentation(.standard))
    }
}

extension Decimal {
    /// Currency string rounded to whole units — used for aggregate amounts
    /// (totals, sums across many expenses) where cents are noise. Keep
    /// `.formatted(.currency(...))` for per-expense values.
    func aggregateCurrency(code: String) -> String {
        formatted(.currency(code: code).precision(.fractionLength(0)))
    }
}

#Preview {
    VStack(spacing: 8) {
        MoneyLabel(amount: 12.34, currencyCode: "USD", font: .largeTitle)
        MoneyLabel(amount: -7.89, currencyCode: "EUR")
    }
}
