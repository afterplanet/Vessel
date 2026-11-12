import Foundation
import simd

struct RadarBlip: Identifiable, Equatable {
    let id: Int // NORAD number
    let azimuth: Double
    let elevation: Double
    let orbit: OrbitClass
}

struct Approach: Identifiable, Equatable {
    let id: Int // NORAD number
    let aos: Date
    let orbit: OrbitClass
}

/// A ground point with its trigonometry worked out once, since it's used for
/// hundreds of thousands of look-angle calculations per scan.
struct GroundPoint {
    let position: SIMD3<Double>
    private let sinLat, cosLat, sinLon, cosLon: Double

    init(lat: Double, lon: Double) {
        position = Astro.ecefFromGeodetic(latDeg: lat, lonDeg: lon)
        sinLat = sin(lat * .pi / 180); cosLat = cos(lat * .pi / 180)
        sinLon = sin(lon * .pi / 180); cosLon = cos(lon * .pi / 180)
    }

    func elevation(of target: SIMD3<Double>) -> Double {
        let d = target - position
        let zenith = cosLat * cosLon * d.x + cosLat * sinLon * d.y + sinLat * d.z
        return asin(zenith / simd_length(d)) * 180 / .pi
    }

    func look(at target: SIMD3<Double>) -> (az: Double, el: Double) {
        let d = target - position
        let south = sinLat * cosLon * d.x + sinLat * sinLon * d.y - cosLat * d.z
        let east = -sinLon * d.x + cosLon * d.y
        var az = atan2(east, -south) * 180 / .pi
        if az < 0 { az += 360 }
        return (az, elevation(of: target))
    }
}

/// Works out what's overhead and what rises next at the selected address. It steps its own copy
/// of every satellite on a private queue, because propagators can't be shared between threads.
@MainActor
final class RadarTracker: ObservableObject {
    /// The true horizon, the same line the Passes panel uses, so the two always agree.
    nonisolated static let passElevation = 0.0
    nonisolated static let maxShown = 24
    /// How many recent arrivals stay on the plot below the highest-first limit.
    nonisolated static let maxArrivals = 6

    /// What the radar shows, highest first. Anything the filters hide is dropped before the limit
    /// is applied, so a filter narrows the sky instead of emptying it. Geostationary and deep-space
    /// objects hang still rather than pass, so they appear only when their own type is chosen.
    nonisolated static func passing(_ blips: [RadarBlip], filter: OrbitClass?, keep: (Int) -> Bool = { _ in true }) -> [RadarBlip] {
        let shown = blips.filter { b in
            guard b.elevation >= passElevation, keep(b.id) else { return false }
            if let filter { return b.orbit == filter }
            return b.orbit != .geo && b.orbit != .deep
        }
        return Array(shown.sorted { $0.elevation > $1.elevation }.prefix(maxShown))
    }

    /// The highest that pass, plus every arrival still up, however low. The filters apply to both.
    nonisolated static func inView(_ blips: [RadarBlip], filter: OrbitClass?, arrived: Set<Int>, keep: (Int) -> Bool = { _ in true }) -> [RadarBlip] {
        var list = passing(blips, filter: filter, keep: keep)
        let have = Set(list.map(\.id))
        for b in blips where arrived.contains(b.id) && !have.contains(b.id) && keep(b.id) && (filter == nil || b.orbit == filter) {
            list.append(b)
        }
        return list.sorted { $0.elevation > $1.elevation }
    }

    /// The moment something changes between two times, to about a second, by halving the gap.
    nonisolated static func crossing(from lo: Double, to hi: Double, isAfter: (Double) -> Bool) -> Double {
        var a = lo, b = hi
        while b - a > 1 {
            let mid = (a + b) / 2
            if isAfter(mid) { b = mid } else { a = mid }
        }
        return b
    }

