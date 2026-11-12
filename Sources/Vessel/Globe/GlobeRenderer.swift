import MetalKit
import simd
import AppKit

struct Uniforms {
    var viewProj: simd_float4x4
    var eye: SIMD3<Float>
    var pointSize: Float
    var sun: SIMD3<Float>
    var dt: Float
    var cosG: Float
    var sinG: Float
    var viewport: SIMD2<Float>
    var time: Float
    var filterClass: Int32 = -1
    var lockedIndex: Int32 = -1
    var regionMarker: Int32 = 0
}

/// Particles grow as a filter narrows the results, up to the size of the icon a locked satellite wears.
enum ParticleSize {
    static let iconPoints: Float = 36

    /// 0 with everything showing, 1 with a single satellite. Logarithmic, and squared so a broad
    /// filter barely changes anything and most of the growth comes with the last few results.
    static func growth(shown: Int, total: Int) -> Float {
        guard total > 1, shown < total else { return 0 }
        let t = 1 - log(Float(max(shown, 1))) / log(Float(total))
        return t * t
    }

    static func points(base: Float, growth: Float) -> Float {
        min(iconPoints, max(base, base + (iconPoints - base) * growth))
    }
}

/// Matches `Particle` in the shader: tightly packed, 40 bytes.
struct ParticleVertex {
    var px, py, pz, vx, vy, vz, r, g, b, a: Float
}

struct TileParams {
    var lon0, dLon, merc0, dMerc, u0, v0, uvScale, fade: Float
}

enum Palette {
    static func color(_ o: OrbitClass) -> SIMD4<Float> {
        switch o {
        case .leo: SIMD4(0.22, 0.58, 1.0, 1)
        case .meo: SIMD4(0.68, 0.38, 1.0, 1)
        case .geo: SIMD4(1.0, 1.0, 1.0, 1)
        case .sso: SIMD4(1.0, 0.58, 0.12, 1)
        case .heo: SIMD4(1.0, 0.16, 0.85, 1)
        case .deep: SIMD4(0.18, 1.0, 0.42, 1)
        case .spacecraft: SIMD4(1.0, 0.82, 0.25, 1)
        }
    }
}

/// A published batch of propagated states, in Earth radii and Earth radii per second.
final class StateFrame {
    let buffer: MTLBuffer
    let count: Int
    let jd: Double
    let wallTime: CFTimeInterval
    let sats: [Satellite]
    let indexByNorad: [Int: Int]
    /// Parallel to `sats`; satellites that failed to propagate are flagged with a NaN x.
    let pos: [SIMD3<Float>]
    let vel: [SIMD3<Float>]

    init(buffer: MTLBuffer, count: Int, jd: Double, wallTime: CFTimeInterval, sats: [Satellite], indexByNorad: [Int: Int],
         pos: [SIMD3<Float>], vel: [SIMD3<Float>]) {
        self.buffer = buffer; self.count = count; self.jd = jd; self.wallTime = wallTime
        self.sats = sats; self.indexByNorad = indexByNorad; self.pos = pos; self.vel = vel
    }
}

