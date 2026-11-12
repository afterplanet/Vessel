import Foundation
import CSGP4
import simd

enum OrbitClass: String, CaseIterable, Identifiable {
    case leo = "LEO", meo = "MEO", geo = "GEO", sso = "SSO", heo = "HEO", deep = "Deep", spacecraft = "Spacecraft"

    var id: String { rawValue }
    /// Position in `allCases`, which is also how the GPU tells the classes apart when filtering.
    var index: Int { Self.allCases.firstIndex(of: self)! }

    var title: String {
        switch self {
        case .leo: "Low Earth orbit"
        case .meo: "Medium Earth orbit"
        case .geo: "Geosynchronous orbit"
        case .sso: "Sun-synchronous orbit"
        case .heo: "Highly elliptical orbit"
        case .deep: "Deep space"
        case .spacecraft: "Telescopes, lunar orbiters and deep space probes"
        }
    }

    /// The first rule that matches wins, so shape and period outrank altitude bands.
    static func classify(periodMinutes p: Double, inclination i: Double, eccentricity e: Double) -> OrbitClass {
        if p > 1500 { return .deep }
        if e >= 0.25 { return .heo }
        if p >= 1380 { return .geo }
        if p > 130 { return .meo }
        // Sun-synchronous orbits are slightly retrograde, which makes their plane track the Sun.
        if (95.5...104).contains(i), e < 0.1 { return .sso }
        return .leo
    }
}

enum SatCategory: String, CaseIterable {
    case station = "Space station"
    case military = "Military"
    case weather = "Weather"
    case navigation = "Navigation"
    case communications = "Communications"
    case earthObservation = "Earth observation"
    case research = "Research"
    case amateur = "Amateur radio"
    case education = "Education / CubeSat"
    case technology = "Technology demo"
    case unknown = "Unclassified"

    var symbol: String {
        switch self {
        case .station: "house.lodge"
        case .military: "shield.lefthalf.filled"
        case .weather: "cloud.sun"
        case .navigation: "location.north.line"
        case .communications: "antenna.radiowaves.left.and.right"
        case .earthObservation: "globe.americas"
        case .research: "atom"
        case .amateur: "dot.radiowaves.left.and.right"
        case .education: "graduationcap"
        case .technology: "wrench.and.screwdriver"
        case .unknown: "questionmark.circle"
        }
    }

}

/// What's publicly documented about a satellite's encryption. No catalogue records this per
/// satellite, so it comes from the published design of each system, and says so when nothing is known.
struct EncryptionInfo: Equatable {
    enum State: String {
        case yes = "Yes", partly = "Partly", no = "No", unknown = "Unknown"

        /// Closed when encrypted, open when any of it can be listened to, and nothing when nobody knows.
        var symbol: String? {
            switch self {
            case .yes: "lock.fill"
            case .partly: "lock.open"
            case .no: "lock.open.fill"
            case .unknown: nil
            }
        }
    }
    let state: State
    let method: String

    static func infer(for s: Satellite) -> EncryptionInfo {
        let n = s.name.uppercased()
        func starts(_ p: String...) -> Bool { p.contains { n.hasPrefix($0) } }

        if s.category == .station { return .init(state: .partly, method: "Amateur links open, operational links encrypted") }
        if s.category == .military { return .init(state: .yes, method: "Method classified") }

        if starts("NAVSTAR", "GPS") { return .init(state: .partly, method: "Military P(Y) and M-code encrypted, civil signals open") }
        if starts("GALILEO", "GSAT0") { return .init(state: .partly, method: "Public Regulated Service encrypted, Open Service not") }
        if starts("BEIDOU") { return .init(state: .partly, method: "Authorised service restricted, civil signals open") }
        if s.category == .navigation { return .init(state: .partly, method: "Restricted service encrypted, civil signals open") }

        if starts("STARLINK", "ONEWEB", "KUIPER", "QIANFAN", "GUOWANG", "HULIANWANG") {
            return .init(state: .yes, method: "Proprietary, method not published")
        }
        if s.category == .communications { return .init(state: .partly, method: "Chosen by the operator or customer, varies by service") }

        if starts("METEOSAT") { return .init(state: .partly, method: "Some HRIT channels use EUMETSAT keys") }
        if s.category == .weather { return .init(state: .no, method: "Open broadcast") }

        // Amateur rules generally forbid hiding the content of a message.
        if s.transmitters.contains(where: { $0.service == "Amateur" }) || s.category == .amateur {
            return .init(state: .no, method: "Amateur service, content must be open")
        }
        if s.category == .education { return .init(state: .no, method: "Open telemetry") }
        // What it's for, from the registry, is a fair guide where nothing more specific is known.
        switch s.registry?.sector {
        case "A": return .init(state: .no, method: "Amateur or academic, usually open")
        case "D": return .init(state: .yes, method: "Defence satellite, method not published")
        case "B": return .init(state: .partly, method: "Commercial, usually encrypted, method not published")
        default: return .init(state: .unknown, method: "Not published")
        }
    }
}

