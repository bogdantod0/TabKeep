import Foundation

/// Wraps a Decimal so it can be Codable as a JSON String — required by the
/// Rails backend, which serializes numeric(20,4) columns via `to_s("F")`
/// (e.g. "42.5000") to preserve precision across JSON's binary-float limit.
struct DecimalString: Codable, Hashable {
    let value: Decimal

    init(_ value: Decimal) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let str = try c.decode(String.self)
        guard let d = Decimal(string: str, locale: Locale(identifier: "en_US_POSIX")) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid decimal string \(str)")
        }
        self.value = d
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        // 4 fractional digits matches the backend's numeric(20,4) precision.
        var copy = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &copy, 4, .plain)
        var s = "\(rounded)"
        if !s.contains(".") { s.append(".0000") }
        try c.encode(s)
    }
}