    /// Satellites the filters hide. They're left out of what's approaching.
    func setHidden(_ ids: Set<Int>) {
        guard ids != hidden else { return }
        hidden = ids
        generation += 1
        engine.setHidden(ids)
        scanningApproaches = false
        refresh(includeApproaches: true)
    }
    private var hidden: Set<Int> = []

    @Published private(set) var blips: [RadarBlip] = []
    @Published private(set) var approaches: [Approach] = []
    /// Approaching satellites that have since risen. They stay on the plot until they set, even
    /// when the highest-first limit would leave them out.
    @Published private(set) var arrived: Set<Int> = []
    /// Every approach seen, by when it rises, so its arrival can be noticed.
    private var expected: [Int: Date] = [:]

    /// The approaches the panel lists. Only these are followed onto the plot when they rise, so
    /// the plot gains what you were told was coming, not every low pass at once.
    func watch(_ list: [Approach]) {
        for a in list where !arrived.contains(a.id) { expected[a.id] = a.aos }
    }

    /// Moves risen approaches into `arrived`, and forgets them once they've set.
    nonisolated static func follow(expected: [Int: Date], arrived: Set<Int>, visible: Set<Int>, now: Date)
        -> (expected: [Int: Date], arrived: Set<Int>) {
        var expected = expected, arrived = arrived
        for (id, aos) in expected where aos <= now {
            if visible.contains(id) {
                arrived.insert(id)
            } else if arrived.contains(id) || aos < now.addingTimeInterval(-60) {
                // Set again, or never seen rising: its next approach is found afresh.
                expected[id] = nil
                arrived.remove(id)
            }
        }
        arrived = arrived.filter { visible.contains($0) && expected[$0] != nil }
        // Only the latest few. In a busy sky something rises every few seconds, and keeping them
        // all would ring the horizon with dots.
        if arrived.count > maxArrivals {
            let newest = arrived.sorted { (expected[$0] ?? .distantPast) > (expected[$1] ?? .distantPast) }
            for id in newest.dropFirst(maxArrivals) { arrived.remove(id); expected[id] = nil }
        }
        return (expected, arrived)
    }
    @Published private(set) var hasStation = false

    private let engine = Engine()
    private var timer: Timer?
    private var seconds = 0
    private var scanning = false
    private var scanningApproaches = false
    private var generation = 0

    func setSatellites(_ list: [Satellite]) {
        generation += 1
        engine.setSatellites(list)
        refresh(includeApproaches: true)
    }

