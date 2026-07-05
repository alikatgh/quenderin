import Foundation

// Additional offline, pure-logic agent tools. Like CalculatorTool, every entry
// point tolerates LLM-generated garbage and returns a message rather than
// throwing — the planner's input is never trusted.

// MARK: - Unit conversion

/// Converts between common units fully offline — length, temperature, mass,
/// volume, speed. Parses `"20 km to mi"`, `"30 C in F"`, `"5 kg to lb"`.
public struct UnitConverterTool: Capability {
    public init() {}
    public let name = "units"
    public let purpose = "Convert units, e.g. \"20 km to mi\", \"30 C to F\", \"5 kg to lb\", \"2 hours to minutes\"."

    public func run(_ input: String) async throws -> String {
        guard let req = UnitConverter.parse(input) else {
            return "Couldn't read a conversion from \"\(input)\". Try \"20 km to mi\"."
        }
        guard let result = UnitConverter.convert(value: req.value, from: req.from, to: req.to) else {
            return "Can't convert \(req.from) to \(req.to) — they measure different things."
        }
        return "\(UnitConverter.format(req.value)) \(req.from) = \(UnitConverter.format(result)) \(req.to)"
    }
}

/// A tiny offline unit engine: linear units convert through a per-dimension base
/// unit; temperature is affine and handled on its own. Unknown / cross-dimension
/// requests return nil.
enum UnitConverter {
    struct Request { let value: Double; let from: String; let to: String }

    // canonical unit → (dimension, factor to the dimension's base unit)
    private static let linear: [String: (dim: String, toBase: Double)] = [
        // length — base: metre
        "m": ("len", 1), "km": ("len", 1000), "cm": ("len", 0.01), "mm": ("len", 0.001),
        "mi": ("len", 1609.344), "ft": ("len", 0.3048), "in": ("len", 0.0254), "yd": ("len", 0.9144),
        // mass — base: gram
        "g": ("mass", 1), "kg": ("mass", 1000), "mg": ("mass", 0.001),
        "lb": ("mass", 453.59237), "oz": ("mass", 28.349523125),
        // volume — base: litre
        "l": ("vol", 1), "ml": ("vol", 0.001),
        "gal": ("vol", 3.785411784), "floz": ("vol", 0.0295735295625),
        // speed — base: metre/second
        "mps": ("spd", 1), "kph": ("spd", 0.277777778), "mph": ("spd", 0.44704),
        // time — base: second
        "s": ("time", 1), "ms": ("time", 0.001), "min": ("time", 60), "h": ("time", 3600),
        "day": ("time", 86400), "week": ("time", 604800),
    ]

    // spelled-out / alternate spellings → canonical symbol
    private static let alias: [String: String] = [
        "meter": "m", "meters": "m", "metre": "m", "metres": "m",
        "kilometer": "km", "kilometers": "km", "kilometre": "km", "kilometres": "km",
        "centimeter": "cm", "centimeters": "cm", "millimeter": "mm", "millimeters": "mm",
        "mile": "mi", "miles": "mi", "foot": "ft", "feet": "ft",
        "inch": "in", "inches": "in", "yard": "yd", "yards": "yd",
        "gram": "g", "grams": "g", "kilogram": "kg", "kilograms": "kg", "kilo": "kg", "kilos": "kg",
        "milligram": "mg", "milligrams": "mg", "pound": "lb", "pounds": "lb", "lbs": "lb",
        "ounce": "oz", "ounces": "oz",
        "liter": "l", "liters": "l", "litre": "l", "litres": "l",
        "milliliter": "ml", "milliliters": "ml", "millilitre": "ml", "millilitres": "ml",
        "gallon": "gal", "gallons": "gal",
        "celsius": "c", "centigrade": "c", "fahrenheit": "f", "kelvin": "k",
        "kmh": "kph", "km/h": "kph", "mi/h": "mph", "m/s": "mps",
        "sec": "s", "secs": "s", "second": "s", "seconds": "s",
        "millisecond": "ms", "milliseconds": "ms", "msec": "ms",
        "minute": "min", "minutes": "min", "mins": "min",
        "hr": "h", "hrs": "h", "hour": "h", "hours": "h",
        "days": "day", "weeks": "week",
    ]

    static func canonical(_ unit: String) -> String {
        let u = unit.lowercased().trimmingCharacters(in: .whitespaces)
        return alias[u] ?? u
    }