struct Transmitter: Codable, Hashable {
    let description: String
    let downlinkHz: Double
    let mode: String
    let active: Bool
    let baud: Double?
    var downlinkHighHz: Double? = nil
    var uplinkLowHz: Double? = nil
    var uplinkHighHz: Double? = nil
    var uplinkMode: String? = nil
    var inverted: Bool = false
    var service: String = ""
    var kind: String = ""
    var coordination: String = ""
    var frequencyViolation: Bool = false
}

final class Satellite: Identifiable {
    let norad: Int
    let name: String
    let objectID: String
    let periodMinutes: Double
    let inclination: Double
    let orbit: OrbitClass
    let launchYear: Int?
    let epochJD: Double
    /// The orbit model. Nil for a spacecraft with no ordinary orbit data, which `ephemeris` covers instead.
    let sat: OpaquePointer?
    private let omm: OMM?
    let spaceObject: SpaceObject?
    let ephemeris: SpaceEphemeris?
    var registry: RegistryEntry?
    /// Other names it goes by, like "AO-91" for RADFXSAT (FOX-1B).
    var otherNames: [String] = []
    /// Where a decoder listens for it, which can be known with no transmitter listed.
    var decoderFrequencyHz: Double?
    /// Reported as transmitting, but not on CelesTrak's active list.
    var fromSatNOGS = false
    /// Set once the drag model gives up on it, as it does for one that may have come down.
    private var withoutDrag: OpaquePointer?
    private(set) var isDecayEstimate = false

    // Enrichment, filled in as catalogues arrive.
    var ownerCode: String = ""
    var category: SatCategory = .unknown
    var transmitters: [Transmitter] = []
    /// Set when these frequencies belong to the station this module or docked vehicle is part of.
    var sharedWith: String?
    /// The satellite's own radio callsign, where the JE9PEL list gives one.
    var callsign: String?

    /// Set by the filters along the bottom of the globe.
    var filteredOut = false
    /// Worked out in the background, since it means checking the decoder list.
    var hasPublicFrequency = false
    /// The temporary number SatNOGS still lists this under, if it's different.
    var satnogsNumber: Int?
    var satnogsNorad: Int { satnogsNumber ?? norad }
    var communication: Set<CommunicationKind> = []
    /// In orbit and listed with an uplink, but nothing says it's working now.
    var talkThroughListedInactive = false
    var media: [MediaSignal] = []
    /// Listed by AMSAT, which can know of a picture mode before there's a frequency for it.
    var amsatMedia: Set<MediaKind> = []
    var mediaKinds: Set<MediaKind> { amsatMedia.union(media.map(\.kind)) }

    var id: Int { norad }

    init?(omm o: OMM) {
        guard let jd = Astro.julianDate(iso: o.EPOCH),
              let p = csgp4_create(jd, o.BSTAR, o.MEAN_MOTION_DOT, o.MEAN_MOTION_DDOT,
                                   o.ECCENTRICITY, o.ARG_OF_PERICENTER, o.INCLINATION,
                                   o.MEAN_ANOMALY, o.MEAN_MOTION, o.RA_OF_ASC_NODE)
        else { return nil }
        sat = p
        epochJD = jd
        omm = o
        spaceObject = SpaceCatalog.byNorad[o.NORAD_CAT_ID]
        ephemeris = nil
        norad = o.NORAD_CAT_ID
        name = o.OBJECT_NAME
        objectID = o.OBJECT_ID
        inclination = o.INCLINATION
        periodMinutes = 1440.0 / max(o.MEAN_MOTION, 0.001)
        orbit = SpaceCatalog.byNorad[o.NORAD_CAT_ID] != nil ? .spacecraft : OrbitClass.classify(periodMinutes: periodMinutes, inclination: o.INCLINATION, eccentricity: o.ECCENTRICITY)
        launchYear = Int(o.OBJECT_ID.prefix(4))
    }

