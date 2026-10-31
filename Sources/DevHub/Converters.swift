import Foundation

// MARK: cron

enum Cron {
    struct Spec {
        var minutes: Set<Int>, hours: Set<Int>, dom: Set<Int>, months: Set<Int>, dow: Set<Int>
        var domStar: Bool, dowStar: Bool
    }

    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let dowNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    static func field(_ text: String, _ lo: Int, _ hi: Int, names: [String] = [], nameBase: Int = 0) -> Set<Int>? {
        var out = Set<Int>()
        func num(_ s: String) -> Int? {
            if let n = Int(s) { return n }
            if let i = names.firstIndex(of: s.lowercased()) { return i + nameBase }
            return nil
        }
        for part in text.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            var range = part
            var step = 1
            if let slash = part.firstIndex(of: "/") {
                guard let st = Int(part[part.index(after: slash)...]), st > 0 else { return nil }
                step = st
                range = String(part[..<slash])
            }
            var a = lo, b = hi
            if range == "*" || range == "?" {
            } else if let dash = range.firstIndex(of: "-") {
                guard let x = num(String(range[..<dash])), let y = num(String(range[range.index(after: dash)...])) else { return nil }
                a = x; b = y
            } else if let x = num(range) {
                a = x
                b = part.contains("/") ? hi : x
            } else { return nil }
            guard a >= lo, b <= hi, a <= b else { return nil }
            var v = a
            while v <= b { out.insert(v); v += step }
        }
        return out.isEmpty ? nil : out
    }

    static func parse(_ expr: String) -> Spec? {
        let f = expr.split(whereSeparator: \.isWhitespace).map(String.init)
        guard f.count == 5,
              let mi = field(f[0], 0, 59), let h = field(f[1], 0, 23),
              let d = field(f[2], 1, 31), let mo = field(f[3], 1, 12, names: monthNames, nameBase: 1),
              var w = field(f[4], 0, 7, names: dowNames) else { return nil }
        if w.contains(7) { w.remove(7); w.insert(0) }
        return Spec(minutes: mi, hours: h, dom: d, months: mo, dow: w, domStar: f[2] == "*" || f[2] == "?", dowStar: f[4] == "*" || f[4] == "?")
    }

    static func matches(_ s: Spec, _ c: DateComponents) -> Bool {
        guard let mi = c.minute, let h = c.hour, let d = c.day, let mo = c.month, let wd = c.weekday else { return false }
        guard s.minutes.contains(mi), s.hours.contains(h), s.months.contains(mo) else { return false }
        let domOK = s.dom.contains(d), dowOK = s.dow.contains(wd - 1)
        if s.domStar && s.dowStar { return true }
        if s.domStar { return dowOK }
        if s.dowStar { return domOK }
        return domOK || dowOK
    }

    static func nextRuns(_ expr: String, count: Int, from: Date = Date(), calendar: Calendar = .current) -> [Date] {
        guard let s = parse(expr) else { return [] }
        var t = calendar.date(bySetting: .second, value: 0, of: from) ?? from
        t = t.addingTimeInterval(60)
        var out: [Date] = []
        var guardCount = 0
        while out.count < count && guardCount < 60 * 24 * 366 * 2 {
            let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: t)
            if matches(s, c) { out.append(t) }
            t = t.addingTimeInterval(60)
            guardCount += 1
        }
        return out
    }

    static func explain(_ expr: String) -> String {
        let f = expr.split(whereSeparator: \.isWhitespace).map(String.init)
        guard f.count == 5, parse(expr) != nil else { return "Invalid cron. Use 5 fields: minute hour day-of-month month day-of-week" }
        func d(_ t: String, _ unit: String, names: [String] = []) -> String {
            if t == "*" || t == "?" { return "every \(unit)" }
            if t.hasPrefix("*/") { return "every \(t.dropFirst(2)) \(unit)s" }
            return "\(unit) \(t)"
        }
        let dowText = f[4] == "*" ? "any weekday" : f[4].lowercased().split(separator: ",").map { p -> String in
            let full = ["sun": "Sunday", "mon": "Monday", "tue": "Tuesday", "wed": "Wednesday", "thu": "Thursday", "fri": "Friday", "sat": "Saturday"]
            let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            return String(p).split(separator: "-").map { x in full[String(x.prefix(3))] ?? (Int(x).map { names[$0 % 8] } ?? String(x)) }.joined(separator: "–")
        }.joined(separator: ", ")
        var lines = [
            "minute:        \(d(f[0], "minute"))",
            "hour:          \(d(f[1], "hour"))",
            "day of month:  \(d(f[2], "day"))",
            "month:         \(d(f[3], "month"))",
            "day of week:   \(dowText)",
        ]
        if f[0].allSatisfy(\.isNumber), f[1].allSatisfy(\.isNumber), let m = Int(f[0]), let h = Int(f[1]) {
            lines.insert(String(format: "Runs at %02d:%02d", h, m) + (f[2] == "*" && f[4] == "*" ? " every day" : ""), at: 0)
            lines.insert("", at: 1)
        }
        return lines.joined(separator: "\n")
    }

    static func report(_ expr: String) -> String {
        let e = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { return "Enter a 5-field cron, e.g. */15 9-17 * * 1-5" }
        let runs = nextRuns(e, count: 5)
        guard !runs.isEmpty else { return explain(e) }
        let f = DateFormatter()
        f.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return explain(e) + "\n\nNext 5 runs (local time):\n" + runs.map { "  " + f.string(from: $0) }.joined(separator: "\n")
    }
}

