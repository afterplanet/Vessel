import Foundation
import simd

/// Spacecraft beyond the reach of ordinary orbit data, or worth finding by what they do.
struct SpaceObject: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case telescope = "Space telescopes"
        case lunar = "Lunar orbiters"
        case sun = "Sun and space weather"
        case mars = "At Mars"
        case probe = "Deep space probes"
        var id: String { rawValue }

        var explanation: String {
            switch self {
            case .telescope: "Observatories. Some orbit close to Earth and show on the globe. Others are far out, and open the solar system."
            case .lunar: "Orbiting the Moon. Choosing one shows it around the Moon, where it is right now."
            case .sun: "Watching the Sun, from near Earth or much closer in."
            case .mars: "Orbiters and a rover at Mars."
            case .probe: "On their way across the solar system, or leaving it."
            }
        }
    }

    /// What a nearby view is centred on, as JPL Horizons numbers it.
    enum Centre: Int {
        case earth = 399, moon = 301, mars = 499, jupiter = 599
        var name: String {
            switch self {
            case .earth: "Earth"
            case .moon: "Moon"
            case .mars: "Mars"
            case .jupiter: "Jupiter"
            }
        }
        var radiusKm: Double {
            switch self {
            case .earth: 6371
            case .moon: 1737
            case .mars: 3390
            case .jupiter: 69911
            }
        }
    }

    let name: String
    let kind: Kind
    /// JPL Horizons' number. Nil for those tracked only by ordinary orbit data.
    var horizons: Int? = nil
    /// Set if it's in the orbit catalogue, in which case it's shown on the globe.
    var norad: Int? = nil
    var centre: Centre? = nil
    var about: String
    var launched: Int
    var id: String { name }

    /// Its number in the satellite catalogue, which every object has even with no current orbit data.
    var noradID: Int { norad ?? SpaceCatalog.numbers[name]?.norad ?? 0 }
    var designator: String { SpaceCatalog.numbers[name]?.designator ?? "" }
}

