import Foundation

/// Satellites someone reports as transmitting, that CelesTrak's active list leaves out. SatNOGS keeps
/// orbits for them, as two-line elements.
enum ExtraSatellites {
    static let url = "https://db.satnogs.org/api/tle/?format=json"
    /// Older than this, its position is too doubtful to draw, and it may well be gone.
    static let freshestDays = 14.0

    struct Row: Decodable {
        let tle0: String?
        let tle1: String?
        let tle2: String?
    }

    /// "12345-3" means 0.12345e-3, as TLEs write small numbers.
    static func assumedDecimal(_ field: Substring) -> Double? {
        let t = field.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let negative = t.hasPrefix("-")
        let digits = negative || t.hasPrefix("+") ? String(t.dropFirst()) : t
        guard let split = digits.dropFirst().lastIndex(where: { $0 == "-" || $0 == "+" }),
              let mantissa = Double("0." + digits[..<split]), let exponent = Double(digits[split...]) else { return nil }
        let value = mantissa * pow(10, exponent)
        return negative ? -value : value
    }

    private static func column(_ line: String, _ from: Int, _ length: Int) -> Substring {
        let a = line.index(line.startIndex, offsetBy: from)
        return line[a..<line.index(a, offsetBy: length)]
    }

    private static func number(_ line: String, _ from: Int, _ length: Int) -> Double? {
        Double(column(line, from, length).trimmingCharacters(in: .whitespaces))
    }

    /// "98067A" is "1998-067A". The catalogue starts in 1957, so two-digit years before that are this century.
    static func designator(_ field: String) -> String {
        let t = field.trimmingCharacters(in: .whitespaces)
        guard t.count >= 5, let year = Int(t.prefix(2)) else { return t }
        return "\(year >= 57 ? 1900 + year : 2000 + year)-\(t.dropFirst(2))"
    }

    static func epoch(year: Int, dayOfYear: Double) -> Date? {
        var c = DateComponents()
        c.year = year >= 57 ? 1900 + year : 2000 + year
        c.month = 1
        c.day = 1
        c.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: c)?.addingTimeInterval((dayOfYear - 1) * 86400)
    }

    /// Nil for anything that isn't a whole, well-formed element set.
    static func parse(_ row: Row) -> (omm: OMM, epoch: Date)? {
        guard let l1 = row.tle1?.trimmingCharacters(in: .whitespaces), let l2 = row.tle2?.trimmingCharacters(in: .whitespaces),
              l1.count >= 68, l2.count >= 68, l1.hasPrefix("1 "), l2.hasPrefix("2 "),
              let norad = Int(column(l1, 2, 5).replacingOccurrences(of: " ", with: "0")),
              let year = Int(column(l1, 18, 2)), let day = number(l1, 20, 12), let date = epoch(year: year, dayOfYear: day),
              let dot = number(l1, 33, 10), let ddot = assumedDecimal(column(l1, 44, 8)), let bstar = assumedDecimal(column(l1, 53, 8)),
              let inclination = number(l2, 8, 8), let node = number(l2, 17, 8), let e = number(l2, 26, 7).map({ $0 / 1e7 }),
              let perigee = number(l2, 34, 8), let anomaly = number(l2, 43, 8), let motion = number(l2, 52, 11), motion > 0 else { return nil }
        var name = (row.tle0 ?? "").trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("0 ") { name = String(name.dropFirst(2)) }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        format.timeZone = TimeZone(identifier: "UTC")
        let iso = format.string(from: date).replacingOccurrences(of: "Z", with: "")
        return (OMM(OBJECT_NAME: name.isEmpty ? "NORAD \(norad)" : name, OBJECT_ID: designator(String(column(l1, 9, 8))), EPOCH: iso,
                    MEAN_MOTION: motion, ECCENTRICITY: e, INCLINATION: inclination, RA_OF_ASC_NODE: node, ARG_OF_PERICENTER: perigee,
                    MEAN_ANOMALY: anomaly, NORAD_CAT_ID: norad, BSTAR: bstar, MEAN_MOTION_DOT: dot, MEAN_MOTION_DDOT: ddot), date)
    }

    /// Reported on the air, with a recent orbit, and not already listed.
    static func select(_ rows: [Row], transmitting: Set<Int>, known: Set<Int>, now: Date) -> [OMM] {
        var seen = Set<Int>()
        return rows.compactMap { row -> OMM? in
            guard let (omm, epoch) = parse(row), transmitting.contains(omm.NORAD_CAT_ID), !known.contains(omm.NORAD_CAT_ID),
                  abs(now.timeIntervalSince(epoch)) <= freshestDays * 86400, seen.insert(omm.NORAD_CAT_ID).inserted else { return nil }
            return omm
        }
    }
}