    func setStation(_ s: Station?) {
        generation += 1
        hasStation = s != nil
        blips = []
        approaches = []
        arrived = []
        expected = [:]
        engine.setStation(s.map { GroundPoint(lat: $0.lat, lon: $0.lon) })
        refresh(includeApproaches: true)
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.seconds += 1
                self.refresh(includeApproaches: self.seconds % 20 == 0)
            }
        }
    }

    private func refresh(includeApproaches: Bool) {
        guard hasStation else { return }
        let gen = generation
        if !scanning {
            scanning = true
            engine.scanBlips { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.scanning = false
                    if gen == self.generation, let result {
                        self.blips = result
                        let f = Self.follow(expected: self.expected, arrived: self.arrived,
                                            visible: Set(result.map(\.id)), now: Date())
                        self.expected = f.expected
                        if f.arrived != self.arrived { self.arrived = f.arrived }
                    }
                }
            }
        }
        if includeApproaches, !scanningApproaches {
            scanningApproaches = true
            engine.scanApproaches { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.scanningApproaches = false
                    if gen == self.generation, let result {
                        self.approaches = result
                    }
                }
            }
        }
    }

    /// Owns the propagator copies. Everything in here runs on `queue`.
    private final class Engine: @unchecked Sendable {
        private struct Entry {
            let norad: Int
            let orbit: OrbitClass
            let sat: Satellite
            /// Short-period orbits rise and set in minutes, so they need finer steps.
            let isFast: Bool
        }

        private let queue = DispatchQueue(label: "vessel.radar", qos: .utility)
        private var entries: [Entry] = []
        private var ground: GroundPoint?

        func setSatellites(_ list: [Satellite]) {
            nonisolated(unsafe) let source = list
            queue.async { [self] in
                entries = source.compactMap { s in
                    guard let copy = s.clone() else { return nil }
                    return Entry(norad: s.norad, orbit: s.orbit, sat: copy, isFast: s.periodMinutes < 200)
                }
            }
        }

        private var hidden: Set<Int> = []
        func setHidden(_ ids: Set<Int>) { queue.async { [self] in hidden = ids } }

        func setStation(_ g: GroundPoint?) {
            queue.async { [self] in ground = g }
        }

        private func forEachChunk(_ body: (Int, Range<Int>) -> Void) {
            let chunks = 8, per = entries.count / chunks + 1, count = entries.count
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let start = c * per
                if start < count { body(c, start..<min(count, start + per)) }
            }
        }

        func scanBlips(_ done: @escaping @Sendable ([RadarBlip]?) -> Void) {
            queue.async { [self] in
                guard let ground else { done(nil); return }
                let jd = Astro.julianDate(), g = Astro.gmst(jd)
                let lock = NSLock()
                var out: [RadarBlip] = []
                forEachChunk { _, range in
                    var local: [RadarBlip] = []
                    for i in range {
                        let e = entries[i]
                        guard let r = e.sat.position(jd: jd) else { continue }
                        let p = Astro.ecef(r, gmst: g)
                        if ground.elevation(of: p) > 0 {
                            let l = ground.look(at: p)
                            local.append(RadarBlip(id: e.norad, azimuth: l.az, elevation: l.el, orbit: e.orbit))
                        }
                    }
                    lock.lock(); out += local; lock.unlock()
                }
                done(out)
            }
        }

        func scanApproaches(_ done: @escaping @Sendable ([Approach]?) -> Void) {
            queue.async { [self] in
                guard let ground else { done(nil); return }
                let start = Date()
                let jd0 = Astro.julianDate(start)
                // Fast orbits: 15 minutes in 20 s steps. Slow ones are rarer, so look 3 hours ahead.
                let lock = NSLock()
                var found: [Approach] = []
                let hidden = self.hidden
                forEachChunk { _, range in
                    var local: [Approach] = []
                    for i in range {
                        let e = entries[i]
                        if hidden.contains(e.norad) { continue }
                        let step = e.isFast ? 20.0 : 60.0
                        let count = e.isFast ? 45 : 180
                        func elevation(_ seconds: Double) -> Double? {
                            let jd = jd0 + seconds / 86400
                            guard let r = e.sat.position(jd: jd) else { return nil }
                            return ground.elevation(of: Astro.ecef(r, gmst: Astro.gmst(jd)))
                        }
                        // Already in the radar's view means it isn't approaching.
                        let mask = RadarTracker.passElevation
                        guard var previous = elevation(0), previous < mask else { continue }
                        for k in 1...count {
                            let t = Double(k) * step
                            guard let el = elevation(t) else { break }
                            if el >= mask {
                                // Narrowed down to the second it clears the horizon.
                                let cross = RadarTracker.crossing(from: t - step, to: t) { (elevation($0) ?? -90) >= mask }
                                local.append(Approach(id: e.norad, aos: start.addingTimeInterval(cross), orbit: e.orbit))
                                break
                            }
                            previous = el
                        }
                    }
                    lock.lock(); found += local; lock.unlock()
                }
                // Enough of each type that filtering to a rare one still fills the list.
                var kept: [Approach] = []
                for (_, group) in Dictionary(grouping: found, by: \.orbit) {
                    kept += group.sorted { $0.aos < $1.aos }.prefix(40)
                }
                done(kept.sorted { $0.aos < $1.aos })
            }
        }
    }
}