enum SpaceCatalog {
    static let all: [SpaceObject] = [
        // Space telescopes
        SpaceObject(name: "James Webb Space Telescope", kind: .telescope, horizons: -170, centre: .earth, about: "Infrared observatory, around the Sun-Earth L2 point", launched: 2021),
        SpaceObject(name: "Hubble Space Telescope", kind: .telescope, norad: 20580, about: "Visible and ultraviolet observatory", launched: 1990),
        SpaceObject(name: "Euclid", kind: .telescope, horizons: -680, centre: .earth, about: "Mapping dark matter and dark energy, around Sun-Earth L2", launched: 2023),
        SpaceObject(name: "Chandra X-ray Observatory", kind: .telescope, norad: 25867, about: "X-ray observatory on a long, high orbit", launched: 1999),
        SpaceObject(name: "XMM-Newton", kind: .telescope, norad: 25989, about: "X-ray observatory", launched: 1999),
        SpaceObject(name: "Fermi Gamma-ray Space Telescope", kind: .telescope, norad: 33053, about: "Gamma-ray observatory", launched: 2008),
        SpaceObject(name: "Swift", kind: .telescope, norad: 28485, about: "Catches gamma-ray bursts", launched: 2004),
        SpaceObject(name: "NuSTAR", kind: .telescope, norad: 38358, about: "High-energy X-ray observatory", launched: 2012),
        SpaceObject(name: "TESS", kind: .telescope, horizons: -95, norad: 43435, centre: .earth, about: "Searching for planets around nearby stars", launched: 2018),
        SpaceObject(name: "Gaia", kind: .telescope, horizons: -139479, about: "Mapped a billion stars. Retired in 2025, now orbiting the Sun", launched: 2013),

        // At the Moon
        SpaceObject(name: "Lunar Reconnaissance Orbiter", kind: .lunar, horizons: -85, centre: .moon, about: "NASA, mapping the Moon's surface", launched: 2009),
        SpaceObject(name: "Chandrayaan-2 Orbiter", kind: .lunar, horizons: -152, centre: .moon, about: "ISRO, studying the Moon from a polar orbit", launched: 2019),
        SpaceObject(name: "Danuri", kind: .lunar, horizons: -155, centre: .moon, about: "KARI, Korea's lunar orbiter", launched: 2022),

        // Sun and space weather
        SpaceObject(name: "Parker Solar Probe", kind: .sun, horizons: -96, about: "Flying through the Sun's outer atmosphere", launched: 2018),
        SpaceObject(name: "Solar Orbiter", kind: .sun, horizons: -144, about: "Imaging the Sun from close up", launched: 2020),
        SpaceObject(name: "SOHO", kind: .sun, horizons: -21, centre: .earth, about: "Watching the Sun from Sun-Earth L1", launched: 1995),
        SpaceObject(name: "ACE", kind: .sun, horizons: -92, centre: .earth, about: "Measuring the solar wind at Sun-Earth L1", launched: 1997),
        SpaceObject(name: "DSCOVR", kind: .sun, horizons: -78, centre: .earth, about: "Space weather warnings, from Sun-Earth L1", launched: 2015),

        // At Mars
        SpaceObject(name: "Mars Reconnaissance Orbiter", kind: .mars, horizons: -74, centre: .mars, about: "NASA, high-resolution imaging and data relay", launched: 2005),
        SpaceObject(name: "Mars Odyssey", kind: .mars, horizons: -53, centre: .mars, about: "NASA, the longest-serving Mars orbiter", launched: 2001),
        SpaceObject(name: "Mars Express", kind: .mars, horizons: -41, centre: .mars, about: "ESA, studying the atmosphere and surface", launched: 2003),
        SpaceObject(name: "Trace Gas Orbiter", kind: .mars, horizons: -143, centre: .mars, about: "ESA and Roscosmos, sampling the atmosphere", launched: 2016),
        SpaceObject(name: "Curiosity", kind: .mars, horizons: -76, centre: .mars, about: "NASA rover on the surface, in Gale Crater", launched: 2011),

        // Deep space probes
        SpaceObject(name: "Voyager 1", kind: .probe, horizons: -31, about: "The farthest spacecraft from Earth, in interstellar space", launched: 1977),
        SpaceObject(name: "Voyager 2", kind: .probe, horizons: -32, about: "In interstellar space, after visiting all four giant planets", launched: 1977),
        SpaceObject(name: "New Horizons", kind: .probe, horizons: -98, about: "Past Pluto and out through the Kuiper Belt", launched: 2006),
        SpaceObject(name: "Juno", kind: .probe, horizons: -61, centre: .jupiter, about: "Orbiting Jupiter", launched: 2011),
        SpaceObject(name: "Europa Clipper", kind: .probe, horizons: -159, about: "On its way to Jupiter's moon Europa", launched: 2024),
        SpaceObject(name: "JUICE", kind: .probe, horizons: -28, about: "ESA, on its way to Jupiter's icy moons", launched: 2023),
        SpaceObject(name: "Lucy", kind: .probe, horizons: -49, about: "Touring the Trojan asteroids", launched: 2021),
        SpaceObject(name: "Psyche", kind: .probe, horizons: -255, about: "On its way to a metal-rich asteroid", launched: 2023),
        SpaceObject(name: "BepiColombo", kind: .probe, horizons: -121, about: "ESA and JAXA, on its way to Mercury", launched: 2018),
        SpaceObject(name: "OSIRIS-APEX", kind: .probe, horizons: -64, about: "On its way to the asteroid Apophis", launched: 2016),
        SpaceObject(name: "Hayabusa2", kind: .probe, horizons: -37, about: "JAXA, extended mission to asteroids", launched: 2014),
    ]

    /// From the General Catalog of Artificial Space Objects, except Europa Clipper's.
    static let numbers: [String: (norad: Int, designator: String)] = [
        "James Webb Space Telescope": (50463, "2021-130A"), "Euclid": (57209, "2023-092A"), "Gaia": (39479, "2013-074A"), "TESS": (43435, "2018-038A"),
        "Lunar Reconnaissance Orbiter": (35315, "2009-031A"), "Chandrayaan-2 Orbiter": (44441, "2019-042A"), "Danuri": (53365, "2022-094A"),
        "Parker Solar Probe": (43592, "2018-065A"), "Solar Orbiter": (45167, "2020-010A"), "SOHO": (23726, "1995-065A"), "ACE": (24912, "1997-045A"), "DSCOVR": (40390, "2015-007A"),
        "Mars Reconnaissance Orbiter": (28788, "2005-029A"), "Mars Odyssey": (26734, "2001-013A"), "Mars Express": (27816, "2003-022A"), "Trace Gas Orbiter": (41388, "2016-017A"), "Curiosity": (37936, "2011-070A"),
        "Voyager 1": (10321, "1977-084A"), "Voyager 2": (10271, "1977-076A"), "New Horizons": (28928, "2006-001A"), "Juno": (37773, "2011-040A"), "Europa Clipper": (61507, "2024-182A"),
        "JUICE": (56176, "2023-053A"), "Lucy": (49328, "2021-093A"), "Psyche": (58049, "2023-157A"), "BepiColombo": (43653, "2018-080A"), "OSIRIS-APEX": (41757, "2016-055A"), "Hayabusa2": (40319, "2014-076A"),
    ]

