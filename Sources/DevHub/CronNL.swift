import Foundation

/// Rule-based English → cron (5 fields). Covers common phrasings; returns nil when nothing is understood.
enum CronNL {
    struct Result { var expr: String; var warnings: [String] }

    private static let dowWords: [(String, Int)] = [
        ("sunday", 0), ("monday", 1), ("tuesday", 2), ("wednesday", 3), ("thursday", 4), ("friday", 5), ("saturday", 6),
        ("sun", 0), ("mon", 1), ("tue", 2), ("tues", 2), ("wed", 3), ("thu", 4), ("thur", 4), ("thurs", 4), ("fri", 5), ("sat", 6),
    ]
    private static let monthWords: [(String, Int)] = [
        ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("june", 6), ("july", 7), ("august", 8),
        ("september", 9), ("october", 10), ("november", 11), ("december", 12),
        ("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4), ("jun", 6), ("jul", 7), ("aug", 8), ("sep", 9), ("sept", 9), ("oct", 10), ("nov", 11), ("dec", 12),
    ]
    private static let ordinals: [String: Int] = ["first": 1, "second": 2, "third": 3, "fifth": 5, "tenth": 10, "fifteenth": 15]

    private static func match(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }

    private static func allMatches(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
        }
    }

    private static func to24(_ h: Int, _ ap: String) -> Int {
        if ap == "pm" { return h == 12 ? 12 : h + 12 }
        if ap == "am" { return h == 12 ? 0 : h }
        return h
    }

