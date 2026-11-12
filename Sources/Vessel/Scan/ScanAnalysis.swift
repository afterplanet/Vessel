import Foundation

/// A stretch of spectrum worth searching.
struct ScanBand: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let lowHz: Double
    let highHz: Double

    /// Whether a receiver can tune to all of it. With its range unknown, nothing is ruled out.
    func isReachable(by ranges: [ClosedRange<Double>]?) -> Bool {
        ranges?.contains { $0.contains(lowHz) && $0.contains(highHz) } ?? true
    }

    static let all = [
        ScanBand(name: "VHF weather, 137 to 138 MHz", lowHz: 137_000_000, highHz: 138_000_000),
        ScanBand(name: "VHF amateur, 145.8 to 146 MHz", lowHz: 145_800_000, highHz: 146_000_000),
        ScanBand(name: "VHF data, 148 to 150 MHz", lowHz: 148_000_000, highHz: 150_000_000),
        ScanBand(name: "UHF satcom, 240 to 270 MHz", lowHz: 240_000_000, highHz: 270_000_000),
        ScanBand(name: "UHF data, 400 to 403 MHz", lowHz: 400_000_000, highHz: 403_000_000),
        ScanBand(name: "UHF amateur, 435 to 438 MHz", lowHz: 435_000_000, highHz: 438_000_000),
        ScanBand(name: "L-band, 1525 to 1559 MHz", lowHz: 1_525_000_000, highHz: 1_559_000_000),
        ScanBand(name: "L-band weather, 1670 to 1710 MHz", lowHz: 1_670_000_000, highHz: 1_710_000_000),
    ]

    /// Where a satellite of this kind usually transmits. Wide bands are left off unless they're
    /// likely, because every extra window slows each sweep.
    static func likely(for category: SatCategory) -> [ScanBand] {
        func named(_ prefixes: String...) -> [ScanBand] { all.filter { b in prefixes.contains { b.name.hasPrefix($0) } } }
        switch category {
        case .weather: return named("VHF weather", "L-band weather")
        case .amateur, .education: return named("VHF amateur", "UHF amateur", "UHF data")
        case .military: return named("UHF satcom", "UHF data")
        case .communications: return named("VHF weather", "VHF data", "UHF data")
        case .navigation: return named("L-band, ")
        default: return named("VHF weather", "VHF amateur", "UHF data", "UHF amateur")
        }
    }

    func reachable(minHz: Double, maxHz: Double) -> Bool { highHz > minHz && lowHz < maxHz }
}

/// One tune of the receiver.
struct ScanWindow: Hashable, Identifiable {
    var id: Double { centerHz }
    let centerHz: Double
    let spanHz: Double
    var lowHz: Double { centerHz - spanHz / 2 }
    var highHz: Double { centerHz + spanHz / 2 }

    /// Steps across the bands with enough overlap that filter edges don't hide anything.
    static func plan(bands: [ScanBand], maxBandwidth: Double, minHz: Double, maxHz: Double, widest: Double = 2_000_000) -> (windows: [ScanWindow], stage: Int) {
        var stage = 0
        while maxBandwidth / pow(2, Double(stage)) > widest, stage < 10 { stage += 1 }
        let span = maxBandwidth / pow(2, Double(stage))
        let step = span * 0.85
        var out: [ScanWindow] = []
        for b in bands {
            let low = max(b.lowHz, minHz), high = min(b.highHz, maxHz)
            guard high > low else { continue }
            var c = low + span * 0.42
            repeat {
                out.append(ScanWindow(centerHz: c, spanHz: span))
                c += step
            } while c - span * 0.42 < high
        }
        return (out, stage)
    }
}

struct ScanDetection: Equatable {
    let hz: Double
    let excessDB: Float
    let widthHz: Double
}

enum ScanPeaks {
    static let threshold: Float = 6

    /// Signals in a time-averaged spectrum, in dB. Skips the filter edges and the receiver's centre spike.
    static func find(spectrum v: [Float], centerHz: Double, spanHz: Double) -> [ScanDetection] {
        let n = v.count
        guard n > 40 else { return [] }
        let edge = n / 16
        let mid = Array(v[edge..<(n - edge)]).sorted()
        let floorDB = mid[mid.count / 2]
        let binHz = spanHz / Double(n)
        let centre = n / 2
        let guardBins = max(2, n / 512)
        var out: [ScanDetection] = []
        var run: [Int] = []
        func close() {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let peak = run.max { v[$0] < v[$1] }!
            out.append(ScanDetection(hz: centerHz + (Double(peak) + 0.5 - Double(centre)) * binHz,
                                     excessDB: v[peak] - floorDB, widthHz: Double(run.count) * binHz))
        }
        for i in edge..<(n - edge) {
            if abs(i - centre) <= guardBins { close(); continue }
            if v[i] - floorDB >= threshold { run.append(i) } else { close() }
        }
        close()
        return out
    }
}

/// What a signal's behaviour says about where it comes from.
enum ScanVerdict: Int, Comparable {
    /// It drifted as this satellite's orbit predicts.
    case dopplerMatch
    /// The satellite barely drifts right now, so this can't be told apart yet.
    case undetermined
    /// It drifted, but not the way this satellite would.
    case otherMover
    /// It stayed put while this satellite's Doppler moved, so it's on the ground.
    case fixed