    static func parse(_ text: String) -> Request? {
        let lower = text.lowercased()
        let sep: String
        if lower.contains(" to ") { sep = " to " } else if lower.contains(" in ") { sep = " in " } else { return nil }
        let parts = lower.components(separatedBy: sep)
        guard parts.count == 2 else { return nil }
        let toUnit = canonical(parts[1])
        let left = parts[0].trimmingCharacters(in: .whitespaces)
        var numStr = ""
        var idx = left.startIndex
        while idx < left.endIndex, left[idx].isNumber || left[idx] == "." || left[idx] == "-" {
            numStr.append(left[idx]); idx = left.index(after: idx)
        }
        guard let value = Double(numStr) else { return nil }
        let fromUnit = canonical(String(left[idx...]))
        guard !fromUnit.isEmpty else { return nil }
        return Request(value: value, from: fromUnit, to: toUnit)
    }

    static func convert(value: Double, from: String, to: String) -> Double? {
        let temps: Set<String> = ["c", "f", "k"]
        if temps.contains(from) || temps.contains(to) {
            guard temps.contains(from), temps.contains(to) else { return nil }
            let celsius: Double
            switch from { case "c": celsius = value; case "f": celsius = (value - 32) * 5 / 9; case "k": celsius = value - 273.15; default: return nil }
            switch to { case "c": return celsius; case "f": return celsius * 9 / 5 + 32; case "k": return celsius + 273.15; default: return nil }
        }
        guard let f = linear[from], let t = linear[to], f.dim == t.dim else { return nil }
        return value * f.toBase / t.toBase
    }

    static func format(_ v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e12 { return String(Int64(v)) }
        return String((v * 10000).rounded() / 10000)   // up to 4 decimal places
    }
}

// MARK: - Date arithmetic

/// Offline date math: `"days between 2026-06-08 and 2026-12-25"` → a day count,
/// or `"2026-06-08 plus 90 days"` / `"… minus 14 days"` → a new ISO date. Dates
/// are parsed and computed in UTC so results are deterministic.
public struct DateCalcTool: Capability {
    public init() {}
    public let name = "date"
    public let purpose = "Date math: \"days between 2026-06-08 and 2026-12-25\", \"2026-06-08 plus 90 days\", or \"what day of the week is 2026-12-25\"."

    public func run(_ input: String) async throws -> String {
        guard let result = DateCalc.evaluate(input) else {
            return "Couldn't read a date calculation from \"\(input)\". Use ISO dates, e.g. 2026-06-08."
        }
        return result
    }
}

enum DateCalc {
    private static func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private static func isoDates(in text: String) -> [Date] {
        guard let re = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#) else { return [] }
        let ns = text as NSString
        let f = formatter()
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match -> Date? in
                let s = ns.substring(with: match.range)
                // DateFormatter silently ROLLS OVER invalid dates (2026-02-30 → 2026-03-02, a non-leap
                // 2026-02-29 → 2026-03-01), which would compute a day count from a date the user never
                // typed — and diverge from Android's strict java.time.LocalDate, which rejects them.
                // Round-trip the parsed date back to a string and reject anything that didn't survive.
                guard let d = f.date(from: s), f.string(from: d) == s else { return nil }
                return d
            }
    }

    private static func firstInteger(in text: String) -> Int? {
        var digits = ""
        for ch in text { if ch.isNumber { digits.append(ch) } else if !digits.isEmpty { break } }
        return Int(digits)
    }

    static func evaluate(_ text: String) -> String? {
        let lower = text.lowercased()
        let dates = isoDates(in: text)

        if dates.count >= 2 && lower.contains("between") {
            let days = utcCalendar().dateComponents([.day], from: dates[0], to: dates[1]).day ?? 0
            let n = abs(days)
            return "\(n) day\(n == 1 ? "" : "s")"
        }

        if dates.count == 1 {
            // "what day of the week is <date>" → the weekday name (deterministic, UTC). Specific
            // triggers so it can't collide with an offset query like "90 days after <date>".
            if lower.contains("weekday") || lower.contains("day of the week") || lower.contains("day of week") {
                let weekday = utcCalendar().component(.weekday, from: dates[0])   // 1 = Sunday … 7 = Saturday
                let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
                guard weekday >= 1, weekday <= 7 else { return nil }
                return names[weekday - 1]
            }
            // strip the date out, then read the offset count from what remains
            let stripped = text.replacingOccurrences(of: #"\d{4}-\d{2}-\d{2}"#, with: " ", options: .regularExpression)
            guard let n = firstInteger(in: stripped) else { return nil }
            let isMinus = lower.contains("minus") || lower.contains("subtract") || lower.contains("before")
            let isPlus = lower.contains("plus") || lower.contains("add") || lower.contains("after")
            guard isPlus || isMinus else { return nil }
            guard let result = utcCalendar().date(byAdding: .day, value: isMinus ? -n : n, to: dates[0]) else { return nil }
            return formatter().string(from: result)
        }

        return nil
    }
}