    /// Published downlinks for spacecraft SatNOGS doesn't list. Few, and only ones that are well documented.
    static let downlinks: [String: [Transmitter]] = [
        "James Webb Space Telescope": [Transmitter(description: "S-band telemetry", downlinkHz: 2_270_500_000, mode: "S-band", active: true, baud: nil)],
        "Lunar Reconnaissance Orbiter": [Transmitter(description: "S-band telemetry", downlinkHz: 2_271_200_000, mode: "S-band", active: true, baud: nil)],
        "Voyager 1": [Transmitter(description: "X-band downlink", downlinkHz: 8_420_432_000, mode: "X-band", active: true, baud: nil)],
    ]

    static func of(kind: SpaceObject.Kind) -> [SpaceObject] { all.filter { $0.kind == kind } }

    /// Everything here that's on the globe, under its catalogue number.
    static let byNorad = Dictionary(all.map { ($0.noradID, $0) }, uniquingKeysWith: { a, _ in a })

    static func search(_ query: String, limit: Int = 4) -> [SpaceObject] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        return Array(all.filter { $0.name.lowercased().contains(q) }.prefix(limit))
    }
}

/// A path through space from JPL Horizons, in km and km/s, relative to a centre.
struct HorizonsTrack: Equatable {
    struct Point: Equatable {
        let jd: Double
        let position: SIMD3<Double>
        let velocity: SIMD3<Double>
    }
    let points: [Point]

    /// Reads Horizons' vector table: "JD, date, X, Y, Z, VX, VY, VZ," between its markers.
    static func parse(_ text: String) -> HorizonsTrack? {
        guard let start = text.range(of: "$$SOE"), let end = text.range(of: "$$EOE"), start.upperBound < end.lowerBound else { return nil }
        let rows = text[start.upperBound..<end.lowerBound].split(whereSeparator: \.isNewline)
        let points = rows.compactMap { row -> Point? in
            let c = row.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard c.count >= 8, let jd = Double(c[0]), let x = Double(c[2]), let y = Double(c[3]), let z = Double(c[4]),
                  let vx = Double(c[5]), let vy = Double(c[6]), let vz = Double(c[7]) else { return nil }
            return Point(jd: jd, position: SIMD3(x, y, z), velocity: SIMD3(vx, vy, vz))
        }
        return points.isEmpty ? nil : HorizonsTrack(points: points)
    }

    /// Where it is at this time, between two samples. Nil outside what was fetched, rather than guessing.
    func at(_ jd: Double) -> Point? {
        guard let first = points.first, let last = points.last, jd >= first.jd, jd <= last.jd else { return nil }
        guard let i = points.firstIndex(where: { $0.jd >= jd }) else { return last }
        if i == 0 { return first }
        let a = points[i - 1], b = points[i]
        let t = (jd - a.jd) / (b.jd - a.jd)
        return Point(jd: jd, position: a.position + (b.position - a.position) * t, velocity: a.velocity + (b.velocity - a.velocity) * t)
    }

    /// The path so far, ending where it is now.
    func trail(upTo jd: Double) -> [SIMD3<Double>] {
        var out = points.filter { $0.jd <= jd }.map(\.position)
        if let now = at(jd) { out.append(now.position) }
        return out
    }
}

enum Horizons {
    static let kmPerAU = 149_597_870.7

    /// How much path to ask for, in each kind of view.
    struct Span: Equatable {
        let backDays: Double
        let stepMinutes: Int
        let keepSeconds: TimeInterval
    }

    static func span(centre: Int, object: Int) -> Span {
        switch centre {
        case 10: return Span(backDays: 60, stepMinutes: 1440, keepSeconds: 6 * 3600)
        case 399 where object == 301: return Span(backDays: 28, stepMinutes: 360, keepSeconds: 6 * 3600)
        case 399: return Span(backDays: 180, stepMinutes: 2880, keepSeconds: 6 * 3600)
        case 599: return Span(backDays: 60, stepMinutes: 1440, keepSeconds: 6 * 3600)
        // Low orbits around the Moon and Mars take about two hours, so this is one or two laps.
        default: return Span(backDays: 0.16, stepMinutes: 5, keepSeconds: 1800)
        }
    }

