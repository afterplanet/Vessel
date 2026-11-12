import Foundation

/// One pass of a satellite over a ground point.
struct SatPass: Identifiable, Equatable {
    struct Point: Equatable { let az: Double; let el: Double }
    var id: Date { aos }
    let aos: Date
    let los: Date
    let peak: Date
    let maxElevation: Double
    /// Azimuth and elevation along the pass, for drawing it on the sky plot.
    let track: [Point]

    var duration: TimeInterval { los.timeIntervalSince(aos) }
    func isUp(at now: Date = Date()) -> Bool { aos <= now && now < los }
}

/// A stretch of time when a satellite is above the horizon at two places at once.
struct MutualWindow: Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    let end: Date
    let maxElevationHere: Double
    let maxElevationThere: Double
}

enum PassPredictor {
    private static func jd(_ d: Date) -> Double { Astro.julianDate(d) }

    private static func look(_ sat: Satellite, _ g: GroundPoint, _ d: Date) -> (az: Double, el: Double)? {
        let t = jd(d)
        guard let r = sat.position(jd: t) else { return nil }
        return g.look(at: Astro.ecef(r, gmst: Astro.gmst(t)))
    }

    /// The moment elevation crosses zero between two times, to about a second.
    private static func crossing(_ sat: Satellite, _ g: GroundPoint, _ a: Date, _ b: Date, rising: Bool) -> Date {
        var lo = a, hi = b
        for _ in 0..<14 {
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
            let up = (look(sat, g, mid)?.el ?? -90) > 0
            if up == rising { hi = mid } else { lo = mid }
        }
        return hi
    }

    /// Every pass in the window, including one already in progress. `sat` must be a private copy,
    /// because propagators can't be shared between threads. Satellites that never set return nothing.
    static func passes(_ sat: Satellite, lat: Double, lon: Double, from start: Date = Date(), hours: Double = 48,
                       minElevation: Double = 0, cancelled: () -> Bool = { false }) -> [SatPass] {
        let g = GroundPoint(lat: lat, lon: lon)
        let step = min(60.0, max(15.0, sat.periodMinutes * 60 / 120))
        let end = start.addingTimeInterval(hours * 3600)
        var out: [SatPass] = []
        var t = start
        var up = (look(sat, g, t)?.el ?? -90) > 0
        var aos: Date? = up ? start : nil
        var crossedSinceStart = false
        while t < end {
            if cancelled() { return out }
            let next = t.addingTimeInterval(step)
            let nowUp = (look(sat, g, next)?.el ?? -90) > 0
            if nowUp, !up { aos = crossing(sat, g, t, next, rising: true); crossedSinceStart = true }
            if up, !nowUp, let a = aos {
                let los = crossing(sat, g, t, next, rising: false)
                if let p = build(sat, g, a, los), p.maxElevation >= minElevation { out.append(p) }
                aos = nil
                crossedSinceStart = true
            }
            up = nowUp
            t = next
        }
        // Up for the whole window means geostationary or similar: there's no pass to list.
        _ = crossedSinceStart
        return out
    }

    private static func build(_ sat: Satellite, _ g: GroundPoint, _ aos: Date, _ los: Date) -> SatPass? {
        let n = 40
        var track: [SatPass.Point] = []
        var best = (el: -90.0, at: aos)
        for i in 0...n {
            let d = aos.addingTimeInterval(los.timeIntervalSince(aos) * Double(i) / Double(n))
            guard let l = look(sat, g, d) else { continue }
            track.append(.init(az: l.az, el: max(0, l.el)))
            if l.el > best.el { best = (l.el, d) }
        }
        guard track.count > 2 else { return nil }
        return SatPass(aos: aos, los: los, peak: best.at, maxElevation: best.el, track: track)
    }

    /// When both places can see the satellite at once, which is when a contact through it is possible.
    static func mutualWindows(_ sat: Satellite, here: (lat: Double, lon: Double), there: (lat: Double, lon: Double),
                              from start: Date = Date(), days: Double = 7, cancelled: () -> Bool = { false }) -> [MutualWindow] {
        let a = GroundPoint(lat: here.lat, lon: here.lon), b = GroundPoint(lat: there.lat, lon: there.lon)
        let step = min(30.0, max(10.0, sat.periodMinutes * 60 / 240))
        let end = start.addingTimeInterval(days * 86400)
        var out: [MutualWindow] = []
        var t = start
        var open: (start: Date, maxA: Double, maxB: Double)?
        while t < end {
            if cancelled() { return out }
            let ea = look(sat, a, t)?.el ?? -90, eb = look(sat, b, t)?.el ?? -90
            if ea > 0, eb > 0 {
                if open == nil { open = (t, ea, eb) } else { open!.maxA = max(open!.maxA, ea); open!.maxB = max(open!.maxB, eb) }
            } else if let o = open {
                // Whole days of overlap is a geostationary satellite, not a window to plan around.
                if t.timeIntervalSince(o.start) < 6 * 3600 {
                    out.append(MutualWindow(start: o.start, end: t, maxElevationHere: o.maxA, maxElevationThere: o.maxB))
                }
                open = nil
            }
            t = t.addingTimeInterval(step)
        }
        return out
    }
}

