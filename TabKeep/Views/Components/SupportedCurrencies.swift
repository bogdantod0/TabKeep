import Foundation

struct SupportedCurrency: Hashable {
    let code: String
    let name: String
}

enum SupportedCurrencies {
    static let all: [SupportedCurrency] = [
        .init(code: "AUD", name: "Australian Dollar"),
        .init(code: "BGN", name: "Bulgarian Lev"),
        .init(code: "BRL", name: "Brazilian Real"),
        .init(code: "CAD", name: "Canadian Dollar"),
        .init(code: "CHF", name: "Swiss Franc"),
        .init(code: "CNY", name: "Chinese Yuan"),
        .init(code: "CZK", name: "Czech Koruna"),
        .init(code: "DKK", name: "Danish Krone"),
        .init(code: "EUR", name: "Euro"),
        .init(code: "GBP", name: "British Pound"),
        .init(code: "HKD", name: "Hong Kong Dollar"),
        .init(code: "HUF", name: "Hungarian Forint"),
        .init(code: "IDR", name: "Indonesian Rupiah"),
        .init(code: "ILS", name: "Israeli New Shekel"),
        .init(code: "INR", name: "Indian Rupee"),
        .init(code: "ISK", name: "Icelandic Króna"),
        .init(code: "JPY", name: "Japanese Yen"),
        .init(code: "KRW", name: "South Korean Won"),
        .init(code: "MXN", name: "Mexican Peso"),
        .init(code: "MYR", name: "Malaysian Ringgit"),
        .init(code: "NOK", name: "Norwegian Krone"),
        .init(code: "NZD", name: "New Zealand Dollar"),
        .init(code: "PHP", name: "Philippine Peso"),
        .init(code: "PLN", name: "Polish Zloty"),
        .init(code: "RON", name: "Romanian Leu"),
        .init(code: "SEK", name: "Swedish Krona"),
        .init(code: "SGD", name: "Singapore Dollar"),
        .init(code: "THB", name: "Thai Baht"),
        .init(code: "TRY", name: "Turkish Lira"),
        .init(code: "USD", name: "US Dollar"),
        .init(code: "ZAR", name: "South African Rand"),
    ]

    static func isSupported(_ code: String) -> Bool {
        all.contains { $0.code == code }
    }

    static func name(for code: String) -> String? {
        all.first { $0.code == code }?.name
    }

    /// The short curated list exposed through the picker UIs
    /// (create-group, edit-group, onboarding, settings). Kept intentionally
    /// small; `.all` is wider and is what the FX service validates against.
    static let displayList: [String] = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CHF", "RON"]

    /// A compact human-readable symbol for a code. Falls back to the 3-letter
    /// ISO code itself for any currency without a curated glyph (avoids the
    /// generic "¤" placeholder).
    static func symbol(for code: String) -> String {
        switch code {
        case "USD", "CAD", "AUD", "NZD", "HKD", "SGD", "MXN": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY", "CNY": return "¥"
        case "CHF": return "Fr"
        case "RON": return "lei"
        case "INR": return "₹"
        case "KRW": return "₩"
        case "TRY": return "₺"
        case "ILS": return "₪"
        case "PHP": return "₱"
        case "THB": return "฿"
        case "PLN": return "zł"
        case "BRL": return "R$"
        case "ZAR": return "R"
        case "NOK", "SEK", "DKK", "ISK": return "kr"
        case "CZK": return "Kč"
        case "HUF": return "Ft"
        case "IDR": return "Rp"
        case "MYR": return "RM"
        case "BGN": return "лв"
        default: return code
        }
    }

    /// Display name (e.g. "US Dollar") preferring the current locale's
    /// localization, with an English fallback from `all`.
    static func displayName(for code: String) -> String {
        if let localized = Locale.current.localizedString(forCurrencyCode: code), !localized.isEmpty {
            return localized.capitalized(with: Locale.current)
        }
        return name(for: code) ?? code
    }
}
