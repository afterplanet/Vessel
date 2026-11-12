import Foundation

/// When a satellite next comes over a host's horizon.
struct HostArrival: Equatable {
    var aos: Date
    /// Nil if it's still up when the prediction window ends.
    var los: Date?
    var maxElevation: Double

    func inView(at now: Date = Date()) -> Bool {
        aos <= now && (los.map { now < $0 } ?? true)
    }
}

/// One orbit track checked against every host, so a whole directory costs little more than one satellite.
enum HostPasses {
    struct Sample {
        let jd: Double
        let position: SIMD3<Double>
    }

    static let windowHours = 24.0

    static func track(_ sat: Satellite, from start: Double, hours: Double = windowHours) -> [Sample] {
        let step = min(60.0, max(15.0, sat.periodMinutes * 60 / 120)) / 86400
        let count = Int(hours / 24 / step)
        return (0...count).compactMap { i in
            let jd = start + Double(i) * step
            guard let s = sat.state(jd: jd) else { return nil }
            return Sample(jd: jd, position: Astro.ecef(s.r, gmst: Astro.gmst(jd)))
        }
    }

    /// The first pass on the track, or nil if it never rises. Horizon crossings are interpolated between samples.
    static func firstPass(on track: [Sample], ground: GroundPoint) -> HostArrival? {
        func date(_ jd: Double) -> Date { Date(timeIntervalSince1970: (jd - 2440587.5) * 86400) }
        func crossing(_ a: Sample, _ ea: Double, _ b: Sample, _ eb: Double) -> Double {
            a.jd + (b.jd - a.jd) * ea / (ea - eb)
        }
        var aos: Double?
        var highest = -90.0
        var previous: (sample: Sample, el: Double)?
        for sample in track {
            let el = ground.elevation(of: sample.position)
            if el > 0 {
                if aos == nil { aos = previous.map { crossing($0.sample, $0.el, sample, el) } ?? sample.jd }
                highest = max(highest, el)
            } else if let rise = aos, let p = previous {
                return HostArrival(aos: date(rise), los: date(crossing(p.sample, p.el, sample, el)), maxElevation: highest)
            }
            previous = (sample, el)
        }
        return aos.map { HostArrival(aos: date($0), los: nil, maxElevation: highest) }
    }

    /// Hosts that could hear it: the satellite comes over them, they can tune to it, and they're alive.
    /// In view first, then soonest to arrive.
    static func listing(_ hosts: [SpyHost], arrivals: [String: HostArrival], frequency: Double?,
                        status: (SpyHost) -> HostStatus) -> [SpyHost] {
        hosts.compactMap { h -> (SpyHost, HostArrival)? in
            guard let a = arrivals[h.id], status(h) != .dead, frequency.map(h.covers) ?? true else { return nil }
            return (h, a)
        }
        .sorted { x, y in
            if x.1.aos != y.1.aos { return x.1.aos < y.1.aos }
            if x.1.maxElevation != y.1.maxElevation { return x.1.maxElevation > y.1.maxElevation }
            return x.0.id < y.0.id
        }
        .map(\.0)
    }
}