final class GlobeRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var earthPipe, tilePipe, atmoPipe, starPipe, particlePipe, markerPipe, iconPipe, linePipeECEF, linePipeTEME: MTLRenderPipelineState!
    private var depthOn, depthRead, depthOff: MTLDepthStencilState!
    private var sphereV, sphereI, atmoV, atmoI, stars, borders: MTLBuffer!
    private var sphereCount = 0, atmoCount = 0, borderCount = 0
    private let starCount = 3500
    private var day, night, water, icon: MTLTexture?
    private var sampler: MTLSamplerState!
    private var iconSampler: MTLSamplerState!
    private var tileSampler: MTLSamplerState!
    private var tileGrid, tileIndices: MTLBuffer!
    private var tileIndexCount = 0
    let tiles: TileStore
    /// Off only for before-and-after sharpness checks.
    var tilesEnabled = true
    private(set) var tilesDrawn = 0
    private(set) var deepestTile = 0

    // Camera, in Earth-fixed coordinates: looks at the centre from (lon, lat, distance).
    var lon: Float = -40, lat: Float = 22, distance: Float = 4.2
    var lonVel: Float = 0, latVel: Float = 0
    var targetDistance: Float = 4.2
    private var viewportPts = SIMD2<Float>(1, 1)
    private var viewProj = matrix_identity_float4x4
    private var eye = SIMD3<Float>(0, 0, 1)
    private let fovY: Float = 32 * .pi / 180

    // Live state.
    private let lock = NSLock()
    private var frameState: StateFrame?
    private var track: MTLBuffer?
    private var trackCount = 0
    private var trackForNorad: Int?
    private var trackJD = 0.0
    var lockedNorad: Int?
    var hoveredNorad: Int?
    /// Selected address, on the drawn sphere so the marker sits exactly on the map.
    var stationPoint: SIMD3<Float>?
    var orbitFilter: OrbitClass?
    var regionPoint: SIMD3<Float>?
    var shownCount = 0
    var totalCount = 0
    private var particleGrowth: Float = 0
    private var particlePoints: Float = 4
    /// Where the camera is gliding to, in degrees.
    private var flyTarget: (lon: Float, lat: Float)?
    var follow = false
    /// Called on the main thread after each draw so labels can stick to their targets.
    var onDrawn: (() -> Void)?
    var onTexturesReady: (() -> Void)?
    var onTextureProblem: ((Int) -> Void)?
    private(set) var framesDrawn = 0
    /// Set from a self-test to prove the retry works.
    nonisolated(unsafe) static var failedLoadsForTesting = 0
    /// One-shot readback of the next frame, for the `--snapshot` launch option.
    var captureNext: ((CGImage?) -> Void)?

    private static func image(from tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height, row = w * 4
        var bytes = [UInt8](repeating: 0, count: row * h)
        tex.getBytes(&bytes, bytesPerRow: row, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
    }

    init?(view: MTKView) {
        guard let d = view.device ?? MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        device = d; queue = q
        tiles = TileStore(device: d)
        super.init()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.004, green: 0.006, blue: 0.012, alpha: 1)
        view.preferredFramesPerSecond = 60
        do { try buildPipelines(view) } catch { NSLog("Vessel shader error: \(error)"); return nil }
        buildGeometry()
        loadTextures()
    }

    private func buildPipelines(_ view: MTKView) throws {
        let lib = try device.makeLibrary(source: metalShaderSource, options: nil)
        func pipe(_ v: String, _ f: String, blend: Int = 0) throws -> MTLRenderPipelineState {
            let p = MTLRenderPipelineDescriptor()
            p.vertexFunction = lib.makeFunction(name: v)
            p.fragmentFunction = lib.makeFunction(name: f)
            p.rasterSampleCount = view.sampleCount
            p.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            let c = p.colorAttachments[0]!
            c.pixelFormat = view.colorPixelFormat
            if blend > 0 {
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.destinationRGBBlendFactor = blend == 1 ? .one : .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: p)
        }
        earthPipe = try pipe("earth_v", "earth_f")
        tilePipe = try pipe("tile_v", "tile_f")
        atmoPipe = try pipe("earth_v", "atmo_f", blend: 1)
        starPipe = try pipe("star_v", "star_f", blend: 1)
        particlePipe = try pipe("particle_v", "particle_f", blend: 2)
        iconPipe = try pipe("icon_v", "icon_f", blend: 2)
        markerPipe = try pipe("marker_v", "marker_f", blend: 2)
        linePipeECEF = try pipe("line_ecef_v", "line_f", blend: 2)
        linePipeTEME = try pipe("line_teme_v", "line_f", blend: 2)

        func depth(_ cmp: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = cmp
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthOn = depth(.less, write: true)
        depthRead = depth(.lessEqual, write: false)
        depthOff = depth(.always, write: false)

        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear; s.mipFilter = .linear
        s.sAddressMode = .repeat; s.tAddressMode = .clampToEdge
        s.maxAnisotropy = 16
        sampler = device.makeSamplerState(descriptor: s)
        let i = MTLSamplerDescriptor()
        i.minFilter = .linear; i.magFilter = .linear; i.mipFilter = .linear
        iconSampler = device.makeSamplerState(descriptor: i)
        let ts = MTLSamplerDescriptor()
        ts.minFilter = .linear; ts.magFilter = .linear; ts.mipFilter = .linear
        ts.sAddressMode = .clampToEdge; ts.tAddressMode = .clampToEdge
        ts.maxAnisotropy = 8
        tileSampler = device.makeSamplerState(descriptor: ts)
    }

    private func makeSphere(radius: Float, stacks: Int, slices: Int) -> (MTLBuffer, MTLBuffer, Int) {
        struct V { var x, y, z, pad: Float; var u, v: Float; var p2, p3: Float }
        var verts: [V] = []
        verts.reserveCapacity((stacks + 1) * (slices + 1))
        for i in 0...stacks {
            let v = Float(i) / Float(stacks)
            let lat = (0.5 - v) * .pi
            for j in 0...slices {
                let u = Float(j) / Float(slices)
                let lon = (u - 0.5) * 2 * .pi
                verts.append(V(x: radius * cos(lat) * cos(lon), y: radius * cos(lat) * sin(lon),
                               z: radius * sin(lat), pad: 0, u: u, v: v, p2: 0, p3: 0))
            }
        }
        var idx: [UInt32] = []
        idx.reserveCapacity(stacks * slices * 6)
        let w = UInt32(slices + 1)
        for i in 0..<UInt32(stacks) {
            for j in 0..<UInt32(slices) {
                let a = i * w + j, b = a + w
                idx += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<V>.stride)!
        let ib = device.makeBuffer(bytes: idx, length: idx.count * 4)!
        return (vb, ib, idx.count)
    }

    private func buildGeometry() {
        (sphereV, sphereI, sphereCount) = makeSphere(radius: 1, stacks: 160, slices: 320)
        let cells = 16
        var grid: [SIMD2<Float>] = []
        for j in 0...cells { for i in 0...cells { grid.append(SIMD2(Float(i) / Float(cells), Float(j) / Float(cells))) } }
        var gridIdx: [UInt16] = []
        let row = UInt16(cells + 1)
        for j in 0..<UInt16(cells) {
            for i in 0..<UInt16(cells) {
                let a = j * row + i, b = a + row
                gridIdx += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        tileGrid = device.makeBuffer(bytes: grid, length: grid.count * MemoryLayout<SIMD2<Float>>.stride)
        tileIndices = device.makeBuffer(bytes: gridIdx, length: gridIdx.count * 2)
        tileIndexCount = gridIdx.count
        (atmoV, atmoI, atmoCount) = makeSphere(radius: 1.045, stacks: 90, slices: 180)

        var rng = SystemRandomNumberGenerator()
        var starData: [SIMD4<Float>] = []
        for _ in 0..<starCount {
            let z = Float.random(in: -1...1, using: &rng), t = Float.random(in: 0...(2 * .pi), using: &rng)
            let r = sqrt(1 - z * z)
            let b = pow(Float.random(in: 0...1, using: &rng), 3.5)
            starData.append(SIMD4(r * cos(t), r * sin(t), z, 0.2 + 0.8 * b))
        }
        stars = device.makeBuffer(bytes: starData, length: starData.count * 16)

        // Country outlines, sitting a hair above the surface.
        var lines: [Float] = []
        for c in Countries.shared.all {
            for ring in c.rings {
                var prev: SIMD3<Float>?
                var i = 0
                while i + 1 < ring.count {
                    let lon = ring[i] * .pi / 180, lat = ring[i + 1] * .pi / 180
                    let p = SIMD3<Float>(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat)) * 1.00003
                    if let q = prev { lines += [q.x, q.y, q.z, p.x, p.y, p.z] }
                    prev = p
                    i += 2
                }
            }
        }
        borderCount = lines.count / 3
        if !lines.isEmpty { borders = device.makeBuffer(bytes: lines, length: lines.count * 4) }
    }

    /// Off the main thread, and retried until it works. A failed load used to leave a black Earth
    /// for the rest of the session, for example if the app was replaced while starting up.
    private func loadTextures() {
        icon = rasterizeIcon()
        let loader = MTKTextureLoader(device: device)
        let opts: [MTKTextureLoader.Option: Any] = [.generateMipmaps: true, .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]
        var failuresToFake = Self.failedLoadsForTesting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var loaded: [String: MTLTexture] = [:]
            var attempts = 0
            while loaded.count < 3 {
                guard self != nil else { return }
                attempts += 1
                for name in ["earth_day.jpg", "earth_night.jpg", "earth_water.png"] where loaded[name] == nil {
                    if failuresToFake > 0 { failuresToFake -= 1; continue }
                    guard let u = Res.url(name) else { continue }
                    do { loaded[name] = try loader.newTexture(URL: u, options: opts) }
                    catch { NSLog("Vessel texture \(name), attempt \(attempts): \(error)") }
                }
                if loaded.count < 3 {
                    DispatchQueue.main.async { self?.onTextureProblem?(attempts) }
                    Thread.sleep(forTimeInterval: 1.5)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.day = loaded["earth_day.jpg"]
                self.night = loaded["earth_night.jpg"]
                self.water = loaded["earth_water.png"]
                self.onTexturesReady?()
            }
        }
    }

    /// Renders satellite.svg through AppKit's SVG support into a mipmapped RGBA texture.
    private func rasterizeIcon() -> MTLTexture? {
        guard let u = Res.url("satellite.svg"), let img = NSImage(contentsOf: u) else { return nil }
        let size = 256
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return try? MTKTextureLoader(device: device).newTexture(cgImage: cg, options: [.generateMipmaps: true, .SRGB: false])
    }

    // MARK: - State

    func publish(_ frame: StateFrame) {
        lock.lock(); frameState = frame; lock.unlock()
    }

    private func currentFrame() -> StateFrame? {
        lock.lock(); defer { lock.unlock() }; return frameState
    }

    /// Current Earth-fixed position (Earth radii) of a satellite index, extrapolated to now.
    private func extrapolated(_ f: StateFrame, _ i: Int, now: CFTimeInterval, g: Float) -> SIMD3<Float> {
        let dt = Float(now - f.wallTime)
        let q = f.pos[i] + f.vel[i] * dt
        let c = cos(g), s = sin(g)
        return SIMD3(c * q.x + s * q.y, -s * q.x + c * q.y, q.z)
    }

    private func gmstNow(_ f: StateFrame, now: CFTimeInterval) -> Float {
        Float(Astro.gmst(f.jd + (now - f.wallTime) / 86400))
    }

    /// Screen point (AppKit coordinates, origin bottom-left) of a world point; nil if behind the Earth.
    private func project(_ p: SIMD3<Float>) -> CGPoint? {
        let c = viewProj * SIMD4(p, 1)
        guard c.w > 0 else { return nil }
        let toP = p - eye, len = simd_length(toP), d = toP / len
        let b = simd_dot(eye, d), disc = b * b - (simd_dot(eye, eye) - 1)
        if disc > 0 {
            let t = -b - sqrt(disc)
            if t > 0, t < len { return nil }
        }
        return CGPoint(x: CGFloat((c.x / c.w * 0.5 + 0.5) * viewportPts.x),
                       y: CGFloat((c.y / c.w * 0.5 + 0.5) * viewportPts.y))
    }

    func pick(at point: CGPoint, radius: CGFloat = 9) -> Satellite? {
        guard let f = currentFrame() else { return nil }
        // A large dot can be clicked anywhere on it.
        let radius = max(radius, CGFloat(particlePoints) / 2)
        let now = CACurrentMediaTime()
        let g = gmstNow(f, now: now)
        var best: Int?
        var bestD = Float(radius * radius)
        let px = Float(point.x), py = Float(point.y)
        let halfW = viewportPts.x * 0.5, halfH = viewportPts.y * 0.5
        let dt = Float(now - f.wallTime), c = cos(g), s = sin(g)
        for i in 0..<f.count {
            let q = f.pos[i] + f.vel[i] * dt
            if q.x.isNaN { continue }
            if let filter = orbitFilter, f.sats[i].orbit != filter { continue }
            if f.sats[i].filteredOut { continue }
            let w = SIMD3(c * q.x + s * q.y, -s * q.x + c * q.y, q.z)
            let clip = viewProj * SIMD4(w, 1)
            guard clip.w > 0 else { continue }
            let dx = (clip.x / clip.w + 1) * halfW - px, dy = (clip.y / clip.w + 1) * halfH - py
            let d = dx * dx + dy * dy
            if d < bestD, project(w) != nil { bestD = d; best = i }
        }
        return best.map { f.sats[$0] }
    }

    func screenPoint(norad: Int) -> CGPoint? {
        guard let f = currentFrame(), let i = f.indexByNorad[norad], !f.pos[i].x.isNaN else { return nil }
        let now = CACurrentMediaTime()
        return project(extrapolated(f, i, now: now, g: gmstNow(f, now: now)))
    }

    func lookAt(norad: Int) {
        guard let f = currentFrame(), let i = f.indexByNorad[norad], !f.pos[i].x.isNaN else { return }
        let now = CACurrentMediaTime()
        let n = simd_normalize(extrapolated(f, i, now: now, g: gmstNow(f, now: now)))
        fly(lat: asin(n.z) * 180 / .pi, lon: atan2(n.y, n.x) * 180 / .pi)
    }

    func fly(lat: Float, lon: Float) {
        guard lat.isFinite, lon.isFinite else { return }
        flyTarget = (lon, max(-89, min(89, lat)))
        lonVel = 0; latVel = 0
    }

    func cancelFly() { flyTarget = nil }

    /// Latitude and longitude under a screen point, or nil if the point misses the Earth.
    /// Built from the camera directly, since inverting the matrix loses precision close to the ground.
    func surfacePoint(at point: CGPoint) -> (lat: Double, lon: Double)? {
        let x = 2 * Float(point.x) / viewportPts.x - 1, y = 2 * Float(point.y) / viewportPts.y - 1
        let forward = simd_normalize(-eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 0, 1)))
        let up = simd_cross(right, forward)
        let h = tan(fovY / 2), w = h * viewportPts.x / viewportPts.y
        let dir = simd_normalize(forward + right * (x * w) + up * (y * h))
        let b = simd_dot(eye, dir), disc = b * b - (simd_dot(eye, eye) - 1)
        guard disc >= 0 else { return nil }
        let p = eye + dir * (-b - sqrt(disc))
        return (Double(asin(max(-1, min(1, p.z)))) * 180 / .pi, Double(atan2(p.y, p.x)) * 180 / .pi)
    }

    /// How much streamed imagery shows: none when far out, where the base map is sharp enough.
    private var tileFade: Float {
        guard tilesEnabled else { return 0 }
        return max(0, min(1, (3.6 - distance) / 0.8))
    }

    private func unit(_ lon: Double, _ merc: Double) -> SIMD3<Float> {
        let lat = 2 * atan(exp(merc)) - .pi / 2
        return SIMD3(Float(cos(lat) * cos(lon)), Float(cos(lat) * sin(lon)), Float(sin(lat)))
    }

    private func lonSpan(_ k: TileKey) -> (lon0: Double, dLon: Double, merc0: Double, dMerc: Double) {
        let n = Double(1 << k.z)
        return (Double(k.x) / n * 2 * .pi - .pi, 2 * .pi / n, .pi * (1 - 2 * Double(k.y) / n), 2 * .pi / n)
    }

    /// Walks the tile pyramid from the top, splitting any tile that would appear larger than its
    /// pixels. Ground near the camera gets fine tiles and the far limb coarse ones.
    private func visibleTiles(drawableSize: CGSize) -> [TileKey] {
        var leaves: [TileKey] = []
        var stack = (0..<4).flatMap { x in (0..<4).map { y in TileKey(z: 2, x: x, y: y) } }
        let w = Float(drawableSize.width), h = Float(drawableSize.height)
        let pixelsPerRadian = h / (2 * tan(fovY / 2))
        let n = simd_normalize(eye)
        let nadirLon = Double(atan2(n.y, n.x))
        let nadirLat = Double(asin(n.z))
        let nadirMerc = log(tan(.pi / 4 + nadirLat / 2))
        let samples = 4

        while let k = stack.popLast() {
            let s = lonSpan(k)

            // The tile's nearest point to the camera. Up close the horizon is so near that a large
            // tile's corners can all lie beyond it, even with the camera right above the tile.
            var bestLon = 0.0, bestGap = Double.infinity
            for candidate in [nadirLon, nadirLon - 2 * .pi, nadirLon + 2 * .pi] {
                let c = min(s.lon0 + s.dLon, max(s.lon0, candidate))
                if abs(c - candidate) < bestGap { bestGap = abs(c - candidate); bestLon = c }
            }
            let nearest = unit(bestLon, min(s.merc0, max(s.merc0 - s.dMerc, nadirMerc)))
            guard simd_dot(nearest, eye) > 1 else { continue }

            // Off-screen test, trusted only when every sample is on the camera's side.
            var minX = Float.infinity, maxX = -Float.infinity, minY = Float.infinity, maxY = -Float.infinity
            var complete = true
            for j in 0...samples {
                for i in 0...samples {
                    let p = unit(s.lon0 + Double(i) / Double(samples) * s.dLon, s.merc0 - Double(j) / Double(samples) * s.dMerc)
                    let c = viewProj * SIMD4(p, 1)
                    guard simd_dot(p, eye) > 1, c.w > 1e-5 else { complete = false; continue }
                    let sx = (c.x / c.w * 0.5 + 0.5) * w, sy = (c.y / c.w * 0.5 + 0.5) * h
                    minX = min(minX, sx); maxX = max(maxX, sx)
                    minY = min(minY, sy); maxY = max(maxY, sy)
                }
            }
            if complete, maxX < -32 || minX > w + 32 || maxY < -32 || minY > h + 32 { continue }

            // On-screen size at the nearest point, reduced where the ground is seen at a slant.
            let toEye = eye - nearest
            let range = simd_length(toEye)
            let slant = max(0.25, simd_dot(nearest, toEye / range))
            let groundWidth = Float(s.dLon) * max(0.05, sqrt(1 - nearest.z * nearest.z))
            let size = groundWidth * pixelsPerRadian / range * slant

            if k.z < 3 || (k.z < TileStore.maxZoom && size > 300) {
                for dx in 0...1 { for dy in 0...1 { stack.append(TileKey(z: k.z + 1, x: k.x * 2 + dx, y: k.y * 2 + dy)) } }
            } else {
                leaves.append(k)
                if leaves.count > 300 { break }
            }
        }
        return leaves
    }

    private func drawTiles(_ enc: MTLRenderCommandEncoder, drawableSize: CGSize, fade: Float) {
        tiles.beginFrame()
        let leaves = visibleTiles(drawableSize: drawableSize)
        tilesDrawn = 0
        deepestTile = 0

        var wanted: [(key: TileKey, rank: Float)] = []
        var seen = Set<TileKey>()
        let centre = simd_normalize(eye)
        enc.setRenderPipelineState(tilePipe)
        enc.setDepthStencilState(depthOff)
        enc.setCullMode(.back)
        enc.setVertexBuffer(tileGrid, offset: 0, index: 0)
        enc.setFragmentSamplerState(tileSampler, index: 1)

        for k in leaves {
            let s = lonSpan(k)
            let mid = unit(s.lon0 + s.dLon / 2, s.merc0 - s.dMerc / 2)
            let rank = 1 - simd_dot(mid, centre)
            if tiles.texture(k) == nil, seen.insert(k).inserted { wanted.append((k, rank + Float(k.z) * 1e-3)) }
            // Coarse ancestors first: they arrive quickly and cover the gap until the sharp tile lands.
            if k.z > 5 {
                var a = k
                for _ in 0..<min(3, k.z - 3) { a = a.parent }
                if tiles.texture(a) == nil, seen.insert(a).inserted { wanted.append((a, rank - 1)) }
            }

            // Use this tile, or the nearest loaded ancestor stretched over the same ground.
            var source = k, u0: Float = 0, v0: Float = 0, scale: Float = 1
            var texture = tiles.texture(k)
            while texture == nil, source.z > 2 {
                u0 = (u0 + Float(source.x & 1)) / 2
                v0 = (v0 + Float(source.y & 1)) / 2
                scale /= 2
                source = source.parent
                texture = tiles.texture(source)
            }
            guard let texture else { continue }
            var params = TileParams(lon0: Float(s.lon0), dLon: Float(s.dLon), merc0: Float(s.merc0), dMerc: Float(s.dMerc),
                                    u0: u0, v0: v0, uvScale: scale, fade: fade)
            enc.setVertexBytes(&params, length: MemoryLayout<TileParams>.stride, index: 2)
            enc.setFragmentBytes(&params, length: MemoryLayout<TileParams>.stride, index: 2)
            enc.setFragmentTexture(texture, index: 3)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: tileIndexCount, indexType: .uint16, indexBuffer: tileIndices, indexBufferOffset: 0)
            tilesDrawn += 1
            deepestTile = max(deepestTile, source.z)
        }
        tiles.want(wanted.sorted { $0.rank < $1.rank }.map(\.key))
    }

    /// Where the address marker appears, for checks.
    func screenPoint(lat: Double, lon: Double) -> CGPoint? {
        let la = Float(lat * .pi / 180), lo = Float(lon * .pi / 180)
        // Just above the surface, or rounding can read the point as hidden by the sphere it's on.
        return project(SIMD3(cos(la) * cos(lo), cos(la) * sin(lo), sin(la)) * 1.0005)
    }

    private func aimCamera(at p: SIMD3<Float>) {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite, simd_length(p) > 0.01 else { return }
        let n = simd_normalize(p)
        lon = atan2(n.y, n.x) * 180 / .pi
        lat = asin(n.z) * 180 / .pi
        lonVel = 0; latVel = 0
    }

    private func updateTrack(_ sat: Satellite, jd: Double) {
        // A dedicated propagator: the shared one belongs to the background thread.
        guard trackForNorad != sat.norad || abs(jd - trackJD) > 1.0 / 24 else { return }
        trackForNorad = sat.norad; trackJD = jd
        // A shell position isn't a true distance, so an orbit line through it would be wrong.
        if sat.ephemeris != nil {
            trackCount = 0
            track = nil
            return
        }
        let steps = 360
        let span = sat.periodMinutes / 1440
        var pts: [Float] = []
        pts.reserveCapacity((steps + 1) * 3)
        TrackPropagator.withClone(of: sat) { state in
            for k in 0...steps {
                let t = jd + span * Double(k) / Double(steps)
                guard let r = state(t) else { continue }
                let e = r / Astro.earthRadiusKm
                pts += [Float(e.x), Float(e.y), Float(e.z)]
            }
        }
        trackCount = pts.count / 3
        track = pts.isEmpty ? nil : device.makeBuffer(bytes: pts, length: pts.count * 4)
    }

    // MARK: - Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        let bounds = view.bounds.size
        viewportPts = SIMD2(Float(max(bounds.width, 1)), Float(max(bounds.height, 1)))

        let now = CACurrentMediaTime()
        let f = currentFrame()
        let jd = f.map { $0.jd + (now - $0.wallTime) / 86400 } ?? Astro.julianDate()
        let g = Float(Astro.gmst(jd))

        // One bad number here would lose the Earth for the rest of the session, so it can't stick.
        if !(lon.isFinite && lat.isFinite && distance.isFinite && targetDistance.isFinite && lonVel.isFinite && latVel.isFinite) {
            NSLog("Vessel: camera reset after an invalid value")
            lon = 0; lat = 20; distance = 4.2; targetDistance = 4.2; lonVel = 0; latVel = 0; flyTarget = nil
        }

        // Inertia and smoothed zoom.
        lon += lonVel; lat = max(-89, min(89, lat + latVel))
        lonVel *= 0.93; latVel *= 0.93
        if abs(lonVel) < 0.001 { lonVel = 0 }
        if abs(latVel) < 0.001 { latVel = 0 }
        distance += (targetDistance - distance) * 0.18
        if let target = flyTarget {
            var dLon = (target.lon - lon).truncatingRemainder(dividingBy: 360)
            if dLon > 180 { dLon -= 360 }
            if dLon < -180 { dLon += 360 }
            let dLat = target.lat - lat
            if abs(dLon) < 0.02, abs(dLat) < 0.02 {
                flyTarget = nil
            } else {
                lon += dLon * 0.09
                lat += dLat * 0.09
            }
        }

        var lockedIndex: Int?
        if let n = lockedNorad, let f { lockedIndex = f.indexByNorad[n] }
        if follow, let i = lockedIndex, let f, !f.pos[i].x.isNaN { aimCamera(at: extrapolated(f, i, now: now, g: g)) }

        let la = lat * .pi / 180, lo = lon * .pi / 180
        eye = SIMD3(cos(la) * cos(lo), cos(la) * sin(lo), sin(la)) * distance
        let aspect = viewportPts.x / viewportPts.y
        let proj = Mat.perspective(fovY: fovY, aspect: aspect, near: max(0.0001, (distance - 1) * 0.1), far: 800)
        viewProj = proj * Mat.lookAt(eye: eye, center: .zero, up: SIMD3(0, 0, 1))

        let sun = Astro.sunDirectionECEF(jd: jd)
        // Particles grow gently as you zoom in, so dense shells stay legible when zoomed out.
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        let basePts = max(1.6, min(4.5, 9.0 / pow(distance, 0.75)))
        // Eased, so changing a filter doesn't make every dot jump.
        particleGrowth += (ParticleSize.growth(shown: shownCount, total: totalCount) - particleGrowth) * 0.15
        particlePoints = ParticleSize.points(base: basePts, growth: particleGrowth)
        let ptPx = particlePoints * scale
        var u = Uniforms(viewProj: viewProj, eye: eye, pointSize: ptPx, sun: sun,
                         dt: f.map { Float(now - $0.wallTime) } ?? 0, cosG: cos(g), sinG: sin(g),
                         viewport: viewportPts, time: Float(now.truncatingRemainder(dividingBy: 1000)),
                         filterClass: Int32(orbitFilter?.index ?? -1))

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)

        // Stars.
        enc.setDepthStencilState(depthOff)
        enc.setRenderPipelineState(starPipe)
        enc.setVertexBuffer(stars, offset: 0, index: 0)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starCount)

        // Earth.
        enc.setDepthStencilState(depthOn)
        enc.setCullMode(.back)
        enc.setFrontFacing(.clockwise)
        enc.setRenderPipelineState(earthPipe)
        enc.setVertexBuffer(sphereV, offset: 0, index: 0)
        enc.setFragmentTexture(day, index: 0)
        enc.setFragmentTexture(night, index: 1)
        enc.setFragmentTexture(water, index: 2)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: sphereCount, indexType: .uint32, indexBuffer: sphereI, indexBufferOffset: 0)

        // Streamed imagery over the base map, once close enough to need it.
        let fade = tileFade
        if fade > 0 {
            drawTiles(enc, drawableSize: view.drawableSize, fade: fade)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        }

        // Atmosphere: only the far side of a larger shell, so the halo wraps the limb.
        enc.setDepthStencilState(depthRead)
        enc.setCullMode(.front)
        enc.setRenderPipelineState(atmoPipe)
        enc.setVertexBuffer(atmoV, offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: atmoCount, indexType: .uint32, indexBuffer: atmoI, indexBufferOffset: 0)
        enc.setCullMode(.none)

        // Borders fade out with distance.
        if let borders, borderCount > 0 {
            var c = SIMD4<Float>(1, 1, 1, 0.07 + 0.2 * max(0, 1 - (distance - 1) / 4))
            c = SIMD4(c.x * c.w, c.y * c.w, c.z * c.w, c.w)
            enc.setRenderPipelineState(linePipeECEF)
            enc.setVertexBuffer(borders, offset: 0, index: 0)
            enc.setVertexBytes(&c, length: 16, index: 2)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: borderCount)
        }

        if let f {
            // Orbit track of the locked satellite.
            if let i = lockedIndex {
                updateTrack(f.sats[i], jd: jd)
                if let track, trackCount > 1 {
                    let col = Palette.color(f.sats[i].orbit)
                    var c = SIMD4(col.x * 0.75, col.y * 0.75, col.z * 0.75, 0.75)
                    enc.setRenderPipelineState(linePipeTEME)
                    enc.setVertexBuffer(track, offset: 0, index: 0)
                    enc.setVertexBytes(&c, length: 16, index: 2)
                    enc.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: trackCount)
                }
            }

            // All particles.
            // The icon replaces a locked satellite's dot, which could otherwise be as large as the icon.
            var drawn = u
            drawn.lockedIndex = icon == nil ? -1 : Int32(lockedIndex ?? -1)
            enc.setVertexBytes(&drawn, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setRenderPipelineState(particlePipe)
            enc.setVertexBuffer(f.buffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: f.count)

            // Hovered particle gets a larger dot in its own colour.
            if let n = hoveredNorad, n != lockedNorad, let i = f.indexByNorad[n] {
                var big = u; big.pointSize = min(ptPx * 2.6, ParticleSize.iconPoints * scale); big.lockedIndex = -1
                enc.setVertexBytes(&big, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setVertexBufferOffset(i * MemoryLayout<ParticleVertex>.stride, index: 0)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            }

            // The locked satellite becomes the SVG icon, keeping its colour.
            if let i = lockedIndex, let icon, !f.pos[i].x.isNaN {
                let p = extrapolated(f, i, now: now, g: g)
                let col = Palette.color(f.sats[i].orbit)
                var ic = IconUniforms(px: p.x, py: p.y, pz: p.z, size: 36, color: col)
                enc.setRenderPipelineState(iconPipe)
                enc.setVertexBytes(&ic, length: MemoryLayout<IconUniforms>.stride, index: 0)
                enc.setFragmentBytes(&ic, length: MemoryLayout<IconUniforms>.stride, index: 0)
                enc.setFragmentTexture(icon, index: 0)
                enc.setFragmentSamplerState(iconSampler, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        // The spot the host list is narrowed to.
        if var spot = regionPoint {
            var mark = u
            mark.pointSize = 58 * scale
            mark.regionMarker = 1
            enc.setDepthStencilState(depthOff)
            enc.setRenderPipelineState(markerPipe)
            enc.setVertexBytes(&spot, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
            enc.setVertexBytes(&mark, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&mark, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        }

        // Selected address.
        if var st = stationPoint {
            var mark = u
            mark.pointSize = 58 * scale
            enc.setDepthStencilState(depthOff)
            enc.setRenderPipelineState(markerPipe)
            enc.setVertexBytes(&st, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
            enc.setVertexBytes(&mark, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&mark, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        }

        enc.endEncoding()
        if let capture = captureNext {
            captureNext = nil
            let tex = drawable.texture
            cmd.addCompletedHandler { _ in
                DispatchQueue.main.async { capture(Self.image(from: tex)) }
            }
        }
        cmd.present(drawable)
        cmd.commit()
        framesDrawn &+= 1
        onDrawn?()
    }
}

struct IconUniforms {
    var px, py, pz, size: Float
    var color: SIMD4<Float>
    init(px: Float, py: Float, pz: Float, size: Float, color: SIMD4<Float>) {
        self.px = px; self.py = py; self.pz = pz; self.size = size; self.color = color
    }
}

/// Stateless one-off propagation for tracks and pass prediction: rebuilds elements so it
/// never touches the record the background ticker is stepping.
enum TrackPropagator {
    static func withClone(of sat: Satellite, _ body: ((Double) -> SIMD3<Double>?) -> Void) {
        guard let c = sat.clone() else { return }
        body { jd in c.state(jd: jd)?.r }
    }
}

enum Mat {
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5), x = y / aspect, z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }
}