    /// A spacecraft placed by JPL's data rather than orbit elements.
    init(space object: SpaceObject, ephemeris: SpaceEphemeris) {
        sat = nil
        omm = nil
        spaceObject = object
        self.ephemeris = ephemeris
        epochJD = Astro.julianDate()
        norad = object.noradID
        name = object.name
        objectID = object.designator
        inclination = 0
        periodMinutes = 1440
        orbit = .spacecraft
        launchYear = object.launched
    }

    deinit {
        if let sat { csgp4_free(sat) }
        if let withoutDrag { csgp4_free(withoutDrag) }
    }

    /// Its last orbit carried forward with no drag: where it would be, if it's still there.
    /// Only for a recent orbit, as this says less and less with age.
    private func estimate(jd: Double) -> (r: SIMD3<Double>, v: SIMD3<Double>)? {
        guard let omm, abs(jd - epochJD) <= ExtraSatellites.freshestDays else { return nil }
        if withoutDrag == nil {
            withoutDrag = csgp4_create(epochJD, 0, 0, 0, omm.ECCENTRICITY, omm.ARG_OF_PERICENTER, omm.INCLINATION,
                                       omm.MEAN_ANOMALY, omm.MEAN_MOTION, omm.RA_OF_ASC_NODE)
        }
        guard let withoutDrag else { return nil }
        var r = [0.0, 0.0, 0.0], v = [0.0, 0.0, 0.0]
        guard csgp4_propagate(withoutDrag, jd, &r, &v) == 1 else { return nil }
        isDecayEstimate = true
        return (SIMD3(r[0], r[1], r[2]), SIMD3(v[0], v[1], v[2]))
    }

    /// Position only, without the array allocations of `state`, for scans over the whole catalogue.
    func position(jd: Double) -> SIMD3<Double>? {
        guard let sat else { return ephemeris?.state(jd: jd)?.r }
        var r = SIMD4<Double>(), v = SIMD4<Double>()
        let ok = withUnsafeMutablePointer(to: &r) { rp in
            withUnsafeMutablePointer(to: &v) { vp in
                rp.withMemoryRebound(to: Double.self, capacity: 4) { a in
                    vp.withMemoryRebound(to: Double.self, capacity: 4) { b in csgp4_propagate(sat, jd, a, b) }
                }
            }
        }
        return ok == 1 ? SIMD3(r.x, r.y, r.z) : estimate(jd: jd)?.r
    }

    /// A second propagator for work off the ticker thread (tracks, pass prediction).
    func clone() -> Satellite? {
        if let omm { return Satellite(omm: omm) }
        // JPL's data is read-only, so it's safe to share between threads.
        return spaceObject.flatMap { o in ephemeris.map { Satellite(space: o, ephemeris: $0) } }
    }

    /// TEME state at `jd`, km and km/s. Deep-space propagation is stateful, so a given
    /// Satellite must only be stepped by one thread at a time.
    func state(jd: Double) -> (r: SIMD3<Double>, v: SIMD3<Double>)? {
        guard let sat else { return ephemeris?.state(jd: jd) }
        var r = [0.0, 0.0, 0.0], v = [0.0, 0.0, 0.0]
        guard csgp4_propagate(sat, jd, &r, &v) == 1 else { return estimate(jd: jd) }
        isDecayEstimate = false
        return (SIMD3(r[0], r[1], r[2]), SIMD3(v[0], v[1], v[2]))
    }

    /// Whether any of its known downlinks falls within these ranges. Unknown frequencies never count.
    func isReachable(by ranges: [ClosedRange<Double>]) -> Bool {
        let downlinks = transmitters.filter(\.active).map(\.downlinkHz) + (decoderFrequencyHz.map { [$0] } ?? [])
        return downlinks.contains { f in f > 0 && ranges.contains { $0.contains(f) } }
    }

    /// Whether its normal model has given up on it at this moment.
    var isDecayingNow: Bool {
        _ = state(jd: Astro.julianDate())
        return isDecayEstimate
    }