    /// A spacecraft's position from Earth, on the equatorial axes the look-angle maths uses.
    /// Enough either side of now to keep it moving until the next day's fetch.
    static func positionURL(object: SpaceObject, now: Date) -> String {
        let moonOrMars = object.centre == .moon || object.centre == .mars
        let span = Span(backDays: 1, stepMinutes: moonOrMars ? 120 : 720, keepSeconds: 2 * 86400)
        return url(object: object.horizons ?? 0, centre: 399, now: now, span: span, plane: "FRAME")
    }

    static func positions(of object: SpaceObject) async -> HorizonsTrack? {
        guard object.horizons != nil else { return nil }
        let name = "horizons_pos_\(object.noradID).json"
        let address = positionURL(object: object, now: Date())
        guard let data = try? await DataFetcher.data(address, cacheName: name, maxAge: 86400, userAgent: AMSATAPI.userAgent) else { return nil }
        struct Reply: Decodable { let result: String }
        if let text = (try? JSONDecoder().decode(Reply.self, from: data))?.result, let parsed = HorizonsTrack.parse(text) { return parsed }
        try? FileManager.default.removeItem(at: Res.cacheDir.appendingPathComponent(name))
        return nil
    }

    static func url(object: Int, centre: Int, now: Date, span: Span, plane: String = "ECLIPTIC") -> String {
        let format = DateFormatter()
        format.timeZone = TimeZone(identifier: "UTC")
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        let start = format.string(from: now.addingTimeInterval(-span.backDays * 86400))
        // Far enough ahead to keep it moving until the next fetch, and for one sample past that.
        let ahead = span.keepSeconds + 3600 + Double(span.stepMinutes) * 60
        let stop = format.string(from: now.addingTimeInterval(ahead))
        let items = [("format", "json"), ("COMMAND", "'\(object)'"), ("OBJ_DATA", "NO"), ("MAKE_EPHEM", "YES"), ("EPHEM_TYPE", "VECTORS"),
                     ("CENTER", "'500@\(centre)'"), ("START_TIME", "'\(start)'"), ("STOP_TIME", "'\(stop)'"), ("STEP_SIZE", "'\(span.stepMinutes) m'"),
                     ("VEC_TABLE", "2"), ("CSV_FORMAT", "YES"), ("OUT_UNITS", "KM-S"), ("REF_PLANE", plane), ("TIME_TYPE", "UT")]
        var c = URLComponents(string: "https://ssd.jpl.nasa.gov/api/horizons.api")!
        c.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url!.absoluteString
    }

    static func track(object: Int, centre: Int) async -> HorizonsTrack? {
        let span = span(centre: centre, object: object)
        let name = "horizons_\(object)_\(centre).json"
        let address = url(object: object, centre: centre, now: Date(), span: span)
        guard let data = try? await DataFetcher.data(address, cacheName: name, maxAge: span.keepSeconds, userAgent: AMSATAPI.userAgent) else { return nil }
        struct Reply: Decodable { let result: String }
        if let text = (try? JSONDecoder().decode(Reply.self, from: data))?.result, let parsed = HorizonsTrack.parse(text) { return parsed }
        // An answer with no table is an error message: not something to keep.
        try? FileManager.default.removeItem(at: Res.cacheDir.appendingPathComponent(name))
        return nil
    }
}

/// Planet positions from JPL's published approximate elements, good from 1800 to 2050.
struct Planet: Identifiable, Equatable {
    let name: String
    let a0, aRate, e0, eRate, i0, iRate, l0, lRate, peri0, periRate, node0, nodeRate: Double
    let drawRadius: Double
    let colour: (r: Double, g: Double, b: Double)
    var id: String { name }

    static func == (x: Planet, y: Planet) -> Bool { x.name == y.name }

