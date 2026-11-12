import Foundation
import simd

/// Who made and runs a satellite, from Jonathan McDowell's General Catalog of Artificial Space Objects.
struct RegistryEntry: Equatable {
    var designator = ""
    var operatorName = ""
    var builder = ""
    var massKg: Double?
    var bus = ""
    /// A amateur, B business, C civil, D defence.
    var sector = ""
}

enum SatelliteRegistry {
    /// Only ever opened in the browser for someone to read. Its terms forbid programs fetching from it
    /// without written permission, so nothing here may download this page or read what's on it.
    static func orbitalRadarPage(norad: Int) -> URL? {
        URL(string: "https://orbitalradar.com/satellite/\(norad)")
    }

    /// Whether any of the details shown are missing, which is when it's worth looking elsewhere.
    static func isMissingDetails(_ entry: RegistryEntry?) -> Bool {
        guard let entry else { return true }
        return entry.operatorName.isEmpty || entry.builder.isEmpty || entry.massKg == nil || entry.bus.isEmpty
    }

    static let catalogueURL = "https://planet4589.org/space/gcat/tsv/cat/satcat.tsv"
    static let payloadsURL = "https://planet4589.org/space/gcat/tsv/cat/psatcat.tsv"
    static let organisationsURL = "https://planet4589.org/space/gcat/tsv/tables/orgs.tsv"

