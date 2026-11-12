import Foundation
import MetalKit

struct TileKey: Hashable {
    let z: Int, x: Int, y: Int
    var parent: TileKey { TileKey(z: z - 1, x: x / 2, y: y / 2) }
}

/// Downloads, caches and hands out Web Mercator imagery tiles. Used from the main thread only:
/// background work comes back through the main queue before it touches any state here.
final class TileStore {
    /// Sentinel-2 cloudless 2016 by EOX, 10 m per pixel, licensed CC BY 4.0. No key needed.
    static let maxZoom = 14
    static func url(_ k: TileKey) -> URL {
        URL(string: "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/\(k.z)/\(k.y)/\(k.x).jpg")!
    }

    private let loader: MTKTextureLoader
    private let session: URLSession
    private let cacheDir: URL
    private var textures: [TileKey: (texture: MTLTexture, used: Int)] = [:]
    private var inFlight = Set<TileKey>()
    private var failedUntil: [TileKey: Date] = [:]
    private var pending: [TileKey] = []
    private var tick = 0
    private let maxInFlight = 6
    private let maxTextures = 450 // about 150 MB with mipmaps

    private(set) var downloaded = 0
    var loadedCount: Int { textures.count }
    var isBusy: Bool { !inFlight.isEmpty || !pending.isEmpty }

    init(device: MTLDevice) {
        loader = MTKTextureLoader(device: device)
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "Vessel/1.0 (macOS)"]
        c.urlCache = nil // tiles get their own disk cache, which outlives the server's expiry
        session = URLSession(configuration: c)
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vessel/tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func beginFrame() { tick += 1 }

    func texture(_ k: TileKey) -> MTLTexture? {
        guard let hit = textures[k] else { return nil }
        textures[k] = (hit.texture, tick)
        return hit.texture
    }

    /// Replaces the wait list with what this frame needs, most wanted first.
    func want(_ keys: [TileKey]) {
        let now = Date()
        pending = keys.filter { k in
            textures[k] == nil && !inFlight.contains(k) && (failedUntil[k].map { $0 < now } ?? true)
        }
        pump()
    }

    private func file(_ k: TileKey) -> URL { cacheDir.appendingPathComponent("\(k.z)_\(k.x)_\(k.y).jpg") }

    private func pump() {
        while inFlight.count < maxInFlight, !pending.isEmpty {
            let k = pending.removeFirst()
            inFlight.insert(k)
            load(k)
        }
    }

    private func load(_ k: TileKey) {
        let path = file(k)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if let d = try? Data(contentsOf: path), !d.isEmpty {
                finish(k, data: d, fromNetwork: false)
                return
            }
            session.dataTask(with: Self.url(k)) { [self] data, response, _ in
                guard let data, !data.isEmpty, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    finish(k, data: nil, fromNetwork: true)
                    return
                }
                try? data.write(to: path, options: .atomic)
                finish(k, data: data, fromNetwork: true)
            }.resume()
        }
    }

    private func finish(_ k: TileKey, data: Data?, fromNetwork: Bool) {
        let tex = data.flatMap {
            try? loader.newTexture(data: $0, options: [.generateMipmaps: true, .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        }
        DispatchQueue.main.async { [self] in
            inFlight.remove(k)
            if let tex {
                textures[k] = (tex, tick)
                if fromNetwork { downloaded += 1 }
                evict()
            } else {
                // A missing or failed tile retries later, and the coarser ones stand in meanwhile.
                failedUntil[k] = Date().addingTimeInterval(60)
            }
            pump()
        }
    }

    private func evict() {
        guard textures.count > maxTextures else { return }
        let old = textures.filter { $0.value.used < tick - 1 }.sorted { $0.value.used < $1.value.used }
        for (k, _) in old.prefix(textures.count - maxTextures) { textures[k] = nil }
    }
}