    static func < (a: ScanVerdict, b: ScanVerdict) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .dopplerMatch: "Follows this satellite's Doppler"
        case .undetermined: "Can't tell yet"
        case .otherMover: "Drifting, but not like this satellite"
        case .fixed: "Fixed, likely on the ground"
        }
    }
}

struct ScanCandidate: Identifiable, Equatable {
    var id: Int
    /// What the satellite transmits, with Doppler taken out when the signal follows it.
    var restHz: Double
    var lastHz: Double
    var strengthDB: Float
    var widthHz: Double
    var sightings: Int
    var verdict: ScanVerdict
}

/// Follows detections across sweeps and tests each against the satellite's predicted Doppler.
struct ScanTracker {
    struct Sighting {
        let hz: Double
        let rangeRate: Double
        let time: TimeInterval
        let excessDB: Float
        let widthHz: Double
    }

    private(set) var tracks: [[Sighting]] = []
    let resolutionHz: Double

    init(resolutionHz: Double) { self.resolutionHz = resolutionHz }

    private static func rest(_ s: Sighting) -> Double { s.hz / (1 - s.rangeRate / Doppler.c) }

    mutating func add(_ d: ScanDetection, rangeRate rr: Double, time: TimeInterval) {
        let s = Sighting(hz: d.hz, rangeRate: rr, time: time, excessDB: d.excessDB, widthHz: d.widthHz)
        let tolerance = max(resolutionHz * 2.5, d.widthHz / 2)
        // Joins a track if it could be the same signal, whether fixed or following the orbit.
        var best: (index: Int, distance: Double)?
        for (i, t) in tracks.enumerated() {
            guard let last = t.last else { continue }
            let fixedGap = abs(last.hz - d.hz)
            let orbitGap = abs(Self.rest(last) - Self.rest(s))
            let gap = min(fixedGap, orbitGap)
            if gap <= tolerance, gap < (best?.distance ?? .infinity) { best = (i, gap) }
        }
        if let best { tracks[best.index].append(s) } else { tracks.append([s]) }
    }

    /// Pieces of one wide signal show up as many narrow peaks, so anything this close is one signal.
    static let mergeHz = 15_000.0

    /// Best prospects first. A single sighting could be anything, so it needs a second to count.
    var candidates: [ScanCandidate] {
        var single: [ScanCandidate] = []
        for (i, t) in tracks.enumerated() where t.count >= 2 {
            guard let last = t.last else { continue }
            let verdict = Self.verdict(t, resolutionHz)
            single.append(ScanCandidate(id: i, restHz: verdict == .dopplerMatch ? Self.mean(t.map(Self.rest)) : Self.mean(t.map(\.hz)),
                                        lastHz: last.hz, strengthDB: t.map(\.excessDB).max() ?? 0, widthHz: t.map(\.widthHz).max() ?? 0,
                                        sightings: t.count, verdict: verdict))
        }
        var merged: [ScanCandidate] = []
        var lowEdge = 0.0
        for c in single.sorted(by: { $0.lastHz < $1.lastHz }) {
            guard var top = merged.last, c.lastHz - top.lastHz <= Self.mergeHz else {
                merged.append(c)
                lowEdge = c.lastHz - c.widthHz / 2
                continue
            }
            // The evidence comes from whichever piece was seen most, and it stays the headline.
            if c.sightings > top.sightings || (c.verdict == .dopplerMatch && top.verdict != .dopplerMatch) {
                top.restHz = c.restHz
                top.verdict = c.verdict
                top.sightings = c.sightings
            }
            top.strengthDB = max(top.strengthDB, c.strengthDB)
            top.widthHz = max(top.widthHz, c.lastHz + c.widthHz / 2 - lowEdge)
            top.lastHz = c.lastHz
            merged[merged.count - 1] = top
        }
        return merged.sorted { a, b in
            if a.verdict != b.verdict { return a.verdict < b.verdict }
            return a.strengthDB > b.strengthDB
        }
    }

    private static func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }
    private static func spread(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }

    static let minMatchSightings = 6
    static let minMatchSeconds = 30.0

    static func verdict(_ t: [Sighting], _ resolution: Double) -> ScanVerdict {
        let raw = t.map(\.hz), rests = t.map(Self.rest)
        let f = mean(raw)
        let predicted = spread(t.map { f * $0.rangeRate / Doppler.c })
        // The drift has to be several bins before it says anything at all.
        guard predicted >= resolution * 4 else {
            return spread(raw) >= resolution * 4 ? .otherMover : .undetermined
        }
        let tolerance = max(resolution * 2, predicted * 0.25)
        // A few chance sightings can line up, so a match has to hold over a good stretch of the pass.
        let span = (t.last?.time ?? 0) - (t.first?.time ?? 0)
        if spread(rests) <= tolerance { return t.count >= minMatchSightings && span >= minMatchSeconds ? .dopplerMatch : .undetermined }
        if spread(raw) <= tolerance { return .fixed }
        return .otherMover
    }
}

enum ScanWords {
    static func hz(_ v: Double) -> String { String(format: "%.4f MHz", v / 1e6) }
}