    static let all = [
        Planet(name: "Mercury", a0: 0.38709927, aRate: 0.00000037, e0: 0.20563593, eRate: 0.00001906, i0: 7.00497902, iRate: -0.00594749, l0: 252.25032350, lRate: 149472.67411175, peri0: 77.45779628, periRate: 0.16047689, node0: 48.33076593, nodeRate: -0.12534081, drawRadius: 0.45, colour: (0.62, 0.58, 0.54)),
        Planet(name: "Venus", a0: 0.72333566, aRate: 0.00000390, e0: 0.00677672, eRate: -0.00004107, i0: 3.39467605, iRate: -0.00078890, l0: 181.97909950, lRate: 58517.81538729, peri0: 131.60246718, periRate: 0.00268329, node0: 76.67984255, nodeRate: -0.27769418, drawRadius: 0.7, colour: (0.9, 0.78, 0.55)),
        Planet(name: "Earth", a0: 1.00000261, aRate: 0.00000562, e0: 0.01671123, eRate: -0.00004392, i0: -0.00001531, iRate: -0.01294668, l0: 100.46457166, lRate: 35999.37244981, peri0: 102.93768193, periRate: 0.32327364, node0: 0, nodeRate: 0, drawRadius: 0.75, colour: (0.25, 0.5, 0.95)),
        Planet(name: "Mars", a0: 1.52371034, aRate: 0.00001847, e0: 0.09339410, eRate: 0.00007882, i0: 1.84969142, iRate: -0.00813131, l0: -4.55343205, lRate: 19140.30268499, peri0: -23.94362959, periRate: 0.44441088, node0: 49.55953891, nodeRate: -0.29257343, drawRadius: 0.55, colour: (0.85, 0.4, 0.25)),
        Planet(name: "Jupiter", a0: 5.20288700, aRate: -0.00011607, e0: 0.04838624, eRate: -0.00013253, i0: 1.30439695, iRate: -0.00183714, l0: 34.39644051, lRate: 3034.74612775, peri0: 14.72847983, periRate: 0.21252668, node0: 100.47390909, nodeRate: 0.20469106, drawRadius: 1.6, colour: (0.85, 0.72, 0.55)),
        Planet(name: "Saturn", a0: 9.53667594, aRate: -0.00125060, e0: 0.05386179, eRate: -0.00050991, i0: 2.48599187, iRate: 0.00193609, l0: 49.95424423, lRate: 1222.49362201, peri0: 92.59887831, periRate: -0.41897216, node0: 113.66242448, nodeRate: -0.28867794, drawRadius: 1.35, colour: (0.9, 0.82, 0.6)),
        Planet(name: "Uranus", a0: 19.18916464, aRate: -0.00196176, e0: 0.04725744, eRate: -0.00004397, i0: 0.77263783, iRate: -0.00242939, l0: 313.23810451, lRate: 428.48202785, peri0: 170.95427630, periRate: 0.40805281, node0: 74.01692503, nodeRate: 0.04240589, drawRadius: 1.0, colour: (0.6, 0.85, 0.9)),
        Planet(name: "Neptune", a0: 30.06992276, aRate: 0.00026291, e0: 0.00859048, eRate: 0.00005105, i0: 1.77004347, iRate: 0.00035372, l0: -55.12002969, lRate: 218.45945325, peri0: 44.96476227, periRate: -0.32241464, node0: 131.78422574, nodeRate: -0.00508664, drawRadius: 1.0, colour: (0.3, 0.45, 0.95)),
    ]

    /// Sun-centred, in AU, on the ecliptic plane. `shift` moves round the orbit for drawing it, in degrees.
    func position(jd: Double, shift: Double = 0) -> SIMD3<Double> {
        let t = (jd - 2451545.0) / 36525
        let a = a0 + aRate * t, e = e0 + eRate * t
        let i = (i0 + iRate * t) * .pi / 180
        let peri = peri0 + periRate * t, node = node0 + nodeRate * t
        var m = (l0 + lRate * t - peri + shift).truncatingRemainder(dividingBy: 360)
        if m > 180 { m -= 360 } else if m < -180 { m += 360 }
        let mRad = m * .pi / 180
        var E = mRad + e * sin(mRad)
        for _ in 0..<8 { E -= (E - e * sin(E) - mRad) / (1 - e * cos(E)) }
        let x = a * (cos(E) - e), y = a * sqrt(1 - e * e) * sin(E)
        let w = (peri - node) * .pi / 180, o = node * .pi / 180
        let cw = cos(w), sw = sin(w), co = cos(o), so = sin(o), ci = cos(i), si = sin(i)
        return SIMD3((cw * co - sw * so * ci) * x + (-sw * co - cw * so * ci) * y,
                     (cw * so + sw * co * ci) * x + (-sw * so + cw * co * ci) * y,
                     (sw * si) * x + (cw * si) * y)
    }
}

/// Fitting the whole solar system on a screen means squeezing distance: inner planets stay apart, and
/// Voyager still fits. Directions are true, and the numbers shown are always the real ones.
enum SolarScale {
    static func compressed(_ au: SIMD3<Double>) -> SIMD3<Double> {
        let r = simd_length(au)
        guard r > 0 else { return au }
        return au / r * (sqrt(r) * 20)
    }
}
