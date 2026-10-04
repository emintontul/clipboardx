import Foundation

public struct ParsedQuery: Equatable, Sendable {
    public var text: String
    public var filters: ClipFilters
}

/// Pulls filters out of a search string: `type:link`, `app:Safari`, `after:2026-09-01`, `before:…`, and the phrases
/// `today`, `yesterday`, `last week`, `last month`. Everything else stays as text, so spaced or partial words still search.
public enum QueryParser {
    public static func parse(_ query: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedQuery {
        let tokens = query.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var filters = ClipFilters()
        var rest: [String] = []
        let startOfToday = calendar.startOfDay(for: now)
        func days(_ n: Int) -> Double { (calendar.date(byAdding: .day, value: -n, to: startOfToday) ?? startOfToday).timeIntervalSince1970 }

        var i = 0
        while i < tokens.count {
            let token = tokens[i], lower = token.lowercased()
            let next = i + 1 < tokens.count ? tokens[i + 1].lowercased() : ""
            if lower == "last", next == "week" { filters.after = days(7); i += 2; continue }
            if lower == "last", next == "month" { filters.after = days(30); i += 2; continue }
            if lower == "today" { filters.after = startOfToday.timeIntervalSince1970; i += 1; continue }
            if lower == "yesterday" { filters.after = days(1); filters.before = startOfToday.timeIntervalSince1970; i += 1; continue }
            if let value = value(of: "type:", in: token), let kind = ClipKind(rawValue: value.lowercased()) { filters.kinds.insert(kind); i += 1; continue }
            if let value = value(of: "app:", in: token), !value.isEmpty { filters.appName = value; i += 1; continue }
            if let value = value(of: "after:", in: token), let date = day(value, calendar) { filters.after = date; i += 1; continue }
            if let value = value(of: "before:", in: token), let date = day(value, calendar) { filters.before = date; i += 1; continue }
            rest.append(token)
            i += 1
        }
        return ParsedQuery(text: rest.joined(separator: " "), filters: filters)
    }

    private static func value(of prefix: String, in token: String) -> String? {
        token.lowercased().hasPrefix(prefix) ? String(token.dropFirst(prefix.count)) : nil
    }

    private static func day(_ text: String, _ calendar: Calendar) -> Double? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return date.timeIntervalSince1970
    }
}