    /// "GSFC" to "NASA Goddard Space Flight Center". The first listing of a code is its current one.
    static func organisations(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count > 8 else { continue }
            let code = f[0].trimmingCharacters(in: .whitespaces)
            let name = f[8].trimmingCharacters(in: .whitespaces)
            if out[code] == nil, !name.isEmpty, name != "-" { out[code] = name }
        }
        return out
    }

    /// A code or several joined by "/", in full wherever the name is known.
    static func names(_ codes: String, in organisations: [String: String]) -> String {
        let trimmed = codes.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "-" else { return "" }
        return trimmed.split(separator: "/").map { organisations[String($0)] ?? String($0) }.joined(separator: ", ")
    }

    /// Reads the catalogue's tab-separated columns, only keeping those asked for.
    /// Matches by number, then by launch designator for those GCAT numbers differently or not at all.
    static func parse(catalogue: String, payloads: String?, organisations: [String: String], wanted: Set<Int>,
                      designators: [String: Int] = [:]) -> [Int: RegistryEntry] {
        var out: [Int: RegistryEntry] = [:]
        var byDesignator: [Int: RegistryEntry] = [:]
        var byPiece: [String: Int] = [:]
        for line in catalogue.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count > 19 else { continue }
            let number = Int(f[1].trimmingCharacters(in: .whitespaces)).flatMap { wanted.contains($0) ? $0 : nil }
            guard let norad = number ?? designators[f[3].trimmingCharacters(in: .whitespaces)] else { continue }
            func text(_ i: Int) -> String {
                let s = f[i].trimmingCharacters(in: .whitespaces)
                return s == "-" ? "" : s
            }
            var entry = RegistryEntry()
            entry.designator = text(3)
            entry.operatorName = names(text(14), in: organisations)
            entry.builder = names(text(16), in: organisations)
            entry.bus = text(17)
            entry.massKg = Double(text(19))
            if number != nil { out[norad] = entry } else { byDesignator[norad] = entry }
            byPiece[f[0].trimmingCharacters(in: .whitespaces)] = norad
        }
        out.merge(byDesignator) { numbered, _ in numbered }
        for line in (payloads ?? "").split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count > 12, let norad = byPiece[f[0].trimmingCharacters(in: .whitespaces)] else { continue }
            out[norad]?.sector = String(f[12].trimmingCharacters(in: .whitespaces).prefix(1))
        }
        return out
    }

    /// SatNOGS gives one name and a comma-separated list of others.
    static func otherNames(name: String?, names: String?) -> [String] {
        ([name ?? ""] + (names ?? "").split(separator: ",").map(String.init))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// "1998-067A", "1998067A" and "98067A" all name the same launch and piece.
    static func normalisedDesignator(_ text: String) -> String? {
        let upper = text.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        guard upper.range(of: #"^\d{2}(\d{2})?\d{3}[A-Z]{0,3}$"#, options: .regularExpression) != nil else { return nil }
        // Only two-digit years need working out: the catalogue began in 1957.
        let hasFullYear = upper.range(of: #"^\d{7}"#, options: .regularExpression) != nil
        if hasFullYear { return upper }
        let year = Int(upper.prefix(2)) ?? 0
        return (year >= 57 ? "19" : "20") + upper
    }
}

/// AMSAT's amateur satellite index, which is what amsat.org/amateur-satellite-index reads.
/// SatNOGS lists a new satellite under a temporary number from 90000 up, often long after it gets its real one.
/// CelesTrak only uses real ones, so without this the two never meet, and the satellite shows no frequency.
enum SatNOGSIdentity {
    struct Row: Decodable {
        let norad_cat_id: Int?
        var norad_follow_id: Int? = nil
        var name: String? = nil
        var names: String? = nil
        var status: String? = nil
    }

    static let temporaryNumbers = 90000...99999

    /// SatNOGS's number for each satellite that the catalogue knows by another, as [theirs: catalogue's].
    /// A name only counts when it points at exactly one satellite, as a wrong match would show the wrong frequency.
    static func aliases(_ rows: [Row], catalog: [(norad: Int, name: String)]) -> [Int: Int] {
        let known = Set(catalog.map(\.norad))
        var byName: [String: Set<Int>] = [:]
        for s in catalog {
            for key in AMSATFrequencyIndex.nameKeys(s.name) where isUsable(key) { byName[key, default: []].insert(s.norad) }
        }
        var out: [Int: Int] = [:]
        for row in rows {
            guard let number = row.norad_cat_id, !known.contains(number), row.status?.lowercased() != "re-entered" else { continue }
            if let real = row.norad_follow_id, known.contains(real) {
                out[number] = real
                continue
            }
            guard temporaryNumbers.contains(number) else { continue }
            let names = [row.name ?? ""] + (row.names ?? "").split(separator: ",").map(String.init)
            let keys = names.flatMap { AMSATFrequencyIndex.nameKeys($0.trimmingCharacters(in: .whitespaces)) }.filter(isUsable)
            let hits = keys.compactMap { byName[$0] }
            // Every name it goes by has to agree.
            guard !hits.contains(where: { $0.count > 1 }), Set(hits.flatMap { $0 }).count == 1, let real = hits.first?.first else { continue }
            out[number] = real
        }
        return out
    }

    /// Too short or too generic to identify anything: "OBJECT A", or "Unknown".
    private static func isUsable(_ key: String) -> Bool {
        key.count >= 3 && !key.hasPrefix("OBJECT") && !["UNKNOWN", "TBA", "TBD"].contains(key)
    }
}

enum AMSATFrequencyIndex {
    static let url = "https://raw.githubusercontent.com/palewire/amateur-satellite-database/main/data/amsat-all-frequencies.json"

    struct Row: Decodable {
        let name: String?
        let norad_id: String?
        let downlink: String?
        let beacon: String?
        let mode: String?
        let status: String?
        var uplink: String? = nil

        /// False for what's come down, never flew or never worked, which no filter can show.
        var isInOrbit: Bool {
            !["re-entered", "to be launched", "failure"].contains(status?.lowercased() ?? "")
        }
        var isActive: Bool { status?.lowercased() == "active" }

        var talkThrough: Set<CommunicationKind> {
            guard isInOrbit, !(uplink ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
            return CommunicationKind.listed(mode: mode)
        }
    }

    /// For matching rows without a NORAD number to a satellite: "Fox-1B" and "RADFXSAT (FOX-1B)".
    static func nameKeys(_ name: String) -> [String] {
        func key(_ s: some StringProtocol) -> String { s.uppercased().filter { $0.isLetter || $0.isNumber } }
        var keys = [key(name)]
        if let open = name.firstIndex(of: "("), let close = name[open...].firstIndex(of: ")") {
            keys.append(key(name[..<open]))
            keys.append(key(name[name.index(after: open)..<close]))
        }
        return keys.filter { !$0.isEmpty }
    }

    private static let modes = ["SSTV", "SSDV", "DVB-S2", "LORA", "AFSK", "GFSK", "GMSK", "BPSK", "QPSK", "FSK", "USB", "LSB", "SSB", "CW", "FM"]

    static func modeName(_ raw: String) -> String {
        let upper = raw.uppercased()
        guard let found = modes.first(where: { upper.contains($0) }) else { return "UNKNOWN" }
        return found == "LORA" ? "LoRa" : found
    }

    /// "9k6" is 9600 baud, and "1k2" 1200.
    static func baud(_ raw: String) -> Double? {
        guard let r = raw.range(of: #"\d+k\d*"#, options: .regularExpression) else { return nil }
        let parts = raw[r].split(separator: "k", omittingEmptySubsequences: false)
        guard let whole = Double(parts[0]) else { return nil }
        let fraction = parts.count > 1 && !parts[1].isEmpty ? (Double("0." + parts[1]) ?? 0) : 0
        return (whole + fraction) * 1000
    }

    /// Downlinks only, deliberately. An uplink from this list wouldn't pass the transmit rules anyway,
    /// which need the coordination details SatNOGS records. Off-air satellites are left out.
    static func transmitters(_ row: Row) -> [Transmitter] {
        guard row.status?.lowercased() == "active" else { return [] }
        let modes = (row.mode ?? "").split(separator: "/").map(String.init)
        var out: [Transmitter] = []
        func add(_ field: String?, beacon: Bool) {
            for (i, part) in (field ?? "").split(separator: "/").enumerated() {
                let ends = part.split(separator: "-").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard let low = ends.first, low > 1, low < 300_000 else { continue }
                let raw = beacon ? "CW" : (i < modes.count ? modes[i] : modes.last ?? "")
                out.append(Transmitter(description: beacon ? "Beacon, listed by AMSAT" : "Downlink, listed by AMSAT",
                                       downlinkHz: low * 1e6, mode: modeName(raw), active: true, baud: baud(raw),
                                       downlinkHighHz: ends.count > 1 ? ends[1] * 1e6 : nil, service: "Amateur", kind: "Transmitter"))
            }
        }
        add(row.downlink, beacon: false)
        add(row.beacon, beacon: true)
        return out
    }

    /// New frequencies only: within 5 kHz of a known one is the same signal.
    static func merge(_ existing: [Transmitter], with extra: [Transmitter]) -> [Transmitter] {
        var out = existing
        for t in extra where !out.contains(where: { abs($0.downlinkHz - t.downlinkHz) < 5000 }) { out.append(t) }
        return out
    }
}

/// A spacecraft's path relative to Earth, for anything with no ordinary orbit data. Between its fixes
/// it's calculated from position and speed, and past the last one from that fix, speed and gravity.
final class SpaceEphemeris: @unchecked Sendable {
    private let lock = NSLock()
    private var track: HorizonsTrack?
    private let precession: simd_double3x3

    init(now: Double = Astro.julianDate()) {
        precession = Self.precession(toJD: now)
    }

    func set(_ new: HorizonsTrack) {
        lock.lock(); track = new; lock.unlock()
    }

    private var current: HorizonsTrack? {
        lock.lock(); defer { lock.unlock() }
        return track
    }

    var lastFixJD: Double? { current?.points.last?.jd }

    /// Whether a time is past what JPL has given it, so is only an estimate.
    func isEstimated(_ jd: Double) -> Bool { lastFixJD.map { jd > $0 } ?? false }

    /// Earth-centred position and velocity at this time, in the frame the look-angle maths uses.
    func state(jd: Double) -> (r: SIMD3<Double>, v: SIMD3<Double>)? {
        guard let track = current, let last = track.points.last, let first = track.points.first, jd >= first.jd else { return nil }
        let s = jd <= last.jd ? track.smooth(jd) : Self.extrapolate(last, to: jd)
        return s.map { (precession * $0.position, precession * $0.velocity) }
    }

    /// Past the last fix: a two-body path around whichever dominates, the Earth up close and the Sun further out.
    static func extrapolate(_ start: HorizonsTrack.Point, to jd: Double) -> HorizonsTrack.Point? {
        let days = jd - start.jd
        guard days >= 0, days <= 3650 else { return nil }
        let nearEarth = simd_length(start.position) < 3_000_000
        let earth0 = nearEarth ? SIMD3<Double>.zero : earthHeliocentric(start.jd)
        let earthV = nearEarth ? SIMD3<Double>.zero : (earthHeliocentric(start.jd + 0.01) - earthHeliocentric(start.jd - 0.01)) / (0.02 * 86400)
        let mu = nearEarth ? 398_600.4418 : 132_712_440_018.0
        var r = start.position + earth0, v = start.velocity + earthV
        // Small steps against how fast it's curving: a low orbit needs far more than a probe out past Pluto.
        let start0 = simd_length(r)
        let timescale = (start0 * start0 * start0 / mu).squareRoot()
        let steps = max(1, min(4000, Int((days * 86400 / (timescale * 0.05)).rounded(.up))))
        let h = days * 86400 / Double(steps)
        func gravity(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let d = simd_length(p)
            return -mu * p / (d * d * d)
        }
        for _ in 0..<steps {
            let a1 = gravity(r)
            let r2 = r + v * h / 2, v2 = v + a1 * h / 2
            let a2 = gravity(r2)
            let r3 = r + v2 * h / 2, v3 = v + a2 * h / 2
            let a3 = gravity(r3)
            let r4 = r + v3 * h, v4 = v + a3 * h
            let a4 = gravity(r4)
            let dr: SIMD3<Double> = v + v2 * 2.0 + v3 * 2.0 + v4
            let dv: SIMD3<Double> = a1 + a2 * 2.0 + a3 * 2.0 + a4
            r += dr * (h / 6)
            v += dv * (h / 6)
        }
        let earth1 = nearEarth ? SIMD3<Double>.zero : earthHeliocentric(jd)
        let earthV1 = nearEarth ? SIMD3<Double>.zero : (earthHeliocentric(jd + 0.01) - earthHeliocentric(jd - 0.01)) / (0.02 * 86400)
        return HorizonsTrack.Point(jd: jd, position: r - earth1, velocity: v - earthV1)
    }

    /// In km, tilted from the ecliptic to the equator like everything else here.
    static func earthHeliocentric(_ jd: Double) -> SIMD3<Double> {
        let e = Planet.all[2].position(jd: jd) * Horizons.kmPerAU
        let tilt = 23.4392911 * Double.pi / 180
        return SIMD3(e.x, e.y * cos(tilt) - e.z * sin(tilt), e.y * sin(tilt) + e.z * cos(tilt))
    }

    /// From JPL's J2000 axes to today's, about a third of a degree by now.
    static func precession(toJD jd: Double) -> simd_double3x3 {
        let t = (jd - 2451545.0) / 36525
        let arc = Double.pi / (180 * 3600)
        let zeta = (2306.2181 * t + 0.30188 * t * t) * arc
        let z = (2306.2181 * t + 1.09468 * t * t) * arc
        let theta = (2004.3109 * t - 0.42665 * t * t) * arc
        let cz = cos(z), sz = sin(z), cd = cos(zeta), sd = sin(zeta), ct = cos(theta), st = sin(theta)
        return simd_double3x3(rows: [
            SIMD3(cz * ct * cd - sz * sd, -cz * ct * sd - sz * cd, -cz * st),
            SIMD3(sz * ct * cd + cz * sd, -sz * ct * sd + cz * cd, -sz * st),
            SIMD3(st * cd, -st * sd, ct),
        ])
    }
}

extension HorizonsTrack {
    /// Follows the curve between two fixes by using each one's velocity, not just a straight line.
    func smooth(_ jd: Double) -> Point? {
        guard let first = points.first, let last = points.last, jd >= first.jd, jd <= last.jd else { return nil }
        guard let i = points.firstIndex(where: { $0.jd >= jd }) else { return last }
        if i == 0 { return first }
        let a = points[i - 1], b = points[i]
        let span = (b.jd - a.jd) * 86400
        guard span > 0 else { return a }
        let t = (jd - a.jd) / (b.jd - a.jd), t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t, h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
        let p = h00 * a.position + h10 * span * a.velocity + h01 * b.position + h11 * span * b.velocity
        return Point(jd: jd, position: p, velocity: a.velocity + (b.velocity - a.velocity) * t)
    }
}
