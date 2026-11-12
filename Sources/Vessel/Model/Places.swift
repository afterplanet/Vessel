import Foundation

/// Nearest town for a coordinate, from GeoNames (CC BY 4.0). Public directories give only a
/// position, and looking up hundreds of hosts online would run into rate limits.
final class Places {
    struct Place { let lat: Float; let lon: Float; let name: String; let state: String }

    static let shared = Places(file: Res.url("places.tsv"))
    /// Beyond this a "nearest town" would mislead more than it helps.
    static let maxDistanceKm = 100.0

    private var grid: [Int: [Place]] = [:]

    init(file: URL?) {
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 4, let lat = Float(f[0]), let lon = Float(f[1]) else { continue }
            grid[Self.cell(lat, lon), default: []].append(Place(lat: lat, lon: lon, name: String(f[2]), state: String(f[3])))
        }
    }

    init(places: [Place]) {
        for p in places { grid[Self.cell(p.lat, p.lon), default: []].append(p) }
    }

    private static func cell(_ lat: Float, _ lon: Float) -> Int {
        Int((lat + 90).rounded(.down)) * 1000 + Int((lon + 180).rounded(.down))
    }

    func nearest(lat: Double, lon: Double) -> Place? {
        // A degree of longitude shrinks towards the poles, so search wider up there.
        let reach = max(2, min(30, Int(ceil(1 / max(0.05, cos(lat * .pi / 180))) * 2)))
        let row = Int((Float(lat) + 90).rounded(.down)), col = Int((Float(lon) + 180).rounded(.down))
        var best: Place?
        var bestKm = Self.maxDistanceKm
        for r in (row - 2)...(row + 2) {
            for c in (col - reach)...(col + reach) {
                let wrapped = (c + 360) % 360
                for p in grid[r * 1000 + wrapped] ?? [] {
                    let km = Astro.distanceKm(lat1: lat, lon1: lon, lat2: Double(p.lat), lon2: Double(p.lon))
                    if km < bestKm { bestKm = km; best = p }
                }
            }
        }
        return best
    }
}