    var countryISO: String { OwnerCodes.iso(for: ownerCode) }
    var countryName: String { OwnerCodes.displayName(for: ownerCode) }
    var primaryDownlink: Transmitter? {
        transmitters.first { $0.active && $0.downlinkHz > 0 } ?? transmitters.first { $0.downlinkHz > 0 }
    }
    var encryption: EncryptionInfo { EncryptionInfo.infer(for: self) }
}

/// CelesTrak GP JSON record.
struct OMM: Decodable {
    let OBJECT_NAME: String
    let OBJECT_ID: String
    let EPOCH: String
    let MEAN_MOTION: Double
    let ECCENTRICITY: Double
    let INCLINATION: Double
    let RA_OF_ASC_NODE: Double
    let ARG_OF_PERICENTER: Double
    let MEAN_ANOMALY: Double
    let NORAD_CAT_ID: Int
    let BSTAR: Double
    let MEAN_MOTION_DOT: Double
    let MEAN_MOTION_DDOT: Double
}

enum Astro {
    static let earthRadiusKm = 6378.137

    static func julianDate(_ date: Date = Date()) -> Double {
        date.timeIntervalSince1970 / 86400.0 + 2440587.5
    }

    static func julianDate(iso: String) -> Double? {
        // "2026-11-03T12:34:56.123456"
        let parts = iso.split(whereSeparator: { "-T:".contains($0) })
        guard parts.count >= 6,
              let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
              let h = Int(parts[3]), let mi = Int(parts[4]), let s = Double(parts[5]) else { return nil }
        let a = (14 - mo) / 12, yy = y + 4800 - a, mm = mo + 12 * a - 3
        let jdn = d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
        return Double(jdn) + (Double(h) - 12) / 24 + Double(mi) / 1440 + s / 86400
    }

    static func gmst(_ jd: Double) -> Double { csgp4_gmst(jd) }

    /// Rotate TEME to Earth-fixed coordinates.
    static func ecef(_ r: SIMD3<Double>, gmst g: Double) -> SIMD3<Double> {
        let c = cos(g), s = sin(g)
        return SIMD3(c * r.x + s * r.y, -s * r.x + c * r.y, r.z)
    }

    /// Unit vector to the Sun in Earth-fixed coordinates (low-precision almanac).
    static func sunDirectionECEF(jd: Double) -> SIMD3<Float> {
        let n = jd - 2451545.0
        let L = (280.460 + 0.9856474 * n) * .pi / 180
        let g = (357.528 + 0.9856003 * n) * .pi / 180
        let lambda = L + (1.915 * sin(g) + 0.020 * sin(2 * g)) * .pi / 180
        let eps = (23.439 - 0.0000004 * n) * .pi / 180
        let eci = SIMD3(cos(lambda), cos(eps) * sin(lambda), sin(eps) * sin(lambda))
        let e = ecef(eci, gmst: gmst(jd))
        return SIMD3<Float>(Float(e.x), Float(e.y), Float(e.z))
    }

    static func ecefFromGeodetic(latDeg: Double, lonDeg: Double, altKm: Double = 0) -> SIMD3<Double> {
        let lat = latDeg * .pi / 180, lon = lonDeg * .pi / 180
        let f = 1 / 298.257223563, e2 = f * (2 - f)
        let n = earthRadiusKm / sqrt(1 - e2 * sin(lat) * sin(lat))
        return SIMD3((n + altKm) * cos(lat) * cos(lon),
                     (n + altKm) * cos(lat) * sin(lon),
                     (n * (1 - e2) + altKm) * sin(lat))
    }

    /// Azimuth, elevation (degrees) and range (km) of an Earth-fixed target from a ground point.
    static func lookAngles(target: SIMD3<Double>, latDeg: Double, lonDeg: Double) -> (az: Double, el: Double, range: Double) {
        let lat = latDeg * .pi / 180, lon = lonDeg * .pi / 180
        let d = target - ecefFromGeodetic(latDeg: latDeg, lonDeg: lonDeg)
        let south = sin(lat) * cos(lon) * d.x + sin(lat) * sin(lon) * d.y - cos(lat) * d.z
        let east = -sin(lon) * d.x + cos(lon) * d.y
        let zen = cos(lat) * cos(lon) * d.x + cos(lat) * sin(lon) * d.y + sin(lat) * d.z
        let range = simd_length(d)
        var az = atan2(east, -south) * 180 / .pi
        if az < 0 { az += 360 }
        return (az, asin(zen / range) * 180 / .pi, range)
    }

