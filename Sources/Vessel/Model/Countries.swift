import Foundation
import AppKit
import SwiftUI

/// Natural Earth 1:50m outlines: drawn as borders on the globe, and used offline to work out
/// which country a spy host is in (the Airspy directory only publishes coordinates).
final class Countries {
    struct Country: Decodable {
        let iso: String
        let name: String
        let rings: [[Float]]
    }

    static let shared = Countries()
    let all: [Country]
    private var boxes: [[(minLon: Float, maxLon: Float, minLat: Float, maxLat: Float)]] = []

    private init() {
        guard let u = Res.url("countries.json"), let d = try? Data(contentsOf: u),
              let list = try? JSONDecoder().decode([Country].self, from: d) else { all = []; return }
        all = list
        boxes = list.map { c in
            c.rings.map { r in
                var b = (minLon: Float(999), maxLon: Float(-999), minLat: Float(999), maxLat: Float(-999))
                var i = 0
                while i + 1 < r.count {
                    b.minLon = min(b.minLon, r[i]); b.maxLon = max(b.maxLon, r[i])
                    b.minLat = min(b.minLat, r[i + 1]); b.maxLat = max(b.maxLat, r[i + 1])
                    i += 2
                }
                return b
            }
        }
    }

    /// ISO code at a coordinate, or the nearest coastline's within about 3° for hosts on small islands.
    func iso(lat: Double, lon: Double) -> String {
        let x = Float(lon), y = Float(lat)
        for (ci, c) in all.enumerated() {
            for (ri, r) in c.rings.enumerated() {
                let b = boxes[ci][ri]
                if x < b.minLon || x > b.maxLon || y < b.minLat || y > b.maxLat { continue }
                if Self.contains(r, x, y) { return c.iso }
            }
        }
        var best = ""
        var bestD = Float(9)
        for (ci, c) in all.enumerated() {
            for (ri, r) in c.rings.enumerated() {
                let b = boxes[ci][ri]
                if x < b.minLon - 3 || x > b.maxLon + 3 || y < b.minLat - 3 || y > b.maxLat + 3 { continue }
                var i = 0
                while i + 1 < r.count {
                    let dx = r[i] - x, dy = r[i + 1] - y, d = dx * dx + dy * dy
                    if d < bestD { bestD = d; best = c.iso }
                    i += 2
                }
            }
        }
        return best
    }

    private static func contains(_ r: [Float], _ x: Float, _ y: Float) -> Bool {
        var inside = false
        let n = r.count / 2
        var j = n - 1
        for i in 0..<n {
            let xi = r[i * 2], yi = r[i * 2 + 1], xj = r[j * 2], yj = r[j * 2 + 1]
            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }
}

/// An SVG flag from the bundled flag-icons set.
struct FlagView: View {
    let iso: String
    var height: CGFloat = 14

    private static let cache = NSCache<NSString, NSImage>()

    /// A flag at menu size. Menus draw an image at its own size, so this copy sets one.
    static func menuImage(_ iso: String) -> NSImage? {
        guard let copy = image(iso)?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 12)
        return copy
    }

    private static func image(_ iso: String) -> NSImage? {
        let key = iso as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard !iso.isEmpty, let u = Res.url("flags/\(iso).svg"),
              let img = NSImage(contentsOf: u) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    var body: some View {
        Group {
            if let img = Self.image(iso) {
                Image(nsImage: img).resizable().aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            } else {
                Image(systemName: "globe").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
            }
        }
        .frame(height: height)
    }
}
