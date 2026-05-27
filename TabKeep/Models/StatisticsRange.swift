import Foundation

/// Period selector for the Statistics tab. `interval(now:)` returns `nil`
/// for `.allTime` — the aggregator treats `nil` as "no filter".
enum StatisticsRange: Hashable {
    case month
    case year
    case allTime
    /// User-picked start / end (inclusive of `interval.start`, exclusive of
    /// `interval.end`, matching `DateInterval.contains` semantics).
    case custom(DateInterval)

    /// The three preset cases, in display order. Used to populate the picker
    /// — `.custom` is offered as a separate calendar control because it
    /// carries an associated value and can't sit alongside the presets.
    static let presets: [StatisticsRange] = [.month, .year, .allTime]

    var title: String {
        switch self {
        case .month:   return "Month"
        case .year:    return "Year"
        case .allTime: return "All time"
        case .custom:  return "Custom"
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// Bucket size used by the trend chart for this range. Custom ranges
    /// shorter than ~60 days bucket daily; longer than that bucket monthly,
    /// matching the heuristic used for `.month` vs `.year` / `.allTime`.
    var bucketGranularity: Calendar.Component {
        switch self {
        case .month:                return .day
        case .year, .allTime:       return .month
        case .custom(let interval): return interval.duration <= 60 * 86_400 ? .day : .month
        }
    }

    /// Inclusive period interval. `nil` for `.allTime`.
    func interval(now: Date, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .month:
            return calendar.dateInterval(of: .month, for: now)
        case .year:
            return calendar.dateInterval(of: .year, for: now)
        case .allTime:
            return nil
        case .custom(let interval):
            return interval
        }
    }

    /// Period immediately before `interval(now:)`, used to compute the
    /// hero delta. `nil` for `.allTime` and when no prior period exists.
    /// For `.custom`, returns an equal-length window ending at the custom
    /// range's start.
    func previousInterval(now: Date, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .month, .year:
            guard let current = interval(now: now, calendar: calendar) else { return nil }
            let priorReference = calendar.date(byAdding: bucketUnit, value: -1, to: current.start) ?? current.start
            switch self {
            case .month:   return calendar.dateInterval(of: .month, for: priorReference)
            case .year:    return calendar.dateInterval(of: .year, for: priorReference)
            default:       return nil
            }
        case .allTime:
            return nil
        case .custom(let interval):
            let priorEnd = interval.start
            let priorStart = priorEnd.addingTimeInterval(-interval.duration)
            return DateInterval(start: priorStart, end: priorEnd)
        }
    }

    /// Localised title shown next to the hero amount. Examples: "May 2026",
    /// "2026", "All time", "May 1 – 15".
    func displayTitle(now: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .month:
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = .current
            f.setLocalizedDateFormatFromTemplate("MMMM y")
            return f.string(from: now)
        case .year:
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = .current
            f.setLocalizedDateFormatFromTemplate("y")
            return f.string(from: now)
        case .allTime:
            return "All time"
        case .custom(let interval):
            return formattedRange(start: interval.start, end: interval.end - 1, calendar: calendar)
        }
    }

    /// Stable string fingerprint suitable for `task(id:)`.
    var taskKey: String {
        switch self {
        case .month:   return "month"
        case .year:    return "year"
        case .allTime: return "allTime"
        case .custom(let interval):
            return "custom-\(Int(interval.start.timeIntervalSince1970))-\(Int(interval.end.timeIntervalSince1970))"
        }
    }

    /// Internal helper: which calendar unit to step backwards to land in
    /// the prior period.
    private var bucketUnit: Calendar.Component {
        switch self {
        case .month:                return .month
        case .year:                 return .year
        case .allTime, .custom:     return .year
        }
    }

    private func formattedRange(start: Date, end: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .current
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        let sameMonth = sameYear && calendar.component(.month, from: start) == calendar.component(.month, from: end)
        let nowYear = calendar.component(.year, from: Date())
        let endYear = calendar.component(.year, from: end)
        let needsYear = !sameYear || endYear != nowYear

        if sameMonth {
            f.setLocalizedDateFormatFromTemplate(needsYear ? "MMM d y" : "MMM d")
            let startDay = calendar.component(.day, from: start)
            let suffix = f.string(from: end)
            return "\(startDay) – \(suffix)"
        } else {
            f.setLocalizedDateFormatFromTemplate("MMM d")
            let startStr = f.string(from: start)
            f.setLocalizedDateFormatFromTemplate(needsYear ? "MMM d y" : "MMM d")
            let endStr = f.string(from: end)
            return "\(startStr) – \(endStr)"
        }
    }
}