    /// Finds clock times like "9am", "5:30 pm", "at 14:00", "midnight", "noon".
    private static func times(in s: String) -> [(h: Int, m: Int)] {
        var out: [(Int, Int)] = []
        var rest = s
        for g in allMatches(#"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)"#, in: s) {
            let ap = g[3].hasPrefix("a") ? "am" : "pm"
            out.append((to24(Int(g[1]) ?? 0, ap), Int(g[2]) ?? 0))
        }
        rest = rest.replacingOccurrences(of: #"\b\d{1,2}(?::\d{2})?\s*(am|pm|a\.m\.|p\.m\.)"#, with: " ", options: .regularExpression)
        for g in allMatches(#"\b(\d{1,2}):(\d{2})\b"#, in: rest) { out.append((Int(g[1]) ?? 0, Int(g[2]) ?? 0)) }
        rest = rest.replacingOccurrences(of: #"\b\d{1,2}:\d{2}\b"#, with: " ", options: .regularExpression)
        for g in allMatches(#"\bat\s+(\d{1,2})\b(?!\s*(?:minutes?|hours?|days?|st|nd|rd|th))"#, in: rest) { out.append((Int(g[1]) ?? 0, 0)) }
        if s.contains("midnight") { out.append((0, 0)) }
        if s.contains("noon") || s.contains("midday") { out.append((12, 0)) }
        return out.filter { $0.0 < 24 && $0.1 < 60 }
    }

    static func parse(_ input: String) -> Result? {
        var s = " " + input.lowercased().replacingOccurrences(of: ",", with: " ") + " "
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        var minute = "*", hour = "*", dom = "*", month = "*", dow = "*"
        var warnings: [String] = []
        var understood = false
        var minuteExplicit = false, hourExplicit = false, dayLevel = false

        // intervals
        if match(#"\bevery\s+(?:other\s+)?second\b|\bevery\s+\d+\s+seconds?\b"#, in: s) != nil {
            warnings.append("Cron has no seconds field; the smallest step is 1 minute.")
            minute = "*"; minuteExplicit = true; hourExplicit = true; understood = true
        }
        if let g = match(#"\bevery\s+(?:(\d+)\s+|(other)\s+)?minutes?\b"#, in: s) {
            let n = g[2] == "other" ? 2 : (Int(g[1]) ?? 1)
            minute = n > 1 ? "*/\(n)" : "*"
            minuteExplicit = true; hourExplicit = true; understood = true
        } else if s.contains("every minute") || s.contains("each minute") || s.contains("minutely") {
            minute = "*"; minuteExplicit = true; hourExplicit = true; understood = true
        }
        if let g = match(#"\bevery\s+(?:(\d+)\s+|(other)\s+)?hours?\b"#, in: s) {
            let n = g[2] == "other" ? 2 : (Int(g[1]) ?? 1)
            hour = n > 1 ? "*/\(n)" : "*"
            if !minuteExplicit { minute = "0" }
            hourExplicit = true; understood = true
        } else if s.contains("hourly") || s.contains("each hour") {
            if !minuteExplicit { minute = "0" }
            hourExplicit = true; understood = true
        }
        if let g = match(#"\b(\d{1,2})\s+minutes?\s+(?:past|after)\b"#, in: s) {
            minute = g[1]; minuteExplicit = true; understood = true
            if !hourExplicit { hourExplicit = true }
        }

        // between X and Y
        if let g = match(#"\bbetween\s+(.+?)\s+and\s+(.+?)(?:\s+(?:on|every|each|daily|during|in)\b|\s*$)"#, in: s) {
            let a = times(in: g[1].contains("at") ? g[1] : "at " + g[1]) + times(in: g[1])
            let b = times(in: g[2].contains("at") ? g[2] : "at " + g[2]) + times(in: g[2])
            if let from = a.first, let to = b.first {
                let step = hour.hasPrefix("*/") ? String(hour.dropFirst(1)) : ""
                hour = "\(from.h)-\(to.h)" + step
                hourExplicit = true; understood = true
                if !minuteExplicit { minute = String(from.m); minuteExplicit = true }
            }
        }

        // clock times
        if !hourExplicit {
            let ts = times(in: s)
            if !ts.isEmpty {
                let ms = Set(ts.map(\.m))
                if ms.count > 1 { warnings.append("Different minutes per time can't be one cron line; used \(ts[0].m) for all.") }
                minute = String(ts[0].m)
                hour = Array(Set(ts.map(\.h))).sorted().map(String.init).joined(separator: ",")
                hourExplicit = true; minuteExplicit = true; understood = true
            }
        }

        // shortcuts
        if s.contains("daily") || s.contains("every day") || s.contains("everyday") || s.contains("each day") || s.contains("nightly") { understood = true; dayLevel = true }
        if s.contains("weekly") || s.contains("every week") { understood = true; dayLevel = true; if dow == "*" { dow = "0" } }
        if s.contains("monthly") || s.contains("every month") || s.contains("each month") { understood = true; dayLevel = true; if dom == "*" { dom = "1" } }
        if s.contains("yearly") || s.contains("annually") || s.contains("every year") { understood = true; dayLevel = true; dom = "1"; month = "1" }
        if s.contains("quarter") { understood = true; dayLevel = true; dom = "1"; month = "*/3" }
        if let g = match(#"\bevery\s+(?:(\d+)\s+|(other)\s+)days?\b"#, in: s) {
            let n = g[2] == "other" ? 2 : (Int(g[1]) ?? 1)
            if n > 1 { dom = "*/\(n)" }
            understood = true; dayLevel = true
        }

        // weekdays
        if s.contains("weekday") { dow = "1-5"; understood = true; dayLevel = true }
        else if s.contains("weekend") { dow = "0,6"; understood = true; dayLevel = true }
        else {
            let names = dowWords.map(\.0).sorted { $0.count > $1.count }.joined(separator: "|")
            if let g = match(#"\b(\#(names))s?\b\s*(?:to|through|thru|until|-)\s*\b(\#(names))s?\b"#, in: s),
               let a = dowWords.first(where: { $0.0 == g[1] })?.1, let b = dowWords.first(where: { $0.0 == g[2] })?.1 {
                dow = "\(a)-\(b)"; understood = true; dayLevel = true
            } else {
                var found: [Int] = []
                for g in allMatches(#"\b(\#(names))s?\b"#, in: s) {
                    if let d = dowWords.first(where: { $0.0 == g[1] })?.1, !found.contains(d) { found.append(d) }
                }
                if !found.isEmpty { dow = found.sorted().map(String.init).joined(separator: ","); understood = true; dayLevel = true }
            }
        }

        // day of month
        var days: [Int] = []
        for g in allMatches(#"\b(\d{1,2})(?:st|nd|rd|th)\b"#, in: s) { if let d = Int(g[1]), (1...31).contains(d) { days.append(d) } }
        for (w, n) in ordinals where s.contains("\(w) day") || s.contains("the \(w) of") { days.append(n) }
        if s.contains("last day") { warnings.append("Standard cron has no 'last day of month'; using 28 (use a month-end check in the script for exact behaviour).") ; days.append(28) }
        if !days.isEmpty { dom = Array(Set(days)).sorted().map(String.init).joined(separator: ","); understood = true; dayLevel = true }

        // months
        let monthNames = monthWords.map(\.0).sorted { $0.count > $1.count }.joined(separator: "|")
        var months: [Int] = []
        for g in allMatches(#"\b(\#(monthNames))\b"#, in: s) { if let m = monthWords.first(where: { $0.0 == g[1] })?.1, !months.contains(m) { months.append(m) } }
        if !months.isEmpty { month = months.sorted().map(String.init).joined(separator: ","); understood = true; dayLevel = true }

        guard understood else { return nil }
        if dayLevel && !hourExplicit { hour = "0" }
        if dayLevel && !minuteExplicit { minute = "0" }
        if dayLevel && hour == "*" && !hourExplicit { hour = "0" }
        return Result(expr: [minute, hour, dom, month, dow].joined(separator: " "), warnings: warnings)
    }

    static func report(_ input: String) -> String {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "Describe a schedule, e.g.:\n  every 5 minutes\n  every weekday at 8:30am\n  every monday and friday at 2pm\n  1st of every month at midnight\n  every 15 minutes between 9am and 5pm on weekdays\n  every 2 hours\n  every sunday at 3:30 pm in june" }
        guard let r = parse(t) else { return "Couldn't understand that. Try: \"every 10 minutes\", \"daily at 6am\", \"every friday at 17:00\"." }
        var out = "Cron:  \(r.expr)\n\n" + Cron.report(r.expr)
        if !r.warnings.isEmpty { out += "\n\nNotes:\n" + r.warnings.map { "• \($0)" }.joined(separator: "\n") }
        return out
    }
}