extension Maidenhead {
    /// The centre of a 4- or 6-character grid square, or nil if it isn't one.
    static func coordinates(_ grid: String) -> (lat: Double, lon: Double)? {
        let g = Array(grid.uppercased().trimmingCharacters(in: .whitespaces).unicodeScalars)
        guard g.count == 4 || g.count == 6 else { return nil }
        func letter(_ s: UnicodeScalar, _ max: UInt32) -> Double? {
            s.value >= 65 && s.value < 65 + max ? Double(s.value - 65) : nil
        }
        func digit(_ s: UnicodeScalar) -> Double? { s.value >= 48 && s.value <= 57 ? Double(s.value - 48) : nil }
        guard let f1 = letter(g[0], 18), let f2 = letter(g[1], 18), let d1 = digit(g[2]), let d2 = digit(g[3]) else { return nil }
        var lon = f1 * 20 + d1 * 2 - 180, lat = f2 * 10 + d2 - 90
        if g.count == 6 {
            guard let s1 = letter(g[4], 24), let s2 = letter(g[5], 24) else { return nil }
            lon += s1 / 12 + 1.0 / 24
            lat += s2 / 24 + 1.0 / 48
        } else {
            lon += 1
            lat += 0.5
        }
        return (lat, lon)
    }
}

/// Amateur contact log in ADIF, the format logging programs and LoTW import.
enum ADIF {
    struct Contact: Equatable {
        var date: Date
        var call: String
        var grid: String
        var sent: String
        var received: String
        var satellite: String
        var mode: String
        var uplinkHz: Double?
        var downlinkHz: Double?
        var myCall: String
        var myGrid: String
    }

    static func band(_ hz: Double) -> String? {
        switch hz / 1e6 {
        case 28..<29.7: "10m"
        case 144..<148: "2m"
        case 420..<450: "70cm"
        case 1240..<1300: "23cm"
        case 2300..<2450: "13cm"
        case 5650..<5925: "6cm"
        case 10000..<10500: "3cm"
        default: nil
        }
    }

    /// ADIF's mode names, with a submode where it has one.
    static func mode(_ name: String) -> (mode: String, submode: String?) {
        let n = name.uppercased()
        if n.contains("FT4") { return ("MFSK", "FT4") }
        if n.contains("FT8") { return ("FT8", nil) }
        if n.contains("PSK31") { return ("PSK", "PSK31") }
        if n.contains("RTTY") { return ("RTTY", nil) }
        if n.contains("CW") { return ("CW", nil) }
        if n.contains("SSB") || n == "USB" || n == "LSB" { return ("SSB", nil) }
        if n.contains("APRS") || n.contains("PACKET") { return ("PKT", nil) }
        return ("FM", nil)
    }

    private static func field(_ name: String, _ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return "<\(name):\(value.utf8.count)>\(value) "
    }

    static func record(_ c: Contact) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let p = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: c.date)
        let m = mode(c.mode)
        var s = field("QSO_DATE", String(format: "%04d%02d%02d", p.year!, p.month!, p.day!))
        s += field("TIME_ON", String(format: "%02d%02d%02d", p.hour!, p.minute!, p.second!))
        s += field("CALL", c.call.uppercased())
        s += field("MODE", m.mode) + field("SUBMODE", m.submode)
        if let up = c.uplinkHz { s += field("BAND", band(up)) + field("FREQ", String(format: "%.6f", up / 1e6)) }
        if let down = c.downlinkHz { s += field("BAND_RX", band(down)) + field("FREQ_RX", String(format: "%.6f", down / 1e6)) }
        s += field("RST_SENT", c.sent) + field("RST_RCVD", c.received)
        s += field("GRIDSQUARE", c.grid.uppercased()) + field("MY_GRIDSQUARE", c.myGrid)
        s += field("STATION_CALLSIGN", c.myCall.uppercased())
        s += field("PROP_MODE", "SAT") + field("SAT_NAME", c.satellite)
        return s + "<EOR>\n"
    }

    static let header = "Vessel contact log\n<ADIF_VER:5>3.1.4 <PROGRAMID:6>Vessel <EOH>\n"

    static func append(_ c: Contact, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { try header.write(to: url, atomically: true, encoding: .utf8) }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(record(c).utf8))
    }

    static func count(in url: URL) -> Int {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "<EOR>").count - 1
    }
}
