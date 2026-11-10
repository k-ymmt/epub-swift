import Foundation

/// URL and path handling for annotation `source` values and body URLs (06-annotations §6.1, §11).
enum AnnotationPath {
    /// `scheme:…` (an absolute URL) rather than a relative URL.
    static func isAbsoluteURL(_ string: String) -> Bool {
        guard let colon = string.firstIndex(of: ":") else { return false }
        let scheme = string[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }

    /// A `source` as read: percent-decoded unless it is an absolute URL (kept as written).
    static func decodedSource(_ string: String) -> String {
        if isAbsoluteURL(string) { return string }
        return string.removingPercentEncoding ?? string
    }

    /// A `source` as written: the container path percent-encoded; absolute URLs as they are.
    static func encodedSource(_ source: String) -> String {
        if isAbsoluteURL(source) { return source }
        return ContainerPath.percentEncoded(source)
    }

    /// Resolves a relative path against `base` (a directory path, "" for the root) without leaving it. nil for
    /// absolute URLs, absolute paths (`/…`), and paths whose `..` segments climb above the root (§6.1; the
    /// specification's §11.3 path traversal). The path is expected percent-decoded; a fragment or query is cut.
    static func resolveContained(_ path: String, base: String = "") -> String? {
        var path = path
        if let cut = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = String(path[..<cut]) }
        guard !path.isEmpty, !isAbsoluteURL(path), !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return nil }
        var segments: [Substring] = base.split(separator: "/", omittingEmptySubsequences: true)
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." { continue }
            if segment == ".." {
                guard !segments.isEmpty else { return nil }
                segments.removeLast()
                continue
            }
            segments.append(segment)
        }
        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: "/")
    }
}

/// ISO 8601 / W3CDTF date-times for annotation documents.
enum AnnotationDate {
    /// Accepts `YYYY`, `YYYY-MM`, `YYYY-MM-DD`, and `YYYY-MM-DDThh:mm[:ss[.fff…]]` with `Z`, `±hh:mm`, `±hhmm` or
    /// no zone (UTC). Returns nil for anything else.
    static func parse(_ string: String) -> Date? {
        let s = Array(string.trimmingCharacters(in: .whitespaces).utf8)
        var i = 0
        func number(_ count: Int) -> Int? {
            guard i + count <= s.count else { return nil }
            var value = 0
            for k in i..<(i + count) {
                guard s[k] >= 0x30, s[k] <= 0x39 else { return nil }
                value = value * 10 + Int(s[k] - 0x30)
            }
            i += count
            return value
        }
        func accept(_ c: Character) -> Bool {
            if i < s.count, s[i] == c.asciiValue! { i += 1; return true }
            return false
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        guard let year = number(4) else { return nil }
        components.year = year
        components.month = 1
        components.day = 1
        var fraction = 0.0
        if accept("-") {
            guard let month = number(2), (1...12).contains(month) else { return nil }
            components.month = month
            if accept("-") {
                guard let day = number(2), (1...31).contains(day) else { return nil }
                components.day = day
                if accept("T") || accept("t") || accept(" ") {
                    guard let hour = number(2), hour <= 24, accept(":"), let minute = number(2), minute < 60 else { return nil }
                    components.hour = hour
                    components.minute = minute
                    if accept(":") {
                        guard let second = number(2), second <= 60 else { return nil }
                        components.second = second
                        if accept(".") || accept(",") {
                            var digits = ""
                            while i < s.count, s[i] >= 0x30, s[i] <= 0x39 { digits.append(Character(UnicodeScalar(s[i]))); i += 1 }
                            guard !digits.isEmpty else { return nil }
                            fraction = Double("0." + digits) ?? 0
                        }
                    }
                    if accept("Z") || accept("z") {
                        // UTC
                    } else if i < s.count, s[i] == 0x2B || s[i] == 0x2D {
                        let sign = s[i] == 0x2D ? -1 : 1
                        i += 1
                        guard let zh = number(2) else { return nil }
                        _ = accept(":")
                        let zm = number(2) ?? 0
                        components.timeZone = TimeZone(secondsFromGMT: sign * (zh * 3600 + zm * 60))
                    }
                }
            }
        }
        guard i == s.count, let date = components.date else { return nil }
        guard fraction > 0 else { return date }
        // Milliseconds as (whole ms) / 1000, the same double `Annotation.truncated` produces, so a stored date
        // reads back equal.
        let millis = (date.timeIntervalSince1970 * 1000).rounded() + (fraction * 1000).rounded(.down)
        let rest = fraction * 1000 - (fraction * 1000).rounded(.down)
        return Date(timeIntervalSince1970: millis / 1000 + rest / 1000)
    }

    enum Precision {
        case day, second, millisecond
    }

    /// `2026-11-10T01:02:03Z` (UTC). `.day` writes the start of the UTC day; `.millisecond` adds `.fff` when the
    /// time has a fractional part.
    static func format(_ date: Date, precision: Precision) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ v: Int?, _ width: Int) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        let day = "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2))"
        switch precision {
        case .day:
            return day + "T00:00:00Z"
        case .second:
            return day + "T\(pad(c.hour, 2)):\(pad(c.minute, 2)):\(pad(c.second, 2))Z"
        case .millisecond:
            let seconds = date.timeIntervalSince1970
            let millis = Int(((seconds - seconds.rounded(.down)) * 1000).rounded())
            let base = day + "T\(pad(c.hour, 2)):\(pad(c.minute, 2)):\(pad(c.second, 2))"
            if millis == 0 || millis >= 1000 { return base + "Z" }
            return base + "." + pad(millis, 3) + "Z"
        }
    }

    /// The date as written at `precision` and read back (the value an exported file carries).
    static func rounded(_ date: Date, precision: Precision) -> Date {
        parse(format(date, precision: precision)) ?? date
    }
}