    static func distanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let a = sin((lat2 - lat1) * .pi / 360), b = sin((lon2 - lon1) * .pi / 360)
        let h = a * a + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * b * b
        return 2 * 6371 * asin(min(1, sqrt(h)))
    }
}

/// CelesTrak SATCAT owner codes to ISO-3166 alpha-2 (or `eu`/`un` for international bodies).
enum OwnerCodes {
    private static let map: [String: String] = [
        "US": "us", "USBZ": "us", "ORB": "us", "IRID": "us", "GLOB": "us", "SEAL": "us", "ITSO": "us",
        "CIS": "ru", "RUS": "ru", "PRC": "cn", "UK": "gb", "IM": "gb", "FR": "fr", "FRIT": "fr", "FGER": "fr",
        "GER": "de", "JPN": "jp", "IND": "in", "ISRO": "in", "ESA": "eu", "ESRO": "eu", "EUME": "eu",
        "EUTE": "eu", "EU": "eu", "ISS": "un", "NATO": "un", "AB": "sa", "ABS": "hk", "AC": "hk",
        "ALG": "dz", "ANG": "ao", "ARGN": "ar", "ARM": "am", "ASRA": "at", "AUS": "au", "AZER": "az",
        "BEL": "be", "BELA": "by", "BERM": "bm", "BGD": "bd", "BHUT": "bt", "BOL": "bo", "BRAZ": "br",
        "BUL": "bg", "CA": "ca", "CHLE": "cl", "COL": "co", "CRI": "cr", "CZCH": "cz", "DEN": "dk",
        "DJI": "dj", "ECU": "ec", "EGYP": "eg", "EST": "ee", "ETH": "et", "FIN": "fi", "GHA": "gh",
        "GREC": "gr", "GRSA": "gr", "GUAT": "gt", "HUN": "hu", "INDO": "id", "IRAN": "ir", "IRAQ": "iq",
        "IRL": "ie", "ISRA": "il", "IT": "it", "JOR": "jo", "KAZ": "kz", "KEN": "ke", "KGZ": "kg",
        "LAOS": "la", "LKA": "lk", "LTU": "lt", "LUXE": "lu", "O3B": "lu", "SES": "lu", "MA": "ma",
        "MALA": "my", "MCO": "mc", "MDA": "md", "MEX": "mx", "MMR": "mm", "MNG": "mn", "MUS": "mu",
        "NETH": "nl", "NIG": "ng", "NKOR": "kp", "NOR": "no", "NPL": "np", "NZ": "nz", "OMAN": "om",
        "PAKI": "pk", "PERU": "pe", "POL": "pl", "POR": "pt", "PRY": "py", "QAT": "qa", "ROC": "tw",
        "ROM": "ro", "RP": "ph", "RWA": "rw", "SAFR": "za", "SAUD": "sa", "SDN": "sd", "SENE": "sn",
        "SGJP": "sg", "SING": "sg", "SKOR": "kr", "SPN": "es", "STCT": "sg", "SVK": "sk", "SVN": "si",
        "SWED": "se", "SWTZ": "ch", "THAI": "th", "TMMC": "tm", "TUN": "tn", "TURK": "tr", "UAE": "ae",
        "KWT": "kw", "MNE": "me", "BHR": "bh", "SLB": "sb", "HRV": "hr", "BWA": "bw", "UKR": "ua", "URY": "uy", "VAT": "va", "VENZ": "ve", "VTNM": "vn", "ZIM": "zw",
    ]

    static func iso(for code: String) -> String { map[code] ?? "" }

    /// English country names, in the short form people use.
    static func countryName(iso: String) -> String? {
        let name = Locale(identifier: "en_US").localizedString(forRegionCode: iso.uppercased())
        return name == "China mainland" ? "China" : name
    }

    static func displayName(for code: String) -> String {
        let iso = iso(for: code)
        switch iso {
        case "": return code.isEmpty ? "Unknown" : code
        case "eu": return "Europe (\(code))"
        case "un": return code == "ISS" ? "International" : "International (\(code))"
        default: return countryName(iso: iso) ?? code
        }
    }
}
