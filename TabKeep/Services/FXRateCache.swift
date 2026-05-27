import Foundation

final class FXRateCache {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.tabkeep.fxcache", attributes: .concurrent)
    private var index: [String: FXRate] = [:]
    private var loaded = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func defaultURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("fx-rates.json")
    }

    func rate(from: String, to: String, on date: Date) -> Decimal? {
        ensureLoaded()
        let key = Self.key(from: from, to: to, date: date)
        return queue.sync { index[key]?.rate }
    }

    func store(rate: Decimal, from: String, to: String, on date: Date) {
        ensureLoaded()
        let entry = FXRate(
            from: from,
            to: to,
            date: Self.startOfDay(date),
            rate: rate,
            fetchedAt: Date()
        )
        let key = Self.key(from: from, to: to, date: date)
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.index[key] = entry
            self.persist()
        }
    }

    private func ensureLoaded() {
        queue.sync(flags: .barrier) {
            guard !loaded else { return }
            loaded = true
            guard let data = try? Data(contentsOf: fileURL) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let entries = try? decoder.decode([FXRate].self, from: data) else { return }
            for entry in entries {
                index[Self.key(from: entry.from, to: entry.to, date: entry.date)] = entry
            }
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let entries = Array(index.values)
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func key(from: String, to: String, date: Date) -> String {
        let iso = startOfDayFormatter.string(from: startOfDay(date))
        return "\(from.uppercased())>\(to.uppercased())@\(iso)"
    }

    private static func startOfDay(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal.startOfDay(for: date)
    }

    private static let startOfDayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
}