// MARK: SQL formatter

enum SQLFormat {
    static let clauses = ["SELECT", "FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET", "UNION ALL", "UNION", "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "RETURNING", "WITH",
                          "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN", "CROSS JOIN", "FULL JOIN", "JOIN"]
    static let keywords: Set<String> = ["AS", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE", "ILIKE", "BETWEEN", "EXISTS", "CASE", "WHEN", "THEN", "ELSE", "END", "DISTINCT", "ON", "ASC", "DESC", "BY", "ALL", "ANY", "TRUE", "FALSE", "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "CAST", "USING", "INTERVAL"]

    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        let c = Array(s)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }
            if ch == "'" || ch == "\"" || ch == "`" {
                var j = i + 1
                while j < c.count && !(c[j] == ch && !(j + 1 < c.count && c[j + 1] == ch)) { j += (c[j] == ch ? 2 : 1) }
                out.append(String(c[i..<min(j + 1, c.count)])); i = j + 1; continue
            }
            if ch == "-" && i + 1 < c.count && c[i + 1] == "-" {
                var j = i
                while j < c.count && c[j] != "\n" { j += 1 }
                out.append(String(c[i..<j])); i = j; continue
            }
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "$" {
                var j = i
                while j < c.count && (c[j].isLetter || c[j].isNumber || c[j] == "_" || c[j] == "$" || c[j] == ".") { j += 1 }
                out.append(String(c[i..<j])); i = j; continue
            }
            if "<>=!:".contains(ch), i + 1 < c.count, "=>:".contains(c[i + 1]) { out.append(String(c[i...i + 1])); i += 2; continue }
            out.append(String(ch)); i += 1
        }
        return out
    }

    static func format(_ sql: String) -> String {
        let toks = tokenize(sql)
        var out = ""
        var depth = 0
        var clause = ""
        var i = 0
        func append(_ t: String, space: Bool) { out += (space && !out.isEmpty && !out.hasSuffix("\n") && !out.hasSuffix(" ") && !out.hasSuffix("(") && !out.hasSuffix(".") ? " " : "") + t }
        while i < toks.count {
            var t = toks[i]
            var matched: String?
            for cl in clauses {
                let words = cl.split(separator: " ").map(String.init)
                if i + words.count <= toks.count, zip(words, toks[i..<(i + words.count)]).allSatisfy({ $0 == $1.uppercased() }) { matched = cl; break }
            }
            if let cl = matched, depth == 0 {
                if !out.isEmpty { out += "\n" }
                out += cl
                clause = cl
                i += cl.split(separator: " ").count
                continue
            }
            let up = t.uppercased()
            if depth == 0, up == "AND" || up == "OR", ["WHERE", "HAVING", "ON"].contains(clause) || clause.contains("JOIN") {
                out += "\n  " + up; i += 1; continue
            }
            if depth == 0, up == "ON", clause.contains("JOIN") { out += "\n  ON"; i += 1; continue }
            if t == "(" { depth += 1; append(t, space: !out.hasSuffix("(")); i += 1; continue }
            if t == ")" { depth = max(0, depth - 1); out += ")"; i += 1; continue }
            if t == "," {
                out += ","
                if depth == 0 && ["SELECT", "SET", "GROUP BY", "ORDER BY"].contains(clause) { out += "\n  " }
                else { out += " " }
                i += 1; continue
            }
            if t == ";" { out += ";\n"; clause = ""; i += 1; continue }
            if keywords.contains(up) { t = up }
            if out.hasSuffix("\n  ") || out.hasSuffix(" ") || out.hasSuffix("\n") || out.isEmpty { out += t }
            else if t == "." || out.hasSuffix(".") { out += t }
            else { out += " " + t }
            i += 1
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: CSV / JSON / INSERT

enum CSVTool {
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let c = Array(text)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if quoted {
                if ch == "\"" { if i + 1 < c.count && c[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false } }
                else { field.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == "," { row.append(field); field = "" }
            else if ch == "\n" || ch == "\r" {
                if ch == "\r", i + 1 < c.count, c[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""
                rows.append(row); row = []
            } else { field.append(ch) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    static func infer(_ s: String) -> Any {
        if s.isEmpty { return NSNull() }
        if s == "true" { return true }
        if s == "false" { return false }
        if s.range(of: "^-?(0|[1-9]\\d*)(\\.\\d+)?$", options: .regularExpression) != nil, let d = Double(s) {
            return s.contains(".") ? d : (Int(s) ?? d)
        }
        return s
    }

    static func csvToObjects(_ text: String) -> [[String: Any]]? {
        let rows = parseCSV(text)
        guard let head = rows.first, rows.count > 1 else { return nil }
        return rows.dropFirst().map { r in
            var o: [String: Any] = [:]
            for (i, h) in head.enumerated() { o[h] = i < r.count ? infer(r[i]) : NSNull() }
            return o
        }
    }

    static func csvToJSON(_ text: String) -> String {
        guard let objs = csvToObjects(text) else { return "Need a header row and at least one data row" }
        let head = parseCSV(text).first ?? []
        // keep column order by emitting manually
        let items = objs.map { o in
            "  {" + head.map { h in "\"\(escape(h))\": \(jsonLiteral(o[h] ?? NSNull()))" }.joined(separator: ", ") + "}"
        }
        return "[\n" + items.joined(separator: ",\n") + "\n]"
    }

    static func jsonObjects(_ text: String) -> [[String: Any]]? {
        guard let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
        if let a = o as? [[String: Any]] { return a }
        if let one = o as? [String: Any] { return [one] }
        return nil
    }

    static func columns(_ objs: [[String: Any]]) -> [String] {
        var seen: [String] = []
        for o in objs { for k in o.keys.sorted() where !seen.contains(k) { seen.append(k) } }
        return seen
    }

    static func jsonToCSV(_ text: String) -> String {
        guard let objs = jsonObjects(text) else { return "Need a JSON array of objects" }
        let cols = columns(objs)
        func cell(_ v: Any?) -> String {
            guard let v, !(v is NSNull) else { return "" }
            let s: String
            if let str = v as? String { s = str } else if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v), let j = String(data: d, encoding: .utf8) { s = j } else { s = "\(v)" }
            return s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        return ([cols.joined(separator: ",")] + objs.map { o in cols.map { cell(o[$0]) }.joined(separator: ",") }).joined(separator: "\n")
    }

    static func sqlLiteral(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "NULL" }
        if let n = v as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "TRUE" : "FALSE") : "\(n)" }
        let s = (v as? String) ?? ((try? JSONSerialization.data(withJSONObject: v)).flatMap { String(data: $0, encoding: .utf8) } ?? "\(v)")
        return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func inserts(_ objs: [[String: Any]], table: String, head: [String]? = nil) -> String {
        let cols = head ?? columns(objs)
        let t = table.isEmpty ? "my_table" : table
        return objs.map { o in
            "INSERT INTO \(t) (\(cols.joined(separator: ", "))) VALUES (\(cols.map { sqlLiteral(o[$0]) }.joined(separator: ", ")));"
        }.joined(separator: "\n")
    }

    static func csvToInserts(_ text: String, table: String) -> String {
        guard let objs = csvToObjects(text) else { return "Need a header row and at least one data row" }
        return inserts(objs, table: table, head: parseCSV(text).first)
    }

    static func jsonToInserts(_ text: String, table: String) -> String {
        guard let objs = jsonObjects(text) else { return "Need a JSON array of objects" }
        return inserts(objs, table: table)
    }

    static func jsonLiteral(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if let b = v as? Bool { return b ? "true" : "false" }
        if let i = v as? Int { return String(i) }
        if let d = v as? Double { return String(d) }
        return "\"\(escape("\(v)"))\""
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: JSON -> TypeScript

enum TSGen {
    static func generate(_ json: String, rootName: String = "Root") -> String {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else {
            return json.isEmpty ? "" : "Invalid JSON"
        }
        var g = Gen()
        let t = g.typeFor([o], rootName)
        if g.order.isEmpty { return "type \(rootName) = \(t);" }
        if t != rootName { g.out[rootName] = "type \(rootName) = \(t);"; g.order.append(rootName) }
        return g.order.map { g.out[$0]! }.joined(separator: "\n\n")
    }

    struct Gen {
        var out: [String: String] = [:]
        var order: [String] = []

        mutating func typeFor(_ values: [Any], _ name: String) -> String {
            var types: [String] = []
            var dicts: [[String: Any]] = []
            var arrays: [Any] = []
            var hasArray = false
            func add(_ t: String) { if !types.contains(t) { types.append(t) } }
            for v in values {
                if v is NSNull { add("null") }
                else if let n = v as? NSNumber { add(CFGetTypeID(n) == CFBooleanGetTypeID() ? "boolean" : "number") }
                else if v is String { add("string") }
                else if let d = v as? [String: Any] { dicts.append(d) }
                else if let a = v as? [Any] { hasArray = true; arrays.append(contentsOf: a) }
            }
            if !dicts.isEmpty { add(interface(dicts, name)) }
            if hasArray {
                let el = arrays.isEmpty ? "unknown" : typeFor(arrays, singular(name))
                add(el.contains(" | ") ? "(\(el))[]" : "\(el)[]")
            }
            return types.joined(separator: " | ")
        }

        mutating func interface(_ dicts: [[String: Any]], _ name: String) -> String {
            var keys: [String] = []
            for d in dicts { for k in d.keys.sorted() where !keys.contains(k) { keys.append(k) } }
            var n = pascal(name)
            var i = 2
            while out[n] != nil { n = pascal(name) + String(i); i += 1 }
            out[n] = ""
            order.append(n)
            var lines: [String] = []
            for k in keys {
                let vals = dicts.compactMap { $0[k] }
                let t = typeFor(vals, k)
                let key = k.range(of: "^[A-Za-z_$][\\w$]*$", options: .regularExpression) != nil ? k : "\"\(k)\""
                lines.append("  \(key)\(vals.count < dicts.count ? "?" : ""): \(t);")
            }
            out[n] = "interface \(n) {\n" + lines.joined(separator: "\n") + "\n}"
            return n
        }

        func pascal(_ s: String) -> String {
            let parts = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            let r = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            return r.isEmpty ? "Item" : (r.first!.isNumber ? "T" + r : r)
        }

        func singular(_ s: String) -> String {
            if s.hasSuffix("ies") { return String(s.dropLast(3)) + "y" }
            if s.hasSuffix("s") && s.count > 1 { return String(s.dropLast()) }
            return s + "Item"
        }
    }
}
