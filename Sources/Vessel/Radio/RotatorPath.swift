import Foundation

/// A whole pass planned for a rotator with limits, so it never has to swing the long way round
/// in the middle. Positions are in the rotator's own numbers, which can exceed 360° or 90°.
struct RotatorPath: Equatable {
    struct Limits: Equatable {
        var azMin = 0.0
        var azMax = 360.0
        /// 180 for a rotator that can tilt over the top and point backwards.
        var elMax = 90.0
        /// Degrees per second. Elevation motors are typically half the speed of azimuth ones.
        var azSpeed = 6.0
        var elSpeed = 3.0
    }

    struct Position: Equatable { let az: Double; let el: Double }

    let aos: Date
    let los: Date
    let points: [Position]
    /// Seconds the antenna can't keep up, even on the best path.
    let downtime: Double

    /// Every way the rotator can point at one spot in the sky.
    static func options(az: Double, el: Double, limits: Limits) -> [Position] {
        var out: [Position] = []
        let a = az.truncatingRemainder(dividingBy: 360), base = a < 0 ? a + 360 : a
        let e = max(0, min(90, el))
        for turn in [-360.0, 0, 360] {
            let direct = base + turn
            if direct >= limits.azMin, direct <= limits.azMax, e <= limits.elMax { out.append(Position(az: direct, el: e)) }
            // Tilted over the top, facing the opposite way.
            let flipped = base + 180 + turn
            if limits.elMax >= 180 - e, limits.elMax > 90, flipped >= limits.azMin, flipped <= limits.azMax {
                out.append(Position(az: flipped, el: 180 - e))
            }
        }
        return out
    }

    /// Finds the path through the pass with the least time off target, then the least movement.
    /// `track` is the pass in plain azimuth and elevation at even intervals from rise to set.
    static func plan(track: [SatPass.Point], aos: Date, los: Date, limits: Limits, from current: Position?) -> RotatorPath? {
        guard track.count > 1 else { return nil }
        let dt = los.timeIntervalSince(aos) / Double(track.count - 1)
        let choices = track.map { options(az: $0.az, el: $0.el, limits: limits) }
        guard choices.allSatisfy({ !$0.isEmpty }) else { return nil }

        func slew(_ a: Position, _ b: Position) -> Double { max(abs(a.az - b.az) / limits.azSpeed, abs(a.el - b.el) / limits.elSpeed) }
        func movement(_ a: Position, _ b: Position) -> Double { abs(a.az - b.az) + abs(a.el - b.el) }

        // cost = (seconds off target, degrees moved), compared in that order.
        var cost: [(late: Double, moved: Double)] = choices[0].map { c in
            // Among equally good paths, start nearest to where the antenna already is.
            (0, current.map { movement($0, c) * 0.001 } ?? 0)
        }
        var back: [[Int]] = [Array(repeating: -1, count: choices[0].count)]
        for i in 1..<choices.count {
            var next: [(late: Double, moved: Double)] = []
            var from: [Int] = []
            for c in choices[i] {
                var best = (late: Double.infinity, moved: Double.infinity), bestJ = 0
                for (j, p) in choices[i - 1].enumerated() {
                    let late = cost[j].late + max(0, slew(p, c) - dt)
                    let moved = cost[j].moved + movement(p, c)
                    if late < best.late - 1e-9 || (abs(late - best.late) <= 1e-9 && moved < best.moved) { best = (late, moved); bestJ = j }
                }
                next.append(best)
                from.append(bestJ)
            }
            cost = next
            back.append(from)
        }
        guard var k = cost.indices.min(by: { (cost[$0].late, cost[$0].moved) < (cost[$1].late, cost[$1].moved) }) else { return nil }
        let downtime = cost[k].late
        var points = [Position](repeating: Position(az: 0, el: 0), count: choices.count)
        for i in stride(from: choices.count - 1, through: 0, by: -1) {
            points[i] = choices[i][k]
            k = back[i][k]
        }
        return RotatorPath(aos: aos, los: los, points: points, downtime: downtime)
    }

    /// Where the plan has the antenna at a moment during the pass.
    func position(at date: Date) -> Position? {
        guard date >= aos, date <= los, points.count > 1 else { return nil }
        let f = date.timeIntervalSince(aos) / los.timeIntervalSince(aos) * Double(points.count - 1)
        let i = min(points.count - 2, Int(f)), t = f - Double(i)
        return Position(az: points[i].az + (points[i + 1].az - points[i].az) * t, el: points[i].el + (points[i + 1].el - points[i].el) * t)
    }

    /// The largest single move the plan asks for between two samples.
    var largestStep: Double {
        zip(points, points.dropFirst()).map { abs($0.az - $1.az) }.max() ?? 0
    }
}
